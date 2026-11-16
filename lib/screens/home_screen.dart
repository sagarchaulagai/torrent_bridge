import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';

import '../models/debrid_models.dart';
import '../models/streaming_models.dart';
import '../services/android_foreground_service.dart';
import '../services/debrid_service.dart';
import '../services/http_streaming_server.dart';
import '../services/server_settings_service.dart';
import '../services/torrent_engine_service.dart';

const String kDefaultTestInfoHash = '2a72c612335bd7cc5221b9c20838a9a349cf3821';

class HomeScreen extends StatefulWidget {
  final DebridService? debridService;

  const HomeScreen({super.key, this.debridService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _server = HttpStreamingServer.instance;
  final _engine = TorrentEngineService.instance;
  final _settings = ServerSettingsService.instance;

  final _magnetCtrl = TextEditingController(text: kDefaultTestInfoHash);
  final _filePathCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '8080');

  late final TabController _tabController;
  int? _selectedTorrentId;
  bool _isInspectingTorrent = false;
  String? _torrentError;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _server.addListener(_onChanged);
    _engine.addListener(_onChanged);
    _settings.addListener(_onChanged);
    _portCtrl.text = _settings.serverPort.toString();
    if ((_settings.keepServerRunning || _settings.autoStartServer) &&
        !_server.isRunning &&
        !_server.isStarting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_server.isRunning && !_server.isStarting) {
          _startServer();
        }
      });
    }
  }

  void _onChanged() {
    if (!mounted) return;
    if (_selectedTorrentId == null && _engine.torrents.isNotEmpty) {
      _selectedTorrentId = _engine.torrents.keys.first;
    } else if (_selectedTorrentId != null &&
        !_engine.torrents.containsKey(_selectedTorrentId)) {
      _selectedTorrentId = _engine.torrents.keys.firstOrNull;
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _lifecycleState = state);
    if (state == AppLifecycleState.paused && _server.isRunning) {
      AndroidForegroundService.instance.updateNotification(
        title: 'Torrent Bridge (${_server.localIp}:${_server.port})',
        content:
            'Running in background • ${_server.activeSessions.length} active stream(s)',
      );
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_server.ensureRunningIfEnabled());
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _server.removeListener(_onChanged);
    _engine.removeListener(_onChanged);
    _settings.removeListener(_onChanged);
    _magnetCtrl.dispose();
    _filePathCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  // ─── Actions ────────────────────────────────────────────────────────────────

  Future<void> _startServer() async {
    final port = _settings.serverPort;
    try {
      await _server.startServer(port: port);
      if (_server.portFallbackUsed) {
        _showSnack(
          'Port $port was busy — server started on ${_server.localIp}:${_server.port}',
        );
      } else {
        _showSnack('Server started on ${_server.localIp}:${_server.port}');
      }
    } catch (e) {
      _showSnack('Failed to start server: $e', error: true);
    }
  }

  Future<void> _stopServer() async {
    await _settings.setKeepServerRunning(false);
    await _server.stopServer(disposeTorrents: false);
    _showSnack('Server stopped.');
  }

  Future<void> _inspectTorrent() async {
    final input = _magnetCtrl.text.trim();
    if (input.isEmpty) return;
    setState(() {
      _isInspectingTorrent = true;
      _torrentError = null;
    });
    try {
      if (!_server.isRunning) {
        await _server.startServer(port: _settings.serverPort);
      }
      final tid = await _engine.addOrGetTorrent(input, streamOnly: true);
      setState(() => _selectedTorrentId = tid);
      await _engine.waitForMetadata(tid);
    } catch (e) {
      setState(() => _torrentError = e.toString());
    } finally {
      if (mounted) setState(() => _isInspectingTorrent = false);
    }
  }

  Future<void> _exposeFileEndpoint(int torrentId, AudioFileEntry file) async {
    try {
      final magnet =
          _engine.getMagnetForTorrent(torrentId) ?? _magnetCtrl.text.trim();
      final session = await _server.createOrGetStreamSession(
        magnetOrInfoHash: magnet,
        filePath: file.path,
        fileIndex: file.index,
      );
      final host = _server.localIp != '127.0.0.1' ? _server.localIp : '127.0.0.1';
      final url = session.buildStreamUrl(host, _server.port);
      final localUrl = session.buildStreamUrl('127.0.0.1', _server.port);
      Clipboard.setData(ClipboardData(text: url));
      _showSnack(
        host == '127.0.0.1'
            ? 'HTTP Stream URL copied ($localUrl)'
            : 'LAN URL copied ($host:${_server.port}) • Local: 127.0.0.1:${_server.port}',
      );
    } catch (e) {
      _showSnack('Failed to expose stream: $e', error: true);
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnack('$label copied');
  }

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? Colors.redAccent : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _confirmClearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Audio Cache?'),
        content: Text(
          'This will remove all ${_settings.cachedBytesFormatted} of downloaded audio files from disk. '
          'Active streams will be protected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear Cache'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final activeHashes = _server.activeSessions.map((s) => s.infoHash).toSet();
      final freed = await _settings.clearCache(activeInfoHashes: activeHashes);
      _showSnack('Cache cleared: freed ${formatBytes(freed)}');
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final running = _server.isRunning;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text(
          'Torrent Bridge',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        actions: [
          _StatusPill(running: running),
          const SizedBox(width: 12),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: Badge(
                isLabelVisible: running,
                child: const Icon(Icons.dns_rounded),
              ),
              text: 'Server',
            ),
            Tab(
              icon: Badge(
                isLabelVisible: _engine.torrents.isNotEmpty,
                label: Text('${_engine.torrents.length}'),
                child: const Icon(Icons.folder_open_rounded),
              ),
              text: 'Torrents',
            ),
            Tab(
              icon: Badge(
                isLabelVisible: _settings.cacheUsageRatio > 0.8,
                backgroundColor: Colors.amberAccent,
                child: const Icon(Icons.tune_rounded),
              ),
              text: 'Settings',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ServerTab(
            server: _server,
            engine: _engine,
            settings: _settings,
            lifecycleState: _lifecycleState,
            onStart: _startServer,
            onStop: _stopServer,
            onCopy: _copyToClipboard,
            onNavigateSettings: () => _tabController.animateTo(2),
          ),
          _TorrentTab(
            engine: _engine,
            server: _server,
            magnetCtrl: _magnetCtrl,
            filePathCtrl: _filePathCtrl,
            selectedTorrentId: _selectedTorrentId,
            isInspecting: _isInspectingTorrent,
            torrentError: _torrentError,
            onSelectTorrent: (id) => setState(() => _selectedTorrentId = id),
            onInspect: _inspectTorrent,
            onExposeEndpoint: _exposeFileEndpoint,
          ),
          _SettingsTab(
            settings: _settings,
            debridService: widget.debridService ?? DebridService.instance,
            portCtrl: _portCtrl,
            serverRunning: _server.isRunning,
            activeServerPort: _server.port,
            onRestartServer: () async {
              await _stopServer();
              await _startServer();
            },
            onClearCache: _confirmClearCache,
            onRefreshCache: () async {
              await _settings.refreshCacheUsage();
              _showSnack('Cache usage: ${_settings.cachedBytesFormatted}');
            },
            onShowMessage: _showSnack,
          ),
        ],
      ),
    );
  }
}

// ─── Status Pill ─────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final bool running;
  const _StatusPill({required this.running});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: running
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: running
              ? Colors.green.withValues(alpha: 0.6)
              : Colors.grey.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: running ? Colors.greenAccent : Colors.grey,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            running ? 'ON' : 'OFF',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: running ? Colors.greenAccent : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAB 1 — SERVER
// ═══════════════════════════════════════════════════════════════════════════════

class _ServerTab extends StatelessWidget {
  final HttpStreamingServer server;
  final TorrentEngineService engine;
  final ServerSettingsService settings;
  final AppLifecycleState lifecycleState;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final void Function(String, String) onCopy;
  final VoidCallback onNavigateSettings;

  const _ServerTab({
    required this.server,
    required this.engine,
    required this.settings,
    required this.lifecycleState,
    required this.onStart,
    required this.onStop,
    required this.onCopy,
    required this.onNavigateSettings,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = server.isRunning;
    final sessions = server.activeSessions;
    final clients = server.connectedClients;
    final logs = server.activityLogs;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Big status hero ──────────────────────────────────────────────────
        _HeroServerCard(
          running: running,
          isStarting: server.isStarting,
          ip: server.localIp,
          port: running ? server.port : settings.serverPort,
          onStart: onStart,
          onStop: onStop,
          onCopy: onCopy,
          lanUrl: server.lanBaseUrl,
          loopbackUrl: server.loopbackBaseUrl,
          libtorrentVersion: engine.libraryVersion,
        ),
        const SizedBox(height: 14),

        // ── Stats row ────────────────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.people_alt_outlined,
                label: 'Clients',
                value: '${server.connectedClientsCount}',
                color: Colors.cyanAccent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                icon: Icons.graphic_eq_rounded,
                label: 'Streams',
                value: '${sessions.length}',
                color: Colors.purpleAccent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: onNavigateSettings,
                borderRadius: BorderRadius.circular(14),
                child: _StatCard(
                  icon: Icons.storage_rounded,
                  label: 'Cache Limit',
                  value: settings.maxCacheSizeFormatted,
                  color: Colors.amberAccent,
                  subtitle: '${settings.cachedBytesFormatted} used',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                icon: Icons.shield_outlined,
                label: 'Service',
                value: AndroidForegroundService.instance.isRunning
                    ? 'Active'
                    : 'Idle',
                color: AndroidForegroundService.instance.isRunning
                    ? Colors.tealAccent
                    : Colors.grey,
              ),
            ),
          ],
        ),

        // ── Active sessions ──────────────────────────────────────────────────
        if (sessions.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel(
            icon: Icons.stream_rounded,
            label: 'Active Streams (${sessions.length})',
          ),
          const SizedBox(height: 8),
          ...sessions.map(
            (s) => _SessionCard(
              session: s,
              port: server.port,
              ip: server.localIp,
              onCopy: (url) => onCopy(url, 'Stream URL'),
              onStop: () => server.stopSession(s.sessionId),
            ),
          ),
        ],

        // ── Connected clients ────────────────────────────────────────────────
        if (clients.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel(
            icon: Icons.sync_alt_rounded,
            label: 'Connected Clients (${clients.length})',
          ),
          const SizedBox(height: 8),
          ...clients.map(
            (c) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${c.remoteAddress}  •  ${c.method}  •  ${formatBytes(c.bytesTransferred)}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],

        // ── Activity log ─────────────────────────────────────────────────────
        const SizedBox(height: 20),
        _SectionLabel(
          icon: Icons.terminal_rounded,
          label: 'Activity Log (${logs.length})',
          trailing: logs.isNotEmpty
              ? Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                )
              : null,
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 180),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: logs.isEmpty
              ? Text(
                  'No events yet. Start the server to see activity.',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: logs.length,
                  itemBuilder: (context, i) => Text(
                    logs[i],
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
        ),

        if (server.lastError != null) ...[
          const SizedBox(height: 10),
          _ErrorBanner(message: 'Server: ${server.lastError}'),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _HeroServerCard extends StatelessWidget {
  final bool running;
  final bool isStarting;
  final String ip;
  final int port;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final void Function(String, String) onCopy;
  final String lanUrl;
  final String loopbackUrl;
  final String libtorrentVersion;

  const _HeroServerCard({
    required this.running,
    required this.isStarting,
    required this.ip,
    required this.port,
    required this.onStart,
    required this.onStop,
    required this.onCopy,
    required this.lanUrl,
    required this.loopbackUrl,
    required this.libtorrentVersion,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: running
              ? Colors.green.withValues(alpha: 0.5)
              : cs.outlineVariant.withValues(alpha: 0.5),
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: running
                        ? Colors.green.withValues(alpha: 0.15)
                        : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    running ? Icons.wifi_tethering_rounded : Icons.dns_outlined,
                    color: running ? Colors.greenAccent : cs.onSurfaceVariant,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        running ? 'Server is running' : 'Server is stopped',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        running ? '$ip:$port' : 'Port $port • Tap below to start',
                        style: TextStyle(
                          fontSize: 13,
                          color: running ? cs.primary : cs.onSurfaceVariant,
                          fontFamily: running ? 'monospace' : null,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'lt $libtorrentVersion',
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            Center(
              child: Column(
                children: [
                  Material(
                    color: running
                        ? Colors.redAccent.withValues(alpha: 0.14)
                        : cs.primary,
                    shape: const CircleBorder(),
                    elevation: running ? 0 : 4,
                    shadowColor: cs.primary.withValues(alpha: 0.45),
                    child: InkWell(
                      onTap: isStarting ? null : (running ? onStop : onStart),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: running
                              ? Border.all(
                                  color: Colors.redAccent.withValues(alpha: 0.7),
                                  width: 2,
                                )
                              : null,
                        ),
                        child: Center(
                          child: isStarting
                              ? SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: cs.onPrimary,
                                  ),
                                )
                              : Icon(
                                  running
                                      ? Icons.stop_rounded
                                      : Icons.power_settings_new_rounded,
                                  size: 48,
                                  color: running ? Colors.redAccent : cs.onPrimary,
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    running
                        ? 'Stop Server'
                        : (isStarting ? 'Starting…' : 'Start Server'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: running ? Colors.redAccent : cs.primary,
                        ),
                  ),
                ],
              ),
            ),

            if (running) ...[
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 14),
              _UrlCopyRow(
                label: 'LAN',
                url: lanUrl,
                onCopy: () => onCopy(lanUrl, 'LAN URL'),
              ),
              const SizedBox(height: 8),
              _UrlCopyRow(
                label: 'LOCAL',
                url: loopbackUrl,
                onCopy: () => onCopy(loopbackUrl, 'Loopback URL'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UrlCopyRow extends StatelessWidget {
  final String label;
  final String url;
  final VoidCallback onCopy;

  const _UrlCopyRow({
    required this.label,
    required this.url,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: cs.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            url,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy_rounded, size: 16),
          onPressed: onCopy,
          tooltip: 'Copy',
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final String? subtitle;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 1),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 9,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final StreamingSession session;
  final int port;
  final String ip;
  final void Function(String) onCopy;
  final VoidCallback onStop;

  const _SessionCard({
    required this.session,
    required this.port,
    required this.ip,
    required this.onCopy,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = session;
    final native = s.latestNativeInfo;
    final speed = formatSpeed(native?.downloadRate ?? 0);
    final peers = native?.activePeers ?? 0;
    final lanUrl = s.buildStreamUrl(ip, port);
    final isReady = native?.isReady ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: s.isPrimary
              ? Colors.greenAccent.withValues(alpha: 0.6)
              : (isReady
                  ? Colors.greenAccent.withValues(alpha: 0.3)
                  : cs.outlineVariant.withValues(alpha: 0.4)),
          width: s.isPrimary ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.graphic_eq_rounded,
                size: 16,
                color: isReady ? Colors.greenAccent : Colors.amberAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.fileName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (s.isPrimary) ...[
                const _Chip(
                  label: 'PRIORITY',
                  color: Colors.greenAccent,
                ),
                const SizedBox(width: 6),
              ],
              if (s.isCached) ...[
                const _Chip(
                  label: 'CACHED',
                  color: Colors.cyanAccent,
                ),
                const SizedBox(width: 6),
              ],
              _Chip(
                label: isReady ? 'READY' : 'BUFFERING',
                color: isReady ? Colors.greenAccent : Colors.amberAccent,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '↓ $speed  •  $peers peers  •  ${s.mimeType}  •  ${formatBytes(s.bytesServed)} served',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  lanUrl,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 15),
                tooltip: 'Copy URL',
                onPressed: () => onCopy(lanUrl),
              ),
              IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: Colors.redAccent,
                ),
                tooltip: 'Stop session',
                onPressed: onStop,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAB 2 — TORRENTS
// ═══════════════════════════════════════════════════════════════════════════════

class _TorrentTab extends StatelessWidget {
  final TorrentEngineService engine;
  final HttpStreamingServer server;
  final TextEditingController magnetCtrl;
  final TextEditingController filePathCtrl;
  final int? selectedTorrentId;
  final bool isInspecting;
  final String? torrentError;
  final void Function(int) onSelectTorrent;
  final VoidCallback onInspect;
  final Future<void> Function(int, AudioFileEntry) onExposeEndpoint;

  const _TorrentTab({
    required this.engine,
    required this.server,
    required this.magnetCtrl,
    required this.filePathCtrl,
    required this.selectedTorrentId,
    required this.isInspecting,
    required this.torrentError,
    required this.onSelectTorrent,
    required this.onInspect,
    required this.onExposeEndpoint,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final torrents = engine.torrents;
    final activeTorrent = selectedTorrentId != null
        ? torrents[selectedTorrentId]
        : torrents.values.firstOrNull;
    final files = activeTorrent != null && activeTorrent.hasMetadata
        ? engine.getFiles(activeTorrent.id)
        : <AudioFileEntry>[];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.search_rounded, color: cs.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Load Torrent',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => magnetCtrl.text = kDefaultTestInfoHash,
                      child: const Text('Test Hash'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: magnetCtrl,
                  decoration: InputDecoration(
                    hintText: 'magnet:?xt=urn:btih:... or infohash',
                    prefixIcon: const Icon(Icons.link_rounded),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.content_paste_rounded),
                      tooltip: 'Paste',
                      onPressed: () async {
                        final d = await Clipboard.getData('text/plain');
                        if (d?.text != null) magnetCtrl.text = d!.text!.trim();
                      },
                    ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: filePathCtrl,
                  decoration: const InputDecoration(
                    hintText:
                        'File path or leave empty for first audio (optional)',
                    prefixIcon: Icon(Icons.audio_file_outlined),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isInspecting ? null : onInspect,
                    icon: isInspecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.travel_explore_rounded),
                    label: Text(isInspecting ? 'Loading…' : 'Load Torrent'),
                  ),
                ),
                if (torrentError != null) ...[
                  const SizedBox(height: 10),
                  _ErrorBanner(message: torrentError!),
                ],
              ],
            ),
          ),
        ),

        if (torrents.length > 1) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: torrents.values.map((t) {
              final sel = t.id == activeTorrent?.id;
              final isPrimary = t.id == engine.primaryTorrentId;
              return ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPrimary) ...[
                      const Icon(Icons.bolt, size: 14, color: Colors.amberAccent),
                      const SizedBox(width: 4),
                    ],
                    Text(t.name.isNotEmpty ? t.name : 'Torrent #${t.id}'),
                  ],
                ),
                selected: sel,
                onSelected: (_) => onSelectTorrent(t.id),
              );
            }).toList(),
          ),
        ],

        if (activeTorrent != null) ...[
          const SizedBox(height: 16),
          _TorrentDetailCard(
            torrent: activeTorrent,
            files: files,
            engine: engine,
            onExposeEndpoint: onExposeEndpoint,
          ),
        ] else if (torrents.isEmpty) ...[
          const SizedBox(height: 48),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  size: 56,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                ),
                const SizedBox(height: 14),
                Text(
                  'No torrents loaded yet',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15),
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter a magnet link or infohash above and tap Load.',
                  style: TextStyle(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _TorrentDetailCard extends StatelessWidget {
  final TorrentInfo torrent;
  final List<AudioFileEntry> files;
  final TorrentEngineService engine;
  final Future<void> Function(int, AudioFileEntry) onExposeEndpoint;

  const _TorrentDetailCard({
    required this.torrent,
    required this.files,
    required this.engine,
    required this.onExposeEndpoint,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = torrent;
    final pct = (t.progress * 100).toStringAsFixed(1);
    final infoHash = engine.getInfoHashForTorrent(t.id) ?? '';
    final isPrimary = t.id == engine.primaryTorrentId;
    final isPaused = t.isPaused;
    final audioFiles = files.where((f) => f.isAudioFile).toList();
    final otherFiles = files.where((f) => !f.isAudioFile).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isPrimary
                  ? Colors.greenAccent.withValues(alpha: 0.6)
                  : cs.outlineVariant.withValues(alpha: 0.3),
              width: isPrimary ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t.name.isEmpty ? 'Resolving metadata…' : t.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (isPaused)
                    TextButton.icon(
                      onPressed: () => engine.resumeTorrent(t.id),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('Resume'),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove',
                    onPressed: () => engine.removeTorrent(t.id),
                  ),
                ],
              ),
              if (infoHash.isNotEmpty)
                Text(
                  infoHash,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: t.hasMetadata ? t.progress : null,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (isPrimary)
                    const _Chip(
                      label: 'TOP PRIORITY',
                      color: Colors.greenAccent,
                    ),
                  _Chip(
                    label: t.state.label.toUpperCase(),
                    color: isPaused ? Colors.amberAccent : cs.primary,
                  ),
                  Text('$pct%', style: const TextStyle(fontSize: 12)),
                  Text(
                    '${formatBytes(t.totalDone)} / ${formatBytes(t.totalWanted)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    '↓ ${formatSpeed(t.downloadRate)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    '${t.numPeers} peers',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              if (t.errorMsg.isNotEmpty) ...[
                const SizedBox(height: 6),
                _ErrorBanner(message: t.errorMsg),
              ],
            ],
          ),
        ),

        if (!t.hasMetadata) ...[
          const SizedBox(height: 20),
          const Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Waiting for metadata from peers/DHT…',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 20),
          _SectionLabel(
            icon: Icons.audiotrack_rounded,
            label: 'Audio Files (${audioFiles.length})',
          ),
          const SizedBox(height: 8),
          if (audioFiles.isEmpty)
            Text(
              'No audio files found in this torrent.',
              style: TextStyle(color: cs.onSurfaceVariant),
            )
          else
            ...audioFiles.map(
              (f) => _FileCard(
                file: f,
                torrentId: t.id,
                onExpose: onExposeEndpoint,
              ),
            ),
          if (otherFiles.isNotEmpty) ...[
            const SizedBox(height: 16),
            _SectionLabel(
              icon: Icons.insert_drive_file_outlined,
              label: 'Other Files (${otherFiles.length})',
            ),
            const SizedBox(height: 8),
            ...otherFiles.map(
              (f) => _FileCard(
                file: f,
                torrentId: t.id,
                onExpose: onExposeEndpoint,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _FileCard extends StatelessWidget {
  final AudioFileEntry file;
  final int torrentId;
  final Future<void> Function(int, AudioFileEntry) onExpose;

  const _FileCard({
    required this.file,
    required this.torrentId,
    required this.onExpose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = file;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: f.isAudioFile
              ? cs.primary.withValues(alpha: 0.35)
              : cs.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            f.isAudioFile
                ? Icons.audiotrack_rounded
                : Icons.insert_drive_file_outlined,
            color: f.isAudioFile ? cs.primary : cs.onSurfaceVariant,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${formatBytes(f.size)}  •  ${f.mimeType}',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (f.isAudioFile)
            IconButton(
              icon: const Icon(Icons.link_rounded),
              tooltip: 'Copy Stream URL',
              onPressed: () => onExpose(torrentId, f),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAB 3 — SETTINGS & CACHE
// ═══════════════════════════════════════════════════════════════════════════════

class _SettingsTab extends StatelessWidget {
  final ServerSettingsService settings;
  final DebridService debridService;
  final TextEditingController portCtrl;
  final bool serverRunning;
  final int activeServerPort;
  final Future<void> Function() onRestartServer;
  final VoidCallback onClearCache;
  final VoidCallback onRefreshCache;
  final void Function(String message) onShowMessage;

  const _SettingsTab({
    required this.settings,
    required this.debridService,
    required this.portCtrl,
    required this.serverRunning,
    required this.activeServerPort,
    required this.onRestartServer,
    required this.onClearCache,
    required this.onRefreshCache,
    required this.onShowMessage,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final usageRatio = settings.cacheUsageRatio;
    final usagePct = (usageRatio * 100).toStringAsFixed(1);

    Color gaugeColor = Colors.greenAccent;
    if (usageRatio >= 0.9) {
      gaugeColor = Colors.redAccent;
    } else if (usageRatio >= 0.75) {
      gaugeColor = Colors.amberAccent;
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── 0. Debrid Service Integration ───────────────────────────────────
        _DebridSettingsCard(
          settings: settings,
          debridService: debridService,
          onShowMessage: onShowMessage,
        ),

        const SizedBox(height: 16),

        // ── 1. Priority Section (Mero Audiobook Mode) ────────────────────────
        _SettingsCard(
          icon: Icons.bolt_rounded,
          iconColor: Colors.amberAccent,
          title: 'Intelligent Stream Priority',
          subtitle:
              'Optimized for single-client audiobook players (Mero Audiobook)',
          child: Column(
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Prioritize Newest Torrent',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                subtitle: Text(
                  'Always allocates maximum peer connections and bandwidth to the most recent chapter requested by Mero Audiobook.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                value: settings.prioritizeNewest,
                onChanged: (v) => settings.setPrioritizeNewest(v),
              ),
              const Divider(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Auto-Pause Background Torrents',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                subtitle: Text(
                  'Pauses older torrents when a new stream starts to stop background data and battery drain.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                value: settings.autoPauseBackgroundTorrents,
                onChanged: (v) => settings.setAutoPauseBackground(v),
              ),
              const Divider(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Fast Audio Preload (Head & Tail)',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                subtitle: Text(
                  'Pre-buffers ID3 tags and audio header for near-instant duration discovery and playback start.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                value: settings.fastAudioPreload,
                onChanged: (v) => settings.setFastAudioPreload(v),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ── 2. Cache Quota & Storage Section ─────────────────────────────────
        _SettingsCard(
          icon: Icons.storage_rounded,
          iconColor: Colors.cyanAccent,
          title: 'Audio & Torrent Cache',
          subtitle:
              'Cached audio pieces stay on disk for instant re-play without network re-downloading.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Gauge
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${settings.cachedBytesFormatted} used',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    'Limit: ${settings.maxCacheSizeFormatted} ($usagePct%)',
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: gaugeColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: usageRatio,
                  minHeight: 10,
                  backgroundColor: cs.surfaceContainerHighest,
                  color: gaugeColor,
                ),
              ),
              const SizedBox(height: 16),

              // Preset chips
              Text(
                'Cache Size Limit Presets',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CachePresetChip(
                    label: '500 MB',
                    bytes: 500 * 1024 * 1024,
                    selected: settings.maxCacheSizeBytes == 500 * 1024 * 1024,
                    onSelected: (b) => settings.setMaxCacheSizeBytes(b),
                  ),
                  _CachePresetChip(
                    label: '1 GB',
                    bytes: 1024 * 1024 * 1024,
                    selected: settings.maxCacheSizeBytes == 1024 * 1024 * 1024,
                    onSelected: (b) => settings.setMaxCacheSizeBytes(b),
                  ),
                  _CachePresetChip(
                    label: '2 GB (Default)',
                    bytes: 2 * 1024 * 1024 * 1024,
                    selected:
                        settings.maxCacheSizeBytes == 2 * 1024 * 1024 * 1024,
                    onSelected: (b) => settings.setMaxCacheSizeBytes(b),
                  ),
                  _CachePresetChip(
                    label: '4 GB',
                    bytes: 4 * 1024 * 1024 * 1024,
                    selected:
                        settings.maxCacheSizeBytes == 4 * 1024 * 1024 * 1024,
                    onSelected: (b) => settings.setMaxCacheSizeBytes(b),
                  ),
                  _CachePresetChip(
                    label: '8 GB',
                    bytes: 8 * 1024 * 1024 * 1024,
                    selected:
                        settings.maxCacheSizeBytes == 8 * 1024 * 1024 * 1024,
                    onSelected: (b) => settings.setMaxCacheSizeBytes(b),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Slider for custom size
              Row(
                children: [
                  const Text('Custom:', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      min: 256.0,
                      max: 8192.0,
                      divisions: 31,
                      label:
                          '${(settings.maxCacheSizeBytes / (1024 * 1024)).round()} MB',
                      value: (settings.maxCacheSizeBytes / (1024 * 1024))
                          .clamp(256.0, 8192.0),
                      onChanged: (v) {
                        settings.setMaxCacheSizeBytes(v.round() * 1024 * 1024);
                      },
                    ),
                  ),
                ],
              ),

              const Divider(height: 20),

              // Cache actions & path
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onClearCache,
                      icon: const Icon(
                        Icons.delete_sweep_rounded,
                        color: Colors.redAccent,
                        size: 18,
                      ),
                      label: const Text(
                        'Clear Cache',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.outlined(
                    tooltip: 'Refresh Cache Calculation',
                    onPressed: onRefreshCache,
                    icon: settings.isCalculatingCache
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Disk location: ${settings.cachePath}',
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ── 3. Server Config ─────────────────────────────────────────────────
        _SettingsCard(
          icon: Icons.router_rounded,
          iconColor: cs.primary,
          title: 'Server Configuration',
          subtitle: 'HTTP Server bind and background execution settings',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Default HTTP Port',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          'Port used when starting the HTTP audio stream server.',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      controller: portCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textAlign: TextAlign.center,
                      onChanged: (v) {
                        final p = int.tryParse(v.trim());
                        if (p != null && p >= 1 && p <= 65535) {
                          settings.setServerPort(p);
                        }
                      },
                      onSubmitted: (v) {
                        final p = int.tryParse(v.trim());
                        if (p != null && p >= 1 && p <= 65535) {
                          settings.setServerPort(p);
                        }
                      },
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              if (serverRunning && activeServerPort != settings.serverPort) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: onRestartServer,
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: Text(
                      'Server is running on port $activeServerPort • Tap to restart on port ${settings.serverPort}',
                    ),
                  ),
                ),
              ],
              const Divider(height: 20),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Auto-Start Server on Launch',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                subtitle: Text(
                  'Automatically starts the HTTP streaming server when Torrent Bridge opens.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                value: settings.autoStartServer,
                onChanged: (v) => settings.setAutoStartServer(v),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),
      ],
    );
  }
}

class _DebridSettingsCard extends StatefulWidget {
  final ServerSettingsService settings;
  final DebridService debridService;
  final void Function(String message) onShowMessage;

  const _DebridSettingsCard({
    required this.settings,
    required this.debridService,
    required this.onShowMessage,
  });

  @override
  State<_DebridSettingsCard> createState() => _DebridSettingsCardState();
}

class _DebridSettingsCardState extends State<_DebridSettingsCard> {
  late final TextEditingController _apiKeyCtrl;
  late DebridProvider _loadedProvider;
  bool _obscureKey = true;
  bool _isValidating = false;
  DebridValidationResult? _validationResult;

  @override
  void initState() {
    super.initState();
    _loadedProvider = widget.settings.debridProvider;
    _apiKeyCtrl = TextEditingController(
      text: widget.settings.debridApiKeyFor(_loadedProvider),
    );
  }

  @override
  void didUpdateWidget(covariant _DebridSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings.debridProvider != _loadedProvider) {
      _syncControllerForProvider(widget.settings.debridProvider);
    }
  }

  void _syncControllerForProvider(DebridProvider provider) {
    _loadedProvider = provider;
    _apiKeyCtrl.text = widget.settings.debridApiKeyFor(provider);
    _validationResult = null;
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _validateAndSaveKey() async {
    final provider = widget.settings.debridProvider;
    if (provider == DebridProvider.none) return;

    final rawKey = _apiKeyCtrl.text.trim();
    if (rawKey.isEmpty) {
      await widget.settings.clearDebridApiKey(provider);
      setState(() {
        _validationResult = DebridValidationResult(
          provider: provider,
          isValid: false,
          message: 'Please enter an API key.',
        );
      });
      return;
    }

    setState(() {
      _isValidating = true;
      _validationResult = null;
    });

    try {
      final result =
          await widget.debridService.validateApiKey(provider, rawKey);
      if (mounted) {
        setState(() {
          _validationResult = result;
        });
      }
      await widget.settings.setDebridApiKey(
        provider,
        rawKey,
        validated: result.isValid,
        accountLabel: result.username,
      );

      if (!mounted) return;
      widget.onShowMessage(
        result.isValid
            ? '${provider.displayName} API key verified!'
            : '${provider.displayName}: ${result.message}',
      );
    } finally {
      if (mounted) {
        setState(() => _isValidating = false);
      }
    }
  }

  Future<void> _clearKey() async {
    final provider = widget.settings.debridProvider;
    _apiKeyCtrl.clear();
    setState(() {
      _validationResult = null;
    });
    await widget.settings.clearDebridApiKey(provider);
    if (mounted) {
      widget.onShowMessage('${provider.displayName} API key cleared.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final provider = widget.settings.debridProvider;
    final savedKey = widget.settings.debridApiKeyFor(provider);
    final isValidatedSaved = widget.settings.isDebridKeyValidatedFor(provider);
    final savedAccount = widget.settings.debridAccountLabelFor(provider);
    final hasUnsavedEdits = _apiKeyCtrl.text.trim() != savedKey.trim();

    return _SettingsCard(
      icon: Icons.cloud_sync_rounded,
      iconColor: cs.primary,
      title: 'Debrid Service',
      subtitle:
          'Stream audiobooks through a Debrid cloud provider using your API key.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<DebridProvider>(
            key: const Key('debrid_provider_dropdown'),
            initialValue: provider,
            decoration: const InputDecoration(
              labelText: 'Debrid Provider',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: DebridProvider.selectableProviders
                .map(
                  (p) => DropdownMenuItem<DebridProvider>(
                    value: p,
                    child: Text(p.displayName),
                  ),
                )
                .toList(),
            onChanged: _isValidating
                ? null
                : (selected) async {
                    if (selected == null) return;
                    await widget.settings.setDebridProvider(selected);
                    if (mounted) {
                      setState(() {
                        _syncControllerForProvider(selected);
                      });
                    }
                  },
          ),
          if (provider.isConfiguredProvider) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('debrid_api_key_field'),
              controller: _apiKeyCtrl,
              obscureText: _obscureKey,
              onChanged: (_) => setState(() {
                _validationResult = null;
              }),
              onSubmitted: (_) => _validateAndSaveKey(),
              decoration: InputDecoration(
                labelText: '${provider.displayName} API Key',
                hintText: 'Paste API key (${provider.keyPortalHint})',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _obscureKey ? 'Show API key' : 'Hide API key',
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        size: 18,
                      ),
                      onPressed: () {
                        setState(() => _obscureKey = !_obscureKey);
                      },
                    ),
                    if (_apiKeyCtrl.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Remove key',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: _isValidating ? null : _clearKey,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('debrid_validate_save_button'),
                    onPressed: _isValidating ? null : _validateAndSaveKey,
                    icon: _isValidating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user_rounded, size: 18),
                    label: Text(
                      _isValidating ? 'Validating...' : 'Validate & Save Key',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildStatusBadge(
              cs: cs,
              provider: provider,
              savedKey: savedKey,
              isValidatedSaved: isValidatedSaved,
              savedAccount: savedAccount,
              hasUnsavedEdits: hasUnsavedEdits,
            ),
          ],
          const Divider(height: 22),
          SwitchListTile.adaptive(
            key: const Key('debrid_fallback_switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Try Torrenting if Debrid Fails',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Text(
              'Default is OFF. When OFF and Debrid fails or is still unavailable, an error message is shown instead of falling back to P2P torrenting.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            value: widget.settings.fallbackToTorrentOnDebridFailure,
            onChanged: (v) =>
                widget.settings.setFallbackToTorrentOnDebridFailure(v),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge({
    required ColorScheme cs,
    required DebridProvider provider,
    required String savedKey,
    required bool isValidatedSaved,
    required String? savedAccount,
    required bool hasUnsavedEdits,
  }) {
    if (hasUnsavedEdits && _validationResult == null) {
      return Text(
        'Unsaved changes — tap "Validate & Save Key" to verify.',
        style: TextStyle(fontSize: 11, color: cs.primary),
      );
    }

    final liveResult = _validationResult;
    if (liveResult != null && liveResult.provider == provider) {
      return _ValidationBanner(
        isValid: liveResult.isValid,
        message: liveResult.message,
      );
    }

    if (savedKey.isNotEmpty) {
      if (isValidatedSaved) {
        final acct =
            savedAccount != null && savedAccount.isNotEmpty ? ' ($savedAccount)' : '';
        return _ValidationBanner(
          isValid: true,
          message: '${provider.displayName} API key is valid$acct.',
        );
      }
      return _ValidationBanner(
        isValid: false,
        message:
            'Saved ${provider.displayName} key is not verified or failed validation.',
      );
    }

    return Text(
      'Enter your ${provider.displayName} API key and tap Validate & Save Key.',
      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  final bool isValid;
  final String message;

  const _ValidationBanner({
    required this.isValid,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final color = isValid ? Colors.greenAccent : Colors.redAccent;
    return Container(
      key: Key(isValid ? 'debrid_valid_badge' : 'debrid_invalid_badge'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(
            isValid ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget child;

  const _SettingsCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const Divider(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}

class _CachePresetChip extends StatelessWidget {
  final String label;
  final int bytes;
  final bool selected;
  final void Function(int) onSelected;

  const _CachePresetChip({
    required this.label,
    required this.bytes,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(bytes),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SHARED HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;

  const _SectionLabel({required this.icon, required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }
}
