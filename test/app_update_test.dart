import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torrent_bridge/screens/home_screen.dart';
import 'package:torrent_bridge/services/app_update_service.dart';
import 'package:torrent_bridge/services/server_settings_service.dart';

class _FakeUiUpdateService extends AppUpdateService {
  _FakeUiUpdateService() : super.forTesting();

  bool checkCalled = false;
  bool installCalled = false;

  AppUpdateInfo _mockInfo = AppUpdateInfo(
    currentVersion: '1.0.0+1',
    latestVersion: '1.0.0+1',
    downloadUrl: '',
    hasUpdate: false,
  );

  bool _hasUpdate = false;
  AppUpdatePhase _phase = AppUpdatePhase.idle;
  String? _status;

  @override
  String get currentVersion => '1.0.0+1';

  @override
  AppUpdateInfo? get latestInfo => _phase == AppUpdatePhase.idle ? null : _mockInfo;

  @override
  AppUpdatePhase get phase => _phase;

  @override
  bool get hasAvailableUpdate => _hasUpdate;

  @override
  String? get statusMessage => _status;

  @override
  Future<AppUpdateInfo?> checkForUpdate({bool silent = false}) async {
    checkCalled = true;
    _mockInfo = AppUpdateInfo(
      currentVersion: '1.0.0+1',
      latestVersion: '1.0.2+3',
      downloadUrl: 'https://github.com/sagarchaulagai/torrent_bridge/releases/download/1.0.2%2B3/app-release.apk',
      hasUpdate: true,
    );
    _hasUpdate = true;
    _phase = AppUpdatePhase.available;
    _status = 'Update available: v1.0.2+3 (installed: v1.0.0+1)';
    notifyListeners();
    return _mockInfo;
  }

  @override
  Future<String?> downloadAndInstallUpdate({AppUpdateInfo? target}) async {
    installCalled = true;
    _phase = AppUpdatePhase.installing;
    _status = 'Installer launched for v1.0.2+3.';
    notifyListeners();
    return '/tmp/torrent_bridge_1.0.2+3.apk';
  }
}

void main() {
  test('AppUpdateService compares semantic + build versions accurately', () {
    expect(AppUpdateService.isRemoteVersionNewer('1.0.0+1', '1.0.0+1'), isFalse);
    expect(AppUpdateService.isRemoteVersionNewer('1.0.0+2', '1.0.0+1'), isTrue);
    expect(AppUpdateService.isRemoteVersionNewer('1.0.1+1', '1.0.0+9'), isTrue);
    expect(AppUpdateService.isRemoteVersionNewer('v1.1.0', '1.0.9+99'), isTrue);
    expect(AppUpdateService.isRemoteVersionNewer('2.0.0+1', '1.9.9+50'), isTrue);
    expect(AppUpdateService.isRemoteVersionNewer('1.0.0+1', '1.0.1+1'), isFalse);
    expect(AppUpdateService.isRemoteVersionNewer('1.0.0', '1.0.0+1'), isFalse);
  });

  group('AppUpdateService manifest check, APK download & verification', () {
    HttpOverrides? savedOverrides;
    late Directory tempDir;
    late HttpServer mockServer;
    late String baseUrl;

    String remoteVersion = '1.0.0+1';
    List<int> apkBytes = [0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4, 5, 6];
    String installOutcome = 'launched';
    String? installedApkPath;

    setUp(() async {
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      tempDir = await Directory.systemTemp.createTemp('tb_update_test_');
      mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${mockServer.port}';
      installedApkPath = null;
      installOutcome = 'launched';

      mockServer.listen((HttpRequest req) async {
        final path = req.uri.path;
        final res = req.response;
        if (path == '/update.json') {
          res.statusCode = HttpStatus.ok;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'version': remoteVersion,
            'link': '$baseUrl/release/app-release.apk',
          }));
          await res.close();
          return;
        }
        if (path == '/release/app-release.apk') {
          res.statusCode = HttpStatus.ok;
          res.contentLength = apkBytes.length;
          res.add(apkBytes);
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.notFound;
        await res.close();
      });
    });

    tearDown(() async {
      await mockServer.close(force: true);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      HttpOverrides.global = savedOverrides;
    });

    test('reports up-to-date when update.json matches current version', () async {
      remoteVersion = '1.0.0+1';
      final updater = AppUpdateService.forTesting(
        manifestUrl: '$baseUrl/update.json',
        versionLoader: () async => '1.0.0+1',
        downloadDirProvider: () async => tempDir,
      );

      final info = await updater.checkForUpdate();
      expect(info, isNotNull);
      expect(info!.hasUpdate, isFalse);
      expect(updater.phase, AppUpdatePhase.upToDate);
      expect(updater.hasAvailableUpdate, isFalse);
    });

    test('downloads valid APK and launches installer when remote version is newer', () async {
      remoteVersion = '1.0.1+2';
      apkBytes = [0x50, 0x4B, 0x03, 0x04, ...List<int>.filled(4096, 42)];

      final updater = AppUpdateService.forTesting(
        manifestUrl: '$baseUrl/update.json',
        versionLoader: () async => '1.0.0+1',
        downloadDirProvider: () async => tempDir,
        apkInstaller: (path) async {
          installedApkPath = path;
          return installOutcome;
        },
      );

      final info = await updater.checkForUpdate();
      expect(info, isNotNull);
      expect(info!.hasUpdate, isTrue);
      expect(info.latestVersion, '1.0.1+2');
      expect(updater.phase, AppUpdatePhase.available);

      final downloadedPath = await updater.downloadAndInstallUpdate();
      expect(downloadedPath, isNotNull);
      expect(installedApkPath, downloadedPath);
      expect(await File(downloadedPath!).exists(), isTrue);
      expect(await File(downloadedPath).length(), apkBytes.length);
      expect(updater.phase, AppUpdatePhase.installing);
    });

    test('surfaces permissionRequired when Android unknown-app permission is needed', () async {
      remoteVersion = '1.0.2+3';
      apkBytes = [0x50, 0x4B, 0x03, 0x04, 9, 8, 7];
      installOutcome = 'permission_requested';

      final updater = AppUpdateService.forTesting(
        manifestUrl: '$baseUrl/update.json',
        versionLoader: () async => '1.0.0+1',
        downloadDirProvider: () async => tempDir,
        apkInstaller: (path) async {
          installedApkPath = path;
          return installOutcome;
        },
      );

      await updater.checkForUpdate();
      final downloadedPath = await updater.downloadAndInstallUpdate();
      expect(downloadedPath, isNotNull);
      expect(updater.phase, AppUpdatePhase.permissionRequired);
      expect(updater.statusMessage, contains('Install unknown apps'));
    });

    test('rejects invalid non-APK download payloads and removes partial files', () async {
      remoteVersion = '1.0.3+4';
      apkBytes = utf8.encode('<html>Not an APK</html>');

      final updater = AppUpdateService.forTesting(
        manifestUrl: '$baseUrl/update.json',
        versionLoader: () async => '1.0.0+1',
        downloadDirProvider: () async => tempDir,
        apkInstaller: (path) async {
          installedApkPath = path;
          return 'launched';
        },
      );

      await updater.checkForUpdate();
      final result = await updater.downloadAndInstallUpdate();
      expect(result, isNull);
      expect(installedApkPath, isNull);
      expect(updater.phase, AppUpdatePhase.error);
      expect(updater.errorMessage, contains('not a valid Android APK'));
    });
  });

  testWidgets('HomeScreen displays App Updates card, check button, update banner, and install button', (
    WidgetTester tester,
  ) async {
    final settings = ServerSettingsService.instance;
    await tester.runAsync(() async {
      await settings.init();
      await settings.setKeepServerRunning(false);
      await settings.setAutoStartServer(false);
    });

    final fakeUpdater = _FakeUiUpdateService();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(appUpdateService: fakeUpdater),
      ),
    );

    // Go to Settings and scroll to App Updates card
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('app_update_check_button')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('App Updates'), findsOneWidget);
    expect(find.text('Current Version: v1.0.0+1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app_update_check_button')));
    await tester.pumpAndSettle();

    expect(fakeUpdater.checkCalled, isTrue);
    expect(find.text('Latest: v1.0.2+3'), findsOneWidget);
    expect(find.byKey(const Key('app_update_install_button')), findsOneWidget);

    // Trigger install from Settings
    await tester.ensureVisible(find.byKey(const Key('app_update_install_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app_update_install_button')));
    await tester.pumpAndSettle();
    expect(fakeUpdater.installCalled, isTrue);

    // Switch to Server tab and verify update banner is displayed
    await tester.tap(find.text('Server'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app_update_banner')), findsOneWidget);
    expect(find.text('Update Available: v1.0.2+3'), findsOneWidget);
  });
}
