import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Inclusive byte range `[start, end]` representing verified cached bytes on disk.
class ByteRange {
  final int start;
  final int end;

  const ByteRange(this.start, this.end);

  int get length => end - start + 1;

  bool contains(int offset) => offset >= start && offset <= end;

  bool containsRange(int rStart, int rEnd) => start <= rStart && end >= rEnd;

  Map<String, int> toJson() => {
        'start': start,
        'end': end,
      };

  factory ByteRange.fromJson(Map<String, dynamic> json) {
    final start = (json['start'] as num?)?.toInt() ?? 0;
    final end = (json['end'] as num?)?.toInt() ?? -1;
    return ByteRange(start, end);
  }

  /// Normalizes and merges overlapping or directly adjacent byte ranges.
  static List<ByteRange> mergeRanges(Iterable<ByteRange> rawRanges) {
    final valid = rawRanges.where((r) => r.start >= 0 && r.end >= r.start).toList();
    if (valid.isEmpty) return const [];

    valid.sort((a, b) {
      final s = a.start.compareTo(b.start);
      return s != 0 ? s : a.end.compareTo(b.end);
    });

    final merged = <ByteRange>[valid.first];
    for (var i = 1; i < valid.length; i++) {
      final next = valid[i];
      final current = merged.last;
      if (next.start <= current.end + 1) {
        merged[merged.length - 1] = ByteRange(
          current.start,
          math.max(current.end, next.end),
        );
      } else {
        merged.add(next);
      }
    }
    return merged;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ByteRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start..$end]';
}

/// Persistent metadata and lock state for a single cached audio file.
class DiskCacheEntry {
  final String key;
  final String infoHash;
  final int fileIndex;

  String fileName;
  String filePath;
  String mimeType;
  int fileSize;
  int lastAccessedMs;
  int updatedAtMs;
  List<ByteRange> ranges;

  /// Active readers/writers prevent LRU eviction or clearing while in use.
  int activeReaders = 0;
  int activeWriters = 0;

  /// Tracks uncommitted bytes written since the last metadata flush.
  int pendingMetadataBytes = 0;

  DiskCacheEntry({
    required this.key,
    required this.infoHash,
    required this.fileIndex,
    this.fileName = '',
    this.filePath = '',
    this.mimeType = 'application/octet-stream',
    this.fileSize = 0,
    int? lastAccessedMs,
    int? updatedAtMs,
    List<ByteRange>? ranges,
  })  : lastAccessedMs = lastAccessedMs ?? DateTime.now().millisecondsSinceEpoch,
        updatedAtMs = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch,
        ranges = List<ByteRange>.from(ByteRange.mergeRanges(ranges ?? const []));

  bool get isInUse => activeReaders > 0 || activeWriters > 0;

  int get cachedBytes => ranges.fold<int>(0, (sum, r) => sum + r.length);

  bool get isComplete =>
      fileSize > 0 &&
      ranges.length == 1 &&
      ranges.first.start == 0 &&
      ranges.first.end >= fileSize - 1;

  double get cachedPercentage =>
      fileSize > 0 ? (cachedBytes / fileSize).clamp(0.0, 1.0) : 0.0;

  bool isRangeCached(int start, int end) {
    if (start < 0 || end < start) return false;
    return ranges.any((r) => r.containsRange(start, end));
  }

  ByteRange? findCoveringRange(int offset) {
    for (final r in ranges) {
      if (r.start <= offset && offset <= r.end) {
        return r;
      }
      if (r.start > offset) {
        break;
      }
    }
    return null;
  }

  ByteRange? findNextCachedRangeAfter(int offset) {
    for (final r in ranges) {
      if (r.start > offset) {
        return r;
      }
    }
    return null;
  }

  void addRange(int start, int end) {
    if (start < 0 || end < start) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    ranges = List<ByteRange>.from(
      ByteRange.mergeRanges([...ranges, ByteRange(start, end)]),
    );
    updatedAtMs = now;
    lastAccessedMs = now;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'infohash': infoHash,
        'file_index': fileIndex,
        'file_name': fileName,
        'file_path': filePath,
        'mime_type': mimeType,
        'file_size': fileSize,
        'last_accessed_ms': lastAccessedMs,
        'updated_at_ms': updatedAtMs,
        'ranges': ranges.map((r) => r.toJson()).toList(),
      };

  factory DiskCacheEntry.fromJson(Map<String, dynamic> json) {
    final rawHash = (json['infohash'] ?? '').toString().trim().toLowerCase();
    final fileIndex = (json['file_index'] as num?)?.toInt() ?? 0;
    final key = (json['key'] ?? '${rawHash}_$fileIndex').toString().toLowerCase();
    final rawRanges = <ByteRange>[];
    if (json['ranges'] is List) {
      for (final item in json['ranges'] as List) {
        if (item is Map<String, dynamic>) {
          rawRanges.add(ByteRange.fromJson(item));
        } else if (item is Map) {
          rawRanges.add(
            ByteRange.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
          );
        }
      }
    }

    return DiskCacheEntry(
      key: key,
      infoHash: rawHash,
      fileIndex: fileIndex,
      fileName: (json['file_name'] ?? '').toString(),
      filePath: (json['file_path'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? 'application/octet-stream').toString(),
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
      lastAccessedMs: (json['last_accessed_ms'] as num?)?.toInt(),
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt(),
      ranges: rawRanges,
    );
  }
}

/// Simple per-key async mutex chain so concurrent writes/flushes on the same
/// cache entry execute sequentially without racing on file descriptors.
class _PerKeyAsyncLock {
  final Map<String, Future<void>> _tails = {};

  Future<T> synchronized<T>(String key, Future<T> Function() action) {
    final prev = _tails[key] ?? Future<void>.value();
    final completer = Completer<void>();
    final nextTail = completer.future;
    _tails[key] = nextTail;

    return prev.catchError((_) {}).then((_) async {
      try {
        return await action();
      } finally {
        if (identical(_tails[key], nextTail)) {
          _tails.remove(key);
        }
        completer.complete();
      }
    });
  }
}

/// Persistent disk-based random-access byte-range cache for streamed audio files.
///
/// Stores sparse data in `<baseCachePath>/streams/<key>.bin` paired with
/// crash-consistent range metadata in `<key>.meta.json` (written via `.tmp` + rename).
class AudioDiskCacheService extends ChangeNotifier {
  static final AudioDiskCacheService instance = AudioDiskCacheService._();
  AudioDiskCacheService._();

  static const int _metadataFlushThresholdBytes = 256 * 1024; // 256 KB

  bool _isInitialized = false;
  String _streamsDirPath = '';
  final Map<String, DiskCacheEntry> _entries = {};
  final _PerKeyAsyncLock _locks = _PerKeyAsyncLock();

  bool get isInitialized => _isInitialized;
  String get streamsDirPath => _streamsDirPath;
  Map<String, DiskCacheEntry> get entries => Map.unmodifiable(_entries);

  static String buildKey(String infoHash, int fileIndex) =>
      '${infoHash.trim().toLowerCase()}_$fileIndex';

  File _binFileForKey(String key) =>
      File('$_streamsDirPath${Platform.pathSeparator}$key.bin');

  File _metaFileForKey(String key) =>
      File('$_streamsDirPath${Platform.pathSeparator}$key.meta.json');

  File _tmpMetaFileForKey(String key) =>
      File('$_streamsDirPath${Platform.pathSeparator}$key.meta.json.tmp');

  int get totalCachedBytes {
    var total = 0;
    for (final entry in _entries.values) {
      total += math.max(entry.cachedBytes, 0);
    }
    return total;
  }

  int get totalDiskBytes {
    var total = 0;
    for (final entry in _entries.values) {
      final bin = _binFileForKey(entry.key);
      if (bin.existsSync()) {
        try {
          total += bin.lengthSync();
        } catch (_) {
          total += math.max(entry.cachedBytes, 0);
        }
      }
    }
    return total;
  }

  /// Initializes the persistent disk cache from `<baseCachePath>/streams`,
  /// recovering any interrupted atomic metadata writes and reconciling
  /// recorded byte ranges against physical `.bin` file lengths.
  Future<void> init({
    required String baseCachePath,
    bool forceReload = false,
  }) async {
    final targetDirPath =
        '$baseCachePath${Platform.pathSeparator}streams';
    if (_isInitialized &&
        !forceReload &&
        _streamsDirPath == targetDirPath) {
      return;
    }

    _streamsDirPath = targetDirPath;
    _entries.clear();

    final dir = Directory(_streamsDirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final metaFilesByKey = <String, File>{};
    final tmpFilesByKey = <String, File>{};
    final binFilesByKey = <String, File>{};

    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.endsWith('.meta.json.tmp')) {
        final key = name.substring(0, name.length - '.meta.json.tmp'.length).toLowerCase();
        tmpFilesByKey[key] = entity;
      } else if (name.endsWith('.meta.json')) {
        final key = name.substring(0, name.length - '.meta.json'.length).toLowerCase();
        metaFilesByKey[key] = entity;
      } else if (name.endsWith('.bin')) {
        final key = name.substring(0, name.length - '.bin'.length).toLowerCase();
        binFilesByKey[key] = entity;
      }
    }

    // Reconcile metadata and recover interrupted .meta.json.tmp files
    final allMetaKeys = <String>{...metaFilesByKey.keys, ...tmpFilesByKey.keys};
    for (final key in allMetaKeys) {
      final metaFile = metaFilesByKey[key];
      final tmpFile = tmpFilesByKey[key];
      final binFile = binFilesByKey[key];

      DiskCacheEntry? parsed = await _tryParseEntryFile(metaFile);
      if (parsed == null) {
        final recovered = await _tryParseEntryFile(tmpFile);
        if (recovered != null) {
          parsed = recovered;
          await _writeMetaAtomic(parsed);
        }
      }

      // Clean up stale temp file
      if (tmpFile != null && await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }

      if (parsed == null) {
        if (metaFile != null && await metaFile.exists()) {
          try {
            await metaFile.delete();
          } catch (_) {}
        }
        continue;
      }

      if (binFile == null || !await binFile.exists()) {
        try {
          if (metaFile != null && await metaFile.exists()) {
            await metaFile.delete();
          }
        } catch (_) {}
        continue;
      }

      final actualLen = await binFile.length();
      if (actualLen <= 0 && parsed.ranges.isEmpty) {
        // Keep empty placeholder only if it has valid metadata? Clean empty uncached artifacts on restart
        try {
          await binFile.delete();
          if (metaFile != null && await metaFile.exists()) {
            await metaFile.delete();
          }
        } catch (_) {}
        continue;
      }

      // Clamp ranges to physical file bounds for crash consistency
      var repaired = false;
      final clampedRanges = <ByteRange>[];
      for (final r in parsed.ranges) {
        if (actualLen <= 0 || r.start >= actualLen) {
          repaired = true;
          continue;
        }
        final clampedEnd = math.min(r.end, actualLen - 1);
        if (clampedEnd != r.end) {
          repaired = true;
        }
        if (clampedEnd >= r.start) {
          clampedRanges.add(ByteRange(r.start, clampedEnd));
        }
      }
      parsed.ranges = List<ByteRange>.from(ByteRange.mergeRanges(clampedRanges));

      if (repaired) {
        await _writeMetaAtomic(parsed);
      }

      _entries[parsed.key] = parsed;
    }

    // Delete orphaned .bin files that have no valid metadata
    for (final entry in binFilesByKey.entries) {
      if (!_entries.containsKey(entry.key)) {
        try {
          await entry.value.delete();
        } catch (_) {}
      }
    }

    _isInitialized = true;
    notifyListeners();
  }

  Future<DiskCacheEntry?> _tryParseEntryFile(File? file) async {
    if (file == null || !await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final entry = DiskCacheEntry.fromJson(json);
      if (entry.infoHash.isEmpty || entry.key.isEmpty) return null;
      return entry;
    } catch (_) {
      return null;
    }
  }

  DiskCacheEntry? getEntry(String infoHash, int fileIndex) {
    return _entries[buildKey(infoHash, fileIndex)];
  }

  DiskCacheEntry? getEntryByKey(String key) {
    return _entries[key.trim().toLowerCase()];
  }

  /// Finds a cached entry matching [infoHash] and optional [fileIndex] / [filePath].
  DiskCacheEntry? findMatchingEntry({
    required String infoHash,
    int? fileIndex,
    String? filePath,
  }) {
    final hashLower = infoHash.trim().toLowerCase();
    if (hashLower.isEmpty) return null;

    if (fileIndex != null && fileIndex >= 0) {
      return _entries[buildKey(hashLower, fileIndex)];
    }

    final candidates = _entries.values
        .where((e) => e.infoHash == hashLower)
        .toList();
    if (candidates.isEmpty) return null;

    if (filePath != null && filePath.trim().isNotEmpty) {
      final query = _normalizePath(filePath).toLowerCase();
      for (final e in candidates) {
        if (_normalizePath(e.filePath).toLowerCase() == query) return e;
      }
      for (final e in candidates) {
        final norm = _normalizePath(e.filePath).toLowerCase();
        if (norm.endsWith('/$query') || query.endsWith('/$norm')) return e;
      }
      for (final e in candidates) {
        if (e.fileName.toLowerCase() == query) return e;
      }
      return null;
    }

    // Pick most recently accessed complete or partial entry for infoHash
    candidates.sort((a, b) => b.lastAccessedMs.compareTo(a.lastAccessedMs));
    return candidates.first;
  }

  static String _normalizePath(String p) {
    var s = p.trim().replaceAll('\\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    return s;
  }

  /// Creates or updates a persistent [DiskCacheEntry] on disk and returns it.
  Future<DiskCacheEntry> ensureEntry({
    required String infoHash,
    required int fileIndex,
    String fileName = '',
    String filePath = '',
    String mimeType = 'application/octet-stream',
    int fileSize = 0,
  }) async {
    if (_streamsDirPath.isEmpty) {
      throw StateError('AudioDiskCacheService must be initialized before use.');
    }

    final hashLower = infoHash.trim().toLowerCase();
    final key = buildKey(hashLower, fileIndex);

    return _locks.synchronized(key, () async {
      var entry = _entries[key];
      var changed = false;
      final now = DateTime.now().millisecondsSinceEpoch;

      if (entry == null) {
        entry = DiskCacheEntry(
          key: key,
          infoHash: hashLower,
          fileIndex: fileIndex,
          fileName: fileName,
          filePath: filePath,
          mimeType: mimeType,
          fileSize: fileSize,
          lastAccessedMs: now,
          updatedAtMs: now,
        );
        _entries[key] = entry;
        changed = true;
      } else {
        if (fileName.isNotEmpty && entry.fileName != fileName) {
          entry.fileName = fileName;
          changed = true;
        }
        if (filePath.isNotEmpty && entry.filePath != filePath) {
          entry.filePath = filePath;
          changed = true;
        }
        if (mimeType.isNotEmpty && entry.mimeType != mimeType) {
          entry.mimeType = mimeType;
          changed = true;
        }
        if (fileSize > 0 && entry.fileSize != fileSize) {
          entry.fileSize = fileSize;
          changed = true;
        }
        entry.lastAccessedMs = now;
      }

      final binFile = _binFileForKey(key);
      if (!await binFile.exists()) {
        await binFile.create(recursive: true);
      }

      if (changed || !await _metaFileForKey(key).exists()) {
        await _writeMetaAtomic(entry);
      }

      notifyListeners();
      return entry;
    });
  }

  bool isRangeCached(String key, int start, int end) {
    final entry = _entries[key.toLowerCase()];
    if (entry == null) return false;
    return entry.isRangeCached(start, end);
  }

  bool isFileComplete(String key) {
    final entry = _entries[key.toLowerCase()];
    return entry?.isComplete ?? false;
  }

  void recordAccess(String key) {
    final entry = _entries[key.toLowerCase()];
    if (entry != null) {
      entry.lastAccessedMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void acquireReadLock(String key) {
    final entry = _entries[key.toLowerCase()];
    if (entry != null) {
      entry.activeReaders++;
      entry.lastAccessedMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void releaseReadLock(String key) {
    final entry = _entries[key.toLowerCase()];
    if (entry != null && entry.activeReaders > 0) {
      entry.activeReaders--;
    }
  }

  void acquireWriteLock(String key) {
    final entry = _entries[key.toLowerCase()];
    if (entry != null) {
      entry.activeWriters++;
      entry.lastAccessedMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  Future<void> releaseWriteLock(String key) async {
    final k = key.toLowerCase();
    final entry = _entries[k];
    if (entry != null && entry.activeWriters > 0) {
      entry.activeWriters--;
    }
    await flushEntry(k);
  }

  /// Flushes metadata atomically to `<key>.meta.json` if the entry exists.
  Future<void> flushEntry(String key) async {
    final k = key.toLowerCase();
    return _locks.synchronized(k, () async {
      final entry = _entries[k];
      if (entry == null) return;
      await _writeMetaAtomic(entry);
      entry.pendingMetadataBytes = 0;
    });
  }

  /// Streams `[start, end]` inclusive directly from the local `.bin` file
  /// while holding an active read lock to protect against concurrent eviction.
  Stream<List<int>> openCachedRangeStream(
    String key,
    int start,
    int end, {
    int chunkSize = 64 * 1024,
  }) async* {
    final k = key.toLowerCase();
    if (start < 0 || end < start) return;

    acquireReadLock(k);
    RandomAccessFile? raf;
    try {
      final binFile = _binFileForKey(k);
      if (!await binFile.exists()) {
        throw FileSystemException('Cached binary file missing', binFile.path);
      }

      raf = await binFile.open(mode: FileMode.read);
      await raf.setPosition(start);

      var remaining = end - start + 1;
      while (remaining > 0) {
        final toRead = math.min(chunkSize, remaining);
        final data = await raf.read(toRead);
        if (data.isEmpty) {
          throw StateError(
            'Unexpected EOF reading cached range [$start..$end] for $k (remaining=$remaining)',
          );
        }
        remaining -= data.length;
        yield data;
      }
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      releaseReadLock(k);
    }
  }

  /// Writes [bytes] at exact byte [offset] into `<key>.bin` and updates
  /// the cached `[start, end]` range metadata atomically.
  Future<void> writeChunk(
    String key,
    int offset,
    List<int> bytes, {
    int? totalFileSize,
    bool forceFlushMetadata = false,
  }) async {
    if (bytes.isEmpty || offset < 0) return;
    final k = key.toLowerCase();

    await _locks.synchronized(k, () async {
      final entry = _entries[k];
      if (entry == null) return;

      final binFile = _binFileForKey(k);
      if (!await binFile.exists()) {
        await binFile.create(recursive: true);
      }

      // Note: On Windows/POSIX, FileMode.append opens O_RDWR without truncating
      // AND without forcing OS O_APPEND in Dart VM's RandomAccessFile.setPosition+writeFrom,
      // allowing random-access writes at any offset.
      final raf = await binFile.open(mode: FileMode.append);
      try {
        await raf.setPosition(offset);
        await raf.writeFrom(bytes);
      } finally {
        await raf.close();
      }

      if (totalFileSize != null && totalFileSize > 0) {
        entry.fileSize = totalFileSize;
      }
      entry.addRange(offset, offset + bytes.length - 1);
      entry.pendingMetadataBytes += bytes.length;

      if (forceFlushMetadata ||
          entry.pendingMetadataBytes >= _metadataFlushThresholdBytes ||
          entry.isComplete) {
        await _writeMetaAtomic(entry);
        entry.pendingMetadataBytes = 0;
        notifyListeners();
      }
    });
  }

  Future<void> _writeMetaAtomic(DiskCacheEntry entry) async {
    if (_streamsDirPath.isEmpty) return;
    final tmpFile = _tmpMetaFileForKey(entry.key);
    final metaFile = _metaFileForKey(entry.key);
    final payload = jsonEncode(entry.toJson());
    await tmpFile.writeAsString(payload, flush: true);
    if (await metaFile.exists()) {
      await metaFile.delete();
    }
    await tmpFile.rename(metaFile.path);
  }

  /// Evicts least recently used unlocked cache entries until total disk usage
  /// fits within `(maxBytes * 0.95)` (or until no evictable entries remain).
  ///
  /// Never evicts any entry with `activeReaders > 0` or `activeWriters > 0`.
  Future<int> enforceCacheLimit({
    required int maxBytes,
    int? currentTotalBytes,
    Set<String>? protectedInfoHashes,
    Set<String>? protectedKeys,
  }) async {
    if (_streamsDirPath.isEmpty || maxBytes <= 0) return 0;

    final protectedHashesLower =
        protectedInfoHashes?.map((h) => h.trim().toLowerCase()).toSet() ??
            const <String>{};
    final protectedKeysLower =
        protectedKeys?.map((k) => k.trim().toLowerCase()).toSet() ??
            const <String>{};

    var totalBytes = currentTotalBytes ?? totalDiskBytes;
    if (totalBytes <= maxBytes) return 0;

    final targetBytes = (maxBytes * 0.95).toInt();
    final candidates = _entries.values.where((e) {
      if (e.isInUse) return false;
      if (protectedKeysLower.contains(e.key)) return false;
      if (protectedHashesLower.contains(e.infoHash)) return false;
      return true;
    }).toList();

    // Sort Least Recently Used first
    candidates.sort((a, b) => a.lastAccessedMs.compareTo(b.lastAccessedMs));

    var freed = 0;
    for (final candidate in candidates) {
      if (totalBytes <= targetBytes) break;
      final removedBytes = await _deleteEntryIfUnlocked(candidate.key);
      if (removedBytes > 0) {
        freed += removedBytes;
        totalBytes = math.max(0, totalBytes - removedBytes);
      }
    }

    if (freed > 0) {
      notifyListeners();
    }
    return freed;
  }

  /// Clears all unlocked cached files from `<cachePath>/streams`.
  Future<int> clearAll({
    Set<String>? protectedInfoHashes,
    Set<String>? protectedKeys,
  }) async {
    if (_streamsDirPath.isEmpty) return 0;
    final protectedHashesLower =
        protectedInfoHashes?.map((h) => h.trim().toLowerCase()).toSet() ??
            const <String>{};
    final protectedKeysLower =
        protectedKeys?.map((k) => k.trim().toLowerCase()).toSet() ??
            const <String>{};

    var freed = 0;
    final keys = _entries.keys.toList();
    for (final key in keys) {
      final entry = _entries[key];
      if (entry == null) continue;
      if (entry.isInUse) continue;
      if (protectedKeysLower.contains(entry.key)) continue;
      if (protectedHashesLower.contains(entry.infoHash)) continue;
      freed += await _deleteEntryIfUnlocked(key);
    }

    if (freed > 0) {
      notifyListeners();
    }
    return freed;
  }

  Future<int> _deleteEntryIfUnlocked(String key) async {
    final k = key.toLowerCase();
    return _locks.synchronized(k, () async {
      final entry = _entries[k];
      if (entry == null || entry.isInUse) return 0;

      var entrySize = entry.cachedBytes;
      final binFile = _binFileForKey(k);
      final metaFile = _metaFileForKey(k);
      final tmpFile = _tmpMetaFileForKey(k);

      try {
        if (await binFile.exists()) {
          final phys = await binFile.length();
          if (phys > 0) {
            entrySize = phys;
          }
          await binFile.delete();
        }
      } catch (e) {
        debugPrint('AudioDiskCacheService: Failed deleting ${binFile.path}: $e');
        return 0;
      }

      for (final f in [metaFile, tmpFile]) {
        try {
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }

      _entries.remove(k);
      return entrySize;
    });
  }

  Map<String, dynamic> toSummaryJson() => {
        'entry_count': _entries.length,
        'total_cached_bytes': totalCachedBytes,
        'entries': _entries.values.map((e) => {
          'key': e.key,
          'infohash': e.infoHash,
          'file_index': e.fileIndex,
          'file_name': e.fileName,
          'file_size': e.fileSize,
          'cached_bytes': e.cachedBytes,
          'cached_percentage': e.cachedPercentage,
          'is_complete': e.isComplete,
          'range_count': e.ranges.length,
          'active_readers': e.activeReaders,
          'active_writers': e.activeWriters,
          'last_accessed_ms': e.lastAccessedMs,
        }).toList(),
      };
}
