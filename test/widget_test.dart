import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torrent_bridge/main.dart';
import 'package:torrent_bridge/models/streaming_models.dart';
import 'package:torrent_bridge/services/audio_disk_cache_service.dart';
import 'package:torrent_bridge/services/server_settings_service.dart';
import 'package:torrent_bridge/services/torrent_engine_service.dart';

void main() {
  testWidgets('Renders AppBar, Status Pill, and 3 Navigation Tabs (Server, Torrents, Settings)', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TorrentAudioStreamerApp());

    expect(find.text('Torrent Bridge'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);

    // Verify 3 TabBar tabs
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Torrents'), findsOneWidget);
    expect(find.text('Player'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);

    // Verify Server tab content
    expect(find.text('Server is stopped'), findsOneWidget);
    expect(find.text('Start Server'), findsOneWidget);
    expect(find.text('Clients'), findsOneWidget);
    expect(find.text('Streams'), findsOneWidget);
    expect(find.text('Cache Limit'), findsOneWidget);

    // Switch to Settings tab
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Debrid Service'), findsOneWidget);
    expect(find.text('Intelligent Stream Priority'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Audio & Torrent Cache'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Audio & Torrent Cache'), findsOneWidget);
    expect(find.text('2 GB (Default)'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Auto-Start Server on Launch'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Auto-Start Server on Launch'), findsOneWidget);
  });

  test('ServerSettingsService defaults to 2 GB cache limit and intelligent priority flags', () {
    final settings = ServerSettingsService.instance;
    expect(settings.maxCacheSizeBytes, 2 * 1024 * 1024 * 1024); // 2 GB default
    expect(settings.prioritizeNewest, isTrue);
    expect(settings.autoPauseBackgroundTorrents, isTrue);
    expect(settings.fastAudioPreload, isTrue);
    expect(settings.autoStartServer, isFalse);
    expect(settings.keepServerRunning, isFalse);
    expect(settings.serverPort, 8080);
  });

  test('ServerSettingsService clamps and adjusts cache limits and autoStartServer', () async {
    final settings = ServerSettingsService.instance;
    await settings.init();
    await settings.setMaxCacheSizeBytes(4 * 1024 * 1024 * 1024);
    expect(settings.maxCacheSizeBytes, 4 * 1024 * 1024 * 1024);

    await settings.setAutoStartServer(true);
    expect(settings.autoStartServer, isTrue);

    // Reset back to defaults
    await settings.setAutoStartServer(false);
    await settings.setMaxCacheSizeBytes(ServerSettingsService.kDefaultCacheLimitBytes);
    expect(settings.maxCacheSizeBytes, 2 * 1024 * 1024 * 1024);
    expect(settings.autoStartServer, isFalse);
  });

  test('ServerSettingsService incrementally evicts only oldest files when over cache limit', () async {
    final settings = ServerSettingsService.instance;
    await settings.init();
    await settings.clearCache();

    const oldHash = '1111111111111111111111111111111111111111';
    const activeHash = '2222222222222222222222222222222222222222';
    final oldDir = Directory('${settings.cachePath}${Platform.pathSeparator}Old_Rolling_Book');
    final activeDir = Directory('${settings.cachePath}${Platform.pathSeparator}Active_Rolling_Book');
    await oldDir.create(recursive: true);
    await activeDir.create(recursive: true);

    final oldestFile = File('${oldDir.path}${Platform.pathSeparator}ch01.mp3');
    final newerOldFile = File('${oldDir.path}${Platform.pathSeparator}ch02.mp3');
    final activeFile = File('${activeDir.path}${Platform.pathSeparator}ch01.mp3');

    try {
      await settings.setMaxCacheSizeBytes(ServerSettingsService.kMinCacheLimitBytes);

      // 70 MB + 40 MB + 30 MB = 140 MB > 128 MB min limit
      await oldestFile.writeAsBytes(List.filled(70 * 1024 * 1024, 1));
      await newerOldFile.writeAsBytes(List.filled(40 * 1024 * 1024, 2));
      await activeFile.writeAsBytes(List.filled(30 * 1024 * 1024, 3));

      final now = DateTime.now();
      await oldestFile.setLastModified(now.subtract(const Duration(hours: 3)));
      await newerOldFile.setLastModified(now.subtract(const Duration(hours: 1)));
      await activeFile.setLastModified(now.subtract(const Duration(hours: 4)));

      settings.registerTorrentRootName(oldHash, 'Old_Rolling_Book/ch01.mp3');
      settings.registerTorrentRootName(activeHash, 'Active_Rolling_Book/ch01.mp3');

      await settings.checkAndEnforceCacheLimit(
        protectedInfoHashes: {activeHash},
        protectedRelativePaths: {'Active_Rolling_Book/ch01.mp3'},
      );

      // Only the oldest unprotected file (70 MB) should be evicted; remaining 70 MB <= 95% of 128 MB
      expect(await oldestFile.exists(), isFalse);
      expect(await newerOldFile.exists(), isTrue);
      expect(await activeFile.exists(), isTrue);
    } finally {
      if (await oldDir.exists()) await oldDir.delete(recursive: true);
      if (await activeDir.exists()) await activeDir.delete(recursive: true);
      await settings.setMaxCacheSizeBytes(ServerSettingsService.kDefaultCacheLimitBytes);
      await settings.refreshCacheUsage();
    }
  });

  test('ServerSettingsService protects active torrent folders by registered root name', () async {
    final settings = ServerSettingsService.instance;
    await settings.init();

    const activeHash = '2a72c612335bd7cc5221b9c20838a9a349cf3821';
    const inactiveHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final activeDir = Directory('${settings.cachePath}${Platform.pathSeparator}Active_Audiobook');
    final inactiveDir = Directory('${settings.cachePath}${Platform.pathSeparator}Old_Audiobook');
    await activeDir.create(recursive: true);
    await inactiveDir.create(recursive: true);

    final activeFile = File('${activeDir.path}${Platform.pathSeparator}ch1.mp3');
    final inactiveFile = File('${inactiveDir.path}${Platform.pathSeparator}ch1.mp3');
    await activeFile.writeAsBytes(List.filled(64, 1));
    await inactiveFile.writeAsBytes(List.filled(64, 2));

    settings.registerTorrentRootName(activeHash, 'Active_Audiobook/ch1.mp3');
    settings.registerTorrentRootName(inactiveHash, 'Old_Audiobook/ch1.mp3');

    final freed = await settings.clearCache(activeInfoHashes: {activeHash});
    expect(freed, greaterThanOrEqualTo(64));
    expect(await activeDir.exists(), isTrue);
    expect(await inactiveDir.exists(), isFalse);

    // Clean up test artifact
    if (await activeDir.exists()) {
      await activeDir.delete(recursive: true);
    }
    await settings.refreshCacheUsage();
  });

  test('TorrentEngineService normalizes infohash and magnet URIs', () {
    const hash = '2a72c612335bd7cc5221b9c20838a9a349cf3821';
    final magnet = TorrentEngineService.normalizeToMagnetUri(hash);
    expect(magnet, 'magnet:?xt=urn:btih:$hash');
    expect(TorrentEngineService.extractInfoHash(magnet), hash);
  });

  test('AudioFileEntry detects audio extensions and MIME types accurately', () {
    expect(AudioFileEntry.mimeTypeForExtension('.mp3'), 'audio/mpeg');
    expect(AudioFileEntry.mimeTypeForExtension('.m4b'), 'audio/mp4');
    expect(AudioFileEntry.mimeTypeForExtension('.flac'), 'audio/flac');
    expect(AudioFileEntry.mimeTypeForExtension('.ogg'), 'audio/ogg');
    expect(AudioFileEntry.mimeTypeForExtension('.opus'), 'audio/opus');
    expect(AudioFileEntry.isAudioExtension('.mp3'), isTrue);
    expect(AudioFileEntry.isAudioExtension('.m4b'), isTrue);
    expect(AudioFileEntry.isAudioExtension('.txt'), isFalse);
  });

  test('ByteRange.mergeRanges normalizes overlapping, adjacent, and duplicate intervals', () {
    final merged = ByteRange.mergeRanges(const [
      ByteRange(200, 299),
      ByteRange(0, 99),
      ByteRange(50, 149), // overlaps [0..99]
      ByteRange(150, 199), // adjacent to 149 and 200 -> merges all into [0..299]
      ByteRange(10, 40), // duplicate sub-range
      ByteRange(500, 599),
    ]);

    expect(merged, const [
      ByteRange(0, 299),
      ByteRange(500, 599),
    ]);
  });

  test('AudioDiskCacheService supports random-access seek writes, persistence across restarts, and crash recovery', () async {
    final tempDir = await Directory.systemTemp.createTemp('tb_disk_cache_test_');
    try {
      final cache = AudioDiskCacheService.instance;
      await cache.init(baseCachePath: tempDir.path, forceReload: true);

      const hash = 'abcdef1234567890abcdef1234567890abcdef12';
      const totalSize = 32768;
      final entry = await cache.ensureEntry(
        infoHash: hash,
        fileIndex: 0,
        fileName: 'chapter01.mp3',
        filePath: 'Book/chapter01.mp3',
        mimeType: 'audio/mpeg',
        fileSize: totalSize,
      );

      // Write seek range [16384..20479] BEFORE beginning [0..4095] to test sparse random-access writes
      final seekBytes = List<int>.generate(4096, (i) => (i + 77) & 0xFF);
      final headBytes = List<int>.generate(4096, (i) => (i + 13) & 0xFF);
      await cache.writeChunk(entry.key, 16384, seekBytes, totalFileSize: totalSize, forceFlushMetadata: true);
      await cache.writeChunk(entry.key, 0, headBytes, totalFileSize: totalSize, forceFlushMetadata: true);

      expect(entry.ranges, const [ByteRange(0, 4095), ByteRange(16384, 20479)]);
      expect(entry.isRangeCached(0, 4095), isTrue);
      expect(entry.isRangeCached(16384, 20479), isTrue);
      expect(entry.isRangeCached(4096, 8191), isFalse);
      expect(entry.findNextCachedRangeAfter(4096), const ByteRange(16384, 20479));

      // Verify exact byte reads on both ranges
      final readHead = <int>[];
      await for (final chunk in cache.openCachedRangeStream(entry.key, 0, 4095)) {
        readHead.addAll(chunk);
      }
      expect(readHead, headBytes);

      final readSeek = <int>[];
      await for (final chunk in cache.openCachedRangeStream(entry.key, 16384, 20479)) {
        readSeek.addAll(chunk);
      }
      expect(readSeek, seekBytes);

      // Simulate app restart via forceReload: true
      await cache.init(baseCachePath: tempDir.path, forceReload: true);
      final reloaded = cache.getEntry(hash, 0);
      expect(reloaded, isNotNull);
      expect(reloaded!.ranges, const [ByteRange(0, 4095), ByteRange(16384, 20479)]);
      expect(reloaded.cachedBytes, 8192);

      // Simulate unexpected crash: corrupt .meta.json has an out-of-bounds range & leftover .tmp file
      final metaFile = File('${cache.streamsDirPath}${Platform.pathSeparator}${entry.key}.meta.json');
      final tmpFile = File('${cache.streamsDirPath}${Platform.pathSeparator}${entry.key}.meta.json.tmp');
      final corrupted = reloaded.toJson();
      corrupted['ranges'] = [
        {'start': 0, 'end': 4095},
        {'start': 16384, 'end': 99999}, // exceeds physical length (20480)
        {'start': 50000, 'end': 60000}, // completely past physical EOF
      ];
      await metaFile.writeAsString(jsonEncode(corrupted));
      await tmpFile.writeAsString('{"broken_tmp": true');

      await cache.init(baseCachePath: tempDir.path, forceReload: true);
      final recovered = cache.getEntry(hash, 0);
      expect(recovered, isNotNull);
      expect(recovered!.ranges, const [ByteRange(0, 4095), ByteRange(16384, 20479)]);
      expect(await tmpFile.exists(), isFalse);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      // Restore default cache dir binding for subsequent tests
      await ServerSettingsService.instance.init();
      await AudioDiskCacheService.instance.init(
        baseCachePath: ServerSettingsService.instance.cachePath,
        forceReload: true,
      );
    }
  });

  test('AudioDiskCacheService LRU eviction respects active read/write locks', () async {
    final tempDir = await Directory.systemTemp.createTemp('tb_lru_lock_test_');
    try {
      final cache = AudioDiskCacheService.instance;
      await cache.init(baseCachePath: tempDir.path, forceReload: true);

      const h1 = '1111111111111111111111111111111111111111';
      const h2 = '2222222222222222222222222222222222222222';
      const h3 = '3333333333333333333333333333333333333333';

      final e1 = await cache.ensureEntry(infoHash: h1, fileIndex: 0, fileSize: 10000);
      final e2 = await cache.ensureEntry(infoHash: h2, fileIndex: 0, fileSize: 10000);
      final e3 = await cache.ensureEntry(infoHash: h3, fileIndex: 0, fileSize: 10000);

      await cache.writeChunk(e1.key, 0, List.filled(6000, 1), forceFlushMetadata: true);
      await cache.writeChunk(e2.key, 0, List.filled(6000, 2), forceFlushMetadata: true);
      await cache.writeChunk(e3.key, 0, List.filled(6000, 3), forceFlushMetadata: true);

      // Make e1 oldest (locked), e2 second oldest (unlocked), e3 newest (unlocked)
      e1.lastAccessedMs = 1000;
      e2.lastAccessedMs = 2000;
      e3.lastAccessedMs = 3000;

      // Active reader lock on oldest entry e1 prevents eviction even when over limit
      // Total = 18000 > maxBytes (14000), 95% target = 13300 -> evicts 1 entry (e2)
      cache.acquireReadLock(e1.key);
      try {
        final freed = await cache.enforceCacheLimit(maxBytes: 14000);
        expect(freed, 6000);
        // e1 MUST survive due to read lock; e2 (oldest unlocked) is evicted; e3 stays
        expect(cache.getEntryByKey(e1.key), isNotNull);
        expect(cache.getEntryByKey(e2.key), isNull);
        expect(cache.getEntryByKey(e3.key), isNotNull);
      } finally {
        cache.releaseReadLock(e1.key);
      }

      // Now test active writer lock on e3 while e1 is unlocked
      cache.acquireWriteLock(e3.key);
      try {
        e3.lastAccessedMs = 500; // even if e3 appears oldest by timestamp
        e1.lastAccessedMs = 4000;
        final freed = await cache.enforceCacheLimit(maxBytes: 6000);
        expect(freed, 6000);
        // e3 MUST survive because activeWriters > 0; e1 is evicted instead
        expect(cache.getEntryByKey(e3.key), isNotNull);
        expect(cache.getEntryByKey(e1.key), isNull);
      } finally {
        await cache.releaseWriteLock(e3.key);
      }
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await ServerSettingsService.instance.init();
      await AudioDiskCacheService.instance.init(
        baseCachePath: ServerSettingsService.instance.cachePath,
        forceReload: true,
      );
    }
  });
}
