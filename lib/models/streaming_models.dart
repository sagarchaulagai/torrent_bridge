import 'package:libtorrent_flutter/libtorrent_flutter.dart';

/// Enriches [FileInfo] from `libtorrent_flutter` with audio format and MIME metadata.
class AudioFileEntry {
  final int index;
  final String name;
  final String path;
  final int size;
  final bool isStreamable;
  final String extension;
  final String mimeType;
  final String formatLabel;
  final bool isAudioFile;

  const AudioFileEntry({
    required this.index,
    required this.name,
    required this.path,
    required this.size,
    required this.isStreamable,
    required this.extension,
    required this.mimeType,
    required this.formatLabel,
    required this.isAudioFile,
  });

  factory AudioFileEntry.fromFileInfo(FileInfo info, {int? fallbackSize}) {
    final effectiveName = info.name.isNotEmpty
        ? info.name
        : info.path.split(RegExp(r'[/\\]')).last;
    final ext = extractExtension(effectiveName);
    final mime = mimeTypeForExtension(ext);
    final isAudio = isAudioExtension(ext);
    final resolvedSize = (info.size > 0) ? info.size : (fallbackSize ?? 0);

    return AudioFileEntry(
      index: info.index,
      name: effectiveName,
      path: info.path.isNotEmpty ? info.path : effectiveName,
      size: resolvedSize,
      isStreamable: info.isStreamable || isAudio,
      extension: ext,
      mimeType: mime,
      formatLabel: ext.isEmpty ? 'RAW' : ext.substring(1).toUpperCase(),
      isAudioFile: isAudio,
    );
  }

  factory AudioFileEntry.fromPathAndSize({
    required int index,
    required String path,
    required int size,
    bool? isStreamable,
  }) {
    final normalizedPath = path.replaceAll('\\', '/');
    final effectiveName = normalizedPath.contains('/')
        ? normalizedPath.split('/').last
        : normalizedPath;
    final ext = extractExtension(effectiveName);
    final mime = mimeTypeForExtension(ext);
    final isAudio = isAudioExtension(ext);

    return AudioFileEntry(
      index: index,
      name: effectiveName,
      path: normalizedPath,
      size: size,
      isStreamable: isStreamable ?? isAudio,
      extension: ext,
      mimeType: mime,
      formatLabel: ext.isEmpty ? 'RAW' : ext.substring(1).toUpperCase(),
      isAudioFile: isAudio,
    );
  }

  AudioFileEntry copyWith({int? size}) {
    return AudioFileEntry(
      index: index,
      name: name,
      path: path,
      size: size ?? this.size,
      isStreamable: isStreamable,
      extension: extension,
      mimeType: mimeType,
      formatLabel: formatLabel,
      isAudioFile: isAudioFile,
    );
  }

  /// Directory portion of [path], or `/` if at root.
  String get directoryPath {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return '/';
    return normalized.substring(0, idx);
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'name': name,
        'path': path,
        'size': size,
        'size_formatted': formatBytes(size),
        'format': formatLabel,
        'mime_type': mimeType,
        'is_streamable': isStreamable,
        'is_audio': isAudioFile,
      };

  static String extractExtension(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return '';
    return filename.substring(dot).toLowerCase();
  }

  static bool isAudioExtension(String ext) {
    const audioExts = {
      '.mp3',
      '.m4a',
      '.m4b',
      '.m4p',
      '.aac',
      '.flac',
      '.ogg',
      '.opus',
      '.oga',
      '.wav',
      '.wma',
      '.weba',
      '.mp4',
    };
    return audioExts.contains(ext.toLowerCase());
  }

  static String mimeTypeForExtension(String ext) {
    switch (ext.toLowerCase()) {
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.m4b':
      case '.m4p':
        return 'audio/mp4';
      case '.aac':
        return 'audio/aac';
      case '.flac':
        return 'audio/flac';
      case '.ogg':
      case '.oga':
        return 'audio/ogg';
      case '.opus':
        return 'audio/opus';
      case '.wav':
        return 'audio/wav';
      case '.wma':
        return 'audio/x-ms-wma';
      case '.webm':
      case '.weba':
        return 'audio/webm';
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      default:
        return 'application/octet-stream';
    }
  }
}

/// Represents a connected HTTP client actively consuming or probing an audio stream.
class ConnectedClientInfo {
  final String clientId;
  final String remoteAddress;
  final String userAgent;
  final String sessionId;
  final String method;
  final String? requestedRange;
  final DateTime connectedAt;
  int bytesTransferred;
  bool isActive;

  ConnectedClientInfo({
    required this.clientId,
    required this.remoteAddress,
    required this.userAgent,
    required this.sessionId,
    required this.method,
    this.requestedRange,
    required this.connectedAt,
    this.bytesTransferred = 0,
    this.isActive = true,
  });

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'remote_address': remoteAddress,
        'user_agent': userAgent,
        'session_id': sessionId,
        'method': method,
        'requested_range': requestedRange,
        'connected_at': connectedAt.toIso8601String(),
        'bytes_transferred': bytesTransferred,
        'is_active': isActive,
      };
}

/// Represents an active torrent-to-HTTP audio streaming session exposed by the server.
class StreamingSession {
  final String sessionId;
  int torrentId;
  int nativeStreamId;
  final String magnetUri;
  final String infoHash;
  final String torrentName;
  final int fileIndex;
  final String fileName;
  final String filePath;
  int fileSize;
  final String mimeType;
  final String formatLabel;
  String nativeStreamUrl;
  final DateTime createdAt;

  bool isDebridStream;
  String? debridProvider;
  String? debridDirectUrl;

  int activeClients;
  int totalRequests;
  int bytesServed;
  String? lastRangeHeader;
  StreamInfo? latestNativeInfo;
  bool isPrimary;
  bool isCached;
  int cachedBytes;
  double cachedPercentage;
  DateTime lastAccessedAt;

  StreamingSession({
    required this.sessionId,
    required this.torrentId,
    required this.nativeStreamId,
    required this.magnetUri,
    required this.infoHash,
    required this.torrentName,
    required this.fileIndex,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.mimeType,
    required this.formatLabel,
    required this.nativeStreamUrl,
    required this.createdAt,
    this.isDebridStream = false,
    this.debridProvider,
    this.debridDirectUrl,
    this.activeClients = 0,
    this.totalRequests = 0,
    this.bytesServed = 0,
    this.lastRangeHeader,
    this.latestNativeInfo,
    this.isPrimary = true,
    this.isCached = false,
    this.cachedBytes = 0,
    this.cachedPercentage = 0.0,
    DateTime? lastAccessedAt,
  }) : lastAccessedAt = lastAccessedAt ?? DateTime.now();

  String buildStreamUrl(String host, int port) {
    final safeName = Uri.encodeComponent(fileName);
    return 'http://$host:$port/stream/$sessionId/$safeName';
  }

  Map<String, dynamic> toJson({required String host, required int port}) => {
        'session_id': sessionId,
        'torrent_id': torrentId,
        'native_stream_id': nativeStreamId,
        'infohash': infoHash,
        'torrent_name': torrentName,
        'file_index': fileIndex,
        'file_name': fileName,
        'file_path': filePath,
        'file_size': fileSize,
        'mime_type': mimeType,
        'format': formatLabel,
        'stream_url': buildStreamUrl(host, port),
        'loopback_stream_url': buildStreamUrl('127.0.0.1', port),
        'active_clients': activeClients,
        'total_requests': totalRequests,
        'bytes_served': bytesServed,
        'is_primary': isPrimary,
        'is_cached': isCached,
        'cached_bytes': cachedBytes,
        'cached_percentage': cachedPercentage,
        'stream_source':
            isDebridStream ? 'debrid' : (isCached ? 'disk_cache' : 'torrent'),
        'is_debrid': isDebridStream,
        'debrid_provider': debridProvider,
        'last_accessed': lastAccessedAt.toIso8601String(),
        'last_range': lastRangeHeader,
        'stream_state': latestNativeInfo?.streamState.name ?? 'buffering',
        'is_ready': latestNativeInfo?.isReady ?? false,
        'buffer_seconds': latestNativeInfo?.bufferSeconds ?? 0.0,
        'buffer_pieces': latestNativeInfo?.bufferPieces ?? 0,
        'readahead_window': latestNativeInfo?.readaheadWindow ?? 0,
        'read_head': latestNativeInfo?.readHead ?? 0,
        'download_rate': latestNativeInfo?.downloadRate ?? 0,
        'active_peers': latestNativeInfo?.activePeers ?? 0,
        'created_at': createdAt.toIso8601String(),
      };
}

