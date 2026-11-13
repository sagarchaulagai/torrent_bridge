import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Manages the native Android Foreground Service (`TorrentServerForegroundService`)
/// to keep the torrent engine and local HTTP audio streaming server alive when
/// the application moves to the background.
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

  bool get isRunning => _isRunning;

  void init({VoidCallback? onStopFromNotification}) {
    onStopRequestedFromNotification = onStopFromNotification;
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onStopServerRequested') {
        _isRunning = false;
        onStopRequestedFromNotification?.call();
      } else if (call.method == 'onServiceDestroyed') {
        _isRunning = false;
      }
    });
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
}

