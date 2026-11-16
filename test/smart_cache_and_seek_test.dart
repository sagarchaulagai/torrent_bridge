import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torrent_bridge/models/debrid_models.dart';
import 'package:torrent_bridge/models/streaming_models.dart';
import 'package:torrent_bridge/screens/home_screen.dart';
import 'package:torrent_bridge/services/audio_disk_cache_service.dart';
import 'package:torrent_bridge/services/http_streaming_server.dart';
import 'package:torrent_bridge/services/server_settings_service.dart';

void main() {
  group('Piece-aware DiskCacheEntry & TorrentManifest', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tb_piece_cache_test_');
      await AudioDiskCacheService.instance.init(
        baseCachePath: tempDir.path,
        forceReload: true,
      );
    });

    tearDown(() async {
      await ServerSettingsService.instance.init();
      await AudioDiskCacheService.instance.init(
        baseCachePath: ServerSettingsService.instance.cachePath,
        forceReload: true,
      );
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('infers exact BitTorrent piece lengths from readaheadWindow', () {
      expect(TorrentManifest.inferPieceLengthFromReadaheadWindow(64), 256 * 1024);
      expect(TorrentManifest.inferPieceLengthFromReadaheadWindow(32), 512 * 1024);
      expect(TorrentManifest.inferPieceLengthFromReadaheadWindow(16), 1024 * 1024);
      expect(TorrentManifest.inferPieceLengthFromReadaheadWindow(8), 2 * 1024 * 1024);
      expect(TorrentManifest.inferPieceLengthFromReadaheadWindow(4), 4 * 1024 * 1024);
      expect(TorrentManifest.inferPieceLengthFromReadaheadWindow(1), 16 * 1024 * 1024);
      expect(TorrentManifest.inferPieceLengthFromReadaheadWindow(0), 0);
    });

    test('computes multi-file piece geometry, downloaded spans, missing gaps, and recovers manifests', () async {
      final cache = AudioDiskCacheService.instance;
      const hash = '0123456789abcdef0123456789abcdef01234567';
      const pieceLen = 512 * 1024; // 512 KB
      const file0Size = 700 * 1024; // spans pieces 0..1 (0 .. 716799)
      const file1Size = 900 * 1024; // offset 716800, spans pieces 1..3

      final manifest = await cache.saveTorrentManifest(
        infoHash: hash,
        torrentName: 'Foundation Audiobook',
        magnetUri: 'magnet:?xt=urn:btih:$hash',
        pieceLength: pieceLen,
        files: [
          AudioFileEntry.fromPathAndSize(
            index: 0,
            path: 'Foundation/Chapter01.mp3',
            size: file0Size,
          ),
          AudioFileEntry.fromPathAndSize(
            index: 1,
            path: 'Foundation/Chapter02.mp3',
            size: file1Size,
          ),
        ],
      );

      expect(manifest.totalSize, file0Size + file1Size);
      expect(manifest.numPieces, 4);
      expect(manifest.files[1].offsetInTorrent, file0Size);
      expect(manifest.files[1].startPiece(pieceLen), 1);
      expect(manifest.files[1].endPiece(pieceLen), 3);

      // Ensure entry for file 1 automatically gets manifest piece geometry
      final entry = await cache.ensureEntry(
        infoHash: hash,
        fileIndex: 1,
        fileName: 'Chapter02.mp3',
        filePath: 'Foundation/Chapter02.mp3',
        mimeType: 'audio/mpeg',
        fileSize: file1Size,
      );

      expect(entry.hasPieceGeometry, isTrue);
      expect(entry.torrentName, 'Foundation Audiobook');
      expect(entry.pieceLength, pieceLen);
      expect(entry.fileOffsetInTorrent, file0Size);
      expect(entry.startPiece, 1);
      expect(entry.endPiece, 3);

      // Piece 1 inside file 1 covers bytes [0 .. (1048576 - 716800 - 1)] = [0 .. 331775]
      final p1Range = entry.pieceFileByteRange(1);
      expect(p1Range, const ByteRange(0, 331775));
      // Piece 2 inside file 1 covers bytes [331776 .. 856063]
      final p2Range = entry.pieceFileByteRange(2);
      expect(p2Range, const ByteRange(331776, 856063));
      // Piece 3 inside file 1 covers bytes [856064 .. 921599]
      final p3Range = entry.pieceFileByteRange(3);
      expect(p3Range, const ByteRange(856064, file1Size - 1));

      // Write piece 1 and piece 3 via pooled open RandomAccessFile writer, leave piece 2 uncached
      await cache.writeChunk(entry.key, 0, List.filled(p1Range.length, 0x11));
      await cache.writeChunk(
        entry.key,
        p3Range.start,
        List.filled(p3Range.length, 0x33),
        forceFlushMetadata: true,
      );

      expect(entry.isPieceCached(1), isTrue);
      expect(entry.isPieceCached(2), isFalse);
      expect(entry.isPieceCached(3), isTrue);
      expect(entry.contiguousBytesFrom(0), p1Range.length);
      expect(entry.findMissingRanges(0, file1Size - 1), [p2Range]);
      expect(entry.alignEndToPieceBoundary(1000), p1Range.end);

      final cov = entry.computePieceCoverage();
      expect(cov.totalPieces, 3);
      expect(cov.downloadedPieces, 2);
      expect(cov.downloadedSpans, const [ByteRange(1, 1), ByteRange(3, 3)]);

      // Simulate restart & corrupt .manifest.json with valid .manifest.json.tmp recovery
      final manifestFile = File(
        '${cache.manifestsDirPath}${Platform.pathSeparator}$hash.manifest.json',
      );
      final tmpManifest = File(
        '${cache.manifestsDirPath}${Platform.pathSeparator}$hash.manifest.json.tmp',
      );
      await tmpManifest.writeAsString(await manifestFile.readAsString());
      await manifestFile.writeAsString('{corrupt_json');

      await cache.init(baseCachePath: tempDir.path, forceReload: true);
      final reloadedManifest = cache.getManifest(hash);
      expect(reloadedManifest, isNotNull);
      expect(reloadedManifest!.torrentName, 'Foundation Audiobook');
      expect(await tmpManifest.exists(), isFalse);

      final reloadedEntry = cache.getEntry(hash, 1);
      expect(reloadedEntry, isNotNull);
      expect(reloadedEntry!.isPieceCached(1), isTrue);
      expect(reloadedEntry.isPieceCached(2), isFalse);
      expect(reloadedEntry.isPieceCached(3), isTrue);

      final summaries = cache.getTorrentSummaries();
      expect(summaries.length, 1);
      expect(summaries.first.downloadedPieces, 2);
      expect(summaries.first.totalPieces, 3);
    });
  });

  group('Zero-wait partial cache, hybrid seek stitching, rapid-seek cancellation & stall recovery', () {
    HttpOverrides? savedOverrides;
    late Directory tempCacheDir;
    late HttpServer mockUpstream;
    late String upstreamBaseUrl;
    late Uint8List fullAudioBytes;
    var upstreamRangeCalls = <String>[];
    var failFirstFetchForRange = false;
    var stallOffsetThreshold = -1;

    setUp(() async {
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      tempCacheDir = await Directory.systemTemp.createTemp('tb_seek_http_test_');

      await ServerSettingsService.instance.init(
        overrideCachePath: tempCacheDir.path,
        forceReload: true,
      );
      await ServerSettingsService.instance.setDebridProvider(DebridProvider.none);
      await ServerSettingsService.instance.setKeepServerRunning(false);
      await ServerSettingsService.instance.setAutoStartServer(false);

      // 1 MB synthetic audio file with unique byte pattern
      fullAudioBytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024, (i) => (i * 13 + (i >> 8)) & 0xFF),
      );
      upstreamRangeCalls = [];
      failFirstFetchForRange = false;
      stallOffsetThreshold = -1;

      mockUpstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${mockUpstream.port}';
      mockUpstream.listen((HttpRequest req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
        upstreamRangeCalls.add(range);
        final res = req.response;

        var start = 0;
        var end = fullAudioBytes.length - 1;
        if (range.startsWith('bytes=')) {
          final parts = range.substring(6).split('-');
          start = int.parse(parts[0]);
          if (parts.length > 1 && parts[1].isNotEmpty) {
            end = math.min(int.parse(parts[1]), fullAudioBytes.length - 1);
          }
        }

        if (failFirstFetchForRange && start >= stallOffsetThreshold) {
          failFirstFetchForRange = false;
          res.statusCode = HttpStatus.internalServerError;
          await res.close();
          return;
        }

      if (req.uri.queryParameters['slow'] == '1' && start == 0) {
          // Simulate slow stream at offset 0 so rapid seek can cancel it
          res.bufferOutput = false;
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${fullAudioBytes.length}',
          );
          res.add(fullAudioBytes.sublist(start, math.min(start + 1024, end + 1)));
          await res.flush();
          await Future<void>.delayed(const Duration(seconds: 5));
          try {
            await res.close();
          } catch (_) {}
          return;
        }

        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${fullAudioBytes.length}',
        );
        final slice = fullAudioBytes.sublist(start, end + 1);
        res.contentLength = slice.length;
        res.add(slice);
        await res.close();
      });

      HttpStreamingServer.instance.skipTorrentEngineInit = true;
    });

    tearDown(() async {
      HttpStreamingServer.instance.upstreamOpenerOverride = null;
      await HttpStreamingServer.instance.stopServer();
      HttpStreamingServer.instance.skipTorrentEngineInit = false;
      await mockUpstream.close(force: true);
      await ServerSettingsService.instance.init(forceReload: true);
      if (await tempCacheDir.exists()) {
        await tempCacheDir.delete(recursive: true);
      }
      HttpOverrides.global = savedOverrides;
    });

    test('resumes partial cache immediately without metadata wait, stitches cached/uncached seeks, and recovers stalls', () async {
      const hash = 'cccccccccccccccccccccccccccccccccccccccc';
      final cache = AudioDiskCacheService.instance;
      await cache.saveTorrentManifest(
        infoHash: hash,
        torrentName: 'Dune Audiobook',
        pieceLength: 256 * 1024,
        files: [
          AudioFileEntry.fromPathAndSize(
            index: 0,
            path: 'Dune/Part1.mp3',
            size: fullAudioBytes.length,
          ),
        ],
      );

      final entry = await cache.ensureEntry(
        infoHash: hash,
        fileIndex: 0,
        fileName: 'Part1.mp3',
        filePath: 'Dune/Part1.mp3',
        mimeType: 'audio/mpeg',
        fileSize: fullAudioBytes.length,
      );

      // Pre-seed two sparse cached regions: [0..4095] and [16384..24575]
      await cache.writeChunk(entry.key, 0, fullAudioBytes.sublist(0, 4096));
      await cache.writeChunk(
        entry.key,
        16384,
        fullAudioBytes.sublist(16384, 24576),
        forceFlushMetadata: true,
      );

      final server = HttpStreamingServer.instance;
      server.upstreamOpenerOverride = (
        StreamingSession session, {
        required String method,
        String? rangeHeader,
        void Function(void Function())? attachAbort,
      }) async {
        final client = HttpClient();
        final req = await client.openUrl(method, Uri.parse('$upstreamBaseUrl/audio'));
        if (rangeHeader != null) {
          req.headers.set(HttpHeaders.rangeHeader, rangeHeader);
        }
        attachAbort?.call(() {
          try {
            req.abort();
          } catch (_) {}
          client.close(force: true);
        });
        final res = await req.close();
        if (res.statusCode >= 400) {
          await res.drain<void>().catchError((_) {});
          client.close(force: true);
          throw HttpException('Upstream HTTP ${res.statusCode}');
        }
        return res;
      };

      await server.startServer(port: 0);

      final client = HttpClient();
      try {
        // 1. POST /api/stream resolves IMMEDIATELY from partial cache + manifest (no 90s metadata wait!)
        final createReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/stream'),
        );
        createReq.write(jsonEncode({'infohash': hash}));
        final createRes = await createReq.close();
        expect(createRes.statusCode, HttpStatus.ok);
        final createdJson =
            jsonDecode(await utf8.decoder.bind(createRes).join())
                as Map<String, dynamic>;
        expect(createdJson['file_name'], 'Part1.mp3');
        expect(createdJson['file_size'], fullAudioBytes.length);

        final streamUrl = Uri.parse(createdJson['loopback_stream_url'] as String);

        // 2. Request purely cached prefix [0..4095] -> zero upstream calls!
        final cachedReq = await client.getUrl(streamUrl);
        cachedReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-4095');
        final cachedRes = await cachedReq.close();
        expect(cachedRes.statusCode, HttpStatus.partialContent);
        final cachedGot =
            await cachedRes.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(cachedGot, fullAudioBytes.sublist(0, 4096));
        expect(upstreamRangeCalls, isEmpty);

        // 3. Hybrid request spanning cached [0..4095], missing [4096..16383], cached [16384..24575], missing [24576..32767]
        final hybridReq = await client.getUrl(streamUrl);
        hybridReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-32767');
        final hybridRes = await hybridReq.close();
        expect(hybridRes.statusCode, HttpStatus.partialContent);
        final hybridGot =
            await hybridRes.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(hybridGot, fullAudioBytes.sublist(0, 32768));

        // 4. Seek to uncached [600000..655359] with transient upstream failure -> coordinator recovers cleanly!
        failFirstFetchForRange = true;
        stallOffsetThreshold = 600000;
        final seekReq = await client.getUrl(streamUrl);
        seekReq.headers.set(HttpHeaders.rangeHeader, 'bytes=600000-655359');
        final seekRes = await seekReq.close();
        expect(seekRes.statusCode, HttpStatus.partialContent);
        final seekGot =
            await seekRes.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(seekGot, fullAudioBytes.sublist(600000, 655360));

        // Verify GET /api/cache reports piece coverage & torrents grouping, and DELETE /api/cache/torrent/<hash> works
        final cacheGetReq = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/cache'),
        );
        final cacheGetRes = await cacheGetReq.close();
        expect(cacheGetRes.statusCode, HttpStatus.ok);
        final cacheJson =
            jsonDecode(await utf8.decoder.bind(cacheGetRes).join())
                as Map<String, dynamic>;
        final torrentsList =
            cacheJson['cache']['disk_cache']['torrents'] as List<dynamic>;
        expect(torrentsList.length, 1);
        expect(torrentsList.first['infohash'], hash);

        server.stopSession(createdJson['session_id'] as String);

        final delReq = await client.deleteUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/cache/torrent/$hash'),
        );
        final delRes = await delReq.close();
        expect(delRes.statusCode, HttpStatus.ok);
        expect(cache.getEntry(hash, 0), isNull);
        expect(cache.getManifest(hash), isNull);
      } finally {
        client.close(force: true);
      }
    });

    test('rapid seek supersedes and aborts in-flight slow upstream request immediately', () async {
      const hash = 'dddddddddddddddddddddddddddddddddddddddd';
      final cache = AudioDiskCacheService.instance;
      await cache.saveTorrentManifest(
        infoHash: hash,
        torrentName: 'Rapid Seek Book',
        pieceLength: 256 * 1024,
        files: [
          AudioFileEntry.fromPathAndSize(
            index: 0,
            path: 'Rapid/Book.mp3',
            size: fullAudioBytes.length,
          ),
        ],
      );

      var abortedCount = 0;
      final firstSlowStarted = Completer<void>();

      final server = HttpStreamingServer.instance;
      server.upstreamOpenerOverride = (
        StreamingSession session, {
        required String method,
        String? rangeHeader,
        void Function(void Function())? attachAbort,
      }) async {
        final client = HttpClient();
        final isStart = rangeHeader != null && rangeHeader.startsWith('bytes=0-');
        final uri = Uri.parse(
          isStart ? '$upstreamBaseUrl/audio?slow=1' : '$upstreamBaseUrl/audio',
        );
        final req = await client.openUrl(method, uri);
        if (rangeHeader != null) {
          req.headers.set(HttpHeaders.rangeHeader, rangeHeader);
        }
        attachAbort?.call(() {
          abortedCount++;
          try {
            req.abort();
          } catch (_) {}
          client.close(force: true);
        });
        if (isStart && !firstSlowStarted.isCompleted) {
          firstSlowStarted.complete();
        }
        return req.close();
      };

      await server.startServer(port: 0);
      final session = await server.createOrGetStreamSession(
        magnetOrInfoHash: hash,
      );
      final streamUrl = Uri.parse(session.buildStreamUrl('127.0.0.1', server.port));

      final client = HttpClient();
      try {
        // Start initial slow playback stream from offset 0 (open-ended)
        final slowReq = await client.getUrl(streamUrl);
        slowReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        final slowDone = slowReq.close().then(
          (r) => r.drain<void>().catchError((_) {}),
          onError: (_) {},
        );

        await firstSlowStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Now user seeks to 524288..589823 — must supersede and abort the slow offset-0 upstream!
        final seekReq = await client.getUrl(streamUrl);
        seekReq.headers.set(HttpHeaders.rangeHeader, 'bytes=524288-589823');
        final seekRes = await seekReq.close();
        expect(seekRes.statusCode, HttpStatus.partialContent);
        final seekBytes =
            await seekRes.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(seekBytes, fullAudioBytes.sublist(524288, 589824));
        expect(abortedCount, greaterThanOrEqualTo(1));

        await slowDone.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () {},
        );
      } finally {
        client.close(force: true);
      }
    });

    test('ServerSettingsService prioritizes pruning duplicate raw files of 100%-cached torrents first', () async {
      final settings = ServerSettingsService.instance;
      await settings.init(
        overrideCachePath: tempCacheDir.path,
        forceReload: true,
      );
      await settings.clearCache();

      const completeHash = '4444444444444444444444444444444444444444';
      const partialHash = '5555555555555555555555555555555555555555';

      final dupDir = Directory('${settings.cachePath}${Platform.pathSeparator}Complete_Book_Raw');
      final otherDir = Directory('${settings.cachePath}${Platform.pathSeparator}Incomplete_Book_Raw');
      await dupDir.create(recursive: true);
      await otherDir.create(recursive: true);

      final dupRawFile = File('${dupDir.path}${Platform.pathSeparator}ch1.mp3');
      final otherRawFile = File('${otherDir.path}${Platform.pathSeparator}ch1.mp3');

      try {
        await settings.setMaxCacheSizeBytes(ServerSettingsService.kMinCacheLimitBytes);

        // Complete book is 100% cached in AudioDiskCacheService (50 MB) AND has duplicate raw (50 MB)
        final completeEntry = await AudioDiskCacheService.instance.ensureEntry(
          infoHash: completeHash,
          fileIndex: 0,
          fileName: 'ch1.mp3',
          fileSize: 50 * 1024 * 1024,
        );
        await AudioDiskCacheService.instance.writeChunk(
          completeEntry.key,
          0,
          List.filled(50 * 1024 * 1024, 7),
          forceFlushMetadata: true,
        );

        await dupRawFile.writeAsBytes(List.filled(50 * 1024 * 1024, 1));
        await otherRawFile.writeAsBytes(List.filled(45 * 1024 * 1024, 2));

        // Make otherRawFile OLDER by timestamp, yet dupRawFile must still be pruned first
        // because Complete_Book_Raw is already 100% cached in streams/!
        final now = DateTime.now();
        await dupRawFile.setLastModified(now);
        await otherRawFile.setLastModified(now.subtract(const Duration(hours: 5)));

        settings.registerTorrentRootName(completeHash, 'Complete_Book_Raw/ch1.mp3');
        settings.registerTorrentRootName(partialHash, 'Incomplete_Book_Raw/ch1.mp3');
        settings.recordAccess(completeHash);

        await settings.checkAndEnforceCacheLimit();

        // Duplicate raw copy is pruned, while incomplete raw & 100% streams cache remain!
        expect(await dupRawFile.exists(), isFalse);
        expect(await otherRawFile.exists(), isTrue);
        expect(AudioDiskCacheService.instance.getEntry(completeHash, 0), isNotNull);
      } finally {
        if (await dupDir.exists()) await dupDir.delete(recursive: true);
        if (await otherDir.exists()) await otherDir.delete(recursive: true);
        await settings.clearCache();
        await settings.setMaxCacheSizeBytes(ServerSettingsService.kDefaultCacheLimitBytes);
        await settings.refreshCacheUsage();
      }
    });
  });

  testWidgets('Settings tab exposes Read-Ahead Seek Buffer and Background Survival card', (
    WidgetTester tester,
  ) async {
    final settings = ServerSettingsService.instance;
    late Directory widgetCacheDir;
    await tester.runAsync(() async {
      widgetCacheDir =
          await Directory.systemTemp.createTemp('tb_widget_settings_test_');
      await settings.init(
        overrideCachePath: widgetCacheDir.path,
        forceReload: true,
      );
      await settings.setKeepServerRunning(false);
      await settings.setAutoStartServer(false);
      await settings.setDebridProvider(DebridProvider.none);
    });

    try {
      await tester.pumpWidget(
        const MaterialApp(home: HomeScreen()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      final settingsListView = find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first;

      await tester.scrollUntilVisible(
        find.textContaining('Seek & Read-Ahead Buffer'),
        200,
        scrollable: settingsListView,
      );
      expect(find.textContaining('Seek & Read-Ahead Buffer'), findsOneWidget);
      expect(find.text('16 MB (Default)'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Background Survival (Non-Play Store)'),
        200,
        scrollable: settingsListView,
      );
      expect(find.text('Background Survival (Non-Play Store)'), findsOneWidget);
    } finally {
      await tester.runAsync(() async {
        await settings.init(forceReload: true);
        if (await widgetCacheDir.exists()) {
          await widgetCacheDir.delete(recursive: true);
        }
      });
    }
  });
}
