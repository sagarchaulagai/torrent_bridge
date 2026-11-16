import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../models/debrid_models.dart';
import '../models/streaming_models.dart';
import 'audio_disk_cache_service.dart';
import 'server_settings_service.dart';

typedef UpstreamOpener = Future<HttpClientResponse> Function(
  StreamingSession session, {
  required String method,
  String? rangeHeader,
  void Function(void Function())? attachAbort,
});

typedef UpstreamStallHandler = Future<void> Function(
  StreamingSession session, {
  required int failedOffset,
  required bool seemsStuckAtZero,
});

typedef StreamLogFn = void Function(String message);

/// Manages intelligent byte-range fetching, seek superseding, rapid-scrub
/// coalescing, piece-aligned sliding windows, stall recovery, and lookahead
/// disk buffering for a single [StreamingSession].
class SessionStreamCoordinator {
  static const int _initialSeekWindowBytes = 1024 * 1024; // 1 MB
  static const int _steadyWindowBytes = 2 * 1024 * 1024; // 2 MB
  static const int _maxPieceAlignedWindowBytes = 4 * 1024 * 1024; // 4 MB
  static const int _headWarmupBytes = 512 * 1024; // 512 KB
  static const int _tailWarmupBytes = 256 * 1024; // 256 KB
  static const Duration _rapidScrubDebounce = Duration(milliseconds: 110);
  static const Duration _p2pFirstByteTimeout = Duration(seconds: 12);
  static const Duration _debridFirstByteTimeout = Duration(seconds: 18);

  final StreamingSession session;
  final UpstreamOpener openUpstream;
  final UpstreamStallHandler? onUpstreamStall;
  final StreamLogFn? log;

  bool _disposed = false;
  int _playbackGeneration = 0;
  int _lastSeekRequestMs = 0;
  int? _lastPlaybackTargetOffset;
  int _downstreamCursor = 0;
  int _chunkEventSeq = 0;

  _ActiveUpstreamToken? _activePlaybackFetch;
  _ActiveUpstreamToken? _activeWarmupFetch;

  final StreamController<void> _chunkSignalCtrl =
      StreamController<void>.broadcast();
  final StreamController<void> _cursorSignalCtrl =
      StreamController<void>.broadcast();

  SessionStreamCoordinator({
    required this.session,
    required this.openUpstream,
    this.onUpstreamStall,
    this.log,
  });

  bool get isDisposed => _disposed;

  void notifyCursor(int cursor) {
    _downstreamCursor = cursor;
    if (!_cursorSignalCtrl.isClosed) {
      _cursorSignalCtrl.add(null);
    }
  }

  /// Classifies small bounded header/tail probes so they don't abort or collide
  /// with main playback seeks unless needed.
  bool isProbeRequest(int reqStart, int reqEnd) {
    final len = reqEnd - reqStart + 1;
    final fs = session.fileSize;
    if (fs <= 0) return false;
    if (len <= 256 * 1024 && reqStart == 0 && reqEnd < fs - 1) {
      return true;
    }
    if (fs > 2 * 1024 * 1024 &&
        len <= 256 * 1024 &&
        reqStart >= fs - 256 * 1024) {
      return true;
    }
    return false;
  }

  /// Streams `[reqStart, reqEnd]` inclusive with full downstream backpressure,
  /// serving cached spans directly from disk and filling uncached spans via
  /// bounded sliding-window upstream fetches.
  Stream<List<int>> streamRange(
    int reqStart,
    int reqEnd, {
    required void Function(int bytes)? onBytesYielded,
  }) async* {
    if (_disposed || reqStart < 0 || reqEnd < reqStart) return;

    final cacheSvc = AudioDiskCacheService.instance;
    final isProbe = isProbeRequest(reqStart, reqEnd);
    final reqLen = reqEnd - reqStart + 1;
    final isContinuousPlayback = !isProbe &&
        (reqLen > 512 * 1024 ||
            (session.fileSize > 1024 * 1024 && reqEnd >= session.fileSize - 1));

    var myGen = _playbackGeneration;
    _ActiveUpstreamToken? localToken;
    Object? pipelineError;
    var pipelineDone = false;

    if (!isProbe) {
      myGen = ++_playbackGeneration;
      _activeWarmupFetch?.cancel();
      _activeWarmupFetch = null;
      _activePlaybackFetch?.cancel();
      notifyCursor(reqStart);

      localToken = _ActiveUpstreamToken();
      _activePlaybackFetch = localToken;
    } else {
      // If a probe hits a cache miss, stop any background warmup first so it
      // never competes with the probe on the native stream.
      localToken = _ActiveUpstreamToken();
    }

    // Check if the start of the seek is already cached on disk.
    final entryAtStart = cacheSvc.getEntry(session.infoHash, session.fileIndex);
    final startsCached = entryAtStart?.findCoveringRange(reqStart) != null;

    // Coalesce rapid scrubbing on uncached seeks so dragging a seek slider
    // doesn't queue multiple conflicting upstream seeks in libtorrent.
    if (!isProbe && !startsCached) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final isRapidScrub = _lastPlaybackTargetOffset != null &&
          (nowMs - _lastSeekRequestMs) < 180 &&
          (reqStart - _lastPlaybackTargetOffset!).abs() > 65536;
      _lastSeekRequestMs = nowMs;
      _lastPlaybackTargetOffset = reqStart;

      if (isRapidScrub) {
        await Future<void>.delayed(_rapidScrubDebounce);
        if (_disposed || localToken.isCancelled || _playbackGeneration != myGen) {
          return;
        }
      }
    } else if (!isProbe) {
      _lastSeekRequestMs = DateTime.now().millisecondsSinceEpoch;
      _lastPlaybackTargetOffset = reqStart;
    }

    // Start upstream pipeline if any bytes inside [reqStart, reqEnd] are missing
    // (or if continuous playback needs lookahead beyond cached islands).
    final hasAnyMissingInReq = entryAtStart == null ||
        entryAtStart.findMissingRanges(reqStart, reqEnd).isNotEmpty;

    if (hasAnyMissingInReq) {
      if (isProbe) {
        _activeWarmupFetch?.cancel();
        _activeWarmupFetch = null;
      }
      // Launch background upstream downloader for this range
      unawaited(
        _runUpstreamPipeline(
          reqStart: reqStart,
          reqEnd: reqEnd,
          isContinuousPlayback: isContinuousPlayback,
          isProbe: isProbe,
          generation: isProbe ? null : myGen,
          token: localToken,
        ).then(
          (_) {
            pipelineDone = true;
            _signalChunk();
          },
          onError: (Object err, StackTrace st) {
            pipelineError = err;
            pipelineDone = true;
            _signalChunk();
          },
        ),
      );
    } else {
      pipelineDone = true;
      // Even on a pure cache hit, proactively warm upcoming bytes beyond reqEnd
      // when serving bounded sequential chunks of a larger audio file.
      if (isContinuousPlayback &&
          reqEnd < session.fileSize - 1) {
        final lookaheadEnd = math.min(
          session.fileSize - 1,
          reqEnd + ServerSettingsService.instance.readAheadBufferBytes,
        );
        final nextMissing = entryAtStart.findNextMissingRangeAfter(
          reqEnd + 1,
          maxEnd: lookaheadEnd,
        );
        if (nextMissing != null) {
          unawaited(
            _runUpstreamPipeline(
              reqStart: nextMissing.start,
              reqEnd: lookaheadEnd,
              isContinuousPlayback: true,
              isProbe: false,
              generation: myGen,
              token: localToken,
            ).catchError((_) {}),
          );
        }
      }
    }

    var cursor = reqStart;
    try {
      while (cursor <= reqEnd && !_disposed && !localToken.isCancelled) {
        if (!isProbe && _playbackGeneration != myGen) {
          break;
        }

        final seqBeforeCheck = _chunkEventSeq;
        final cacheEntry =
            cacheSvc.getEntry(session.infoHash, session.fileIndex);
        final covering = cacheEntry?.findCoveringRange(cursor);

        if (covering != null && cacheEntry != null) {
          final segEnd = math.min(covering.end, reqEnd);
          await for (final chunk in cacheSvc.openCachedRangeStream(
            cacheEntry.key,
            cursor,
            segEnd,
          )) {
            if (_disposed ||
                localToken.isCancelled ||
                (!isProbe && _playbackGeneration != myGen)) {
              return;
            }
            yield chunk;
            cursor += chunk.length;
            onBytesYielded?.call(chunk.length);
            if (!isProbe) {
              notifyCursor(cursor);
            }
          }
          continue;
        }

        // Wait for upstream pipeline to write bytes covering `cursor`.
        if (pipelineError != null) {
          throw pipelineError!;
        }
        if (pipelineDone) {
          // Re-check once in case last write finished just before pipelineDone
          final recheck =
              cacheSvc.getEntry(session.infoHash, session.fileIndex);
          if (recheck?.findCoveringRange(cursor) != null) {
            continue;
          }
          throw StateError(
            'Stream ended before offset $cursor could be fetched.',
          );
        }

        if (_chunkEventSeq == seqBeforeCheck) {
          await _waitForChunkOrTimeout(const Duration(milliseconds: 300));
        }
      }
    } finally {
      // If downstream client closed/sought away, immediately abort upstream!
      localToken.cancel();
      if (!isProbe && identical(_activePlaybackFetch, localToken)) {
        _activePlaybackFetch = null;
      }
    }
  }

  /// Schedules non-blocking head (512 KB) & tail (256 KB) warmup into
  /// [AudioDiskCacheService] when no active playback fetch is competing.
  void scheduleHeadTailWarmup() {
    if (_disposed || session.fileSize <= 0) return;
    if (!ServerSettingsService.instance.fastAudioPreload) return;
    if (_activePlaybackFetch != null || _activeWarmupFetch != null) return;

    final cacheSvc = AudioDiskCacheService.instance;
    final entry = cacheSvc.getEntry(session.infoHash, session.fileIndex);
    if (entry != null && entry.isComplete) return;

    final headEnd = math.min(session.fileSize - 1, _headWarmupBytes - 1);
    final tailStart = math.max(0, session.fileSize - _tailWarmupBytes);
    final tailEnd = session.fileSize - 1;

    final headMissing =
        entry == null ? [ByteRange(0, headEnd)] : entry.findMissingRanges(0, headEnd);
    final tailMissing = entry == null
        ? (tailStart > headEnd ? [ByteRange(tailStart, tailEnd)] : const <ByteRange>[])
        : entry.findMissingRanges(tailStart, tailEnd);

    if (headMissing.isEmpty && tailMissing.isEmpty) return;

    final token = _ActiveUpstreamToken();
    _activeWarmupFetch = token;

    unawaited(() async {
      try {
        for (final gap in [...headMissing, ...tailMissing]) {
          if (_disposed ||
              token.isCancelled ||
              _activePlaybackFetch != null) {
            break;
          }
          await _fetchWindowIntoCache(
            gap.start,
            gap.end,
            token: token,
            generation: null,
            maxRetries: 1,
          );
        }
      } catch (_) {
        // Warmup is best-effort; never surface background warmup errors
      } finally {
        if (identical(_activeWarmupFetch, token)) {
          _activeWarmupFetch = null;
        }
      }
    }());
  }

  Future<void> _runUpstreamPipeline({
    required int reqStart,
    required int reqEnd,
    required bool isContinuousPlayback,
    required bool isProbe,
    required int? generation,
    required _ActiveUpstreamToken token,
  }) async {
    final cacheSvc = AudioDiskCacheService.instance;
    var cursor = reqStart;
    var isFirstWindow = true;

    while (cursor <= reqEnd && !_disposed && !token.isCancelled) {
      if (generation != null && _playbackGeneration != generation) return;

      final cacheEntry = cacheSvc.getEntry(session.infoHash, session.fileIndex);
      final cov = cacheEntry?.findCoveringRange(cursor);
      if (cov != null) {
        cursor = cov.end + 1;
        continue;
      }

      // If continuous playback is running ahead of the player, pause upstream
      // once the configured read-ahead buffer ahead of `_downstreamCursor` is full.
      if (isContinuousPlayback && !isProbe) {
        final readAheadBudget =
            ServerSettingsService.instance.readAheadBufferBytes;
        while (!_disposed &&
            !token.isCancelled &&
            (generation == null || _playbackGeneration == generation) &&
            (cursor - _downstreamCursor) >= readAheadBudget) {
          await _waitForCursorAdvance(const Duration(milliseconds: 500));
        }
        if (_disposed ||
            token.isCancelled ||
            (generation != null && _playbackGeneration != generation)) {
          return;
        }
      }

      // Compute bounded sliding window [wStart, wEnd]
      final wStart = cursor;
      final nextCached = cacheEntry?.findNextCachedRangeAfter(wStart);
      final maxWindowEnd = nextCached != null
          ? math.min(nextCached.start - 1, reqEnd)
          : reqEnd;

      if (maxWindowEnd < wStart) {
        cursor = nextCached != null ? nextCached.end + 1 : reqEnd + 1;
        continue;
      }

      int wEnd;
      if (isProbe) {
        wEnd = maxWindowEnd;
      } else {
        final targetSpan =
            isFirstWindow ? _initialSeekWindowBytes : _steadyWindowBytes;
        wEnd = math.min(maxWindowEnd, wStart + targetSpan - 1);

        // Snap window end to torrent piece boundary when piece geometry is known
        // and piece size is reasonable, so completed pieces align cleanly.
        if (cacheEntry != null &&
            cacheEntry.hasPieceGeometry &&
            cacheEntry.pieceLength <= _maxPieceAlignedWindowBytes) {
          final aligned = cacheEntry.alignEndToPieceBoundary(wEnd);
          if (aligned >= wEnd &&
              aligned <= maxWindowEnd &&
              (aligned - wStart + 1) <= _maxPieceAlignedWindowBytes) {
            wEnd = aligned;
          }
        }
      }

      final fetchedUpTo = await _fetchWindowIntoCache(
        wStart,
        wEnd,
        token: token,
        generation: generation,
        maxRetries: isProbe ? 1 : 3,
      );

      if (fetchedUpTo < wStart) {
        return;
      }

      cursor = fetchedUpTo + 1;
      isFirstWindow = false;
    }
  }

  /// Fetches `[wStart, wEnd]` into [AudioDiskCacheService] with stall detection
  /// and retry recovery. Returns the highest offset successfully written.
  Future<int> _fetchWindowIntoCache(
    int wStart,
    int wEnd, {
    required _ActiveUpstreamToken token,
    required int? generation,
    required int maxRetries,
  }) async {
    final cacheSvc = AudioDiskCacheService.instance;
    var currentStart = wStart;
    var attempts = 0;

    while (currentStart <= wEnd && !_disposed && !token.isCancelled) {
      if (generation != null && _playbackGeneration != generation) {
        return currentStart - 1;
      }

      attempts++;
      var gotAnyByteThisAttempt = false;
      Timer? firstByteWatchdog;
      HttpClientResponse? upstreamRes;
      StreamSubscription<List<int>>? sub;
      var writeLockAcquired = false;
      String? lockedKey;

      try {
        final resFuture = openUpstream(
          session,
          method: 'GET',
          rangeHeader: 'bytes=$currentStart-$wEnd',
          attachAbort: token.attachAbort,
        );
        upstreamRes = await resFuture;

        if (_disposed ||
            token.isCancelled ||
            (generation != null && _playbackGeneration != generation)) {
          await upstreamRes.drain<void>().catchError((_) {});
          return currentStart - 1;
        }

        DiskCacheEntry? cacheEntry = cacheSvc.getEntry(
          session.infoHash,
          session.fileIndex,
        );
        if (cacheEntry == null &&
            cacheSvc.isInitialized &&
            session.fileSize > 0) {
          cacheEntry = await cacheSvc.ensureEntry(
            infoHash: session.infoHash,
            fileIndex: session.fileIndex,
            torrentName: session.torrentName,
            fileName: session.fileName,
            filePath: session.filePath,
            mimeType: session.mimeType,
            fileSize: session.fileSize,
          );
        }

        if (cacheEntry != null) {
          cacheSvc.acquireWriteLock(cacheEntry.key);
          writeLockAcquired = true;
          lockedKey = cacheEntry.key;
        }

        var upstreamPos = _resolveUpstreamStartOffset(
          upstreamRes,
          fallbackStart: currentStart,
        );

        final completer = Completer<void>();
        final timeoutDur = session.isDebridStream
            ? _debridFirstByteTimeout
            : _p2pFirstByteTimeout;

        void resetWatchdog() {
          firstByteWatchdog?.cancel();
          firstByteWatchdog = Timer(timeoutDur, () {
            if (!completer.isCompleted) {
              completer.completeError(
                TimeoutException(
                  'Upstream stalled at offset $currentStart for ${timeoutDur.inSeconds}s',
                ),
              );
            }
          });
        }

        resetWatchdog();

        sub = upstreamRes.listen(
          (chunk) async {
            if (chunk.isEmpty) return;
            if (_disposed ||
                token.isCancelled ||
                (generation != null && _playbackGeneration != generation)) {
              if (!completer.isCompleted) completer.complete();
              return;
            }

            sub?.pause();
            try {
              resetWatchdog();

              final chunkStart = upstreamPos;
              final chunkEnd = upstreamPos + chunk.length - 1;
              upstreamPos += chunk.length;

              if (chunkEnd < currentStart) return;
              if (chunkStart > wEnd) {
                if (!completer.isCompleted) completer.complete();
                return;
              }

              final sliceStart = math.max(0, currentStart - chunkStart);
              final sliceEndExclusive = math.min(
                chunk.length,
                wEnd - chunkStart + 1,
              );
              if (sliceEndExclusive <= sliceStart) return;

              final effectiveChunk =
                  (sliceStart == 0 && sliceEndExclusive == chunk.length)
                      ? chunk
                      : chunk.sublist(sliceStart, sliceEndExclusive);
              final writeOffset = chunkStart + sliceStart;

              final activeEntry = cacheEntry;
              if (activeEntry != null) {
                await cacheSvc.writeChunk(
                  activeEntry.key,
                  writeOffset,
                  effectiveChunk,
                  totalFileSize: session.fileSize > 0 ? session.fileSize : null,
                );
                session.cachedBytes = activeEntry.cachedBytes;
                session.cachedPercentage = activeEntry.cachedPercentage;
                session.isCached = activeEntry.isComplete;
              }

              gotAnyByteThisAttempt = true;
              currentStart = writeOffset + effectiveChunk.length;
              _signalChunk();

              if (currentStart > wEnd && !completer.isCompleted) {
                completer.complete();
              }
            } catch (e, st) {
              if (!completer.isCompleted) {
                completer.completeError(e, st);
              }
            } finally {
              if (!completer.isCompleted &&
                  !_disposed &&
                  !token.isCancelled) {
                sub?.resume();
              }
            }
          },
          onError: (Object err, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(err, st);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

        token.attachAbort(() {
          firstByteWatchdog?.cancel();
          sub?.cancel().catchError((_) {});
          if (!completer.isCompleted) completer.complete();
        });

        await completer.future;
      } on DebridException {
        rethrow;
      } catch (e) {
        if (_disposed ||
            token.isCancelled ||
            (generation != null && _playbackGeneration != generation)) {
          return currentStart - 1;
        }

        if (attempts > maxRetries) {
          rethrow;
        }

        log?.call(
          'Recovering stalled seek/fetch for ${session.fileName} at byte $currentStart (attempt $attempts/$maxRetries): $e',
        );

        final stuckAtZero = !gotAnyByteThisAttempt &&
            !session.isDebridStream &&
            (session.latestNativeInfo?.readHead ?? 0) == 0 &&
            currentStart > 512 * 1024;
        if (onUpstreamStall != null) {
          await onUpstreamStall!(
            session,
            failedOffset: currentStart,
            seemsStuckAtZero: stuckAtZero,
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * attempts));
      } finally {
        firstByteWatchdog?.cancel();
        try {
          await sub?.cancel();
        } catch (_) {}
        if (writeLockAcquired && lockedKey != null) {
          await cacheSvc.releaseWriteLock(lockedKey);
          final updated = cacheSvc.getEntryByKey(lockedKey);
          if (updated != null) {
            session.cachedBytes = updated.cachedBytes;
            session.cachedPercentage = updated.cachedPercentage;
            session.isCached = updated.isComplete;
          }
        }
      }

      // If upstream returned EOF early without delivering bytes and without throwing,
      // avoid infinite spin.
      if (!gotAnyByteThisAttempt && attempts > maxRetries) {
        break;
      }
      if (gotAnyByteThisAttempt && currentStart <= wEnd) {
        // Continue seamlessly from currentStart
        attempts = math.max(0, attempts - 1);
      } else if (!gotAnyByteThisAttempt) {
        // Trigger stall recovery if stream returned empty early
        if (attempts > maxRetries) break;
        final stuckAtZero = !session.isDebridStream &&
            (session.latestNativeInfo?.readHead ?? 0) == 0 &&
            currentStart > 512 * 1024;
        if (onUpstreamStall != null) {
          await onUpstreamStall!(
            session,
            failedOffset: currentStart,
            seemsStuckAtZero: stuckAtZero,
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * attempts));
      }
    }

    return currentStart - 1;
  }

  static int _resolveUpstreamStartOffset(
    HttpClientResponse upstreamRes, {
    required int fallbackStart,
  }) {
    final cr = upstreamRes.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) {
      final m = RegExp(
        r'bytes\s+(\d+)-(\d+)/(\d+|\*)',
        caseSensitive: false,
      ).firstMatch(cr);
      if (m != null) {
        final parsed = int.tryParse(m.group(1) ?? '');
        if (parsed != null && parsed >= 0) return parsed;
      }
    }
    if (upstreamRes.statusCode == HttpStatus.ok) {
      return 0;
    }
    return fallbackStart;
  }

  void _signalChunk() {
    _chunkEventSeq++;
    if (!_chunkSignalCtrl.isClosed) {
      _chunkSignalCtrl.add(null);
    }
  }

  Future<void> _waitForChunkOrTimeout(Duration timeout) async {
    if (_chunkSignalCtrl.isClosed) return;
    try {
      await _chunkSignalCtrl.stream.first.timeout(timeout);
    } catch (_) {}
  }

  Future<void> _waitForCursorAdvance(Duration timeout) async {
    if (_cursorSignalCtrl.isClosed) return;
    try {
      await _cursorSignalCtrl.stream.first.timeout(timeout);
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeWarmupFetch?.cancel();
    _activePlaybackFetch?.cancel();
    _activeWarmupFetch = null;
    _activePlaybackFetch = null;
    if (!_chunkSignalCtrl.isClosed) {
      _chunkSignalCtrl.close();
    }
    if (!_cursorSignalCtrl.isClosed) {
      _cursorSignalCtrl.close();
    }
  }
}

class _ActiveUpstreamToken {
  bool _cancelled = false;
  final List<void Function()> _abortCallbacks = [];

  bool get isCancelled => _cancelled;

  void attachAbort(void Function() fn) {
    if (_cancelled) {
      try {
        fn();
      } catch (_) {}
      return;
    }
    _abortCallbacks.add(fn);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final fn in _abortCallbacks) {
      try {
        fn();
      } catch (_) {}
    }
    _abortCallbacks.clear();
  }
}
