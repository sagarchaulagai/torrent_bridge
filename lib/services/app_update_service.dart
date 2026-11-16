import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Metadata parsed from the remote `update.json` manifest.
class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final bool hasUpdate;
  final DateTime checkedAt;

  AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.hasUpdate,
    DateTime? checkedAt,
  }) : checkedAt = checkedAt ?? DateTime.now();
}

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,
  permissionRequired,
  error,
}

/// Checks for sideloaded Android APK updates via GitHub `update.json`,
/// downloads the release APK with progress, and launches the Android
/// package installer via [FileProvider].
class AppUpdateService extends ChangeNotifier {
  static final AppUpdateService instance = AppUpdateService._();

  static const String kDefaultUpdateManifestUrl =
      'https://raw.githubusercontent.com/sagarchaulagai/torrent_bridge/refs/heads/main/update.json';
  static const String kFallbackAppVersion = '1.0.0+1';

  static const MethodChannel _channel = MethodChannel(
    'com.rehesagar.torrentbridge/app_updater',
  );

  AppUpdateService._([
    String? manifestUrl,
    HttpClient Function()? httpClientFactory,
    this._versionLoader,
    this._apkInstaller,
    this._downloadDirProvider,
  ])  : _manifestUrl = manifestUrl ?? kDefaultUpdateManifestUrl,
        _httpClientFactory = httpClientFactory ?? _defaultHttpClient;

  @visibleForTesting
  AppUpdateService.forTesting({
    String? manifestUrl,
    HttpClient Function()? httpClientFactory,
    Future<String> Function()? versionLoader,
    Future<String> Function(String apkPath)? apkInstaller,
    Future<Directory> Function()? downloadDirProvider,
  }) : this._(
          manifestUrl,
          httpClientFactory,
          versionLoader,
          apkInstaller,
          downloadDirProvider,
        );

  final String _manifestUrl;
  final HttpClient Function() _httpClientFactory;
  final Future<String> Function()? _versionLoader;
  final Future<String> Function(String apkPath)? _apkInstaller;
  final Future<Directory> Function()? _downloadDirProvider;

  AppUpdatePhase _phase = AppUpdatePhase.idle;
  AppUpdateInfo? _latestInfo;
  String? _currentVersionCache;
  double? _downloadProgress;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  String? _errorMessage;
  String? _statusMessage;

  AppUpdatePhase get phase => _phase;
  AppUpdateInfo? get latestInfo => _latestInfo;
  String get currentVersion => _currentVersionCache ?? kFallbackAppVersion;
  double? get downloadProgress => _downloadProgress;
  int get downloadedBytes => _downloadedBytes;
  int get totalBytes => _totalBytes;
  String? get errorMessage => _errorMessage;
  String? get statusMessage => _statusMessage;
  bool get hasAvailableUpdate => _latestInfo?.hasUpdate ?? false;
  bool get isBusy =>
      _phase == AppUpdatePhase.checking || _phase == AppUpdatePhase.downloading;

  static HttpClient _defaultHttpClient() {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
  }

  /// Resolves the currently installed app version (`versionName+versionCode`).
  Future<String> getCurrentVersion() async {
    if (_currentVersionCache != null && _versionLoader == null) {
      return _currentVersionCache!;
    }
    if (_versionLoader != null) {
      final loaded = await _versionLoader();
      _currentVersionCache = loaded;
      return loaded;
    }
    if (Platform.isAndroid) {
      try {
        final raw = await _channel.invokeMapMethod<String, dynamic>(
          'getAppVersion',
        );
        final full = raw?['fullVersion']?.toString().trim();
        if (full != null && full.isNotEmpty) {
          _currentVersionCache = full;
          return full;
        }
      } catch (e) {
        debugPrint('AppUpdateService.getCurrentVersion error: $e');
      }
    }
    _currentVersionCache = kFallbackAppVersion;
    return _currentVersionCache!;
  }

  /// Fetches remote `update.json` and checks whether a newer version is available.
  ///
  /// When [silent] is true (e.g. startup check), network failures leave state
  /// clean without displaying an error banner.
  Future<AppUpdateInfo?> checkForUpdate({bool silent = false}) async {
    if (_phase == AppUpdatePhase.downloading) return _latestInfo;

    _phase = AppUpdatePhase.checking;
    if (!silent) {
      _errorMessage = null;
      _statusMessage = 'Checking for updates...';
    }
    notifyListeners();

    final client = _httpClientFactory();
    try {
      final currentVer = await getCurrentVersion();
      final req = await client.getUrl(Uri.parse(_manifestUrl));
      req.followRedirects = true;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        throw HttpException(
          'Update server returned HTTP ${res.statusCode}',
          uri: Uri.parse(_manifestUrl),
        );
      }

      final body = await utf8.decoder.bind(res).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('Invalid update.json payload.');
      }

      final remoteVer = decoded['version']?.toString().trim() ?? '';
      final link = decoded['link']?.toString().trim() ?? '';
      if (remoteVer.isEmpty) {
        throw const FormatException('Missing "version" field in update.json.');
      }

      final isNewer = isRemoteVersionNewer(remoteVer, currentVer);
      if (isNewer && link.isEmpty) {
        throw const FormatException(
          'Update available in update.json, but "link" is missing.',
        );
      }

      final info = AppUpdateInfo(
        currentVersion: currentVer,
        latestVersion: remoteVer,
        downloadUrl: link,
        hasUpdate: isNewer,
      );
      _latestInfo = info;
      _errorMessage = null;
      if (isNewer) {
        _phase = AppUpdatePhase.available;
        _statusMessage =
            'Update available: v${info.latestVersion} (installed: v${info.currentVersion})';
      } else {
        _phase = AppUpdatePhase.upToDate;
        _statusMessage = 'You are on the latest version (v${info.currentVersion}).';
      }
      notifyListeners();
      return info;
    } catch (e) {
      debugPrint('AppUpdateService.checkForUpdate error: $e');
      if (silent && _latestInfo == null) {
        _phase = AppUpdatePhase.idle;
      } else {
        _phase = AppUpdatePhase.error;
        _errorMessage = 'Failed to check for updates: $e';
        _statusMessage = _errorMessage;
      }
      notifyListeners();
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the APK for [target] (or the latest discovered update) and triggers
  /// Android installation. Returns the downloaded APK file path on success.
  Future<String?> downloadAndInstallUpdate({AppUpdateInfo? target}) async {
    if (_phase == AppUpdatePhase.downloading) return null;

    var info = target ?? _latestInfo;
    if (info == null || !info.hasUpdate) {
      info = await checkForUpdate(silent: false);
    }
    if (info == null) return null;
    if (!info.hasUpdate) {
      _phase = AppUpdatePhase.upToDate;
      _statusMessage = 'Already running the latest version (v${info.currentVersion}).';
      notifyListeners();
      return null;
    }

    final downloadUri = Uri.tryParse(info.downloadUrl);
    if (downloadUri == null ||
        !downloadUri.hasScheme ||
        (downloadUri.scheme != 'http' && downloadUri.scheme != 'https')) {
      _phase = AppUpdatePhase.error;
      _errorMessage = 'Invalid APK download URL: "${info.downloadUrl}"';
      _statusMessage = _errorMessage;
      notifyListeners();
      return null;
    }

    _phase = AppUpdatePhase.downloading;
    _downloadProgress = 0.0;
    _downloadedBytes = 0;
    _totalBytes = 0;
    _errorMessage = null;
    _statusMessage = 'Downloading v${info.latestVersion}...';
    notifyListeners();

    final client = _httpClientFactory();
    IOSink? sink;
    File? tmpFile;

    try {
      final baseDir = await _resolveDownloadDirectory();
      final updatesDir = Directory(
        '${baseDir.path}${Platform.pathSeparator}updates',
      );
      if (!await updatesDir.exists()) {
        await updatesDir.create(recursive: true);
      }

      final safeVersion = info.latestVersion.replaceAll(RegExp(r'[^a-zA-Z0-9._+-]'), '_');
      final finalApk = File(
        '${updatesDir.path}${Platform.pathSeparator}torrent_bridge_$safeVersion.apk',
      );
      tmpFile = File('${finalApk.path}.part');
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }

      final req = await client.getUrl(downloadUri);
      req.followRedirects = true;
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw HttpException(
          'APK download failed (HTTP ${res.statusCode})',
          uri: downloadUri,
        );
      }

      final total = res.contentLength;
      _totalBytes = total > 0 ? total : 0;

      sink = tmpFile.openWrite();
      final headerPrefix = <int>[];
      var lastNotifyMs = 0;

      await for (final chunk in res) {
        if (chunk.isEmpty) continue;
        if (headerPrefix.length < 4) {
          for (final b in chunk) {
            headerPrefix.add(b);
            if (headerPrefix.length >= 4) break;
          }
        }
        sink.add(chunk);
        _downloadedBytes += chunk.length;

        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastNotifyMs >= 100 ||
            (_totalBytes > 0 && _downloadedBytes >= _totalBytes)) {
          lastNotifyMs = nowMs;
          _downloadProgress = _totalBytes > 0
              ? (_downloadedBytes / _totalBytes).clamp(0.0, 1.0)
              : null;
          if (_totalBytes > 0) {
            final pct = ((_downloadProgress ?? 0) * 100).toStringAsFixed(0);
            _statusMessage = 'Downloading v${info.latestVersion}... $pct%';
          } else {
            final mb = (_downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
            _statusMessage = 'Downloading v${info.latestVersion}... $mb MB';
          }
          notifyListeners();
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (_downloadedBytes <= 0 ||
          headerPrefix.length < 2 ||
          headerPrefix[0] != 0x50 ||
          headerPrefix[1] != 0x4B) {
        throw const FormatException(
          'Downloaded file is not a valid Android APK package.',
        );
      }

      if (await finalApk.exists()) {
        await finalApk.delete();
      }
      await tmpFile.rename(finalApk.path);
      tmpFile = null;

      _downloadProgress = 1.0;
      notifyListeners();

      final installOutcome = await _triggerInstall(finalApk.path);
      if (installOutcome == 'permission_requested') {
        _phase = AppUpdatePhase.permissionRequired;
        _statusMessage =
            'Enable "Install unknown apps" for Torrent Bridge, then the installer will continue.';
      } else {
        _phase = AppUpdatePhase.installing;
        _statusMessage =
            'Installer launched for v${info.latestVersion}. Confirm installation on your device.';
      }
      notifyListeners();
      return finalApk.path;
    } catch (e) {
      debugPrint('AppUpdateService.downloadAndInstallUpdate error: $e');
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (tmpFile != null && await tmpFile.exists()) {
          await tmpFile.delete();
        }
      } catch (_) {}
      _phase = AppUpdatePhase.error;
      _errorMessage = 'Update failed: $e';
      _statusMessage = _errorMessage;
      _downloadProgress = null;
      notifyListeners();
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Directory> _resolveDownloadDirectory() async {
    if (_downloadDirProvider != null) {
      return _downloadDirProvider();
    }
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<String> _triggerInstall(String apkPath) async {
    if (_apkInstaller != null) {
      return _apkInstaller(apkPath);
    }
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Automatic APK installation is only supported on Android.',
      );
    }
    final res = await _channel.invokeMethod<String>(
      'installApk',
      {'apkPath': apkPath},
    );
    return res ?? 'launched';
  }

  /// Returns `true` when [remoteVersion] is strictly newer than [currentVersion].
  static bool isRemoteVersionNewer(String remoteVersion, String currentVersion) {
    return compareVersions(remoteVersion, currentVersion) > 0;
  }

  /// Compares two version strings such as `"1.0.0+1"` and `"1.0.1+2"`.
  /// Returns positive if [a] > [b], negative if [a] < [b], or 0 if equal.
  static int compareVersions(String a, String b) {
    final pa = _ParsedVersion.parse(a);
    final pb = _ParsedVersion.parse(b);

    final maxLen =
        pa.parts.length > pb.parts.length ? pa.parts.length : pb.parts.length;
    for (var i = 0; i < maxLen; i++) {
      final av = i < pa.parts.length ? pa.parts[i] : 0;
      final bv = i < pb.parts.length ? pb.parts[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }

    if (pa.isPreRelease != pb.isPreRelease) {
      return pa.isPreRelease ? -1 : 1;
    }
    if (pa.preRelease != null && pb.preRelease != null) {
      final preCmp = pa.preRelease!.compareTo(pb.preRelease!);
      if (preCmp != 0) return preCmp;
    }

    final ab = pa.build ?? 0;
    final bb = pb.build ?? 0;
    return ab.compareTo(bb);
  }
}

class _ParsedVersion {
  final List<int> parts;
  final String? preRelease;
  final int? build;

  bool get isPreRelease => preRelease != null && preRelease!.isNotEmpty;

  const _ParsedVersion({
    required this.parts,
    this.preRelease,
    this.build,
  });

  factory _ParsedVersion.parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1).trim();
    }

    int? buildNum;
    final plusIdx = s.indexOf('+');
    if (plusIdx >= 0) {
      final buildStr = s.substring(plusIdx + 1).trim();
      buildNum = int.tryParse(buildStr);
      s = s.substring(0, plusIdx).trim();
    }

    String? preRel;
    final dashIdx = s.indexOf('-');
    if (dashIdx >= 0) {
      preRel = s.substring(dashIdx + 1).trim();
      s = s.substring(0, dashIdx).trim();
    }

    final numericParts = s
        .split('.')
        .where((p) => p.isNotEmpty)
        .map((p) {
          final m = RegExp(r'^\d+').firstMatch(p.trim());
          return m != null ? int.parse(m.group(0)!) : 0;
        })
        .toList();

    return _ParsedVersion(
      parts: numericParts.isEmpty ? const [0] : numericParts,
      preRelease: preRel,
      build: buildNum,
    );
  }
}
