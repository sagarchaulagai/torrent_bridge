import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';

import '../models/streaming_models.dart';
import 'server_settings_service.dart';

/// Service managing the native `libtorrent_flutter` engine lifecycle,
/// torrent metadata resolution, file inspection, and native stream creation.
class TorrentEngineService extends ChangeNotifier {
  static final TorrentEngineService instance = TorrentEngineService._();
  TorrentEngineService._();

  bool _initializing = false;
  String? _lastError;
  String _savePath = '';
  int? _primaryTorrentId;
  bool _hadTorrents = false;
  bool _hadStreams = false;

  /// Maps normalized 40-char infohash (or normalized magnet URI) -> torrentId
  final Map<String, int> _infoHashToTorrentId = {};
  final Map<int, String> _torrentIdToInfoHash = {};
  final Map<int, String> _torrentIdToMagnet = {};

  /// Cache of discovered file sizes from startStream when FileInfo.size is 0
  final Map<String, int> _knownFileSizes = {};

  /// Cached file lists per torrentId once metadata is available
  final Map<int, List<AudioFileEntry>> _cachedFiles = {};

  StreamSubscription<Map<int, TorrentInfo>>? _torrentSub;
  StreamSubscription<Map<int, StreamInfo>>? _streamSub;

  bool get isInitialized => LibtorrentFlutter.isInitialized;
  bool get isInitializing => _initializing;
  String? get lastError => _lastError;
  String get savePath => _savePath;
  int? get primaryTorrentId => _primaryTorrentId;

  String get libraryVersion {
    if (!LibtorrentFlutter.isInitialized) return 'Uninitialized';
    try {
      return LibtorrentFlutter.instance.libraryVersion;
    } catch (_) {
      return '2.0.0';
    }
  }

  Map<int, TorrentInfo> get torrents =>
      LibtorrentFlutter.isInitialized ? LibtorrentFlutter.instance.torrents : {};

  Map<int, StreamInfo> get streams =>
      LibtorrentFlutter.isInitialized ? LibtorrentFlutter.instance.streams : {};

  Stream<Map<int, TorrentInfo>> get torrentUpdates =>
      LibtorrentFlutter.isInitialized
          ? LibtorrentFlutter.instance.torrentUpdates
          : const Stream.empty();

  Stream<Map<int, StreamInfo>> get streamUpdates =>
      LibtorrentFlutter.isInitialized
          ? LibtorrentFlutter.instance.streamUpdates
          : const Stream.empty();

  /// Initialize the native `libtorrent_flutter` session.
  Future<void> ensureInitialized() async {
    if (LibtorrentFlutter.isInitialized) return;
    if (_initializing) {
      while (_initializing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (LibtorrentFlutter.isInitialized) return;
    }

    _initializing = true;
    _lastError = null;
    notifyListeners();

    try {
      await ServerSettingsService.instance.init();
      _savePath = ServerSettingsService.instance.cachePath;

      await LibtorrentFlutter.init(
        defaultSavePath: _savePath,
        fetchTrackers: true,
        pollInterval: const Duration(milliseconds: 400),
      );

      _attachListeners();
      _lastError = null;
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  void _attachListeners() {
    _torrentSub?.cancel();
    _streamSub?.cancel();
    if (!LibtorrentFlutter.isInitialized) return;

    final engine = LibtorrentFlutter.instance;
    _torrentSub = engine.torrentUpdates.listen((torrentMap) {
      final hasAny = torrentMap.isNotEmpty;
      if (hasAny || _hadTorrents) {
        _hadTorrents = hasAny;
        notifyListeners();
      }
    });
    _streamSub = engine.streamUpdates.listen((streamMap) {
      for (final s in streamMap.values) {
        if (s.fileSize > 0) {
          final key = '${s.torrentId}:${s.fileIndex}';
          if (_knownFileSizes[key] != s.fileSize) {
            _knownFileSizes[key] = s.fileSize;
            _cachedFiles.remove(s.torrentId);
          }
        }
      }
      final hasAny = streamMap.isNotEmpty;
      if (hasAny || _hadStreams) {
        _hadStreams = hasAny;
        notifyListeners();
      }
    });
  }

  /// Normalizes either a magnet link or a bare infohash into a valid magnet URI.
  static String normalizeToMagnetUri(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Magnet link or infohash cannot be empty.');
    }
    if (trimmed.toLowerCase().startsWith('magnet:?')) {
      return trimmed;
    }
    // Check for 40-char hex SHA-1 infohash or 32-char base32 infohash
    final hexHash = RegExp(r'^[0-9a-fA-F]{40}$');
    final base32Hash = RegExp(r'^[A-Za-z2-7]{32}$');
    if (hexHash.hasMatch(trimmed) || base32Hash.hasMatch(trimmed)) {
      return 'magnet:?xt=urn:btih:${trimmed.toLowerCase()}';
    }
    throw ArgumentError(
      'Invalid input: expected a magnet:?xt=urn:btih:... URI or 40-character hex infohash.',
    );
  }

  /// Extracts the lowercase infohash from a magnet URI or raw infohash string.
  static String extractInfoHash(String input) {
    final trimmed = input.trim();
    final hexHash = RegExp(r'^[0-9a-fA-F]{40}$');
    if (hexHash.hasMatch(trimmed)) {
      return trimmed.toLowerCase();
    }
    final match = RegExp(
      r'xt=urn:btih:([0-9a-fA-F]{40}|[A-Za-z2-7]{32})',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match != null) {
      return match.group(1)!.toLowerCase();
    }
    return trimmed.toLowerCase();
  }

  String? getInfoHashForTorrent(int torrentId) =>
      _torrentIdToInfoHash[torrentId];

  String? getMagnetForTorrent(int torrentId) => _torrentIdToMagnet[torrentId];

  /// Adds a torrent by magnet link or infohash, or returns the existing torrent ID
  /// if it was already added to the session.
  ///
  /// Uses `streamOnly: true` by default so unselected files are never downloaded.
  Future<int> addOrGetTorrent(
    String magnetOrInfoHash, {
    bool streamOnly = true,
  }) async {
    await ensureInitialized();
    final magnetUri = normalizeToMagnetUri(magnetOrInfoHash);
    final infoHash = extractInfoHash(magnetUri);

    final existingId = _infoHashToTorrentId[infoHash];
    if (existingId != null &&
        LibtorrentFlutter.instance.torrents.containsKey(existingId)) {
      return existingId;
    }

    final id = LibtorrentFlutter.instance.addMagnet(
      magnetUri,
      _savePath,
      streamOnly,
    );
    _infoHashToTorrentId[infoHash] = id;
    _torrentIdToInfoHash[id] = infoHash;
    _torrentIdToMagnet[id] = magnetUri;
    notifyListeners();
    return id;
  }

  /// Waits until `hasMetadata == true` for [torrentId].
  Future<TorrentInfo> waitForMetadata(
    int torrentId, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    await ensureInitialized();
    final engine = LibtorrentFlutter.instance;

    final current = engine.torrents[torrentId];
    if (current != null && current.hasMetadata) {
      return current;
    }

    final completer = Completer<TorrentInfo>();
    Timer? timer;
    StreamSubscription<Map<int, TorrentInfo>>? sub;

    void checkTorrent(Map<int, TorrentInfo> map) {
      final info = map[torrentId];
      if (info == null) return;
      if (info.state == TorrentState.error && info.errorMsg.isNotEmpty) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Torrent error: ${info.errorMsg}'),
          );
        }
        return;
      }
      if (info.hasMetadata && !completer.isCompleted) {
        completer.complete(info);
      }
    }

    sub = engine.torrentUpdates.listen(checkTorrent);
    // Also check snapshot periodically in case metadata arrived between polls
    final pollCheck = Timer.periodic(const Duration(milliseconds: 300), (_) {
      checkTorrent(engine.torrents);
      if (!completer.isCompleted &&
          engine.getFiles(torrentId).isNotEmpty &&
          engine.torrents[torrentId] != null) {
        completer.complete(engine.torrents[torrentId]!);
      }
    });

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException(
            'Timed out waiting for torrent metadata after ${timeout.inSeconds}s.',
          ),
        );
      }
    });

    try {
      final info = await completer.future;
      _cachedFiles.remove(torrentId);
      _registerRootName(torrentId, fallbackName: info.name);
      return info;
    } finally {
      await sub.cancel();
      pollCheck.cancel();
      timer.cancel();
    }
  }

  void _registerRootName(
    int torrentId, {
    List<AudioFileEntry>? files,
    String? fallbackName,
  }) {
    final hash = _torrentIdToInfoHash[torrentId];
    if (hash == null || hash.isEmpty) return;

    String? rootCandidate;
    if (files != null && files.isNotEmpty) {
      final firstPath = files.first.path.replaceAll('\\', '/');
      final seg = firstPath
          .split('/')
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      if (seg.isNotEmpty) rootCandidate = seg;
    }
    if ((rootCandidate == null || rootCandidate.isEmpty) &&
        fallbackName != null &&
        fallbackName.trim().isNotEmpty) {
      rootCandidate = fallbackName.trim();
    }
    if (rootCandidate != null && rootCandidate.isNotEmpty) {
      ServerSettingsService.instance.registerTorrentRootName(
        hash,
        rootCandidate,
      );
    }
  }

  /// Lists all files inside [torrentId] as [AudioFileEntry] objects.
  List<AudioFileEntry> getFiles(int torrentId) {
    final cached = _cachedFiles[torrentId];
    if (cached != null) return cached;

    if (!LibtorrentFlutter.isInitialized) return [];
    final engine = LibtorrentFlutter.instance;
    final rawFiles = engine.getFiles(torrentId);
    if (rawFiles.isEmpty) return [];

    final torrentInfo = engine.torrents[torrentId];
    final singleFileFallback = (rawFiles.length == 1 && torrentInfo != null)
        ? torrentInfo.totalWanted
        : null;

    final entries = rawFiles.map((f) {
      final cachedSize = _knownFileSizes['$torrentId:${f.index}'];
      return AudioFileEntry.fromFileInfo(
        f,
        fallbackSize: cachedSize ?? singleFileFallback,
      );
    }).toList();

    if (torrentInfo?.hasMetadata == true) {
      _cachedFiles[torrentId] = List.unmodifiable(entries);
    }
    _registerRootName(
      torrentId,
      files: entries,
      fallbackName: torrentInfo?.name,
    );
    return entries;
  }

  /// Resolves an [AudioFileEntry] in [torrentId] by [filePath] or [fileIndex].
  ///
  /// Matching order:
  /// 1. Explicit [fileIndex] (>= 0)
  /// 2. Exact or normalized [filePath] match, suffix match, or file name match
  /// 3. First audio file (or largest streamable file) if neither is specified
  AudioFileEntry resolveAudioFile(
    int torrentId, {
    String? filePath,
    int? fileIndex,
  }) {
    final files = getFiles(torrentId);
    if (files.isEmpty) {
      throw StateError(
        'No files available for torrent $torrentId (metadata not yet loaded).',
      );
    }
    return selectAudioFile(files, filePath: filePath, fileIndex: fileIndex);
  }

  /// Selects a matching [AudioFileEntry] from [files] by [fileIndex], [filePath],
  /// or default first audio / streamable file.
  static AudioFileEntry selectAudioFile(
    List<AudioFileEntry> files, {
    String? filePath,
    int? fileIndex,
  }) {
    if (files.isEmpty) {
      throw StateError('No files available to select from.');
    }

    if (fileIndex != null && fileIndex >= 0) {
      final byIdx = files.where((f) => f.index == fileIndex).firstOrNull;
      if (byIdx != null) return byIdx;
      throw ArgumentError(
        'File index $fileIndex out of range (0..${files.length - 1}).',
      );
    }

    if (filePath != null && filePath.trim().isNotEmpty) {
      final query = _normalizePath(filePath);
      final queryLower = query.toLowerCase();

      // 1. Exact normalized path match
      for (final f in files) {
        if (_normalizePath(f.path) == query) return f;
      }
      // 2. Case-insensitive path match
      for (final f in files) {
        if (_normalizePath(f.path).toLowerCase() == queryLower) return f;
      }
      // 3. Suffix match (e.g. client passes "Audiobook/Chapter 01.mp3" or "Chapter 01.mp3"
      //    when torrent path is "BookRoot/Audiobook/Chapter 01.mp3")
      for (final f in files) {
        final norm = _normalizePath(f.path).toLowerCase();
        if (norm.endsWith('/$queryLower') || queryLower.endsWith('/$norm')) {
          return f;
        }
      }
      // 4. Exact or case-insensitive file name match
      for (final f in files) {
        if (f.name.toLowerCase() == queryLower) return f;
      }
      // 5. Partial substring match in audio files
      for (final f in files.where((e) => e.isAudioFile)) {
        if (_normalizePath(f.path).toLowerCase().contains(queryLower)) {
          return f;
        }
      }
      // 6. Numeric string fallback
      final asInt = int.tryParse(query);
      if (asInt != null && asInt >= 0 && asInt < files.length) {
        return files[asInt];
      }

      throw ArgumentError(
        'Audio file matching "$filePath" was not found in torrent (available files: ${files.length}).',
      );
    }

    // Default: pick first audio file, or first streamable file, or index 0
    final audioFiles = files.where((f) => f.isAudioFile).toList();
    if (audioFiles.isNotEmpty) return audioFiles.first;

    final streamableFiles = files.where((f) => f.isStreamable).toList();
    if (streamableFiles.isNotEmpty) return streamableFiles.first;

    return files.first;
  }

  static String _normalizePath(String p) {
    var s = p.trim().replaceAll('\\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    return s;
  }

  /// Starts a native stream in `libtorrent_flutter` for [torrentId] and [fileIndex].
  StreamInfo startNativeStream(
    int torrentId, {
    required int fileIndex,
    int maxCacheBytes = 64 * 1024 * 1024,
  }) {
    if (!LibtorrentFlutter.isInitialized) {
      throw StateError('LibtorrentFlutter engine is not initialized.');
    }
    final engine = LibtorrentFlutter.instance;

    // Reuse an existing active stream for the same torrentId + fileIndex if present
    for (final existing in engine.streams.values) {
      if (existing.torrentId == torrentId &&
          existing.fileIndex == fileIndex &&
          existing.isActive &&
          existing.url.isNotEmpty) {
        if (existing.fileSize > 0) {
          _knownFileSizes['$torrentId:$fileIndex'] = existing.fileSize;
        }
        prioritizeTorrentAndFile(torrentId, fileIndex: fileIndex, streamId: existing.id);
        return existing;
      }
    }

    final info = engine.startStream(
      torrentId,
      fileIndex: fileIndex,
      maxCacheBytes: maxCacheBytes,
    );
    if (info.fileSize > 0) {
      _knownFileSizes['$torrentId:$fileIndex'] = info.fileSize;
    }

    prioritizeTorrentAndFile(torrentId, fileIndex: fileIndex, streamId: info.id);

    notifyListeners();
    return info;
  }

  /// Ensures [magnetUri] is loaded with metadata and returns an active native
  /// [StreamInfo] for [fileIndex], creating or reusing it lazily.
  Future<StreamInfo> ensureNativeStreamForSession({
    required String magnetUri,
    required int fileIndex,
  }) async {
    final torrentId = await addOrGetTorrent(magnetUri, streamOnly: true);
    await waitForMetadata(torrentId);
    return startNativeStream(torrentId, fileIndex: fileIndex);
  }

  /// Sets [torrentId] and [fileIndex] as the newest primary requested torrent.
  ///
  /// Automatically deprioritizes/pauses background torrents, sets file priority to 7
  /// for [fileIndex] and 0 for others, and triggers head/tail preloading.
  Future<void> prioritizeTorrentAndFile(
    int torrentId, {
    required int fileIndex,
    int? streamId,
  }) async {
    final settings = ServerSettingsService.instance;
    _primaryTorrentId = torrentId;

    if (!LibtorrentFlutter.isInitialized) return;
    final engine = LibtorrentFlutter.instance;

    // 1. Resume the target torrent
    engine.resumeTorrent(torrentId);

    // 2. Pause background torrents if auto-pause is enabled
    if (settings.prioritizeNewest && settings.autoPauseBackgroundTorrents) {
      for (final tid in engine.torrents.keys) {
        if (tid != torrentId) {
          try {
            engine.pauseTorrent(tid);
            debugPrint('TorrentEngine: Deprioritized/paused background torrent #$tid');
          } catch (_) {}
        }
      }
    }

    // 3. Set download priorities on files inside this torrent ONLY when no
    // active native stream is running; otherwise lt_start_stream/serve_range
    // manages piece-level deadlines directly and prioritize_files() would
    // asynchronously wipe out piece priorities.
    if (streamId == null) {
      final files = getFiles(torrentId);
      if (files.isNotEmpty) {
        final priorities = List<int>.filled(files.length, 0);
        if (fileIndex >= 0 && fileIndex < files.length) {
          priorities[fileIndex] = 7; // Highest priority
        }
        try {
          engine.setFilePriorities(torrentId, priorities);
          debugPrint('TorrentEngine: Set file priorities for torrent #$torrentId (file #$fileIndex -> 7, others -> 0)');
        } catch (e) {
          debugPrint('TorrentEngine: Could not set file priorities: $e');
        }
      }
    }

    // 4. Preload and configure TorrServer cache if stream is provided
    if (streamId != null) {
      try {
        engine.setCacheSettings(
          streamId,
          capacity: 64 * 1024 * 1024,
          readAheadPct: 95,
          connectionsLimit: 30,
        );
        if (settings.fastAudioPreload) {
          final ok = engine.preloadStream(streamId);
          debugPrint('TorrentEngine: Preloaded stream #$streamId: $ok');
        }
      } catch (e) {
        debugPrint('TorrentEngine: Error configuring stream cache/preload: $e');
      }
    }

    // 5. Update LRU registry and check cache limit
    final hash = _torrentIdToInfoHash[torrentId];
    if (hash != null) {
      settings.recordAccess(hash);
      unawaited(settings.checkAndEnforceCacheLimit(protectedInfoHashes: {hash}));
    }

    notifyListeners();
  }

  void stopNativeStream(int streamId) {
    if (!LibtorrentFlutter.isInitialized) return;
    LibtorrentFlutter.instance.stopStream(streamId);
    notifyListeners();
  }

  void pauseTorrent(int torrentId) {
    if (!LibtorrentFlutter.isInitialized) return;
    LibtorrentFlutter.instance.pauseTorrent(torrentId);
    notifyListeners();
  }

  void resumeTorrent(int torrentId) {
    if (!LibtorrentFlutter.isInitialized) return;
    LibtorrentFlutter.instance.resumeTorrent(torrentId);
    notifyListeners();
  }

  void removeTorrent(int torrentId, {bool deleteFiles = true}) {
    if (!LibtorrentFlutter.isInitialized) return;
    final engine = LibtorrentFlutter.instance;
    final torrentInfo = engine.torrents[torrentId];
    final existingHash = _torrentIdToInfoHash[torrentId];
    final existingFiles = _cachedFiles[torrentId];

    String? rootSegment = existingHash != null
        ? ServerSettingsService.instance.getRootNameForInfoHash(existingHash)
        : null;
    if ((rootSegment == null || rootSegment.isEmpty) &&
        existingFiles != null &&
        existingFiles.isNotEmpty) {
      final firstPath = existingFiles.first.path.replaceAll('\\', '/');
      rootSegment = firstPath
          .split('/')
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    }
    if ((rootSegment == null || rootSegment.isEmpty) &&
        torrentInfo != null &&
        torrentInfo.name.isNotEmpty) {
      rootSegment = torrentInfo.name;
    }

    engine.disposeTorrent(torrentId);
    _cachedFiles.remove(torrentId);
    final hash = _torrentIdToInfoHash.remove(torrentId);
    if (hash != null) {
      _infoHashToTorrentId.remove(hash);
    }
    _torrentIdToMagnet.remove(torrentId);

    if (deleteFiles &&
        _savePath.isNotEmpty &&
        rootSegment != null &&
        rootSegment.isNotEmpty) {
      final targetPath = '$_savePath${Platform.pathSeparator}$rootSegment';
      unawaited(_deleteCachedPath(targetPath));
    }

    notifyListeners();
  }

  Future<void> _deleteCachedPath(String targetPath) async {
    try {
      final dir = Directory(targetPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      } else {
        final file = File(targetPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
      await ServerSettingsService.instance.refreshCacheUsage();
    } catch (e) {
      debugPrint('TorrentEngine: Failed to delete cached path "$targetPath": $e');
    }
  }

  void disposeAllTorrents() {
    if (!LibtorrentFlutter.isInitialized) return;
    LibtorrentFlutter.instance.disposeAll();
    _infoHashToTorrentId.clear();
    _torrentIdToInfoHash.clear();
    _torrentIdToMagnet.clear();
    _knownFileSizes.clear();
    _cachedFiles.clear();
    notifyListeners();
  }

  Future<void> shutdownEngine() async {
    await _torrentSub?.cancel();
    await _streamSub?.cancel();
    _torrentSub = null;
    _streamSub = null;
    if (LibtorrentFlutter.isInitialized) {
      await LibtorrentFlutter.instance.dispose();
    }
    _infoHashToTorrentId.clear();
    _torrentIdToInfoHash.clear();
    _torrentIdToMagnet.clear();
    _knownFileSizes.clear();
    _cachedFiles.clear();
    notifyListeners();
  }
}

