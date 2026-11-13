# Mero Torrent-to-HTTP Audio Streaming Server

A standalone Android companion application built with **Flutter**, **`libtorrent_flutter` (`^2.0.0`)**, and **`just_audio` (`^0.10.6`)** that operates as a local **Torrent-to-HTTP Audio Streaming Server** for Mero Audiobook and any compatible HTTP audio player.

---

## Architecture & Core Modules

- **[`lib/models/streaming_models.dart`](lib/models/streaming_models.dart)**: Data models for `AudioFileEntry`, `ConnectedClientInfo`, and `StreamingSession`.
- **[`lib/services/torrent_engine_service.dart`](lib/services/torrent_engine_service.dart)**: Native `LibtorrentFlutter` engine wrapper handling initialization, magnet/infohash normalization, sparse stream-only torrent addition (`streamOnly: true`), reactive metadata resolution, file path/index matching, and native stream lifecycle.
- **[`lib/services/http_streaming_server.dart`](lib/services/http_streaming_server.dart)**: Local HTTP server (`dart:io` `HttpServer`) exposing REST control endpoints and HTTP byte-range audio streaming endpoints with live client connection tracking and audio MIME header injection.
- **[`lib/services/audio_player_service.dart`](lib/services/audio_player_service.dart)**: Built-in `just_audio` test player that connects to the local HTTP streaming server (`POST /api/stream` -> `GET /stream/<sessionId>`) to verify playback and byte-range seeking end-to-end.
- **[`lib/services/android_foreground_service.dart`](lib/services/android_foreground_service.dart) & [`TorrentServerForegroundService.kt`](android/app/src/main/kotlin/com/example/torrent_streamer/TorrentServerForegroundService.kt)**: Native Android Foreground Service (`mediaPlayback|dataSync`) with persistent status notification, `Stop Server` notification action, CPU partial `WakeLock`, and low-latency `WifiLock`.
- **[`lib/screens/home_screen.dart`](lib/screens/home_screen.dart)**: Material 3 interface containing the **Server Dashboard**, **Test Audio Player (`just_audio`)**, **Torrent Information & Audio Files**, and **Server Activity Log**.
- **[`tool/test_streaming_server.py`](tool/test_streaming_server.py)**: Python 3.12 verification script testing server status, metadata inspection, stream creation, `HEAD` probing, and `206 Partial Content` HTTP Range seeking.

---

## HTTP API Reference

### 1. Create / Resolve Audio Stream (`POST /api/stream` or `POST /stream`)

**Request Body:**
```json
{
  "magnet": "magnet:?xt=urn:btih:2a72c612335bd7cc5221b9c20838a9a349cf3821",
  "file_path": "Audiobook/Chapter 01.mp3"
}
```
*(Also accepts `"infohash"` instead of `"magnet"`, and `"file_index"` instead of `"file_path"`.)*

**Response (`200 OK`):**
```json
{
  "status": "ok",
  "session_id": "s1_1_0",
  "torrent_id": 1,
  "native_stream_id": 1,
  "infohash": "2a72c612335bd7cc5221b9c20838a9a349cf3821",
  "torrent_name": "...",
  "file_index": 0,
  "file_name": "Chapter 01.mp3",
  "file_path": "Audiobook/Chapter 01.mp3",
  "file_size": 12345678,
  "mime_type": "audio/mpeg",
  "format": "MP3",
  "stream_url": "http://192.168.1.10:8080/stream/s1_1_0/Chapter%2001.mp3",
  "loopback_stream_url": "http://127.0.0.1:8080/stream/s1_1_0/Chapter%2001.mp3"
}
```

### 2. Stream Audio with HTTP Range Support (`GET /stream/<sessionId>/<fileName>`)
- Supports `GET`, `HEAD`, and `OPTIONS`.
- Supports `Range: bytes=start-end`, `Range: bytes=start-`, and suffix ranges `Range: bytes=-suffix` (`206 Partial Content`).
- Also available directly via `GET /audio?magnet=<magnet_or_hash>&file_path=<relative_path>`.

### 3. Inspect Torrent Metadata (`POST /api/torrent/inspect`)
- Resolves torrent metadata and returns the complete file list with indices, paths, sizes, formats, and MIME types without starting a stream.

### 4. Server Status (`GET /api/status`)
- Returns server running status, IP addresses, port, connected clients, and active streaming sessions.
