import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/http_streaming_server.dart';
import 'services/server_settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ServerSettingsService.instance.init();

  // Start the HTTP server directly from main() when keepServerRunning or
  // autoStartServer is enabled so headless background restarts (e.g. Android
  // START_STICKY / boot) bring the server back online even before any UI frame.
  if (ServerSettingsService.instance.keepServerRunning ||
      ServerSettingsService.instance.autoStartServer) {
    unawaited(HttpStreamingServer.instance.ensureRunningOrAutoStart());
  }

  runApp(const TorrentAudioStreamerApp());
}

class TorrentAudioStreamerApp extends StatelessWidget {
  const TorrentAudioStreamerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Torrent Bridge',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          brightness: Brightness.dark,
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          brightness: Brightness.light,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
