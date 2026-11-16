import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/streaming_models.dart';

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

/// Summary of piece-level completion for a cached file.
class PieceCoverageStats {
  final int pieceLength;
  final int startPiece;
  final int endPiece;
  final int totalPieces;
  final int downloadedPieces;
  final List<ByteRange> downloadedSpans;
  final bool isExactTorrentPieces;

  const PieceCoverageStats({
    required this.pieceLength,
    required this.startPiece,
    required this.endPiece,
    required this.totalPieces,
    required this.downloadedPieces,
    required this.downloadedSpans,
    required this.isExactTorrentPieces,
  });

  double get completionRatio =>
      totalPieces > 0 ? (downloadedPieces / totalPieces).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
        'piece_length': pieceLength,
        'start_piece': startPiece,
        'end_piece': endPiece,
        'total_pieces': totalPieces,
        'downloaded_pieces': downloadedPieces,
        'missing_pieces': math.max(0, totalPieces - downloadedPieces),
        'is_exact_torrent_pieces': isExactTorrentPieces,
        'downloaded_spans': downloadedSpans
            .map((s) => {'start': s.start, 'end': s.end})
            .toList(),
      };
}

/// File entry within a persisted [TorrentManifest].
class TorrentManifestFile {
  final int index;
  final String name;
  final String path;
  final int size;
  final int offsetInTorrent;
  final String mimeType;
  final bool isAudioFile;

  const TorrentManifestFile({
    required this.index,
    required this.name,
    required this.path,
    required this.size,
    required this.offsetInTorrent,
    required this.mimeType,
    required this.isAudioFile,
  });

  int startPiece(int pieceLength) {
    if (pieceLength <= 0 || size <= 0) return -1;
    return offsetInTorrent ~/ pieceLength;
  }

  int endPiece(int pieceLength) {
    if (pieceLength <= 0 || size <= 0) return -1;
    return (offsetInTorrent + size - 1) ~/ pieceLength;
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'name': name,
        'path': path,
        'size': size,
        'offset_in_torrent': offsetInTorrent,
        'mime_type': mimeType,
        'is_audio_file': isAudioFile,
      };

  factory TorrentManifestFile.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '').toString();
    final path = (json['path'] ?? name).toString();
    final ext = AudioFileEntry.extractExtension(
      name.isNotEmpty ? name : path,
    );
    return TorrentManifestFile(
      index: (json['index'] as num?)?.toInt() ?? 0,
      name: name,
      path: path,
      size: (json['size'] as num?)?.toInt() ?? 0,
      offsetInTorrent: (json['offset_in_torrent'] as num?)?.toInt() ?? 0,
      mimeType: (json['mime_type'] ?? AudioFileEntry.mimeTypeForExtension(ext))
          .toString(),
      isAudioFile: json['is_audio_file'] as bool? ??
          AudioFileEntry.isAudioExtension(ext),
    );
  }
}

/// Persisted torrent metadata & piece geometry manifest so partially or fully
/// cached torrents can resume instantaneously without waiting on peer metadata.
class TorrentManifest {
  final String infoHash;
  String torrentName;
  String magnetUri;
  int pieceLength;
  int totalSize;
  int numPieces;
  int updatedAtMs;
  List<TorrentManifestFile> files;

  TorrentManifest({
    required this.infoHash,
    this.torrentName = '',
    this.magnetUri = '',
    this.pieceLength = 0,
    this.totalSize = 0,
    this.numPieces = 0,
    int? updatedAtMs,
    List<TorrentManifestFile>? files,
  })  : updatedAtMs = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch,
        files = files ?? const [];

  TorrentManifestFile? fileAtIndex(int fileIndex) {
    for (final f in files) {
      if (f.index == fileIndex) return f;
    }
    return null;
  }

  TorrentManifestFile? findFile({int? fileIndex, String? filePath}) {
    if (files.isEmpty) return null;
    if (fileIndex != null && fileIndex >= 0) {
      return fileAtIndex(fileIndex);
    }
    if (filePath != null && filePath.trim().isNotEmpty) {
      final entries = files
          .map(
            (f) => AudioFileEntry(
              index: f.index,
              name: f.name,
              path: f.path,
              size: f.size,
              isStreamable: f.isAudioFile,
              extension: AudioFileEntry.extractExtension(f.name),
              mimeType: f.mimeType,
              formatLabel: '',
              isAudioFile: f.isAudioFile,
            ),
          )
          .toList();
      try {
        final match = _selectMatching(entries, filePath);
        return fileAtIndex(match.index);
      } catch (_) {
        return null;
      }
    }
    for (final f in files) {
      if (f.isAudioFile) return f;
    }
    return files.first;
  }

  static AudioFileEntry _selectMatching(
    List<AudioFileEntry> files,
    String filePath,
  ) {
    var query = filePath.trim().replaceAll('\\', '/');
    while (query.startsWith('/')) {
      query = query.substring(1);
    }
    final queryLower = query.toLowerCase();
    for (final f in files) {
      if (f.path.replaceAll('\\', '/').toLowerCase() == queryLower) return f;
    }
    for (final f in files) {
      final norm = f.path.replaceAll('\\', '/').toLowerCase();
      if (norm.endsWith('/$queryLower') || queryLower.endsWith('/$norm')) {
        return f;
      }
    }
    for (final f in files) {
      if (f.name.toLowerCase() == queryLower) return f;
    }
    throw ArgumentError('No matching file');
  }

  /// Infers the exact BitTorrent power-of-two piece length from `libtorrent_flutter`'s
  /// `StreamInfo.readaheadWindow` (`16 MB / piece_length`).
  static int inferPieceLengthFromReadaheadWindow(int readaheadWindow) {
    if (readaheadWindow <= 0) return 0;
    const fixedReadahead = 16 * 1024 * 1024;
    final approx = fixedReadahead / readaheadWindow;
    const candidates = <int>[
      16 * 1024,
      32 * 1024,
      64 * 1024,
      128 * 1024,
      256 * 1024,
      512 * 1024,
      1024 * 1024,
      2 * 1024 * 1024,
      4 * 1024 * 1024,
      8 * 1024 * 1024,
      16 * 1024 * 1024,
    ];
    var best = candidates.first;
    var bestDiff = (approx - best).abs();
    for (final c in candidates.skip(1)) {
      final diff = (approx - c).abs();
      if (diff < bestDiff) {
        best = c;
        bestDiff = diff;
      }
    }
    return best;
  }

  Map<String, dynamic> toJson() => {
        'infohash': infoHash,
        'torrent_name': torrentName,
        'magnet_uri': magnetUri,
        'piece_length': pieceLength,
        'total_size': totalSize,
        'num_pieces': numPieces,
        'updated_at_ms': updatedAtMs,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory TorrentManifest.fromJson(Map<String, dynamic> json) {
    final hash = (json['infohash'] ?? '').toString().trim().toLowerCase();
    final filesList = <TorrentManifestFile>[];
    if (json['files'] is List) {
      for (final item in json['files'] as List) {
        if (item is Map<String, dynamic>) {
          filesList.add(TorrentManifestFile.fromJson(item));
        } else if (item is Map) {
          filesList.add(
            TorrentManifestFile.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
    }
    return TorrentManifest(
      infoHash: hash,
      torrentName: (json['torrent_name'] ?? '').toString(),
      magnetUri: (json['magnet_uri'] ?? '').toString(),
      pieceLength: (json['piece_length'] as num?)?.toInt() ?? 0,
      totalSize: (json['total_size'] as num?)?.toInt() ?? 0,
      numPieces: (json['num_pieces'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt(),
      files: filesList,
    );
  }
}

/// Persistent metadata, piece geometry, and lock state for a single cached audio file.
class DiskCacheEntry {
  final String key;
  final String infoHash;
  final int fileIndex;

  String torrentName;
  String fileName;
  String filePath;
  String mimeType;
  int fileSize;
  int pieceLength;
  int fileOffsetInTorrent;
  int startPiece;
  int endPiece;
  int lastAccessedMs;
  int updatedAtMs;
  List<ByteRange> ranges;

  /// Active readers/writers prevent LRU eviction or clearing while in use.
  int activeReaders = 0;
  int activeWriters = 0;

  /// Tracks uncommitted bytes written since the last metadata flush.
  int pendingMetadataBytes = 0;
  int lastMetadataFlushMs = 0;

  DiskCacheEntry({
    required this.key,
    required this.infoHash,
    required this.fileIndex,
    this.torrentName = '',
    this.fileName = '',
    this.filePath = '',
    this.mimeType = 'application/octet-stream',
    this.fileSize = 0,
    this.pieceLength = 0,
    this.fileOffsetInTorrent = 0,
    this.startPiece = -1,
    this.endPiece = -1,
    int? lastAccessedMs,
    int? updatedAtMs,
    List<ByteRange>? ranges,
  })  : lastAccessedMs =
            lastAccessedMs ?? DateTime.now().millisecondsSinceEpoch,
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

  bool get hasPieceGeometry =>
      pieceLength > 0 && fileSize > 0 && startPiece >= 0 && endPiece >= startPiece;

  int get effectiveBlockSize => pieceLength > 0 ? pieceLength : 256 * 1024;

  /// Computes piece geometry boundaries when [pieceLength] & [fileOffsetInTorrent] are known.
  void applyPieceGeometry({
    String? torrentName,
    int? pieceLength,
    int? fileOffsetInTorrent,
  }) {
    if (torrentName != null && torrentName.isNotEmpty) {
      this.torrentName = torrentName;
    }
    if (pieceLength != null && pieceLength > 0) {
      this.pieceLength = pieceLength;
    }
    if (fileOffsetInTorrent != null && fileOffsetInTorrent >= 0) {
      this.fileOffsetInTorrent = fileOffsetInTorrent;
    }
    if (this.pieceLength > 0 && fileSize > 0) {
      startPiece = this.fileOffsetInTorrent ~/ this.pieceLength;
      endPiece = (this.fileOffsetInTorrent + fileSize - 1) ~/ this.pieceLength;
    }
  }

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

  int contiguousBytesFrom(int offset) {
    final cov = findCoveringRange(offset);
    if (cov == null) return 0;
    return cov.end - offset + 1;
  }

  ByteRange? findNextCachedRangeAfter(int offset) {
    for (final r in ranges) {
      if (r.start > offset) {
        return r;
      }
    }
    return null;
  }

  /// Returns all uncached byte gap ranges within `[start, end]` inclusive.
  List<ByteRange> findMissingRanges(int start, int end) {
    if (start < 0 || end < start) return const [];
    final clampedEnd = fileSize > 0 ? math.min(end, fileSize - 1) : end;
    if (start > clampedEnd) return const [];

    final missing = <ByteRange>[];
    var cursor = start;
    while (cursor <= clampedEnd) {
      final cov = findCoveringRange(cursor);
      if (cov != null) {
        cursor = cov.end + 1;
        continue;
      }
      final next = findNextCachedRangeAfter(cursor);
      final gapEnd =
          next != null ? math.min(next.start - 1, clampedEnd) : clampedEnd;
      if (gapEnd >= cursor) {
        missing.add(ByteRange(cursor, gapEnd));
      }
      cursor = gapEnd + 1;
    }
    return missing;
  }

  /// Returns the next uncached gap starting at or after [offset], optionally
  /// capped to [maxLength] bytes (or [maxEnd]).
  ByteRange? findNextMissingRangeAfter(
    int offset, {
    int? maxEnd,
    int? maxLength,
  }) {
    if (fileSize <= 0) return null;
    final limitEnd = maxEnd != null
        ? math.min(maxEnd, fileSize - 1)
        : fileSize - 1;
    var cursor = math.max(0, offset);
    while (cursor <= limitEnd) {
      final cov = findCoveringRange(cursor);
      if (cov != null) {
        cursor = cov.end + 1;
        continue;
      }
      final next = findNextCachedRangeAfter(cursor);
      var gapEnd = next != null ? math.min(next.start - 1, limitEnd) : limitEnd;
      if (maxLength != null && maxLength > 0) {
        gapEnd = math.min(gapEnd, cursor + maxLength - 1);
      }
      if (gapEnd >= cursor) {
        return ByteRange(cursor, gapEnd);
      }
      break;
    }
    return null;
  }

  /// Maps a file-local byte offset to its global torrent piece index (or virtual block index).
  int byteToPiece(int fileOffset) {
    if (fileSize <= 0) return hasPieceGeometry ? startPiece : 0;
    final clamped = fileOffset.clamp(0, fileSize - 1);
    if (hasPieceGeometry) {
      return (fileOffsetInTorrent + clamped) ~/ pieceLength;
    }
    return clamped ~/ effectiveBlockSize;
  }

  /// Maps a torrent piece index (or virtual block index) to file-local `[start, end]`.
  ByteRange pieceFileByteRange(int pieceIndex) {
    if (fileSize <= 0) return const ByteRange(0, -1);
    if (hasPieceGeometry) {
      final pStart = pieceIndex * pieceLength;
      final pEnd = pStart + pieceLength - 1;
      final fStart = fileOffsetInTorrent;
      final fEnd = fileOffsetInTorrent + fileSize - 1;
      final localStart = math.max(pStart, fStart) - fStart;
      final localEnd = math.min(pEnd, fEnd) - fStart;
      return ByteRange(localStart, localEnd);
    }
    final bs = effectiveBlockSize;
    final localStart = pieceIndex * bs;
    final localEnd = math.min(fileSize - 1, localStart + bs - 1);
    return ByteRange(localStart, localEnd);
  }

  /// Snaps [endOffset] up to the end of the piece containing it (clamped to `fileSize - 1`).
  int alignEndToPieceBoundary(int endOffset) {
    if (fileSize <= 0) return endOffset;
    final clamped = endOffset.clamp(0, fileSize - 1);
    final pieceIdx = byteToPiece(clamped);
    final pieceRange = pieceFileByteRange(pieceIdx);
    if (pieceRange.end >= clamped) {
      return math.min(fileSize - 1, pieceRange.end);
    }
    return clamped;
  }

  bool isPieceCached(int pieceIndex) {
    final r = pieceFileByteRange(pieceIndex);
    if (r.end < r.start || r.start < 0) return false;
    return isRangeCached(r.start, r.end);
  }

  /// Computes piece-level download stats in `O(totalPieces + ranges.length)`.
  PieceCoverageStats computePieceCoverage() {
    if (fileSize <= 0) {
      return const PieceCoverageStats(
        pieceLength: 0,
        startPiece: -1,
        endPiece: -1,
        totalPieces: 0,
        downloadedPieces: 0,
        downloadedSpans: [],
        isExactTorrentPieces: false,
      );
    }

    final exact = hasPieceGeometry;
    final pLen = exact ? pieceLength : effectiveBlockSize;
    final firstP = exact ? startPiece : 0;
    final lastP = exact ? endPiece : ((fileSize - 1) ~/ pLen);
    final totalP = math.max(0, lastP - firstP + 1);

    final spans = <ByteRange>[];
    var downloaded = 0;
    var rangeIdx = 0;
    var spanStart = -1;

    for (var p = firstP; p <= lastP; p++) {
      final pr = pieceFileByteRange(p);
      while (rangeIdx < ranges.length && ranges[rangeIdx].end < pr.start) {
        rangeIdx++;
      }
      final havePiece = rangeIdx < ranges.length &&
          ranges[rangeIdx].start <= pr.start &&
          ranges[rangeIdx].end >= pr.end;

      if (havePiece) {
        downloaded++;
        if (spanStart < 0) {
          spanStart = p;
        }
      } else if (spanStart >= 0) {
        spans.add(ByteRange(spanStart, p - 1));
        spanStart = -1;
      }
    }
    if (spanStart >= 0) {
      spans.add(ByteRange(spanStart, lastP));
    }

    return PieceCoverageStats(
      pieceLength: pLen,
      startPiece: firstP,
      endPiece: lastP,
      totalPieces: totalP,
      downloadedPieces: downloaded,
      downloadedSpans: spans,
      isExactTorrentPieces: exact,
    );
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
        'torrent_name': torrentName,
        'file_name': fileName,
        'file_path': filePath,
        'mime_type': mimeType,
        'file_size': fileSize,
        'piece_length': pieceLength,
        'file_offset_in_torrent': fileOffsetInTorrent,
        'start_piece': startPiece,
        'end_piece': endPiece,
        'last_accessed_ms': lastAccessedMs,
        'updated_at_ms': updatedAtMs,
        'ranges': ranges.map((r) => r.toJson()).toList(),
      };

  factory DiskCacheEntry.fromJson(Map<String, dynamic> json) {
    final rawHash = (json['infohash'] ?? '').toString().trim().toLowerCase();
    final fileIndex = (json['file_index'] as num?)?.toInt() ?? 0;
    final key =
        (json['key'] ?? '${rawHash}_$fileIndex').toString().toLowerCase();
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

    final entry = DiskCacheEntry(
      key: key,
      infoHash: rawHash,
      fileIndex: fileIndex,
      torrentName: (json['torrent_name'] ?? '').toString(),
      fileName: (json['file_name'] ?? '').toString(),
      filePath: (json['file_path'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? 'application/octet-stream').toString(),
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
      pieceLength: (json['piece_length'] as num?)?.toInt() ?? 0,
      fileOffsetInTorrent:
          (json['file_offset_in_torrent'] as num?)?.toInt() ?? 0,
      startPiece: (json['start_piece'] as num?)?.toInt() ?? -1,
      endPiece: (json['end_piece'] as num?)?.toInt() ?? -1,
      lastAccessedMs: (json['last_accessed_ms'] as num?)?.toInt(),
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt(),
      ranges: rawRanges,
    );
    entry.applyPieceGeometry();
    return entry;
  }
}

/// Aggregated piece & file cache summary grouped per torrent `infoHash`.
class CachedTorrentSummary {
  final String infoHash;
  final String torrentName;
  final int pieceLength;
  final int totalTorrentBytes;
  final int cachedBytes;
  final int totalPieces;
  final int downloadedPieces;
  final int cachedFilesCount;
  final int totalFilesCount;
  final bool isInUse;
  final int lastAccessedMs;
  final List<DiskCacheEntry> entries;

  const CachedTorrentSummary({
    required this.infoHash,
    required this.torrentName,
    required this.pieceLength,
    required this.totalTorrentBytes,
    required this.cachedBytes,
    required this.totalPieces,
    required this.downloadedPieces,
    required this.cachedFilesCount,
    required this.totalFilesCount,
    required this.isInUse,
    required this.lastAccessedMs,
    required this.entries,
  });

  double get cachedPercentage => totalTorrentBytes > 0
      ? (cachedBytes / totalTorrentBytes).clamp(0.0, 1.0)
      : 0.0;

  bool get allFilesComplete =>
      entries.isNotEmpty && entries.every((e) => e.isComplete);

  Map<String, dynamic> toJson() => {
        'infohash': infoHash,
        'torrent_name': torrentName,
        'piece_length': pieceLength,
        'total_torrent_bytes': totalTorrentBytes,
        'cached_bytes': cachedBytes,
        'cached_percentage': cachedPercentage,
        'total_pieces': totalPieces,
        'downloaded_pieces': downloadedPieces,
        'cached_files_count': cachedFilesCount,
        'total_files_count': totalFilesCount,
        'is_in_use': isInUse,
        'all_files_complete': allFilesComplete,
        'last_accessed_ms': lastAccessedMs,
        'files': entries.map((e) {
          final cov = e.computePieceCoverage();
          return {
            'key': e.key,
            'file_index': e.fileIndex,
            'file_name': e.fileName,
            'file_path': e.filePath,
            'file_size': e.fileSize,
            'cached_bytes': e.cachedBytes,
            'cached_percentage': e.cachedPercentage,
            'is_complete': e.isComplete,
            'range_count': e.ranges.length,
            'piece_coverage': cov.toJson(),
          };
        }).toList(),
      };
}

/// Simple per-key async mutex chain so concurrent writes/flushes on the same
/// cache entry execute sequentially without racing on file descriptors.
class _PerKeyAsyncLock {
  final Map<String, Future<void>> _tails = {};

  Future<void> waitForAll() async {
    while (_tails.isNotEmpty) {
      final pending = _tails.values.toList();
      await Future.wait(pending.map((f) => f.catchError((_) {})));
    }
  }

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

/// Persistent piece-aware disk random-access byte-range cache for streamed audio files.
///
/// Stores sparse data in `<baseCachePath>/streams/<key>.bin`, crash-consistent range &
/// piece metadata in `<key>.meta.json`, and torrent file/piece manifests in
/// `<baseCachePath>/manifests/<infoHash>.manifest.json`.
class AudioDiskCacheService extends ChangeNotifier {
  static final AudioDiskCacheService instance = AudioDiskCacheService._();
  AudioDiskCacheService._();

  static const int _metadataFlushThresholdBytes = 512 * 1024; // 512 KB
  static const int _metadataFlushIntervalMs = 2000;

  bool _isInitialized = false;
  int _initEpoch = 0;
  String _streamsDirPath = '';
  String _manifestsDirPath = '';
  final Map<String, DiskCacheEntry> _entries = {};
  final Map<String, TorrentManifest> _manifests = {};
  final Map<String, RandomAccessFile> _openWriters = {};
  final _PerKeyAsyncLock _locks = _PerKeyAsyncLock();
  final StreamController<String> _entryWrittenCtrl =
      StreamController<String>.broadcast();

  bool get isInitialized => _isInitialized;
  String get streamsDirPath => _streamsDirPath;
  String get manifestsDirPath => _manifestsDirPath;
  Map<String, DiskCacheEntry> get entries => Map.unmodifiable(_entries);
  Map<String, TorrentManifest> get manifests => Map.unmodifiable(_manifests);

  /// Emits the cache entry `key` whenever new bytes are written for that entry.
  Stream<String> get entryUpdates => _entryWrittenCtrl.stream;

  static String buildKey(String infoHash, int fileIndex) =>
      '${infoHash.trim().toLowerCase()}_$fileIndex';

  File _binFileForKey(String key) =>
      File('$_streamsDirPath${Platform.pathSeparator}$key.bin');

  File _metaFileForKey(String key) =>
      File('$_streamsDirPath${Platform.pathSeparator}$key.meta.json');

  File _tmpMetaFileForKey(String key) =>
      File('$_streamsDirPath${Platform.pathSeparator}$key.meta.json.tmp');

  File _manifestFileForHash(String infoHash) => File(
        '$_manifestsDirPath${Platform.pathSeparator}${infoHash.trim().toLowerCase()}.manifest.json',
      );

  File _tmpManifestFileForHash(String infoHash) => File(
        '$_manifestsDirPath${Platform.pathSeparator}${infoHash.trim().toLowerCase()}.manifest.json.tmp',
      );

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

  /// Initializes the persistent disk cache and torrent manifest store from
  /// `<baseCachePath>/streams` and `<baseCachePath>/manifests`, recovering any
  /// interrupted atomic `.tmp` writes and reconciling byte ranges.
  Future<void> init({
    required String baseCachePath,
    bool forceReload = false,
  }) async {
    final targetDirPath = '$baseCachePath${Platform.pathSeparator}streams';
    final targetManifestDir =
        '$baseCachePath${Platform.pathSeparator}manifests';
    if (_isInitialized &&
        !forceReload &&
        _streamsDirPath == targetDirPath) {
      return;
    }

    _initEpoch++;
    await _locks.waitForAll();
    await _closeAllWriters();

    _streamsDirPath = targetDirPath;
    _manifestsDirPath = targetManifestDir;
    _entries.clear();
    _manifests.clear();

    final dir = Directory(_streamsDirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final manifestDir = Directory(_manifestsDirPath);
    if (!await manifestDir.exists()) {
      await manifestDir.create(recursive: true);
    }

    // Load manifests first so entries can hydrate missing piece geometry
    await _loadAllManifests(manifestDir);

    final metaFilesByKey = <String, File>{};
    final tmpFilesByKey = <String, File>{};
    final binFilesByKey = <String, File>{};

    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.endsWith('.meta.json.tmp')) {
        final key =
            name.substring(0, name.length - '.meta.json.tmp'.length).toLowerCase();
        tmpFilesByKey[key] = entity;
      } else if (name.endsWith('.meta.json')) {
        final key =
            name.substring(0, name.length - '.meta.json'.length).toLowerCase();
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

      // Hydrate piece geometry from manifest if available
      final manifest = _manifests[parsed.infoHash];
      if (manifest != null) {
        final mf = manifest.fileAtIndex(parsed.fileIndex);
        parsed.applyPieceGeometry(
          torrentName: manifest.torrentName,
          pieceLength: manifest.pieceLength,
          fileOffsetInTorrent: mf?.offsetInTorrent,
        );
      }

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

  Future<void> _loadAllManifests(Directory manifestDir) async {
    final mainFiles = <String, File>{};
    final tmpFiles = <String, File>{};

    await for (final entity in manifestDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.endsWith('.manifest.json.tmp')) {
        final hash = name
            .substring(0, name.length - '.manifest.json.tmp'.length)
            .toLowerCase();
        tmpFiles[hash] = entity;
      } else if (name.endsWith('.manifest.json')) {
        final hash = name
            .substring(0, name.length - '.manifest.json'.length)
            .toLowerCase();
        mainFiles[hash] = entity;
      }
    }

    final hashes = <String>{...mainFiles.keys, ...tmpFiles.keys};
    for (final h in hashes) {
      final mainFile = mainFiles[h];
      final tmpFile = tmpFiles[h];
      var parsed = await _tryParseManifestFile(mainFile);
      if (parsed == null) {
        final recovered = await _tryParseManifestFile(tmpFile);
        if (recovered != null) {
          parsed = recovered;
          await _writeManifestAtomic(parsed);
        }
      }
      if (tmpFile != null && await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      if (parsed != null) {
        _manifests[parsed.infoHash] = parsed;
      }
    }
  }

  Future<TorrentManifest?> _tryParseManifestFile(File? file) async {
    if (file == null || !await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final m = TorrentManifest.fromJson(json);
      if (m.infoHash.isEmpty) return null;
      return m;
    } catch (_) {
      return null;
    }
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

  TorrentManifest? getManifest(String infoHash) =>
      _manifests[infoHash.trim().toLowerCase()];

  /// Persists or updates a [TorrentManifest] and propagates its piece geometry
  /// to any cached entries belonging to [infoHash].
  Future<TorrentManifest> saveTorrentManifest({
    required String infoHash,
    String? torrentName,
    String? magnetUri,
    int? pieceLength,
    int? numPieces,
    List<AudioFileEntry>? files,
  }) async {
    final hashLower = infoHash.trim().toLowerCase();
    if (_manifestsDirPath.isEmpty) {
      throw StateError('AudioDiskCacheService must be initialized before use.');
    }

    return _locks.synchronized('manifest:$hashLower', () async {
      final existing = _manifests[hashLower];
      var changed = existing == null;
      final manifest = existing ?? TorrentManifest(infoHash: hashLower);

      if (torrentName != null &&
          torrentName.isNotEmpty &&
          manifest.torrentName != torrentName) {
        manifest.torrentName = torrentName;
        changed = true;
      }
      if (magnetUri != null &&
          magnetUri.isNotEmpty &&
          manifest.magnetUri != magnetUri) {
        manifest.magnetUri = magnetUri;
        changed = true;
      }
      if (pieceLength != null &&
          pieceLength > 0 &&
          manifest.pieceLength != pieceLength) {
        manifest.pieceLength = pieceLength;
        changed = true;
      }
      if (files != null && files.isNotEmpty) {
        final builtFiles = <TorrentManifestFile>[];
        var offset = 0;
        for (final f in files) {
          builtFiles.add(
            TorrentManifestFile(
              index: f.index,
              name: f.name,
              path: f.path,
              size: f.size,
              offsetInTorrent: offset,
              mimeType: f.mimeType,
              isAudioFile: f.isAudioFile,
            ),
          );
          if (f.size > 0) {
            offset += f.size;
          }
        }
        if (manifest.files.length != builtFiles.length ||
            manifest.totalSize != offset) {
          manifest.files = builtFiles;
          manifest.totalSize = offset;
          changed = true;
        }
      }

      if (numPieces != null && numPieces > 0) {
        manifest.numPieces = numPieces;
        changed = true;
      } else if (manifest.pieceLength > 0 && manifest.totalSize > 0) {
        final computed =
            (manifest.totalSize + manifest.pieceLength - 1) ~/
                manifest.pieceLength;
        if (manifest.numPieces != computed) {
          manifest.numPieces = computed;
          changed = true;
        }
      }

      manifest.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      _manifests[hashLower] = manifest;

      // Propagate geometry to existing cached entries for this torrent
      for (final entry in _entries.values) {
        if (entry.infoHash != hashLower) continue;
        final mf = manifest.fileAtIndex(entry.fileIndex);
        final prevPieceLen = entry.pieceLength;
        final prevOffset = entry.fileOffsetInTorrent;
        final prevName = entry.torrentName;
        entry.applyPieceGeometry(
          torrentName: manifest.torrentName,
          pieceLength: manifest.pieceLength,
          fileOffsetInTorrent: mf?.offsetInTorrent,
        );
        if (entry.pieceLength != prevPieceLen ||
            entry.fileOffsetInTorrent != prevOffset ||
            entry.torrentName != prevName) {
          unawaited(flushEntry(entry.key));
        }
      }

      if (changed) {
        await _writeManifestAtomic(manifest);
        notifyListeners();
      }
      return manifest;
    });
  }

  Future<void> _writeManifestAtomic(TorrentManifest manifest) async {
    if (_manifestsDirPath.isEmpty) return;
    final tmpFile = _tmpManifestFileForHash(manifest.infoHash);
    final targetFile = _manifestFileForHash(manifest.infoHash);
    await tmpFile.writeAsString(jsonEncode(manifest.toJson()), flush: true);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await tmpFile.rename(targetFile.path);
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

    // If manifest knows which fileIndex corresponds to filePath, prefer exact index lookup
    final manifest = _manifests[hashLower];
    if (manifest != null && filePath != null && filePath.trim().isNotEmpty) {
      final mf = manifest.findFile(filePath: filePath);
      if (mf != null) {
        final byManifest = _entries[buildKey(hashLower, mf.index)];
        if (byManifest != null) return byManifest;
      }
    }

    final candidates =
        _entries.values.where((e) => e.infoHash == hashLower).toList();
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

    // Prefer complete or most recently accessed entry for infoHash
    candidates.sort((a, b) {
      if (a.isComplete != b.isComplete) {
        return a.isComplete ? -1 : 1;
      }
      return b.lastAccessedMs.compareTo(a.lastAccessedMs);
    });
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
    String torrentName = '',
    String fileName = '',
    String filePath = '',
    String mimeType = 'application/octet-stream',
    int fileSize = 0,
    int pieceLength = 0,
    int? fileOffsetInTorrent,
  }) async {
    if (_streamsDirPath.isEmpty) {
      throw StateError('AudioDiskCacheService must be initialized before use.');
    }

    final hashLower = infoHash.trim().toLowerCase();
    final key = buildKey(hashLower, fileIndex);
    final manifest = _manifests[hashLower];
    final mf = manifest?.fileAtIndex(fileIndex);

    final effectiveTorrentName = torrentName.isNotEmpty
        ? torrentName
        : (manifest?.torrentName ?? '');
    final effectivePieceLength =
        pieceLength > 0 ? pieceLength : (manifest?.pieceLength ?? 0);
    final effectiveOffset =
        fileOffsetInTorrent ?? mf?.offsetInTorrent ?? 0;

    return _locks.synchronized(key, () async {
      var entry = _entries[key];
      var changed = false;
      final now = DateTime.now().millisecondsSinceEpoch;

      if (entry == null) {
        entry = DiskCacheEntry(
          key: key,
          infoHash: hashLower,
          fileIndex: fileIndex,
          torrentName: effectiveTorrentName,
          fileName: fileName,
          filePath: filePath,
          mimeType: mimeType,
          fileSize: fileSize,
          pieceLength: effectivePieceLength,
          fileOffsetInTorrent: effectiveOffset,
          lastAccessedMs: now,
          updatedAtMs: now,
        );
        entry.applyPieceGeometry();
        _entries[key] = entry;
        changed = true;
      } else {
        if (effectiveTorrentName.isNotEmpty &&
            entry.torrentName != effectiveTorrentName) {
          entry.torrentName = effectiveTorrentName;
          changed = true;
        }
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
        if (effectivePieceLength > 0 &&
            entry.pieceLength != effectivePieceLength) {
          entry.pieceLength = effectivePieceLength;
          changed = true;
        }
        if (effectiveOffset > 0 &&
            entry.fileOffsetInTorrent != effectiveOffset) {
          entry.fileOffsetInTorrent = effectiveOffset;
          changed = true;
        }
        entry.applyPieceGeometry();
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

  bool isTorrentFullyCached(String infoHash) {
    final hashLower = infoHash.trim().toLowerCase();
    final matching =
        _entries.values.where((e) => e.infoHash == hashLower).toList();
    if (matching.isEmpty) return false;
    return matching.every((e) => e.isComplete);
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
    return _locks.synchronized(k, () async {
      final entry = _entries[k];
      if (entry != null && entry.activeWriters > 0) {
        entry.activeWriters--;
      }
      if (entry == null || entry.activeWriters == 0) {
        await _closeWriterLocked(k);
      }
      if (entry != null) {
        await _writeMetaAtomic(entry);
        entry.pendingMetadataBytes = 0;
        entry.lastMetadataFlushMs = DateTime.now().millisecondsSinceEpoch;
      }
    });
  }

  Future<RandomAccessFile> _getOrOpenWriterLocked(String key) async {
    final existing = _openWriters[key];
    if (existing != null) return existing;

    final binFile = _binFileForKey(key);
    if (!await binFile.exists()) {
      await binFile.create(recursive: true);
    }
    final raf = await binFile.open(mode: FileMode.append);
    _openWriters[key] = raf;
    return raf;
  }

  Future<void> _closeWriterLocked(String key) async {
    final raf = _openWriters.remove(key);
    if (raf == null) return;
    try {
      await raf.flush();
    } catch (_) {}
    try {
      await raf.close();
    } catch (_) {}
  }

  Future<void> _closeAllWriters() async {
    final keys = _openWriters.keys.toList();
    for (final k in keys) {
      final raf = _openWriters.remove(k);
      if (raf != null) {
        try {
          await raf.flush();
        } catch (_) {}
        try {
          await raf.close();
        } catch (_) {}
      }
    }
  }

  /// Flushes buffered writer FD & metadata atomically to `<key>.meta.json`.
  Future<void> flushEntry(String key) async {
    final k = key.toLowerCase();
    return _locks.synchronized(k, () async {
      final raf = _openWriters[k];
      if (raf != null) {
        try {
          await raf.flush();
        } catch (_) {}
      }
      final entry = _entries[k];
      if (entry == null) return;
      await _writeMetaAtomic(entry);
      entry.pendingMetadataBytes = 0;
      entry.lastMetadataFlushMs = DateTime.now().millisecondsSinceEpoch;
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

  /// Writes [bytes] at exact byte [offset] into `<key>.bin` using a pooled open
  /// [RandomAccessFile] handle and updates range & piece metadata atomically.
  Future<void> writeChunk(
    String key,
    int offset,
    List<int> bytes, {
    int? totalFileSize,
    bool forceFlushMetadata = false,
  }) async {
    if (bytes.isEmpty || offset < 0) return;
    final k = key.toLowerCase();
    final epoch = _initEpoch;

    await _locks.synchronized(k, () async {
      if (_initEpoch != epoch) return;
      final entry = _entries[k];
      if (entry == null) return;

      final raf = await _getOrOpenWriterLocked(k);
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);

      if (totalFileSize != null && totalFileSize > 0 && entry.fileSize != totalFileSize) {
        entry.fileSize = totalFileSize;
        entry.applyPieceGeometry();
      }
      entry.addRange(offset, offset + bytes.length - 1);
      entry.pendingMetadataBytes += bytes.length;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final shouldFlushMeta = forceFlushMetadata ||
          entry.pendingMetadataBytes >= _metadataFlushThresholdBytes ||
          (nowMs - entry.lastMetadataFlushMs >= _metadataFlushIntervalMs) ||
          entry.isComplete;

      if (shouldFlushMeta) {
        await raf.flush();
        await _writeMetaAtomic(entry);
        entry.pendingMetadataBytes = 0;
        entry.lastMetadataFlushMs = nowMs;
        if (entry.activeWriters == 0) {
          await _closeWriterLocked(k);
        }
        notifyListeners();
      }

      if (!_entryWrittenCtrl.isClosed) {
        _entryWrittenCtrl.add(k);
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

  /// Groups cached entries & persisted manifests by `infoHash` with piece stats.
  List<CachedTorrentSummary> getTorrentSummaries() {
    final grouped = <String, List<DiskCacheEntry>>{};
    for (final entry in _entries.values) {
      grouped.putIfAbsent(entry.infoHash, () => []).add(entry);
    }

    final summaries = <CachedTorrentSummary>[];
    for (final e in grouped.entries) {
      final hash = e.key;
      final list = e.value..sort((a, b) => a.fileIndex.compareTo(b.fileIndex));
      final manifest = _manifests[hash];

      var torrentName = manifest?.torrentName ?? '';
      var pieceLen = manifest?.pieceLength ?? 0;
      var cachedTotal = 0;
      var totalPieces = 0;
      var downloadedPieces = 0;
      var inUse = false;
      var lastAccessed = 0;
      var knownFilesSize = 0;

      for (final item in list) {
        if (torrentName.isEmpty && item.torrentName.isNotEmpty) {
          torrentName = item.torrentName;
        }
        if (pieceLen <= 0 && item.pieceLength > 0) {
          pieceLen = item.pieceLength;
        }
        cachedTotal += item.cachedBytes;
        knownFilesSize += item.fileSize;
        final cov = item.computePieceCoverage();
        totalPieces += cov.totalPieces;
        downloadedPieces += cov.downloadedPieces;
        if (item.isInUse) inUse = true;
        if (item.lastAccessedMs > lastAccessed) {
          lastAccessed = item.lastAccessedMs;
        }
      }

      if (torrentName.isEmpty) {
        torrentName = list.first.fileName.isNotEmpty
            ? list.first.fileName
            : hash;
      }

      final totalBytes =
          (manifest != null && manifest.totalSize > 0) ? manifest.totalSize : knownFilesSize;

      summaries.add(
        CachedTorrentSummary(
          infoHash: hash,
          torrentName: torrentName,
          pieceLength: pieceLen,
          totalTorrentBytes: totalBytes,
          cachedBytes: cachedTotal,
          totalPieces: totalPieces,
          downloadedPieces: downloadedPieces,
          cachedFilesCount: list.length,
          totalFilesCount: manifest?.files.length ?? list.length,
          isInUse: inUse,
          lastAccessedMs: lastAccessed,
          entries: List.unmodifiable(list),
        ),
      );
    }

    summaries.sort((a, b) => b.lastAccessedMs.compareTo(a.lastAccessedMs));
    return summaries;
  }

  /// Deletes all unlocked cache entries (and manifest if no entries remain) for [infoHash].
  Future<int> deleteTorrentCache(String infoHash) async {
    if (_streamsDirPath.isEmpty) return 0;
    final hashLower = infoHash.trim().toLowerCase();
    var freed = 0;
    final matchingKeys = _entries.values
        .where((e) => e.infoHash == hashLower)
        .map((e) => e.key)
        .toList();
    for (final k in matchingKeys) {
      freed += await _deleteEntryIfUnlocked(k);
    }

    final stillHasEntries = _entries.values.any((e) => e.infoHash == hashLower);
    if (!stillHasEntries) {
      await _deleteManifestFile(hashLower);
    }
    if (freed > 0 || !stillHasEntries) {
      notifyListeners();
    }
    return freed;
  }

  Future<void> _deleteManifestFile(String infoHash) async {
    final hashLower = infoHash.trim().toLowerCase();
    await _locks.synchronized('manifest:$hashLower', () async {
      _manifests.remove(hashLower);
      for (final f in [
        _manifestFileForHash(hashLower),
        _tmpManifestFileForHash(hashLower),
      ]) {
        try {
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
    });
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

  /// Clears all unlocked cached files from `<cachePath>/streams` and unreferenced manifests.
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

    final remainingHashes = _entries.values.map((e) => e.infoHash).toSet();
    final manifestHashes = _manifests.keys.toList();
    for (final h in manifestHashes) {
      if (protectedHashesLower.contains(h) || remainingHashes.contains(h)) {
        continue;
      }
      await _deleteManifestFile(h);
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

      await _closeWriterLocked(k);

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
        debugPrint(
          'AudioDiskCacheService: Failed deleting ${binFile.path}: $e',
        );
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
        'manifest_count': _manifests.length,
        'total_cached_bytes': totalCachedBytes,
        'torrents': getTorrentSummaries().map((t) => t.toJson()).toList(),
        'entries': _entries.values.map((e) {
          final cov = e.computePieceCoverage();
          return {
            'key': e.key,
            'infohash': e.infoHash,
            'torrent_name': e.torrentName,
            'file_index': e.fileIndex,
            'file_name': e.fileName,
            'file_size': e.fileSize,
            'piece_length': e.pieceLength,
            'downloaded_pieces': cov.downloadedPieces,
            'total_pieces': cov.totalPieces,
            'piece_spans': cov.downloadedSpans
                .map((s) => [s.start, s.end])
                .toList(),
            'cached_bytes': e.cachedBytes,
            'cached_percentage': e.cachedPercentage,
            'is_complete': e.isComplete,
            'range_count': e.ranges.length,
            'active_readers': e.activeReaders,
            'active_writers': e.activeWriters,
            'last_accessed_ms': e.lastAccessedMs,
          };
        }).toList(),
      };
}
