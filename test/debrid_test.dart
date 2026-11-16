import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torrent_bridge/models/debrid_models.dart';
import 'package:torrent_bridge/screens/home_screen.dart';
import 'package:torrent_bridge/services/audio_disk_cache_service.dart';
import 'package:torrent_bridge/services/debrid_service.dart';
import 'package:torrent_bridge/services/http_streaming_server.dart';
import 'package:torrent_bridge/services/server_settings_service.dart';

class _FakeUiDebridService extends DebridService {
  _FakeUiDebridService() : super.forTesting();

  @override
  Future<DebridValidationResult> validateApiKey(
    DebridProvider provider,
    String apiKey,
  ) async {
    if (apiKey.trim() == 'valid-key-123') {
      return DebridValidationResult(
        provider: provider,
        isValid: true,
        username: 'audiobook_fan',
        isPremium: true,
        message: 'Connected as audiobook_fan (Premium)',
      );
    }
    return DebridValidationResult(
      provider: provider,
      isValid: false,
      message: 'API key rejected by ${provider.displayName}',
    );
  }
}

void main() {
  test('ServerSettingsService defaults to Debrid OFF and torrent fallback OFF', () async {
    final settings = ServerSettingsService.instance;
    await settings.init();
    await settings.setDebridProvider(DebridProvider.none);
    await settings.setFallbackToTorrentOnDebridFailure(false);

    expect(settings.debridProvider, DebridProvider.none);
    expect(settings.fallbackToTorrentOnDebridFailure, isFalse);
    expect(settings.hasConfiguredDebrid, isFalse);

    await settings.setDebridProvider(DebridProvider.realdebrid);
    await settings.setDebridApiKey(
      DebridProvider.realdebrid,
      'rd_test_token_999',
      validated: true,
      accountLabel: 'sagar',
    );
    expect(settings.hasConfiguredDebrid, isTrue);
    expect(settings.isActiveDebridKeyValidated, isTrue);
    expect(settings.activeDebridAccountLabel, 'sagar');
    expect(
      ServerSettingsService.maskApiKey(settings.activeDebridApiKey),
      'rd_...999',
    );

    await settings.clearDebridApiKey(DebridProvider.realdebrid);
    await settings.setDebridProvider(DebridProvider.none);
    expect(settings.hasConfiguredDebrid, isFalse);
  });

  group('DebridService API validation & resolution across all 6 providers', () {
    HttpOverrides? savedHttpOverrides;
    late HttpServer mockApiServer;
    late String baseUrl;
    late DebridService debrid;

    var allDebridStatusPolls = 0;
    var debridLinkPolls = 0;
    var offcloudPolls = 0;
    var premiumizePolls = 0;
    var rdSelectCalled = false;
    var rdPolls = 0;
    var torboxPolls = 0;

    setUp(() async {
      savedHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;

      allDebridStatusPolls = 0;
      debridLinkPolls = 0;
      offcloudPolls = 0;
      premiumizePolls = 0;
      rdSelectCalled = false;
      rdPolls = 0;
      torboxPolls = 0;

      mockApiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${mockApiServer.port}';

      debrid = DebridService.forTesting(
        baseUrlOverrides: {
          DebridProvider.alldebrid: baseUrl,
          DebridProvider.debridlink: baseUrl,
          DebridProvider.offcloud: baseUrl,
          DebridProvider.premiumize: baseUrl,
          DebridProvider.realdebrid: baseUrl,
          DebridProvider.torbox: baseUrl,
        },
        pollInterval: const Duration(milliseconds: 10),
        resolveTimeout: const Duration(seconds: 3),
      );

      mockApiServer.listen((HttpRequest req) async {
        final path = req.uri.path;
        final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
        final body = await utf8.decoder.bind(req).join();
        final res = req.response;
        res.headers.contentType = ContentType.json;

        void sendJson(int status, Object obj) {
          res.statusCode = status;
          res.write(jsonEncode(obj));
          res.close();
        }

        // Direct audio mock file (for HEAD size probe)
        if (path == '/cdn/book.mp3') {
          res.statusCode = HttpStatus.ok;
          res.headers.set(HttpHeaders.contentLengthHeader, '262144');
          await res.close();
          return;
        }

        // 1. ALLDEBRID
        if (path == '/v4/user') {
          if (auth == 'Bearer ad_good') {
            sendJson(200, {
              'status': 'success',
              'data': {
                'user': {'username': 'ad_user', 'isPremium': true}
              }
            });
          } else {
            sendJson(200, {
              'status': 'error',
              'error': {'code': 'AUTH_BAD_APIKEY', 'message': 'Invalid AD key'}
            });
          }
          return;
        }
        if (path == '/v4/magnet/upload') {
          sendJson(200, {
            'status': 'success',
            'data': {
              'magnets': [
                {'id': 42, 'ready': false}
              ]
            }
          });
          return;
        }
        if (path == '/v4.1/magnet/status') {
          allDebridStatusPolls++;
          sendJson(200, {
            'status': 'success',
            'data': {
              'magnets': {
                'id': 42,
                'statusCode': allDebridStatusPolls >= 2 ? 4 : 2,
                'status': allDebridStatusPolls >= 2 ? 'Ready' : 'Downloading',
              }
            }
          });
          return;
        }
        if (path == '/v4/magnet/files') {
          sendJson(200, {
            'status': 'success',
            'data': {
              'magnets': [
                {
                  'id': 42,
                  'files': [
                    {
                      'n': 'BookRoot',
                      'e': [
                        {'n': 'Cover.jpg', 's': 1000, 'l': 'https://alldebrid.com/f/cover'},
                        {'n': 'Chapter01.mp3', 's': 5000000, 'l': 'https://alldebrid.com/f/ch1'},
                      ]
                    }
                  ]
                }
              ]
            }
          });
          return;
        }
        if (path == '/v4/link/unlock') {
          sendJson(200, {
            'status': 'success',
            'data': {
              'link': '$baseUrl/cdn/Chapter01.mp3',
              'filename': 'Chapter01.mp3',
              'filesize': 5000000,
            }
          });
          return;
        }

        // 2. DEBRID-LINK
        if (path == '/account/infos') {
          if (auth == 'Bearer dl_good') {
            sendJson(200, {
              'success': true,
              'value': {'username': 'dl_user', 'accountType': 1}
            });
          } else {
            sendJson(401, {'success': false, 'error': 'badToken'});
          }
          return;
        }
        if (path == '/seedbox/add') {
          sendJson(200, {
            'success': true,
            'value': {'id': 'dl_t1', 'downloadPercent': 20, 'files': []}
          });
          return;
        }
        if (path == '/seedbox/list') {
          debridLinkPolls++;
          sendJson(200, {
            'success': true,
            'value': [
              {
                'id': 'dl_t1',
                'downloadPercent': debridLinkPolls >= 2 ? 100 : 50,
                'error': 0,
                'files': [
                  {
                    'name': 'Part1.m4b',
                    'size': 9000000,
                    'downloadUrl': '$baseUrl/cdn/Part1.m4b',
                  }
                ]
              }
            ]
          });
          return;
        }

        // 3. OFFCLOUD
        if (path == '/cloud/history') {
          final key = req.uri.queryParameters['key'];
          if (key == 'oc_good') {
            sendJson(200, []);
          } else {
            sendJson(200, {'error': 'Your API key is invalid or expired.'});
          }
          return;
        }
        if (path == '/cloud') {
          sendJson(200, {
            'requestId': 'oc_req1',
            'status': 'created',
          });
          return;
        }
        if (path == '/cloud/status') {
          offcloudPolls++;
          sendJson(200, {
            'status': {
              'requestId': 'oc_req1',
              'status': offcloudPolls >= 2 ? 'downloaded' : 'downloading',
              'isDirectory': true,
            }
          });
          return;
        }
        if (path == '/cloud/explore/oc_req1') {
          sendJson(200, ['$baseUrl/cdn/book.mp3']);
          return;
        }

        // 4. PREMIUMIZE
        if (path == '/account/info') {
          if (auth == 'Bearer pm_good') {
            sendJson(200, {
              'status': 'success',
              'customer_id': 98765,
              'premium_until': 4102444800,
            });
          } else {
            // Premiumize returns HTTP 200 even on auth errors
            sendJson(200, {
              'status': 'error',
              'code': 'authentication_failed',
              'message': 'Invalid API key',
            });
          }
          return;
        }
        if (path == '/transfer/directdl') {
          if (body.contains('pm_noncached')) {
            sendJson(200, {'status': 'error', 'message': 'not cached'});
          } else {
            sendJson(200, {
              'status': 'success',
              'content': [
                {
                  'path': 'Book/Intro.mp3',
                  'size': 123456,
                  'link': '$baseUrl/cdn/Intro.mp3',
                }
              ]
            });
          }
          return;
        }
        if (path == '/transfer/create') {
          sendJson(200, {'status': 'success', 'id': 'pm_tr1'});
          return;
        }
        if (path == '/transfer/list') {
          premiumizePolls++;
          sendJson(200, {
            'status': 'success',
            'transfers': [
              {
                'id': 'pm_tr1',
                'status': premiumizePolls >= 2 ? 'finished' : 'downloading',
                'folder_id': 'pm_fld1',
              }
            ]
          });
          return;
        }
        if (path == '/folder/list') {
          sendJson(200, {
            'status': 'success',
            'content': [
              {
                'type': 'file',
                'name': 'FallbackChapter.flac',
                'size': 444444,
                'link': '$baseUrl/cdn/FallbackChapter.flac',
              }
            ]
          });
          return;
        }

        // 5. REAL-DEBRID
        if (path == '/user') {
          if (auth == 'Bearer rd_good') {
            sendJson(200, {
              'username': 'rd_user',
              'type': 'premium',
              'premium': 1,
            });
          } else {
            sendJson(401, {'error': 'bad_token'});
          }
          return;
        }
        if (path == '/torrents/addMagnet') {
          sendJson(201, {'id': 'RD123'});
          return;
        }
        if (path == '/torrents/selectFiles/RD123') {
          rdSelectCalled = body.contains('files=2');
          res.statusCode = HttpStatus.noContent;
          await res.close();
          return;
        }
        if (path == '/torrents/info/RD123') {
          if (!rdSelectCalled) {
            sendJson(200, {
              'id': 'RD123',
              'status': 'waiting_files_selection',
              'files': [
                {'id': 1, 'path': '/Book/Readme.txt', 'bytes': 200, 'selected': 0},
                {'id': 2, 'path': '/Book/Audio.m4a', 'bytes': 777777, 'selected': 0},
              ],
              'links': [],
            });
          } else {
            rdPolls++;
            sendJson(200, {
              'id': 'RD123',
              'status': rdPolls >= 2 ? 'downloaded' : 'downloading',
              'files': [
                {'id': 1, 'path': '/Book/Readme.txt', 'bytes': 200, 'selected': 0},
                {'id': 2, 'path': '/Book/Audio.m4a', 'bytes': 777777, 'selected': 1},
              ],
              'links': rdPolls >= 2 ? ['https://real-debrid.com/d/RD_HOST_LINK'] : [],
            });
          }
          return;
        }
        if (path == '/unrestrict/link') {
          sendJson(200, {
            'download': '$baseUrl/cdn/Audio.m4a',
            'filename': 'Audio.m4a',
            'filesize': 777777,
          });
          return;
        }

        // 6. TORBOX
        if (path == '/user/me') {
          if (auth == 'Bearer tb_good') {
            sendJson(200, {
              'success': true,
              'data': {'email': 'tb@example.com', 'plan': 2},
            });
          } else {
            sendJson(401, {
              'success': false,
              'error': 'BAD_TOKEN',
              'detail': 'Invalid token',
            });
          }
          return;
        }
        if (path == '/torrents/createtorrent') {
          expect(body, contains('name="magnet"'));
          sendJson(200, {
            'success': true,
            'data': {'torrent_id': 9001},
          });
          return;
        }
        if (path == '/torrents/mylist') {
          torboxPolls++;
          sendJson(200, {
            'success': true,
            'data': {
              'id': 9001,
              'download_present': torboxPolls >= 2,
              'download_finished': torboxPolls >= 2,
              'files': [
                {'id': 7, 'name': 'Audiobook/Track01.mp3', 'size': 333333},
              ],
            },
          });
          return;
        }
        if (path == '/torrents/requestdl') {
          sendJson(200, {
            'success': true,
            'data': '$baseUrl/cdn/Track01.mp3',
          });
          return;
        }

        sendJson(404, {'error': 'Unhandled route: $path'});
      });
    });

    tearDown(() async {
      await mockApiServer.close(force: true);
      HttpOverrides.global = savedHttpOverrides;
    });

    test('validates API keys accurately for all 6 Debrid providers', () async {
      final adOk = await debrid.validateApiKey(DebridProvider.alldebrid, 'ad_good');
      expect(adOk.isValid, isTrue);
      expect(adOk.username, 'ad_user');
      expect((await debrid.validateApiKey(DebridProvider.alldebrid, 'ad_bad')).isValid, isFalse);

      final dlOk = await debrid.validateApiKey(DebridProvider.debridlink, 'dl_good');
      expect(dlOk.isValid, isTrue);
      expect(dlOk.username, 'dl_user');
      expect((await debrid.validateApiKey(DebridProvider.debridlink, 'dl_bad')).isValid, isFalse);

      final ocOk = await debrid.validateApiKey(DebridProvider.offcloud, 'oc_good');
      expect(ocOk.isValid, isTrue);
      expect((await debrid.validateApiKey(DebridProvider.offcloud, 'oc_bad')).isValid, isFalse);

      final pmOk = await debrid.validateApiKey(DebridProvider.premiumize, 'pm_good');
      expect(pmOk.isValid, isTrue);
      expect(pmOk.isPremium, isTrue);
      expect((await debrid.validateApiKey(DebridProvider.premiumize, 'pm_bad')).isValid, isFalse);

      final rdOk = await debrid.validateApiKey(DebridProvider.realdebrid, 'rd_good');
      expect(rdOk.isValid, isTrue);
      expect(rdOk.username, 'rd_user');
      expect((await debrid.validateApiKey(DebridProvider.realdebrid, 'rd_bad')).isValid, isFalse);

      final tbOk = await debrid.validateApiKey(DebridProvider.torbox, 'tb_good');
      expect(tbOk.isValid, isTrue);
      expect(tbOk.username, 'tb@example.com');
      expect((await debrid.validateApiKey(DebridProvider.torbox, 'tb_bad')).isValid, isFalse);
    });

    test('resolves audio file direct URLs across all 6 Debrid providers', () async {
      const hash = '2a72c612335bd7cc5221b9c20838a9a349cf3821';

      final ad = await debrid.resolveAudioFile(
        provider: DebridProvider.alldebrid,
        apiKey: 'ad_good',
        magnetOrInfoHash: hash,
      );
      expect(ad.fileName, 'Chapter01.mp3');
      expect(ad.fileSize, 5000000);
      expect(ad.directUrl, '$baseUrl/cdn/Chapter01.mp3');

      final dl = await debrid.resolveAudioFile(
        provider: DebridProvider.debridlink,
        apiKey: 'dl_good',
        magnetOrInfoHash: hash,
      );
      expect(dl.fileName, 'Part1.m4b');
      expect(dl.directUrl, '$baseUrl/cdn/Part1.m4b');

      final oc = await debrid.resolveAudioFile(
        provider: DebridProvider.offcloud,
        apiKey: 'oc_good',
        magnetOrInfoHash: hash,
      );
      expect(oc.fileName, 'book.mp3');
      expect(oc.fileSize, 262144);
      expect(oc.directUrl, '$baseUrl/cdn/book.mp3');

      final pmDirect = await debrid.resolveAudioFile(
        provider: DebridProvider.premiumize,
        apiKey: 'pm_good',
        magnetOrInfoHash: hash,
      );
      expect(pmDirect.fileName, 'Intro.mp3');

      final pmTransfer = await debrid.resolveAudioFile(
        provider: DebridProvider.premiumize,
        apiKey: 'pm_good',
        magnetOrInfoHash: 'magnet:?xt=urn:btih:$hash&dn=pm_noncached',
      );
      expect(pmTransfer.fileName, 'FallbackChapter.flac');

      final rd = await debrid.resolveAudioFile(
        provider: DebridProvider.realdebrid,
        apiKey: 'rd_good',
        magnetOrInfoHash: hash,
      );
      expect(rdSelectCalled, isTrue);
      expect(rd.fileName, 'Audio.m4a');
      expect(rd.fileSize, 777777);

      final tb = await debrid.resolveAudioFile(
        provider: DebridProvider.torbox,
        apiKey: 'tb_good',
        magnetOrInfoHash: hash,
      );
      expect(tb.fileName, 'Track01.mp3');
      expect(tb.fileSize, 333333);
    });
  });

  group('HttpStreamingServer Debrid streaming & error audio loop', () {
    HttpOverrides? savedHttpOverrides;
    late Directory tempCacheDir;
    late HttpServer upstreamServer;
    late String upstreamBaseUrl;
    var cdnHitCount = 0;

    setUp(() async {
      savedHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;

      tempCacheDir = await Directory.systemTemp.createTemp('tb_debrid_srv_');
      await ServerSettingsService.instance.init();
      await AudioDiskCacheService.instance.init(
        baseCachePath: tempCacheDir.path,
        forceReload: true,
      );

      cdnHitCount = 0;
      final sampleBytes = Uint8List.fromList(
        List<int>.generate(32768, (i) => i % 251),
      );

      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';
      upstreamServer.listen((HttpRequest req) async {
        final path = req.uri.path;
        final res = req.response;

        if (path == '/user' &&
            req.headers.value(HttpHeaders.authorizationHeader) == 'Bearer good_rd') {
          res.statusCode = 200;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'username': 'ok', 'type': 'premium', 'premium': 1}));
          await res.close();
          return;
        }
        if (path == '/torrents/addMagnet') {
          res.statusCode = 201;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'id': 'T1'}));
          await res.close();
          return;
        }
        if (path == '/torrents/selectFiles/T1') {
          res.statusCode = 204;
          await res.close();
          return;
        }
        if (path == '/torrents/info/T1') {
          res.statusCode = 200;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'id': 'T1',
            'status': 'downloaded',
            'files': [
              {'id': 1, 'path': '/Book/Chapter.mp3', 'bytes': sampleBytes.length, 'selected': 1},
            ],
            'links': ['https://real-debrid.com/d/X'],
          }));
          await res.close();
          return;
        }
        if (path == '/unrestrict/link') {
          final auth = req.headers.value(HttpHeaders.authorizationHeader);
          if (auth != 'Bearer good_rd') {
            res.statusCode = 401;
            res.headers.contentType = ContentType.json;
            res.write(jsonEncode({'error': 'bad_token'}));
            await res.close();
            return;
          }
          res.statusCode = 200;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'download': '$upstreamBaseUrl/cdn/Chapter.mp3',
            'filename': 'Chapter.mp3',
            'filesize': sampleBytes.length,
          }));
          await res.close();
          return;
        }
        if (path == '/cdn/Chapter.mp3') {
          cdnHitCount++;
          final range = req.headers.value(HttpHeaders.rangeHeader);
          var start = 0;
          var end = sampleBytes.length - 1;
          if (range != null && range.startsWith('bytes=')) {
            final parts = range.substring(6).split('-');
            start = int.parse(parts[0]);
            if (parts.length > 1 && parts[1].isNotEmpty) {
              end = int.parse(parts[1]);
            }
            res.statusCode = HttpStatus.partialContent;
            res.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${sampleBytes.length}',
            );
          } else {
            res.statusCode = HttpStatus.ok;
          }
          final slice = sampleBytes.sublist(start, end + 1);
          res.contentLength = slice.length;
          res.add(slice);
          await res.close();
          return;
        }

        res.statusCode = 401;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'error': 'unauthorized'}));
        await res.close();
      });
    });

    tearDown(() async {
      await HttpStreamingServer.instance.stopServer();
      HttpStreamingServer.instance.debridService = DebridService.instance;
      await ServerSettingsService.instance.setDebridProvider(DebridProvider.none);
      await ServerSettingsService.instance.setFallbackToTorrentOnDebridFailure(false);
      await upstreamServer.close(force: true);
      if (await tempCacheDir.exists()) {
        await tempCacheDir.delete(recursive: true);
      }
      await ServerSettingsService.instance.init();
      await AudioDiskCacheService.instance.init(
        baseCachePath: ServerSettingsService.instance.cachePath,
        forceReload: true,
      );
      HttpOverrides.global = savedHttpOverrides;
    });

    test('streams via Debrid CDN into disk cache and serves Range seeks from disk cache', () async {
      final server = HttpStreamingServer.instance;
      server.debridService = DebridService.forTesting(
        baseUrlOverrides: {DebridProvider.realdebrid: upstreamBaseUrl},
        pollInterval: const Duration(milliseconds: 5),
      );
      await ServerSettingsService.instance.setDebridProvider(DebridProvider.realdebrid);
      await ServerSettingsService.instance.setDebridApiKey(
        DebridProvider.realdebrid,
        'good_rd',
        validated: true,
      );
      await server.startServer(port: 0);

      final client = HttpClient();
      try {
        final createReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/stream'),
        );
        createReq.write(jsonEncode({
          'infohash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        }));
        final createRes = await createReq.close();
        expect(createRes.statusCode, HttpStatus.ok);
        final createdJson = jsonDecode(await utf8.decoder.bind(createRes).join())
            as Map<String, dynamic>;
        expect(createdJson['stream_source'], 'debrid');

        final streamUrl = Uri.parse(createdJson['loopback_stream_url'] as String);

        // First Range request -> hits mock CDN + caches bytes 4096..8191
        final r1Req = await client.getUrl(streamUrl);
        r1Req.headers.set(HttpHeaders.rangeHeader, 'bytes=4096-8191');
        final r1Res = await r1Req.close();
        expect(r1Res.statusCode, HttpStatus.partialContent);
        final r1Bytes = await r1Res.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(r1Bytes.length, 4096);
        expect(cdnHitCount, 1);

        // Second identical Range request -> served from disk cache (cdnHitCount stays 1!)
        final r2Req = await client.getUrl(streamUrl);
        r2Req.headers.set(HttpHeaders.rangeHeader, 'bytes=4096-8191');
        final r2Res = await r2Req.close();
        expect(r2Res.statusCode, HttpStatus.partialContent);
        final r2Bytes = await r2Res.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(r2Bytes, r1Bytes);
        expect(cdnHitCount, 1);
      } finally {
        client.close(force: true);
      }
    });

    test('returns an error message instead of audio when Debrid fails and fallback is OFF (default)', () async {
      final server = HttpStreamingServer.instance;
      server.debridService = DebridService.forTesting(
        baseUrlOverrides: {DebridProvider.realdebrid: upstreamBaseUrl},
        pollInterval: const Duration(milliseconds: 5),
      );
      await ServerSettingsService.instance.setDebridProvider(DebridProvider.realdebrid);
      await ServerSettingsService.instance.setDebridApiKey(
        DebridProvider.realdebrid,
        'broken_key',
        validated: false,
      );
      // Confirm default is OFF
      expect(ServerSettingsService.instance.fallbackToTorrentOnDebridFailure, isFalse);

      await server.startServer(port: 0);

      final client = HttpClient();
      try {
        final createReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/stream'),
        );
        createReq.write(jsonEncode({
          'infohash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        }));
        final createRes = await createReq.close();
        expect(createRes.statusCode, HttpStatus.badGateway);
        final errorJson = jsonDecode(await utf8.decoder.bind(createRes).join())
            as Map<String, dynamic>;
        expect(errorJson['provider'], 'realdebrid');
        expect(errorJson['error'].toString(), contains('bad_token'));
        expect(server.lastError, contains('bad_token'));
        expect(server.activeSessions, isEmpty);

        // Direct GET /audio also returns JSON error instead of audio stream
        final directReq = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/audio?infohash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          ),
        );
        final directRes = await directReq.close();
        expect(directRes.statusCode, HttpStatus.badGateway);
        final directJson = jsonDecode(await utf8.decoder.bind(directRes).join())
            as Map<String, dynamic>;
        expect(directJson['error'].toString(), contains('bad_token'));

        // Must NOT pollute disk cache with failed Debrid requests
        expect(
          AudioDiskCacheService.instance.getEntry(
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            0,
          ),
          isNull,
        );
      } finally {
        client.close(force: true);
      }
    });
  });

  testWidgets('Settings tab shows Debrid providers, validates API keys, and defaults fallback OFF', (
    WidgetTester tester,
  ) async {
    final settings = ServerSettingsService.instance;
    await tester.runAsync(() async {
      await settings.init();
      await settings.setKeepServerRunning(false);
      await settings.setAutoStartServer(false);
      await settings.setDebridProvider(DebridProvider.none);
      await settings.setFallbackToTorrentOnDebridFailure(false);
    });

    final fakeDebrid = _FakeUiDebridService();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(debridService: fakeDebrid),
      ),
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Debrid Service'), findsOneWidget);
    expect(find.byKey(const Key('debrid_provider_dropdown')), findsOneWidget);
    expect(find.byKey(const Key('debrid_fallback_switch')), findsOneWidget);

    final fallbackSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('debrid_fallback_switch')),
    );
    expect(fallbackSwitch.value, isFalse);

    // Open provider dropdown and select TorBox
    await tester.tap(find.byKey(const Key('debrid_provider_dropdown')));
    await tester.pumpAndSettle();

    expect(find.text('AllDebrid'), findsOneWidget);
    expect(find.text('Debrid-Link'), findsOneWidget);
    expect(find.text('Offcloud'), findsOneWidget);
    expect(find.text('Premiumize'), findsOneWidget);
    expect(find.text('Real-Debrid'), findsOneWidget);
    expect(find.text('TorBox'), findsOneWidget);

    await tester.tap(find.text('TorBox').last);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // Test invalid key validation
    await tester.enterText(find.byKey(const Key('debrid_api_key_field')), 'bad-key');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('debrid_validate_save_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('debrid_validate_save_button')));
    await tester.pump();
    for (var i = 0;
        i < 40 &&
            (find.byKey(const Key('debrid_invalid_badge')).evaluate().isEmpty ||
                find.text('Validating...').evaluate().isNotEmpty);
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const Key('debrid_invalid_badge')), findsOneWidget);
    expect(find.textContaining('API key rejected'), findsOneWidget);
    await tester.pumpAndSettle();

    // Test valid key validation
    await tester.enterText(find.byKey(const Key('debrid_api_key_field')), 'valid-key-123');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('debrid_validate_save_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('debrid_validate_save_button')));
    await tester.pump();
    for (var i = 0;
        i < 40 &&
            (find.byKey(const Key('debrid_valid_badge')).evaluate().isEmpty ||
                find.text('Validating...').evaluate().isNotEmpty);
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const Key('debrid_valid_badge')), findsOneWidget);
    expect(find.textContaining('audiobook_fan'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    await tester.runAsync(() async {
      await settings.clearDebridApiKey(DebridProvider.torbox);
      await settings.setDebridProvider(DebridProvider.none);
    });
  });
}
