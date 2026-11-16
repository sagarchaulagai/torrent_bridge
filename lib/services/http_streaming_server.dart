import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';

import '../models/debrid_models.dart';
import '../models/streaming_models.dart';
import 'android_foreground_service.dart';
import 'audio_disk_cache_service.dart';
import 'debrid_service.dart';
import 'server_settings_service.dart';
import 'torrent_engine_service.dart';

/// Local Torrent-to-HTTP Audio Streaming Server for Mero Audiobook and
/// compatible HTTP audio players (such as `just_audio` / ExoPlayer).
class HttpStreamingServer extends ChangeNotifier {
  static final HttpStreamingServer instance = HttpStreamingServer._();
  HttpStreamingServer._() {
    AndroidForegroundService.instance.init(
      onStopFromNotification: () async {
        await ServerSettingsService.instance.setKeepServerRunning(false);
        await stopServer();
      },
    );
    TorrentEngineService.instance.addListener(_onEngineUpdated);
  }

  HttpServer? _httpServer;
  HttpClient? _upstreamHttpClient;
  bool _isStarting = false;
  bool _portFallbackUsed = false;
  int _port = 8080;
  String _localIp = '127.0.0.1';
  DateTime? _startedAt;
  String? _lastError;
  String _authToken =
      ''; // Optional authorization token (empty = allow all local clients)

  int _sessionCounter = 0;
  int _clientCounter = 0;
  int _maintenanceTickCounter = 0;

  /// Active streaming sessions keyed by sessionId.
  final Map<String, StreamingSession> _sessions = {};

  /// In-flight session creation futures keyed by normalized request key.
  final Map<String, Future<StreamingSession>> _pendingSessions = {};

  /// Currently connected HTTP streaming clients keyed by clientId.
  final Map<String, ConnectedClientInfo> _activeClients = {};

  /// Recent server activity log lines for diagnostics.
  final List<String> _activityLogs = [];

  Timer? _notificationSyncTimer;

  @visibleForTesting
  DebridService debridService = DebridService.instance;

  @visibleForTesting
  bool skipTorrentEngineInit = false;

  bool get isRunning => _httpServer != null;
  bool get isStarting => _isStarting;
  bool get portFallbackUsed => _portFallbackUsed;
  int get port => _port;
  String get localIp => _localIp;
  DateTime? get startedAt => _startedAt;
  String? get lastError => _lastError;
  String get authToken => _authToken;

  int get connectedClientsCount => _activeClients.length;
  List<ConnectedClientInfo> get connectedClients =>
      List.unmodifiable(_activeClients.values);

  List<StreamingSession> get activeSessions =>
      List.unmodifiable(_sessions.values);

  List<String> get activityLogs => List.unmodifiable(_activityLogs);

  String get loopbackBaseUrl => 'http://127.0.0.1:$_port';
  String get lanBaseUrl => 'http://$_localIp:$_port';

  void setAuthToken(String token) {
    _authToken = token.trim();
    notifyListeners();
  }

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    final entry = '[$ts] $message';
    _activityLogs.insert(0, entry);
    if (_activityLogs.length > 100) {
      _activityLogs.removeRange(100, _activityLogs.length);
    }
    debugPrint('HttpStreamingServer: $message');
  }

  void _onEngineUpdated() {
    if (!LibtorrentFlutter.isInitialized) return;
    final nativeStreams = LibtorrentFlutter.instance.streams;
    bool updated = false;
    for (final session in _sessions.values) {
      final latest = nativeStreams[session.nativeStreamId];
      if (latest != null) {
        session.latestNativeInfo = latest;
        if (latest.fileSize > 0 && session.fileSize == 0) {
          session.fileSize = latest.fileSize;
        }
        updated = true;
      }
    }
    if (updated) {
      notifyListeners();
    }
  }

  /// Discovers the device's primary non-loopback IPv4 address on Wi-Fi / LAN.
  static Future<String> resolveLocalIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('en') ||
            name.contains('eth')) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback) return addr.address;
          }
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  /// Starts the local HTTP streaming server and Android Foreground Service.
  Future<void> startServer({int? port}) async {
    if (_httpServer != null || _isStarting) return;
    _isStarting = true;
    _portFallbackUsed = false;
    _lastError = null;
    notifyListeners();

    final targetPort = port ?? ServerSettingsService.instance.serverPort;

    try {
      // 1. Initialize the native libtorrent_flutter engine
      if (!skipTorrentEngineInit) {
        try {
          await TorrentEngineService.instance.ensureInitialized();
        } catch (e) {
          if (!ServerSettingsService.instance.hasConfiguredDebrid) {
            rethrow;
          }
          _log(
            'Native torrent engine unavailable ($e); continuing in Debrid-only mode.',
          );
        }
      }

      // 2. Discover local IP address
      _localIp = await resolveLocalIpv4();

      // 3. Bind HTTP server on 0.0.0.0:<targetPort> (fallback to random free port if busy)
      try {
        _httpServer = await HttpServer.bind(
          InternetAddress.anyIPv4,
          targetPort,
          shared: true,
        );
      } on SocketException {
        _httpServer = await HttpServer.bind(
          InternetAddress.anyIPv4,
          0,
          shared: true,
        );
        _portFallbackUsed = true;
      }

      _port = _httpServer!.port;
      _startedAt = DateTime.now();

      if (_portFallbackUsed) {
        _log(
          'Warning: Port $targetPort was busy, bound to fallback port $_port instead.',
        );
      }

      _httpServer!.listen(
        _handleHttpRequest,
        onError: (Object err) {
          _log('HTTP listener error: $err');
        },
        cancelOnError: false,
      );

      // 4. Start Android Foreground Service to keep server alive in background
      await AndroidForegroundService.instance.startService(
        title: 'Torrent Bridge Running ($_localIp:$_port)',
        content: 'Ready for streaming • 0 active streams',
      );

      _maintenanceTickCounter = 0;
      _notificationSyncTimer?.cancel();
      _notificationSyncTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _onMaintenanceTick(),
      );

      unawaited(ServerSettingsService.instance.setKeepServerRunning(true));
      _log(
        'Server started on http://$_localIp:$_port (loopback http://127.0.0.1:$_port)',
      );
    } catch (e) {
      _lastError = e.toString();
      _log('Failed to start server: $e');
      rethrow;
    } finally {
      _isStarting = false;
      notifyListeners();
    }
  }

  /// Ensures the server is running if the user previously turned it ON and hasn't stopped it.
  Future<void> ensureRunningIfEnabled() async {
    if (ServerSettingsService.instance.keepServerRunning &&
        !isRunning &&
        !isStarting) {
      try {
        await startServer(port: ServerSettingsService.instance.serverPort);
      } catch (e) {
        _log('Auto-recovery failed: $e');
      }
    }
  }

  void _onMaintenanceTick() {
    _syncForegroundNotification();
    _maintenanceTickCounter++;
    if (_maintenanceTickCounter % 3 == 0 && _sessions.isNotEmpty) {
      unawaited(
        ServerSettingsService.instance.checkAndEnforceCacheLimit(
          protectedInfoHashes: _sessions.values.map((s) => s.infoHash).toSet(),
          protectedRelativePaths: _sessions.values
              .map((s) => s.filePath)
              .toSet(),
        ),
      );
    }
  }

  void _syncForegroundNotification() {
    if (!isRunning || !Platform.isAndroid) return;
    final streamsCount = _sessions.length;
    final clientsCount = _activeClients.length;
    int totalSpeed = 0;
    for (final s in _sessions.values) {
      totalSpeed += s.latestNativeInfo?.downloadRate ?? 0;
    }
    final speedStr = totalSpeed > 0 ? ' • ${formatSpeed(totalSpeed)}' : '';
    AndroidForegroundService.instance.updateNotification(
      title: 'Torrent Bridge ($_localIp:$_port)',
      content:
          '$streamsCount active stream(s) • $clientsCount client(s)$speedStr',
    );
  }

  /// Stops the HTTP streaming server, closes all active streams, and stops the Foreground Service.
  Future<void> stopServer({bool disposeTorrents = false}) async {
    _notificationSyncTimer?.cancel();
    _notificationSyncTimer = null;
    _maintenanceTickCounter = 0;

    // Stop all active streaming sessions
    final sessionIds = _sessions.keys.toList();
    for (final sid in sessionIds) {
      stopSession(sid);
    }
    _sessions.clear();
    _pendingSessions.clear();
    _activeClients.clear();

    _upstreamHttpClient?.close(force: true);
    _upstreamHttpClient = null;

    final srv = _httpServer;
    _httpServer = null;
    _startedAt = null;
    _portFallbackUsed = false;
    if (srv != null) {
      try {
        await srv.close(force: true);
      } catch (_) {}
    }

    if (disposeTorrents) {
      TorrentEngineService.instance.disposeAllTorrents();
    }

    await AndroidForegroundService.instance.stopService();
    _log('Server stopped.');
    notifyListeners();
  }

  /// Creates or reuses an active [StreamingSession] for the given magnet/infohash
  /// and target audio file (`filePath` or `fileIndex`).
  Future<StreamingSession> createOrGetStreamSession({
    required String magnetOrInfoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final normalizedHash = TorrentEngineService.extractInfoHash(
      magnetOrInfoHash,
    );
    final pendingKey = '$normalizedHash|${filePath ?? ""}|${fileIndex ?? -1}';
    final existingFuture = _pendingSessions[pendingKey];
    if (existingFuture != null) {
      return existingFuture;
    }

    final future = _createOrGetStreamSessionInternal(
      magnetOrInfoHash: magnetOrInfoHash,
      filePath: filePath,
      fileIndex: fileIndex,
    );
    _pendingSessions[pendingKey] = future;
    try {
      return await future;
    } finally {
      _pendingSessions.remove(pendingKey);
    }
  }

  Future<StreamingSession> _createOrGetStreamSessionInternal({
    required String magnetOrInfoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    if (!isRunning) {
      await startServer(port: ServerSettingsService.instance.serverPort);
    }

    final normalizedHash = TorrentEngineService.extractInfoHash(
      magnetOrInfoHash,
    );
    final magnetUri = TorrentEngineService.normalizeToMagnetUri(
      magnetOrInfoHash,
    );
    final cacheSvc = AudioDiskCacheService.instance;
    final settings = ServerSettingsService.instance;

    // Fast path: if the full file is already cached on disk (e.g. after app
    // restart), serve immediately without waiting for torrent peers or Debrid.
    final cachedEntry = cacheSvc.findMatchingEntry(
      infoHash: normalizedHash,
      fileIndex: fileIndex,
      filePath: filePath,
    );
    if (cachedEntry != null &&
        cachedEntry.isComplete &&
        cachedEntry.fileSize > 0) {
      for (final existing in _sessions.values) {
        if (existing.infoHash == cachedEntry.infoHash &&
            existing.fileIndex == cachedEntry.fileIndex) {
          existing.lastAccessedAt = DateTime.now();
          existing.isCached = true;
          existing.cachedBytes = cachedEntry.cachedBytes;
          existing.cachedPercentage = cachedEntry.cachedPercentage;
          cacheSvc.recordAccess(cachedEntry.key);
          for (final s in _sessions.values) {
            s.isPrimary = (s.sessionId == existing.sessionId);
          }
          _log(
            'Reusing offline cached session ${existing.sessionId} for "${cachedEntry.fileName}"',
          );
          notifyListeners();
          return existing;
        }
      }

      _sessionCounter++;
      final resolvedFileName = cachedEntry.fileName.isNotEmpty
          ? cachedEntry.fileName
          : 'audio_${cachedEntry.fileIndex}.bin';
      final ext = AudioFileEntry.extractExtension(resolvedFileName);
      final formatLabel = ext.isEmpty ? 'RAW' : ext.substring(1).toUpperCase();
      final sessionId =
          's${_sessionCounter}_cached_${cachedEntry.infoHash.substring(0, math.min(8, cachedEntry.infoHash.length))}_${cachedEntry.fileIndex}';

      for (final s in _sessions.values) {
        s.isPrimary = false;
      }

      final session = StreamingSession(
        sessionId: sessionId,
        torrentId: -1,
        nativeStreamId: -1,
        magnetUri: magnetUri,
        infoHash: cachedEntry.infoHash,
        torrentName: cachedEntry.infoHash,
        fileIndex: cachedEntry.fileIndex,
        fileName: resolvedFileName,
        filePath: cachedEntry.filePath.isNotEmpty
            ? cachedEntry.filePath
            : resolvedFileName,
        fileSize: cachedEntry.fileSize,
        mimeType: cachedEntry.mimeType,
        formatLabel: formatLabel,
        nativeStreamUrl: '',
        createdAt: DateTime.now(),
        isPrimary: true,
        isCached: true,
        cachedBytes: cachedEntry.cachedBytes,
        cachedPercentage: cachedEntry.cachedPercentage,
        lastAccessedAt: DateTime.now(),
      );

      _sessions[sessionId] = session;
      cacheSvc.recordAccess(cachedEntry.key);
      ServerSettingsService.instance.recordAccess(cachedEntry.infoHash);
      _log(
        'Created cached-disk stream session $sessionId -> [${cachedEntry.fileIndex}] $resolvedFileName (${formatBytes(cachedEntry.fileSize)}) [100% CACHED ON DISK]',
      );
      _syncForegroundNotification();
      notifyListeners();
      return session;
    }

    // Debrid-first path when user has configured a Debrid provider + API key
    if (settings.hasConfiguredDebrid) {
      final activeProvider = settings.debridProvider;
      final activeKey = settings.activeDebridApiKey;

      for (final existing in _sessions.values) {
        if (existing.isDebridStream &&
            existing.debridProvider == activeProvider.id &&
            existing.infoHash == normalizedHash &&
            (fileIndex == null || existing.fileIndex == fileIndex) &&
            (filePath == null ||
                existing.filePath.toLowerCase() ==
                    filePath.trim().toLowerCase() ||
                existing.fileName.toLowerCase() ==
                    filePath.trim().toLowerCase())) {
          existing.lastAccessedAt = DateTime.now();
          for (final s in _sessions.values) {
            s.isPrimary = (s.sessionId == existing.sessionId);
          }
          _log(
            'Reusing Debrid (${activeProvider.displayName}) session ${existing.sessionId} for "${existing.fileName}"',
          );
          notifyListeners();
          return existing;
        }
      }

      try {
        _log(
          'Resolving audio via ${activeProvider.displayName} for ${normalizedHash.substring(0, math.min(8, normalizedHash.length))}...',
        );
        final resolved = await debridService.resolveAudioFile(
          provider: activeProvider,
          apiKey: activeKey,
          magnetOrInfoHash: magnetUri,
          filePath: filePath,
          fileIndex: fileIndex,
        );

        DiskCacheEntry? diskEntry;
        if (cacheSvc.isInitialized && resolved.fileSize > 0) {
          diskEntry = await cacheSvc.ensureEntry(
            infoHash: resolved.infoHash,
            fileIndex: resolved.fileIndex,
            fileName: resolved.fileName,
            filePath: resolved.filePath,
            mimeType: resolved.mimeType,
            fileSize: resolved.fileSize,
          );
        }

        _sessionCounter++;
        final shortHash = resolved.infoHash.substring(
          0,
          math.min(8, resolved.infoHash.length),
        );
        final sessionId =
            's${_sessionCounter}_debrid_${activeProvider.id}_${shortHash}_${resolved.fileIndex}';

        for (final s in _sessions.values) {
          s.isPrimary = false;
        }

        final session = StreamingSession(
          sessionId: sessionId,
          torrentId: -1,
          nativeStreamId: -1,
          magnetUri: magnetUri,
          infoHash: resolved.infoHash,
          torrentName: '${activeProvider.displayName} • ${resolved.fileName}',
          fileIndex: resolved.fileIndex,
          fileName: resolved.fileName,
          filePath: resolved.filePath,
          fileSize: resolved.fileSize,
          mimeType: resolved.mimeType,
          formatLabel: resolved.formatLabel,
          nativeStreamUrl: '',
          createdAt: DateTime.now(),
          isDebridStream: true,
          debridProvider: activeProvider.id,
          debridDirectUrl: resolved.directUrl,
          isPrimary: true,
          isCached: diskEntry?.isComplete ?? false,
          cachedBytes: diskEntry?.cachedBytes ?? 0,
          cachedPercentage: diskEntry?.cachedPercentage ?? 0.0,
          lastAccessedAt: DateTime.now(),
        );

        _sessions[sessionId] = session;
        _lastError = null;
        ServerSettingsService.instance.recordAccess(resolved.infoHash);
        _log(
          'Created Debrid (${activeProvider.displayName}) stream session $sessionId -> ${resolved.fileName}',
        );
        _syncForegroundNotification();
        notifyListeners();
        return session;
      } catch (e) {
        final baseMessage = e is DebridException
            ? e.toString()
            : 'Debrid (${activeProvider.displayName}) failed: $e';
        _log(baseMessage);
        if (!settings.fallbackToTorrentOnDebridFailure) {
          final userMessage =
              '$baseMessage. Enable "Try Torrenting if Debrid Fails" in Settings to fall back to P2P torrenting.';
          _lastError = userMessage;
          notifyListeners();
          throw DebridException(
            userMessage,
            statusCode: e is DebridException ? e.statusCode : null,
            provider: activeProvider,
          );
        }
        _log(
          'Debrid fallback to P2P torrent is ON; switching to torrent engine...',
        );
      }
    }

    final engineSvc = TorrentEngineService.instance;
    final torrentId = await engineSvc.addOrGetTorrent(
      magnetOrInfoHash,
      streamOnly: true,
    );

    _log('Resolving metadata for torrent #$torrentId...');
    final torrentInfo = await engineSvc.waitForMetadata(torrentId);

    final targetFile = engineSvc.resolveAudioFile(
      torrentId,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    // Check if we already have an active session for (torrentId, targetFile.index)
    for (final existing in _sessions.values) {
      if (existing.torrentId == torrentId &&
          existing.fileIndex == targetFile.index) {
        // Verify native stream is still alive
        final nativeStreams = engineSvc.streams;
        if (nativeStreams.containsKey(existing.nativeStreamId)) {
          existing.latestNativeInfo = nativeStreams[existing.nativeStreamId];
          existing.lastAccessedAt = DateTime.now();

          final diskEntry = cacheSvc.getEntry(
            existing.infoHash,
            existing.fileIndex,
          );
          if (diskEntry != null) {
            existing.isCached = diskEntry.isComplete;
            existing.cachedBytes = diskEntry.cachedBytes;
            existing.cachedPercentage = diskEntry.cachedPercentage;
            cacheSvc.recordAccess(diskEntry.key);
          }

          // Mark this session as primary, others as secondary
          for (final s in _sessions.values) {
            s.isPrimary = (s.sessionId == existing.sessionId);
          }

          // Prioritize this torrent and file
          await engineSvc.prioritizeTorrentAndFile(
            torrentId,
            fileIndex: targetFile.index,
            streamId: existing.nativeStreamId,
          );

          _log(
            'Reusing prioritized session ${existing.sessionId} for "${targetFile.path}"',
          );
          notifyListeners();
          return existing;
        }
      }
    }

    // Start the native libtorrent_flutter stream
    final streamInfo = engineSvc.startNativeStream(
      torrentId,
      fileIndex: targetFile.index,
    );

    final resolvedSize = streamInfo.fileSize > 0
        ? streamInfo.fileSize
        : targetFile.size;
    final infoHash =
        engineSvc.getInfoHashForTorrent(torrentId) ?? normalizedHash;
    final resolvedMagnet =
        engineSvc.getMagnetForTorrent(torrentId) ?? magnetUri;

    final diskEntry = await cacheSvc.ensureEntry(
      infoHash: infoHash,
      fileIndex: targetFile.index,
      fileName: targetFile.name,
      filePath: targetFile.path,
      mimeType: targetFile.mimeType,
      fileSize: resolvedSize,
    );

    _sessionCounter++;
    final sessionId = 's${_sessionCounter}_${torrentId}_${targetFile.index}';

    // Mark previous sessions as secondary
    for (final s in _sessions.values) {
      s.isPrimary = false;
    }

    final session = StreamingSession(
      sessionId: sessionId,
      torrentId: torrentId,
      nativeStreamId: streamInfo.id,
      magnetUri: resolvedMagnet,
      infoHash: infoHash,
      torrentName: torrentInfo.name.isNotEmpty ? torrentInfo.name : infoHash,
      fileIndex: targetFile.index,
      fileName: targetFile.name,
      filePath: targetFile.path,
      fileSize: resolvedSize,
      mimeType: targetFile.mimeType,
      formatLabel: targetFile.formatLabel,
      nativeStreamUrl: streamInfo.url,
      createdAt: DateTime.now(),
      latestNativeInfo: streamInfo,
      isPrimary: true,
      isCached: diskEntry.isComplete,
      cachedBytes: diskEntry.cachedBytes,
      cachedPercentage: diskEntry.cachedPercentage,
      lastAccessedAt: DateTime.now(),
    );

    _sessions[sessionId] = session;

    // Apply priority & preloading for this newest torrent
    await engineSvc.prioritizeTorrentAndFile(
      torrentId,
      fileIndex: targetFile.index,
      streamId: streamInfo.id,
    );

    _log(
      'Created primary stream session $sessionId -> [${targetFile.index}] ${targetFile.path} (${formatBytes(resolvedSize)})'
      '${diskEntry.cachedBytes > 0 ? " [${(diskEntry.cachedPercentage * 100).toStringAsFixed(0)}% CACHED ON DISK]" : ""}',
    );
    _syncForegroundNotification();
    notifyListeners();
    return session;
  }

  /// Lazily ensures a native `libtorrent_flutter` stream is running for [session]
  /// when uncached byte ranges need to be fetched from the torrent swarm.
  Future<void> _ensureNativeStreamActive(StreamingSession session) async {
    final engineSvc = TorrentEngineService.instance;
    if (session.nativeStreamId > 0 &&
        session.nativeStreamUrl.isNotEmpty &&
        engineSvc.isInitialized &&
        engineSvc.streams.containsKey(session.nativeStreamId)) {
      final info = engineSvc.streams[session.nativeStreamId];
      if (info != null && info.isActive && info.url.isNotEmpty) {
        return;
      }
    }

    final info = await engineSvc.ensureNativeStreamForSession(
      magnetUri: session.magnetUri,
      fileIndex: session.fileIndex,
    );
    session.torrentId = info.torrentId;
    session.nativeStreamId = info.id;
    session.nativeStreamUrl = info.url;
    session.latestNativeInfo = info;
    if (session.fileSize <= 0 && info.fileSize > 0) {
      session.fileSize = info.fileSize;
    }
  }

  /// Stops and removes a specific [StreamingSession].
  void stopSession(String sessionId) {
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    try {
      TorrentEngineService.instance.stopNativeStream(session.nativeStreamId);
    } catch (_) {}
    _log('Stopped stream session $sessionId (${session.fileName})');
    _syncForegroundNotification();
    notifyListeners();
  }

  // ─── HTTP Request Routing ───────────────────────────────────────────────────

  bool _isAuthorized(HttpRequest req) {
    if (_authToken.isEmpty) return true;
    final headerToken = req.headers.value('x-auth-token');
    if (headerToken == _authToken) return true;
    final authHeader = req.headers.value(HttpHeaders.authorizationHeader);
    if (authHeader == 'Bearer $_authToken') return true;
    final queryToken = req.uri.queryParameters['token'];
    if (queryToken == _authToken) return true;
    return false;
  }

  void _addCorsHeaders(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, HEAD, DELETE, OPTIONS',
    );
    res.headers.set(
      'Access-Control-Allow-Headers',
      'Origin, Content-Type, Accept, Range, Authorization, X-Auth-Token',
    );
    res.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Length, Content-Range, Accept-Ranges, Content-Type, ETag',
    );
  }

  Future<void> _handleHttpRequest(HttpRequest req) async {
    _addCorsHeaders(req.response);

    if (req.method == 'OPTIONS') {
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
      return;
    }

    if (!_isAuthorized(req)) {
      await _sendJson(req.response, HttpStatus.unauthorized, {
        'error':
            'Unauthorized client. Provide valid X-Auth-Token or Bearer token.',
      });
      return;
    }

    final path = req.uri.path;
    final segments = req.uri.pathSegments;

    try {
      // 1. Health / Status Endpoint: GET / or GET /status or GET /api/status
      if ((path == '/' || path == '/status' || path == '/api/status') &&
          req.method == 'GET') {
        await _handleStatusRequest(req);
        return;
      }

      // 2. Create / Resolve Stream Endpoint: POST /api/stream or POST /stream
      if ((path == '/api/stream' || path == '/stream') &&
          req.method == 'POST') {
        await _handleCreateStreamPost(req);
        return;
      }

      // 3. Inspect Torrent Metadata & Files: POST /api/torrent/inspect
      if (path == '/api/torrent/inspect' && req.method == 'POST') {
        await _handleInspectTorrentPost(req);
        return;
      }

      // 4. List Active Sessions: GET /api/sessions
      if (path == '/api/sessions' && req.method == 'GET') {
        final host = _requestHostIp(req);
        await _sendJson(req.response, HttpStatus.ok, {
          'status': 'ok',
          'sessions': _sessions.values
              .map((s) => s.toJson(host: host, port: _port))
              .toList(),
        });
        return;
      }

      // 5. Stop Session: DELETE /api/stream/<sessionId>
      if (segments.length == 3 &&
          segments[0] == 'api' &&
          segments[1] == 'stream' &&
          req.method == 'DELETE') {
        final sid = segments[2];
        stopSession(sid);
        await _sendJson(req.response, HttpStatus.ok, {
          'status': 'stopped',
          'session_id': sid,
        });
        return;
      }

      // 6. Cache Endpoints: GET|DELETE /api/cache
      if (path == '/api/cache') {
        if (req.method == 'GET') {
          await _handleCacheGet(req);
          return;
        } else if (req.method == 'DELETE') {
          await _handleCacheDelete(req);
          return;
        }
      }

      // 7. Settings Endpoints: GET|POST /api/settings
      if (path == '/api/settings') {
        if (req.method == 'GET') {
          await _sendJson(req.response, HttpStatus.ok, {
            'status': 'ok',
            'settings': ServerSettingsService.instance.toJson(),
          });
          return;
        } else if (req.method == 'POST') {
          await _handleSettingsPost(req);
          return;
        }
      }

      // 8. Direct Query Audio Stream Endpoint: GET|HEAD /audio?magnet=...&file_path=...
      if (path == '/audio' && (req.method == 'GET' || req.method == 'HEAD')) {
        await _handleDirectAudioQueryStream(req);
        return;
      }

      // 9. Session Audio Stream Endpoint: GET|HEAD /stream/<sessionId>[/<fileName>]
      if (segments.length >= 2 &&
          segments[0] == 'stream' &&
          (req.method == 'GET' || req.method == 'HEAD')) {
        final sessionId = segments[1];
        final session = _sessions[sessionId];
        if (session == null) {
          await _sendJson(req.response, HttpStatus.notFound, {
            'error': 'Streaming session "$sessionId" not found or expired.',
          });
          return;
        }
        await _proxyAudioStreamRequest(req, session);
        return;
      }

      await _sendJson(req.response, HttpStatus.notFound, {
        'error': 'Endpoint not found: ${req.method} $path',
      });
    } on DebridException catch (e) {
      _log('Debrid error on ${req.method} $path: ${e.message}');
      try {
        await _sendJson(req.response, HttpStatus.badGateway, {
          'error': e.message,
          'provider': e.provider?.id,
        });
      } catch (_) {}
    } catch (e) {
      _log('Error handling ${req.method} $path: $e');
      try {
        await _sendJson(req.response, HttpStatus.internalServerError, {
          'error': e.toString(),
        });
      } catch (_) {}
    }
  }

  String _requestHostIp(HttpRequest req) {
    final hostHeader = req.headers.value(HttpHeaders.hostHeader);
    if (hostHeader != null && hostHeader.isNotEmpty) {
      final colon = hostHeader.indexOf(':');
      return colon > 0 ? hostHeader.substring(0, colon) : hostHeader;
    }
    return _localIp;
  }

  Future<void> _handleStatusRequest(HttpRequest req) async {
    final host = _requestHostIp(req);
    final engineSvc = TorrentEngineService.instance;
    await _sendJson(req.response, HttpStatus.ok, {
      'status': 'running',
      'server_ip': _localIp,
      'loopback_ip': '127.0.0.1',
      'port': _port,
      'started_at': _startedAt?.toIso8601String(),
      'libtorrent_version': engineSvc.libraryVersion,
      'connected_clients_count': _activeClients.length,
      'connected_clients': _activeClients.values
          .map((c) => c.toJson())
          .toList(),
      'active_sessions_count': _sessions.length,
      'active_sessions': _sessions.values
          .map((s) => s.toJson(host: host, port: _port))
          .toList(),
    });
  }

  /// Handles `POST /api/stream` (and `POST /stream`):
  /// ```json
  /// {
  ///   "magnet": "magnet:?xt=urn:btih:...",
  ///   "file_path": "Audiobook/Chapter 01.mp3"
  /// }
  /// ```
  Future<void> _handleCreateStreamPost(HttpRequest req) async {
    final bodyStr = await utf8.decoder.bind(req).join();
    if (bodyStr.trim().isEmpty) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Request body must be JSON with "magnet" (or "infohash") and optional "file_path" / "file_index".',
      });
      return;
    }

    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(bodyStr) as Map<String, dynamic>;
    } catch (e) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Invalid JSON body: $e',
      });
      return;
    }

    final magnetOrHash =
        (payload['magnet'] ?? payload['infohash'] ?? payload['uri'])
            ?.toString()
            .trim();
    if (magnetOrHash == null || magnetOrHash.isEmpty) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Missing required field "magnet" or "infohash".',
      });
      return;
    }

    final filePath = payload['file_path']?.toString();
    final rawFileIndex = payload['file_index'];
    final int? fileIndex = rawFileIndex is int
        ? rawFileIndex
        : (rawFileIndex != null ? int.tryParse(rawFileIndex.toString()) : null);

    _log(
      'Client POST /api/stream from ${req.connectionInfo?.remoteAddress.address ?? "local"} '
      '(file_path: ${filePath ?? "auto"}, file_index: ${fileIndex ?? "auto"})',
    );

    final session = await createOrGetStreamSession(
      magnetOrInfoHash: magnetOrHash,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    final host = _requestHostIp(req);
    await _sendJson(req.response, HttpStatus.ok, {
      'status': 'ok',
      ...session.toJson(host: host, port: _port),
    });
  }

  /// Handles `POST /api/torrent/inspect` to resolve metadata & list files.
  Future<void> _handleInspectTorrentPost(HttpRequest req) async {
    final bodyStr = await utf8.decoder.bind(req).join();
    if (bodyStr.trim().isEmpty) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Request body must be JSON with "magnet" or "infohash".',
      });
      return;
    }

    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(bodyStr) as Map<String, dynamic>;
    } catch (e) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Invalid JSON body: $e',
      });
      return;
    }

    final magnetOrHash = (payload['magnet'] ?? payload['infohash'])
        ?.toString()
        .trim();
    if (magnetOrHash == null || magnetOrHash.isEmpty) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Missing "magnet" or "infohash".',
      });
      return;
    }

    final engineSvc = TorrentEngineService.instance;
    final torrentId = await engineSvc.addOrGetTorrent(
      magnetOrHash,
      streamOnly: true,
    );
    final info = await engineSvc.waitForMetadata(torrentId);
    final files = engineSvc.getFiles(torrentId);

    await _sendJson(req.response, HttpStatus.ok, {
      'status': 'ok',
      'torrent_id': torrentId,
      'name': info.name,
      'infohash': engineSvc.getInfoHashForTorrent(torrentId),
      'state': info.state.name,
      'progress': info.progress,
      'total_wanted': info.totalWanted,
      'num_peers': info.numPeers,
      'num_seeds': info.numSeeds,
      'has_metadata': info.hasMetadata,
      'file_count': files.length,
      'files': files.map((f) => f.toJson()).toList(),
    });
  }

  Future<void> _handleCacheGet(HttpRequest req) async {
    final settings = ServerSettingsService.instance;
    await settings.refreshCacheUsage();
    await _sendJson(req.response, HttpStatus.ok, {
      'status': 'ok',
      'cache': settings.toJson(),
    });
  }

  Future<void> _handleCacheDelete(HttpRequest req) async {
    final settings = ServerSettingsService.instance;
    final activeHashes = _sessions.values.map((s) => s.infoHash).toSet();
    final freed = await settings.clearCache(activeInfoHashes: activeHashes);
    _log('Cleared cache: freed ${formatBytes(freed)}');
    await _sendJson(req.response, HttpStatus.ok, {
      'status': 'ok',
      'freed_bytes': freed,
      'freed_formatted': formatBytes(freed),
      'remaining_bytes': settings.cachedBytes,
      'remaining_formatted': settings.cachedBytesFormatted,
    });
  }

  Future<void> _handleSettingsPost(HttpRequest req) async {
    final bodyStr = await utf8.decoder.bind(req).join();
    final settings = ServerSettingsService.instance;
    if (bodyStr.trim().isEmpty) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Request body must be JSON.',
      });
      return;
    }
    try {
      final json = jsonDecode(bodyStr) as Map<String, dynamic>;
      if (json['max_cache_size_bytes'] is num) {
        await settings.setMaxCacheSizeBytes(
          (json['max_cache_size_bytes'] as num).toInt(),
        );
      } else if (json['max_cache_size_mb'] is num) {
        await settings.setMaxCacheSizeBytes(
          (json['max_cache_size_mb'] as num).toInt() * 1024 * 1024,
        );
      }

      if (json['prioritize_newest'] is bool) {
        await settings.setPrioritizeNewest(json['prioritize_newest'] as bool);
      }
      if (json['auto_pause_background'] is bool) {
        await settings.setAutoPauseBackground(
          json['auto_pause_background'] as bool,
        );
      }
      if (json['fast_audio_preload'] is bool) {
        await settings.setFastAudioPreload(json['fast_audio_preload'] as bool);
      }
      if (json['debrid_provider'] is String) {
        await settings.setDebridProvider(
          DebridProvider.fromId(json['debrid_provider'] as String),
        );
      }
      if (json['debrid_api_key'] is String) {
        await settings.setDebridApiKey(
          settings.debridProvider,
          json['debrid_api_key'] as String,
        );
      }
      if (json['fallback_to_torrent_on_debrid_failure'] is bool) {
        await settings.setFallbackToTorrentOnDebridFailure(
          json['fallback_to_torrent_on_debrid_failure'] as bool,
        );
      }

      await _sendJson(req.response, HttpStatus.ok, {
        'status': 'ok',
        'settings': settings.toJson(),
      });
    } catch (e) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Failed to update settings: $e',
      });
    }
  }

  /// Handles `GET /audio?magnet=...&file_path=...` (or `infohash` & `file_index`)
  /// so a client or audio player can stream directly via query parameters.
  Future<void> _handleDirectAudioQueryStream(HttpRequest req) async {
    final qp = req.uri.queryParameters;
    final magnetOrHash = (qp['magnet'] ?? qp['infohash'])?.trim();
    if (magnetOrHash == null || magnetOrHash.isEmpty) {
      await _sendJson(req.response, HttpStatus.badRequest, {
        'error': 'Query parameter "magnet" or "infohash" is required.',
      });
      return;
    }
    final filePath = qp['file_path'];
    final fileIndex = qp['file_index'] != null
        ? int.tryParse(qp['file_index']!)
        : null;

    final session = await createOrGetStreamSession(
      magnetOrInfoHash: magnetOrHash,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    await _proxyAudioStreamRequest(req, session);
  }

  HttpClient _getUpstreamClient() {
    return _upstreamHttpClient ??= (HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 15));
  }

  /// Serves an incoming HTTP audio `GET` or `HEAD` request using a hybrid
  /// persistent disk cache + `libtorrent_flutter` byte-range pipeline:
  /// - Cached byte ranges (including seeks into already-cached regions) are
  ///   served directly from local disk under an active read lock.
  /// - Uncached byte range gaps are fetched from `libtorrent_flutter` (which
  ///   prioritizes those seek pieces), written incrementally to disk under a
  ///   write lock with crash-safe metadata updates, and streamed to the client.
  Future<void> _proxyAudioStreamRequest(
    HttpRequest req,
    StreamingSession session,
  ) async {
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    final remoteAddr = req.connectionInfo?.remoteAddress.address ?? '127.0.0.1';
    final userAgent =
        req.headers.value(HttpHeaders.userAgentHeader) ?? 'AudioPlayer';

    _clientCounter++;
    final clientId = 'c$_clientCounter';
    final clientInfo = ConnectedClientInfo(
      clientId: clientId,
      remoteAddress: remoteAddr,
      userAgent: userAgent,
      sessionId: session.sessionId,
      method: req.method,
      requestedRange: rangeHeader,
      connectedAt: DateTime.now(),
    );

    _activeClients[clientId] = clientInfo;
    session.activeClients++;
    session.totalRequests++;
    session.lastAccessedAt = DateTime.now();
    if (rangeHeader != null) {
      session.lastRangeHeader = rangeHeader;
    }
    notifyListeners();

    final cacheSvc = AudioDiskCacheService.instance;
    final res = req.response;
    res.bufferOutput = false;

    try {
      // Ensure disk cache entry exists once fileSize is known
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
          fileName: session.fileName,
          filePath: session.filePath,
          mimeType: session.mimeType,
          fileSize: session.fileSize,
        );
      }

      if (session.fileSize > 0) {
        final parsed = _parseRangeHeader(rangeHeader, session.fileSize);
        if (parsed != null && parsed.unsatisfiable) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${session.fileSize}',
          );
          await res.close();
          return;
        }

        if (parsed != null) {
          final totalToSend = parsed.end - parsed.start + 1;
          final isFullCacheHit =
              cacheEntry != null &&
              cacheEntry.isRangeCached(parsed.start, parsed.end);

          _log(
            '${req.method} /stream/${session.sessionId} from $remoteAddr '
            '(${rangeHeader ?? "full file"}) ${isFullCacheHit ? "[DISK CACHE HIT]" : (session.isDebridStream ? "[DEBRID/HYBRID]" : "[TORRENT/HYBRID]")}',
          );

          var headersCommitted = false;
          void commitHeaders() {
            if (headersCommitted) return;
            headersCommitted = true;
            res.statusCode = parsed.isPartial
                ? HttpStatus.partialContent
                : HttpStatus.ok;
            res.headers.set(HttpHeaders.contentTypeHeader, session.mimeType);
            res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            res.headers.set(
              HttpHeaders.cacheControlHeader,
              'no-store, no-cache',
            );
            res.headers.set(HttpHeaders.connectionHeader, 'close');
            res.headers.set(
              HttpHeaders.etagHeader,
              '"${session.infoHash}-${session.fileIndex}"',
            );
            if (parsed.isPartial) {
              res.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes ${parsed.start}-${parsed.end}/${session.fileSize}',
              );
            }
            res.contentLength = totalToSend;
          }

          if (req.method == 'HEAD') {
            commitHeaders();
            if (cacheEntry != null) {
              cacheSvc.recordAccess(cacheEntry.key);
            }
            await res.close();
            return;
          }

          var currentOffset = parsed.start;
          var anyMissDownloaded = false;

          try {
            while (currentOffset <= parsed.end) {
              final covering = cacheEntry?.findCoveringRange(currentOffset);
              if (covering != null && cacheEntry != null) {
                commitHeaders();
                final segEnd = math.min(covering.end, parsed.end);
                await for (final chunk in cacheSvc.openCachedRangeStream(
                  cacheEntry.key,
                  currentOffset,
                  segEnd,
                )) {
                  res.add(chunk);
                  clientInfo.bytesTransferred += chunk.length;
                  session.bytesServed += chunk.length;
                }
                currentOffset = segEnd + 1;
                continue;
              }

              // Cache miss for currentOffset..segEnd: fetch only up to next cached hole
              final nextCached = cacheEntry?.findNextCachedRangeAfter(
                currentOffset,
              );
              final segEnd = nextCached != null
                  ? math.min(nextCached.start - 1, parsed.end)
                  : parsed.end;

              final upstreamRes = await _openUpstreamResponse(
                session,
                method: 'GET',
                rangeHeader: 'bytes=$currentOffset-$segEnd',
              );

              commitHeaders();

              if (cacheEntry == null && cacheSvc.isInitialized) {
                cacheEntry = await cacheSvc.ensureEntry(
                  infoHash: session.infoHash,
                  fileIndex: session.fileIndex,
                  fileName: session.fileName,
                  filePath: session.filePath,
                  mimeType: session.mimeType,
                  fileSize: session.fileSize,
                );
              }

              var upstreamPos = _resolveUpstreamStartOffset(
                upstreamRes,
                fallbackStart: currentOffset,
              );
              anyMissDownloaded = true;

              if (cacheEntry != null) {
                cacheSvc.acquireWriteLock(cacheEntry.key);
              }
              try {
                await for (final chunk in upstreamRes) {
                  if (chunk.isEmpty) continue;
                  final chunkStart = upstreamPos;
                  final chunkEnd = upstreamPos + chunk.length - 1;
                  upstreamPos += chunk.length;

                  // Slice if upstream returned bytes outside [currentOffset, segEnd]
                  if (chunkEnd < currentOffset) continue;
                  if (chunkStart > segEnd) break;

                  final sliceStart = math.max(0, currentOffset - chunkStart);
                  final sliceEndExclusive = math.min(
                    chunk.length,
                    segEnd - chunkStart + 1,
                  );
                  if (sliceEndExclusive <= sliceStart) continue;

                  final effectiveChunk =
                      (sliceStart == 0 && sliceEndExclusive == chunk.length)
                      ? chunk
                      : chunk.sublist(sliceStart, sliceEndExclusive);
                  final writeOffset = chunkStart + sliceStart;

                  if (cacheEntry != null) {
                    await cacheSvc.writeChunk(
                      cacheEntry.key,
                      writeOffset,
                      effectiveChunk,
                      totalFileSize: session.fileSize,
                    );
                  }

                  res.add(effectiveChunk);
                  clientInfo.bytesTransferred += effectiveChunk.length;
                  session.bytesServed += effectiveChunk.length;
                }
              } finally {
                if (cacheEntry != null) {
                  await cacheSvc.releaseWriteLock(cacheEntry.key);
                  session.cachedBytes = cacheEntry.cachedBytes;
                  session.cachedPercentage = cacheEntry.cachedPercentage;
                  session.isCached = cacheEntry.isComplete;
                }
              }

              currentOffset = segEnd + 1;
            }
          } on DebridException catch (e) {
            _lastError = e.message;
            _log('Debrid upstream failed: ${e.message}');
            notifyListeners();
            if (!headersCommitted) {
              await _sendJson(res, HttpStatus.badGateway, {
                'error': e.message,
                'provider': e.provider?.id,
              });
              return;
            }
            rethrow;
          }

          commitHeaders();
          await res.flush();
          await res.close();

          if (anyMissDownloaded) {
            unawaited(
              ServerSettingsService.instance.checkAndEnforceCacheLimit(
                protectedInfoHashes: _sessions.values
                    .map((s) => s.infoHash)
                    .toSet(),
                protectedRelativePaths: _sessions.values
                    .map((s) => s.filePath)
                    .toSet(),
              ),
            );
          }
          return;
        }
      }

      // Fallback when total fileSize is not yet known before upstream responds
      _log(
        '${req.method} /stream/${session.sessionId} from $remoteAddr '
        '(${rangeHeader ?? "full file"}) ${session.isDebridStream ? "[DEBRID UNKNOWN SIZE]" : "[UNKNOWN SIZE PROXY]"}',
      );

      final String? normalizedRange =
          (rangeHeader != null && rangeHeader.isNotEmpty)
          ? _normalizeRangeHeader(rangeHeader, session.fileSize)
          : null;

      final HttpClientResponse upstreamRes;
      try {
        upstreamRes = await _openUpstreamResponse(
          session,
          method: req.method,
          rangeHeader: normalizedRange,
        );
      } on DebridException catch (e) {
        _lastError = e.message;
        _log('Debrid upstream failed: ${e.message}');
        notifyListeners();
        await _sendJson(res, HttpStatus.badGateway, {
          'error': e.message,
          'provider': e.provider?.id,
        });
        return;
      }

      // Update fileSize on session if discovered from Content-Length / Content-Range
      if (session.fileSize <= 0 &&
          upstreamRes.contentLength > 0 &&
          rangeHeader == null) {
        session.fileSize = upstreamRes.contentLength;
      } else if (session.fileSize <= 0) {
        final cr = upstreamRes.headers.value(HttpHeaders.contentRangeHeader);
        if (cr != null && cr.contains('/')) {
          final totalPart = cr.split('/').last.trim();
          final parsedTotal = int.tryParse(totalPart);
          if (parsedTotal != null && parsedTotal > 0) {
            session.fileSize = parsedTotal;
          }
        }
      }

      res.statusCode = upstreamRes.statusCode;
      res.headers.set(HttpHeaders.contentTypeHeader, session.mimeType);
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-store, no-cache');
      res.headers.set(HttpHeaders.connectionHeader, 'close');

      final contentRange = upstreamRes.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      if (contentRange != null) {
        res.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }

      final etag = upstreamRes.headers.value(HttpHeaders.etagHeader);
      if (etag != null) {
        res.headers.set(HttpHeaders.etagHeader, etag);
      }

      if (upstreamRes.contentLength >= 0) {
        res.contentLength = upstreamRes.contentLength;
      }

      if (req.method == 'HEAD') {
        await res.close();
        return;
      }

      if (cacheEntry == null &&
          cacheSvc.isInitialized &&
          session.fileSize > 0) {
        cacheEntry = await cacheSvc.ensureEntry(
          infoHash: session.infoHash,
          fileIndex: session.fileIndex,
          fileName: session.fileName,
          filePath: session.filePath,
          mimeType: session.mimeType,
          fileSize: session.fileSize,
        );
      }

      var fallbackOffset = _resolveUpstreamStartOffset(
        upstreamRes,
        fallbackStart: 0,
      );
      if (cacheEntry != null) {
        cacheSvc.acquireWriteLock(cacheEntry.key);
      }
      try {
        await for (final chunk in upstreamRes) {
          if (cacheEntry != null && chunk.isNotEmpty) {
            await cacheSvc.writeChunk(
              cacheEntry.key,
              fallbackOffset,
              chunk,
              totalFileSize: session.fileSize > 0 ? session.fileSize : null,
            );
            fallbackOffset += chunk.length;
          }
          res.add(chunk);
          clientInfo.bytesTransferred += chunk.length;
          session.bytesServed += chunk.length;
        }
      } finally {
        if (cacheEntry != null) {
          await cacheSvc.releaseWriteLock(cacheEntry.key);
          session.cachedBytes = cacheEntry.cachedBytes;
          session.cachedPercentage = cacheEntry.cachedPercentage;
          session.isCached = cacheEntry.isComplete;
        }
      }
      await res.flush();
      await res.close();
    } catch (e) {
      // Client disconnects during seeking/range switches are normal in ExoPlayer/just_audio
      debugPrint('Stream connection closed ($clientId): $e');
      try {
        await req.response.close();
      } catch (_) {}
    } finally {
      clientInfo.isActive = false;
      _activeClients.remove(clientId);
      if (session.activeClients > 0) {
        session.activeClients--;
      }
      notifyListeners();
    }
  }

  Future<HttpClientResponse> _openUpstreamResponse(
    StreamingSession session, {
    required String method,
    String? rangeHeader,
  }) async {
    Future<HttpClientResponse> doOpen(
      String url, {
      required bool followRedirects,
    }) async {
      final upstreamClient = _getUpstreamClient();
      final req = await upstreamClient.openUrl(method, Uri.parse(url));
      req.followRedirects = followRedirects;
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        req.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      }
      return req.close();
    }

    if (!session.isDebridStream) {
      await _ensureNativeStreamActive(session);
      final res = await doOpen(session.nativeStreamUrl, followRedirects: false);
      if (res.statusCode >= 400) {
        await res.drain<void>().catchError((_) {});
        throw HttpException('Torrent engine returned HTTP ${res.statusCode}');
      }
      return res;
    }

    String? url = session.debridDirectUrl;
    Object? lastErr;

    if (url != null && url.isNotEmpty) {
      try {
        final res = await doOpen(url, followRedirects: true);
        if (res.statusCode < 400) {
          return res;
        }
        await res.drain<void>().catchError((_) {});
        lastErr = 'HTTP ${res.statusCode}';
      } catch (e) {
        lastErr = e;
      }
    }

    // Direct URL missing or expired: try re-resolving once through Debrid
    final settings = ServerSettingsService.instance;
    if (settings.hasConfiguredDebrid) {
      try {
        final resolved = await debridService.resolveAudioFile(
          provider: settings.debridProvider,
          apiKey: settings.activeDebridApiKey,
          magnetOrInfoHash: session.magnetUri,
          filePath: session.filePath,
          fileIndex: session.fileIndex,
        );
        session.debridDirectUrl = resolved.directUrl;
        if (session.fileSize <= 0 && resolved.fileSize > 0) {
          session.fileSize = resolved.fileSize;
        }
        final retryRes = await doOpen(
          resolved.directUrl,
          followRedirects: true,
        );
        if (retryRes.statusCode < 400) {
          return retryRes;
        }
        await retryRes.drain<void>().catchError((_) {});
        lastErr = 'HTTP ${retryRes.statusCode}';
      } catch (e) {
        lastErr = e;
      }
    }

    // If fallback to P2P torrent is enabled, switch this session to libtorrent
    if (settings.fallbackToTorrentOnDebridFailure) {
      _log(
        'Debrid upstream unreachable ($lastErr); falling back to P2P torrent...',
      );
      session.isDebridStream = false;
      await _ensureNativeStreamActive(session);
      final fallbackRes = await doOpen(
        session.nativeStreamUrl,
        followRedirects: false,
      );
      if (fallbackRes.statusCode >= 400) {
        await fallbackRes.drain<void>().catchError((_) {});
        throw HttpException(
          'Torrent fallback returned HTTP ${fallbackRes.statusCode}',
        );
      }
      return fallbackRes;
    }

    final provider = DebridProvider.fromId(session.debridProvider);
    final errMsg =
        'Debrid stream unreachable: ${lastErr ?? "unknown error"}. Enable "Try Torrenting if Debrid Fails" in Settings to fall back to P2P torrenting.';
    throw DebridException(
      errMsg,
      provider: provider.isConfiguredProvider ? provider : null,
    );
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

  static _RangeParseResult? _parseRangeHeader(
    String? rangeHeader,
    int fileSize,
  ) {
    if (fileSize <= 0) return null;
    if (rangeHeader == null || rangeHeader.trim().isEmpty) {
      return _RangeParseResult(start: 0, end: fileSize - 1, isPartial: false);
    }

    final trimmed = rangeHeader.trim();
    if (!trimmed.toLowerCase().startsWith('bytes=')) {
      return const _RangeParseResult(unsatisfiable: true);
    }

    final spec = trimmed.substring(6).trim();
    // Multi-part ranges fall back or take single range check
    if (spec.contains(',')) {
      return null;
    }

    final dashIdx = spec.indexOf('-');
    if (dashIdx < 0) {
      return const _RangeParseResult(unsatisfiable: true);
    }

    final startPart = spec.substring(0, dashIdx).trim();
    final endPart = spec.substring(dashIdx + 1).trim();

    if (startPart.isEmpty) {
      // Suffix range: bytes=-<suffixLen>
      final suffix = int.tryParse(endPart);
      if (suffix == null || suffix <= 0) {
        return const _RangeParseResult(unsatisfiable: true);
      }
      final start = math.max(0, fileSize - suffix);
      return _RangeParseResult(
        start: start,
        end: fileSize - 1,
        isPartial: true,
      );
    }

    final start = int.tryParse(startPart);
    if (start == null || start < 0 || start >= fileSize) {
      return const _RangeParseResult(unsatisfiable: true);
    }

    int end;
    if (endPart.isEmpty) {
      end = fileSize - 1;
    } else {
      final parsedEnd = int.tryParse(endPart);
      if (parsedEnd == null || parsedEnd < start) {
        return const _RangeParseResult(unsatisfiable: true);
      }
      end = math.min(parsedEnd, fileSize - 1);
    }

    return _RangeParseResult(start: start, end: end, isPartial: true);
  }

  /// Converts suffix ranges like `bytes=-500` into explicit `bytes=start-end`
  /// when fileSize is known, ensuring consistent handling across native bridges.
  static String _normalizeRangeHeader(String rangeHeader, int fileSize) {
    if (fileSize <= 0) return rangeHeader;
    final match = RegExp(
      r'^\s*bytes\s*=\s*-(\d+)\s*$',
      caseSensitive: false,
    ).firstMatch(rangeHeader);
    if (match == null) return rangeHeader;
    final suffixLen = int.tryParse(match.group(1) ?? '');
    if (suffixLen == null || suffixLen <= 0) return rangeHeader;
    final start = (fileSize - suffixLen).clamp(0, fileSize - 1);
    final end = fileSize - 1;
    return 'bytes=$start-$end';
  }

  Future<void> _sendJson(
    HttpResponse res,
    int statusCode,
    Map<String, dynamic> data,
  ) async {
    final encoded = utf8.encode(jsonEncode(data));
    res.statusCode = statusCode;
    res.headers.contentType = ContentType.json;
    res.contentLength = encoded.length;
    res.add(encoded);
    await res.close();
  }
}

class _RangeParseResult {
  final int start;
  final int end;
  final bool isPartial;
  final bool unsatisfiable;

  const _RangeParseResult({
    this.start = 0,
    this.end = -1,
    this.isPartial = false,
    this.unsatisfiable = false,
  });
}
