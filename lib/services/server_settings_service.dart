import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/debrid_models.dart';
import 'audio_disk_cache_service.dart';

/// Manages server preferences, disk cache quota (default 2 GB),
/// LRU cache eviction, and priority rules for Torrent Bridge.
class ServerSettingsService extends ChangeNotifier {
  static final ServerSettingsService instance = ServerSettingsService._();
  ServerSettingsService._();

  static const int kDefaultCacheLimitBytes = 2 * 1024 * 1024 * 1024; // 2 GB
  static const int kMinCacheLimitBytes = 128 * 1024 * 1024; // 128 MB
  static const int kMaxCacheLimitBytes = 16 * 1024 * 1024 * 1024; // 16 GB
  static const int kDefaultReadAheadBytes = 16 * 1024 * 1024; // 16 MB
  static const int kMinReadAheadBytes = 4 * 1024 * 1024; // 4 MB
  static const int kMaxReadAheadBytes = 64 * 1024 * 1024; // 64 MB

  bool _isLoaded = false;
  int _maxCacheSizeBytes = kDefaultCacheLimitBytes;
  int _readAheadBufferBytes = kDefaultReadAheadBytes;
  bool _prioritizeNewest = true;
  bool _autoPauseBackgroundTorrents = true;
  bool _fastAudioPreload = true;
  bool _autoStartServer = false;
  bool _keepServerRunning = false;
  bool _cacheDefault2GbMigrated = true;
  int _serverPort = 8080;

  DebridProvider _debridProvider = DebridProvider.none;
  final Map<String, String> _debridApiKeys = {};
  final Map<String, bool> _debridKeyValidated = {};
  final Map<String, String> _debridAccountLabels = {};
  bool _fallbackToTorrentOnDebridFailure = false;

  int _cachedBytes = 0;
  bool _isCalculatingCache = false;
  bool _isEnforcingCache = false;
  String _cachePath = '';
  Timer? _saveDebounceTimer;

  /// LRU access registry mapping infoHash -> lastAccessed timestamp (millisecondsSinceEpoch)
  final Map<String, int> _lastAccessedMap = {};

  /// Maps lowercase infoHash -> top-level folder or file name on disk.
  final Map<String, String> _infoHashToRootName = {};

  bool get isLoaded => _isLoaded;
  int get maxCacheSizeBytes => _maxCacheSizeBytes;
  int get readAheadBufferBytes => _readAheadBufferBytes;
  String get readAheadBufferFormatted => formatBytes(_readAheadBufferBytes);
  bool get prioritizeNewest => _prioritizeNewest;
  bool get autoPauseBackgroundTorrents => _autoPauseBackgroundTorrents;
  bool get fastAudioPreload => _fastAudioPreload;
  bool get autoStartServer => _autoStartServer;
  bool get keepServerRunning => _keepServerRunning;
  int get serverPort => _serverPort;

  DebridProvider get debridProvider => _debridProvider;
  String get activeDebridApiKey =>
      _debridApiKeys[_debridProvider.id]?.trim() ?? '';
  String debridApiKeyFor(DebridProvider provider) =>
      _debridApiKeys[provider.id] ?? '';
  bool get isActiveDebridKeyValidated =>
      _debridKeyValidated[_debridProvider.id] ?? false;
  bool isDebridKeyValidatedFor(DebridProvider provider) =>
      _debridKeyValidated[provider.id] ?? false;
  String? debridAccountLabelFor(DebridProvider provider) =>
      _debridAccountLabels[provider.id];
  String? get activeDebridAccountLabel =>
      _debridAccountLabels[_debridProvider.id];
  bool get hasConfiguredDebrid =>
      _debridProvider.isConfiguredProvider && activeDebridApiKey.isNotEmpty;
  bool get fallbackToTorrentOnDebridFailure =>
      _fallbackToTorrentOnDebridFailure;

  int get cachedBytes => _cachedBytes;
  bool get isCalculatingCache => _isCalculatingCache;
  String get cachePath => _cachePath;

  double get cacheUsageRatio => _maxCacheSizeBytes > 0
      ? (_cachedBytes / _maxCacheSizeBytes).clamp(0.0, 1.0)
      : 0.0;

  /// Human-readable label for current cache limit (e.g. "1.0 GB", "500 MB")
  String get maxCacheSizeFormatted => formatBytes(_maxCacheSizeBytes);
  String get cachedBytesFormatted => formatBytes(_cachedBytes);

  /// Initializes paths and loads persisted preferences.
  Future<void> init({
    String? overrideCachePath,
    bool forceReload = false,
  }) async {
    if (_isLoaded && !forceReload && overrideCachePath == null) return;
    try {
      Directory dir;
      if (overrideCachePath != null && overrideCachePath.isNotEmpty) {
        dir = Directory(overrideCachePath);
      } else {
        Directory baseDir;
        try {
          baseDir = await getApplicationSupportDirectory();
        } catch (_) {
          baseDir = Directory.systemTemp;
        }
        dir = Directory(
          '${baseDir.path}${Platform.pathSeparator}torrent_audio_cache',
        );
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _cachePath = dir.path;

      _lastAccessedMap.clear();
      _infoHashToRootName.clear();
      await _loadSettingsFile();
      await AudioDiskCacheService.instance.init(
        baseCachePath: _cachePath,
        forceReload: forceReload || overrideCachePath != null,
      );
      await refreshCacheUsage();
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('ServerSettingsService.init error: $e');
      _isLoaded = true;
    }
  }

  File _getConfigFile() {
    final basePath = _cachePath.isNotEmpty
        ? _cachePath
        : '${Directory.systemTemp.path}${Platform.pathSeparator}torrent_audio_cache';
    return File('$basePath${Platform.pathSeparator}settings_config.json');
  }

  Future<void> _loadSettingsFile() async {
    try {
      final file = _getConfigFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _maxCacheSizeBytes = (json['max_cache_size_bytes'] as num?)?.toInt() ??
            kDefaultCacheLimitBytes;
        final savedRa = (json['read_ahead_buffer_bytes'] as num?)?.toInt();
        if (savedRa != null && savedRa > 0) {
          _readAheadBufferBytes =
              savedRa.clamp(kMinReadAheadBytes, kMaxReadAheadBytes);
        }
        _prioritizeNewest = json['prioritize_newest'] as bool? ?? true;
        _autoPauseBackgroundTorrents =
            json['auto_pause_background'] as bool? ?? true;
        _fastAudioPreload = json['fast_audio_preload'] as bool? ?? true;
        _autoStartServer = json['auto_start_server'] as bool? ?? false;
        _keepServerRunning = json['keep_server_running'] as bool? ?? false;
        _serverPort = (json['server_port'] as num?)?.toInt() ?? 8080;
        _debridProvider =
            DebridProvider.fromId(json['debrid_provider']?.toString());
        _fallbackToTorrentOnDebridFailure =
            json['fallback_to_torrent_on_debrid_failure'] as bool? ?? false;

        _debridApiKeys.clear();
        if (json['debrid_api_keys'] is Map) {
          for (final e in (json['debrid_api_keys'] as Map).entries) {
            final k = e.key.toString();
            final v = e.value?.toString().trim() ?? '';
            if (v.isNotEmpty) {
              _debridApiKeys[k] = v;
            }
          }
        }
        _debridKeyValidated.clear();
        if (json['debrid_key_validated'] is Map) {
          for (final e in (json['debrid_key_validated'] as Map).entries) {
            _debridKeyValidated[e.key.toString()] = e.value == true;
          }
        }
        _debridAccountLabels.clear();
        if (json['debrid_account_labels'] is Map) {
          for (final e in (json['debrid_account_labels'] as Map).entries) {
            final v = e.value?.toString().trim() ?? '';
            if (v.isNotEmpty) {
              _debridAccountLabels[e.key.toString()] = v;
            }
          }
        }

        _cacheDefault2GbMigrated =
            json['cache_default_2gb_migrated'] as bool? ?? false;

        if (!_cacheDefault2GbMigrated &&
            _maxCacheSizeBytes == 1024 * 1024 * 1024) {
          _maxCacheSizeBytes = kDefaultCacheLimitBytes;
          _cacheDefault2GbMigrated = true;
          unawaited(_saveSettingsFile());
        } else {
          _cacheDefault2GbMigrated = true;
        }

        if (json['last_accessed'] is Map) {
          final map = json['last_accessed'] as Map;
          for (final entry in map.entries) {
            _lastAccessedMap[entry.key.toString().toLowerCase()] =
                (entry.value as num).toInt();
          }
        }
        if (json['root_names'] is Map) {
          final map = json['root_names'] as Map;
          for (final entry in map.entries) {
            final root = entry.value?.toString() ?? '';
            if (root.isNotEmpty) {
              _infoHashToRootName[entry.key.toString().toLowerCase()] = root;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error reading settings file: $e');
    }
  }

  Future<void> _saveSettingsFile() async {
    try {
      final file = _getConfigFile();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final json = {
        'max_cache_size_bytes': _maxCacheSizeBytes,
        'read_ahead_buffer_bytes': _readAheadBufferBytes,
        'cache_default_2gb_migrated': _cacheDefault2GbMigrated,
        'prioritize_newest': _prioritizeNewest,
        'auto_pause_background': _autoPauseBackgroundTorrents,
        'fast_audio_preload': _fastAudioPreload,
        'auto_start_server': _autoStartServer,
        'keep_server_running': _keepServerRunning,
        'server_port': _serverPort,
        'debrid_provider': _debridProvider.id,
        'debrid_api_keys': _debridApiKeys,
        'debrid_key_validated': _debridKeyValidated,
        'debrid_account_labels': _debridAccountLabels,
        'fallback_to_torrent_on_debrid_failure':
            _fallbackToTorrentOnDebridFailure,
        'last_accessed': _lastAccessedMap,
        'root_names': _infoHashToRootName,
      };
      final tmpFile = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await tmpFile.writeAsString(jsonEncode(json), flush: true);
      if (await tmpFile.exists()) {
        await tmpFile.rename(file.path);
      }
    } catch (e) {
      debugPrint('Error saving settings file: $e');
    }
  }

  void _scheduleDebouncedSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_saveSettingsFile());
    });
  }

  // ─── Setters ───────────────────────────────────────────────────────────────

  Future<void> setMaxCacheSizeBytes(int bytes) async {
    final clamped = bytes.clamp(kMinCacheLimitBytes, kMaxCacheLimitBytes);
    if (_maxCacheSizeBytes != clamped) {
      _maxCacheSizeBytes = clamped;
      notifyListeners();
      await _saveSettingsFile();
      await checkAndEnforceCacheLimit();
    }
  }

  Future<void> setReadAheadBufferBytes(int bytes) async {
    final clamped = bytes.clamp(kMinReadAheadBytes, kMaxReadAheadBytes);
    if (_readAheadBufferBytes != clamped) {
      _readAheadBufferBytes = clamped;
      notifyListeners();
      await _saveSettingsFile();
    }
  }

  Future<void> setPrioritizeNewest(bool value) async {
    _prioritizeNewest = value;
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> setAutoPauseBackground(bool value) async {
    _autoPauseBackgroundTorrents = value;
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> setFastAudioPreload(bool value) async {
    _fastAudioPreload = value;
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> setAutoStartServer(bool value) async {
    _autoStartServer = value;
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> setKeepServerRunning(bool value) async {
    if (_keepServerRunning == value) return;
    _keepServerRunning = value;
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> setServerPort(int port) async {
    if (port > 0 && port <= 65535) {
      _serverPort = port;
      notifyListeners();
      await _saveSettingsFile();
    }
  }

  Future<void> setDebridProvider(DebridProvider provider) async {
    if (_debridProvider == provider) return;
    _debridProvider = provider;
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> setDebridApiKey(
    DebridProvider provider,
    String apiKey, {
    bool validated = false,
    String? accountLabel,
  }) async {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      _debridApiKeys.remove(provider.id);
      _debridKeyValidated.remove(provider.id);
      _debridAccountLabels.remove(provider.id);
    } else {
      _debridApiKeys[provider.id] = trimmed;
      _debridKeyValidated[provider.id] = validated;
      if (accountLabel != null && accountLabel.trim().isNotEmpty) {
        _debridAccountLabels[provider.id] = accountLabel.trim();
      } else if (!validated) {
        _debridAccountLabels.remove(provider.id);
      }
    }
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> clearDebridApiKey(DebridProvider provider) async {
    _debridApiKeys.remove(provider.id);
    _debridKeyValidated.remove(provider.id);
    _debridAccountLabels.remove(provider.id);
    notifyListeners();
    await _saveSettingsFile();
  }

  Future<void> setFallbackToTorrentOnDebridFailure(bool value) async {
    if (_fallbackToTorrentOnDebridFailure == value) return;
    _fallbackToTorrentOnDebridFailure = value;
    notifyListeners();
    await _saveSettingsFile();
  }

  static String maskApiKey(String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.length <= 6) return '***';
    return '${trimmed.substring(0, 3)}...${trimmed.substring(trimmed.length - 3)}';
  }

  // ─── LRU Cache Management ──────────────────────────────────────────────────

  /// Registers the top-level directory or file name on disk for [infoHash].
  void registerTorrentRootName(String infoHash, String rootName) {
    final normalizedHash = infoHash.trim().toLowerCase();
    final trimmedRoot = rootName.trim();
    if (normalizedHash.isEmpty || trimmedRoot.isEmpty) return;

    final normalizedPath = trimmedRoot.replaceAll('\\', '/');
    final topSegment = normalizedPath
        .split('/')
        .firstWhere((seg) => seg.isNotEmpty, orElse: () => '');
    if (topSegment.isEmpty) return;

    if (_infoHashToRootName[normalizedHash] != topSegment) {
      _infoHashToRootName[normalizedHash] = topSegment;
      _scheduleDebouncedSave();
    }
  }

  String? getRootNameForInfoHash(String infoHash) {
    return _infoHashToRootName[infoHash.trim().toLowerCase()];
  }

  String? _matchInfoHashForBasename(String basename) {
    final baseLower = basename.toLowerCase();
    for (final entry in _infoHashToRootName.entries) {
      if (entry.value.toLowerCase() == baseLower ||
          baseLower.contains(entry.key.toLowerCase())) {
        return entry.key;
      }
    }
    for (final hash in _lastAccessedMap.keys) {
      if (baseLower.contains(hash.toLowerCase())) {
        return hash;
      }
    }
    return null;
  }

  bool _isBasenameProtected(
    String basename,
    Set<String>? protectedInfoHashes,
    String? matchedHash,
  ) {
    if (protectedInfoHashes == null || protectedInfoHashes.isEmpty) {
      return false;
    }
    final normalizedProtected =
        protectedInfoHashes.map((h) => h.toLowerCase()).toSet();
    if (matchedHash != null &&
        normalizedProtected.contains(matchedHash.toLowerCase())) {
      return true;
    }
    final baseLower = basename.toLowerCase();
    for (final hash in normalizedProtected) {
      if (baseLower.contains(hash)) return true;
      final rootName = _infoHashToRootName[hash];
      if (rootName != null && rootName.toLowerCase() == baseLower) {
        return true;
      }
    }
    return false;
  }

  /// Marks an infohash as recently accessed right now.
  void recordAccess(String infoHash) {
    if (infoHash.isEmpty) return;
    _lastAccessedMap[infoHash.toLowerCase()] =
        DateTime.now().millisecondsSinceEpoch;
    _scheduleDebouncedSave();
  }

  int getLastAccessed(String infoHash) {
    return _lastAccessedMap[infoHash.toLowerCase()] ?? 0;
  }

  /// Calculates total size of all cached files inside [_cachePath].
  Future<int> refreshCacheUsage() async {
    if (_cachePath.isEmpty) return 0;
    _isCalculatingCache = true;
    notifyListeners();

    int totalBytes = 0;
    try {
      final dir = Directory(_cachePath);
      if (await dir.exists()) {
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            // Exclude our internal config & sidecar metadata files from cache stats
            if (entity.path.endsWith('settings_config.json') ||
                entity.path.endsWith('.meta.json') ||
                entity.path.endsWith('.manifest.json') ||
                entity.path.endsWith('.tmp')) {
              continue;
            }
            try {
              totalBytes += await entity.length();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Error scanning cache size: $e');
    } finally {
      _cachedBytes = totalBytes;
      _isCalculatingCache = false;
      notifyListeners();
    }
    return totalBytes;
  }

  /// Clears all downloaded audio files from the cache directory.
  /// [activeInfoHashes] can be supplied to avoid deleting active sessions if desired.
  Future<int> clearCache({Set<String>? activeInfoHashes}) async {
    if (_cachePath.isEmpty) return 0;
    int freedBytes = 0;
    final protectedNormalized = activeInfoHashes
        ?.map((h) => h.toLowerCase())
        .toSet();
    try {
      freedBytes += await AudioDiskCacheService.instance.clearAll(
        protectedInfoHashes: activeInfoHashes,
      );

      final dir = Directory(_cachePath);
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity.path.endsWith('settings_config.json')) continue;

          final basename = entity.path.split(Platform.pathSeparator).last;
          // AudioDiskCacheService owns `<cachePath>/streams` and `<cachePath>/manifests`.
          if (basename == 'streams' || basename == 'manifests') continue;
          final matchedHash = _matchInfoHashForBasename(basename);
          if (_isBasenameProtected(basename, protectedNormalized, matchedHash)) {
            continue;
          }

          try {
            if (entity is File) {
              freedBytes += await entity.length();
              await entity.delete();
            } else if (entity is Directory) {
              await for (final f in entity.list(recursive: true)) {
                if (f is File) freedBytes += await f.length();
              }
              await entity.delete(recursive: true);
            }
            if (matchedHash != null) {
              _lastAccessedMap.remove(matchedHash);
              _infoHashToRootName.remove(matchedHash);
            }
          } catch (_) {}
        }
      }
      if (protectedNormalized == null || protectedNormalized.isEmpty) {
        _lastAccessedMap.clear();
        _infoHashToRootName.clear();
      } else {
        _lastAccessedMap.removeWhere(
          (hash, _) => !protectedNormalized.contains(hash.toLowerCase()),
        );
        _infoHashToRootName.removeWhere(
          (hash, _) => !protectedNormalized.contains(hash.toLowerCase()),
        );
      }
      await _saveSettingsFile();
      await refreshCacheUsage();
    } catch (e) {
      debugPrint('Error clearing cache: $e');
    }
    return freedBytes;
  }

  /// Deletes all unlocked cached data (smart stream cache, manifest, and raw
  /// torrent folder) associated with [infoHash].
  Future<int> deleteTorrentCache(String infoHash) async {
    if (_cachePath.isEmpty || infoHash.trim().isEmpty) return 0;
    final hashLower = infoHash.trim().toLowerCase();
    var freed = await AudioDiskCacheService.instance.deleteTorrentCache(hashLower);

    final stillInUse = AudioDiskCacheService.instance.entries.values
        .any((e) => e.infoHash == hashLower);
    if (!stillInUse) {
      final rootName = _infoHashToRootName[hashLower];
      if (rootName != null && rootName.isNotEmpty) {
        final rawTarget = Directory(
          '$_cachePath${Platform.pathSeparator}$rootName',
        );
        try {
          if (await rawTarget.exists()) {
            await for (final f in rawTarget.list(recursive: true)) {
              if (f is File) freed += await f.length();
            }
            await rawTarget.delete(recursive: true);
          } else {
            final rawFile = File(rawTarget.path);
            if (await rawFile.exists()) {
              freed += await rawFile.length();
              await rawFile.delete();
            }
          }
        } catch (_) {}
      }
      _lastAccessedMap.remove(hashLower);
      _infoHashToRootName.remove(hashLower);
      await _saveSettingsFile();
    }

    await refreshCacheUsage();
    return freed;
  }

  /// Checks if cached bytes exceed [_maxCacheSizeBytes]. If so, incrementally evicts
  /// the oldest accessed cached files until usage is <= 95% of capacity.
  Future<void> checkAndEnforceCacheLimit({
    Set<String>? protectedInfoHashes,
    Set<String>? protectedRelativePaths,
  }) async {
    if (_isEnforcingCache || _cachePath.isEmpty) return;
    _isEnforcingCache = true;
    try {
      final currentUsage = await refreshCacheUsage();
      if (currentUsage <= _maxCacheSizeBytes) return;

      final targetLimit = (_maxCacheSizeBytes * 0.95).toInt();
      debugPrint(
        'Cache limit exceeded (${formatBytes(currentUsage)} > ${formatBytes(_maxCacheSizeBytes)}). '
        'Incrementally evicting oldest cached files to reach ${formatBytes(targetLimit)}...',
      );

      final dir = Directory(_cachePath);
      if (!await dir.exists()) return;

      final normalizedProtectedPaths = protectedRelativePaths
          ?.map((p) => p.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '').toLowerCase())
          .where((p) => p.isNotEmpty)
          .toSet();

      final items = <_CacheItemEntry>[];
      final cachePrefix = _cachePath.endsWith(Platform.pathSeparator)
          ? _cachePath
          : '$_cachePath${Platform.pathSeparator}';

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (entity.path.endsWith('settings_config.json') ||
            entity.path.endsWith('.meta.json') ||
            entity.path.endsWith('.manifest.json') ||
            entity.path.endsWith('.tmp')) {
          continue;
        }

        final relRaw = entity.path.startsWith(cachePrefix)
            ? entity.path.substring(cachePrefix.length)
            : entity.path.split(Platform.pathSeparator).last;
        final relNorm = relRaw.replaceAll('\\', '/');
        final topSegment = relNorm
            .split('/')
            .firstWhere((seg) => seg.isNotEmpty, orElse: () => relNorm);
        if (topSegment == 'streams' || topSegment == 'manifests') {
          // Handled safely by AudioDiskCacheService with reader/writer locks.
          continue;
        }

        int size = 0;
        int fileModifiedMs = 0;
        try {
          final stat = await entity.stat();
          size = stat.size;
          fileModifiedMs = stat.modified.millisecondsSinceEpoch;
        } catch (_) {
          continue;
        }

        final matchedHash = _matchInfoHashForBasename(topSegment);
        final torrentAccessMs = matchedHash != null
            ? (_lastAccessedMap[matchedHash] ?? fileModifiedMs)
            : fileModifiedMs;

        final isProtectedByHash = _isBasenameProtected(
          topSegment,
          protectedInfoHashes,
          matchedHash,
        );
        final isProtectedByPath = normalizedProtectedPaths != null &&
            normalizedProtectedPaths.contains(relNorm.toLowerCase());

        final isDuplicateOfCompleteCache = matchedHash != null &&
            AudioDiskCacheService.instance.isTorrentFullyCached(matchedHash);

        items.add(_CacheItemEntry(
          entity: entity,
          infoHash: matchedHash,
          sizeBytes: size,
          lastAccessedMs: torrentAccessMs,
          fileModifiedMs: fileModifiedMs,
          isProtected: isProtectedByHash || isProtectedByPath,
          isDuplicateTemp: isDuplicateOfCompleteCache,
        ));
      }

      // Sort unprotected items: redundant raw copies of 100%-cached torrents first,
      // then oldest-first (by torrent access time, then file mtime).
      items.sort((a, b) {
        if (a.isProtected != b.isProtected) {
          return a.isProtected ? 1 : -1;
        }
        if (a.isDuplicateTemp != b.isDuplicateTemp) {
          return a.isDuplicateTemp ? -1 : 1;
        }
        final accessCmp = a.lastAccessedMs.compareTo(b.lastAccessedMs);
        if (accessCmp != 0) return accessCmp;
        return a.fileModifiedMs.compareTo(b.fileModifiedMs);
      });

      int remaining = currentUsage;
      for (final item in items) {
        if (remaining <= targetLimit) break;
        if (item.isProtected) continue;

        try {
          await item.entity.delete();
          remaining -= item.sizeBytes;
          debugPrint('Evicted old cache file "${item.entity.path}" (${formatBytes(item.sizeBytes)})');
        } catch (e) {
          debugPrint('Failed to evict ${item.entity.path}: $e');
        }
      }

      if (remaining > _maxCacheSizeBytes) {
        final freedFromStreams =
            await AudioDiskCacheService.instance.enforceCacheLimit(
          maxBytes: _maxCacheSizeBytes,
          currentTotalBytes: remaining,
          protectedInfoHashes: protectedInfoHashes,
        );
        remaining -= freedFromStreams;
      }

      await _pruneEmptyDirectories(dir);
      await _saveSettingsFile();
      await refreshCacheUsage();
    } catch (e) {
      debugPrint('Error enforcing cache limit: $e');
    } finally {
      _isEnforcingCache = false;
    }
  }

  Future<void> _pruneEmptyDirectories(Directory root) async {
    try {
      final subdirs = <Directory>[];
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is Directory) {
          subdirs.add(entity);
        }
      }
      // Sort deepest paths first so nested empty folders collapse cleanly.
      subdirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in subdirs) {
        try {
          if (await d.list(followLinks: false).isEmpty) {
            await d.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Map<String, dynamic> toJson() => {
        'max_cache_size_bytes': _maxCacheSizeBytes,
        'max_cache_size_formatted': maxCacheSizeFormatted,
        'read_ahead_buffer_bytes': _readAheadBufferBytes,
        'read_ahead_buffer_formatted': readAheadBufferFormatted,
        'cached_bytes': _cachedBytes,
        'cached_bytes_formatted': cachedBytesFormatted,
        'cache_usage_ratio': cacheUsageRatio,
        'prioritize_newest': _prioritizeNewest,
        'auto_pause_background': _autoPauseBackgroundTorrents,
        'fast_audio_preload': _fastAudioPreload,
        'auto_start_server': _autoStartServer,
        'keep_server_running': _keepServerRunning,
        'server_port': _serverPort,
        'debrid_provider': _debridProvider.id,
        'debrid_provider_name': _debridProvider.displayName,
        'has_debrid_api_key': hasConfiguredDebrid,
        'debrid_api_key_masked': maskApiKey(activeDebridApiKey),
        'debrid_key_validated': isActiveDebridKeyValidated,
        'debrid_account_label': activeDebridAccountLabel,
        'fallback_to_torrent_on_debrid_failure':
            _fallbackToTorrentOnDebridFailure,
        'cache_path': _cachePath,
        'disk_cache': AudioDiskCacheService.instance.toSummaryJson(),
      };
}

class _CacheItemEntry {
  final FileSystemEntity entity;
  final String? infoHash;
  final int sizeBytes;
  final int lastAccessedMs;
  final int fileModifiedMs;
  final bool isProtected;
  final bool isDuplicateTemp;

  _CacheItemEntry({
    required this.entity,
    required this.infoHash,
    required this.sizeBytes,
    required this.lastAccessedMs,
    required this.fileModifiedMs,
    required this.isProtected,
    this.isDuplicateTemp = false,
  });
}
