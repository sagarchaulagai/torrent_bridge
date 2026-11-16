import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Snapshot of Android background survival permissions & restrictions.
class BackgroundHealthStatus {
  final bool ignoringBatteryOptimizations;
  final bool notificationPermissionGranted;
  final bool notificationsEnabled;
  final bool unrestrictedBackgroundData;
  final bool isServiceRunning;
  final String manufacturer;
  final String model;
  final int sdkInt;

  const BackgroundHealthStatus({
    required this.ignoringBatteryOptimizations,
    required this.notificationPermissionGranted,
    required this.notificationsEnabled,
    required this.unrestrictedBackgroundData,
    required this.isServiceRunning,
    required this.manufacturer,
    required this.model,
    required this.sdkInt,
  });

  bool get isHealthy =>
      ignoringBatteryOptimizations &&
      notificationPermissionGranted &&
      notificationsEnabled &&
      unrestrictedBackgroundData;

  bool get isAggressiveOem {
    final m = manufacturer.toLowerCase();
    return m.contains('xiaomi') ||
        m.contains('redmi') ||
        m.contains('poco') ||
        m.contains('oppo') ||
        m.contains('realme') ||
        m.contains('vivo') ||
        m.contains('oneplus') ||
        m.contains('huawei') ||
        m.contains('honor') ||
        m.contains('samsung');
  }

  factory BackgroundHealthStatus.fromMap(Map<dynamic, dynamic> map) {
    return BackgroundHealthStatus(
      ignoringBatteryOptimizations:
          map['ignoringBatteryOptimizations'] == true,
      notificationPermissionGranted:
          map['notificationPermissionGranted'] != false,
      notificationsEnabled: map['notificationsEnabled'] != false,
      unrestrictedBackgroundData: map['unrestrictedBackgroundData'] != false,
      isServiceRunning: map['isServiceRunning'] == true,
      manufacturer: (map['manufacturer'] ?? 'Android').toString(),
      model: (map['model'] ?? '').toString(),
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Manages the native Android Foreground Service (`TorrentServerForegroundService`)
/// to keep the torrent engine and local HTTP audio streaming server alive when
/// the application moves to the background or the Activity is destroyed.
class AndroidForegroundService {
  static final AndroidForegroundService instance =
      AndroidForegroundService._();
  AndroidForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'com.rehesagar.torrentbridge/foreground_service',
  );

  bool _isRunning = false;
  bool _initialized = false;
  VoidCallback? onStopRequestedFromNotification;
  VoidCallback? onNetworkChanged;

  bool get isRunning => _isRunning;

  void init({
    VoidCallback? onStopFromNotification,
    VoidCallback? onNetworkChangedCallback,
  }) {
    if (onStopFromNotification != null) {
      onStopRequestedFromNotification = onStopFromNotification;
    }
    if (onNetworkChangedCallback != null) {
      onNetworkChanged = onNetworkChangedCallback;
    }
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onStopServerRequested') {
        _isRunning = false;
        onStopRequestedFromNotification?.call();
      } else if (call.method == 'onServiceDestroyed') {
        _isRunning = false;
      } else if (call.method == 'onNetworkChanged') {
        onNetworkChanged?.call();
      }
    });
  }

  /// Synchronizes [_isRunning] with the live native Kotlin service flag.
  Future<bool> syncServiceState() async {
    if (!Platform.isAndroid) return _isRunning;
    try {
      final running = await _channel.invokeMethod<bool>('isServiceRunning');
      _isRunning = running ?? _isRunning;
      return _isRunning;
    } catch (_) {
      return _isRunning;
    }
  }

  /// Requests `POST_NOTIFICATIONS` permission on Android 13+ (API 33+) if needed.
  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final granted = await _channel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      return granted ?? true;
    } catch (e) {
      debugPrint('AndroidForegroundService.requestNotificationPermission: $e');
      return false;
    }
  }

  /// Starts the persistent Android Foreground Service with WakeLock & WifiLock.
  Future<bool> startService({
    required String title,
    required String content,
  }) async {
    if (!Platform.isAndroid) {
      _isRunning = true;
      return true;
    }
    try {
      await requestNotificationPermission();
      final started = await _channel.invokeMethod<bool>('startService', {
        'title': title,
        'content': content,
      });
      _isRunning = started ?? true;
      return _isRunning;
    } catch (e) {
      debugPrint('AndroidForegroundService.startService error: $e');
      return false;
    }
  }

  /// Updates the persistent notification text while the server is running.
  Future<void> updateNotification({
    required String title,
    required String content,
  }) async {
    if (!Platform.isAndroid || !_isRunning) return;
    try {
      await _channel.invokeMethod<void>('updateNotification', {
        'title': title,
        'content': content,
      });
    } catch (e) {
      debugPrint('AndroidForegroundService.updateNotification error: $e');
    }
  }

  /// Stops the Android Foreground Service and releases WakeLock & WifiLock.
  Future<void> stopService() async {
    if (!Platform.isAndroid) {
      _isRunning = false;
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopService');
    } catch (e) {
      debugPrint('AndroidForegroundService.stopService error: $e');
    } finally {
      _isRunning = false;
    }
  }

  /// Collects Android background restriction and permission diagnostics.
  Future<BackgroundHealthStatus?> getBackgroundHealth() async {
    if (!Platform.isAndroid) return null;
    try {
      final map = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getBackgroundHealth',
      );
      if (map == null) return null;
      final status = BackgroundHealthStatus.fromMap(map);
      _isRunning = status.isServiceRunning;
      return status;
    } catch (e) {
      debugPrint('AndroidForegroundService.getBackgroundHealth error: $e');
      return null;
    }
  }

  Future<bool> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'requestBatteryOptimizationExemption',
      );
      return ok ?? false;
    } catch (e) {
      debugPrint(
        'AndroidForegroundService.requestBatteryOptimizationExemption error: $e',
      );
      return false;
    }
  }

  Future<bool> openUnrestrictedDataSettings() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'openUnrestrictedDataSettings',
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openOemBackgroundSettings() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'openOemBackgroundSettings',
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openAppSettings() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('openAppSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
