import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/debrid_models.dart';
import '../models/streaming_models.dart';
import 'torrent_engine_service.dart';

/// Handles API key validation and magnet-to-HTTP file resolution across
/// AllDebrid, Debrid-Link, Offcloud, Premiumize, Real-Debrid, and TorBox.
class DebridService {
  static final DebridService instance = DebridService._();

  DebridService._({
    HttpClient Function()? httpClientFactory,
    Map<DebridProvider, String>? baseUrlOverrides,
    Duration? pollInterval,
    Duration? resolveTimeout,
  })  : _httpClientFactory = httpClientFactory ?? _defaultHttpClient,
        _baseUrlOverrides = baseUrlOverrides ?? const {},
        _pollInterval = pollInterval ?? const Duration(seconds: 2),
        _resolveTimeout = resolveTimeout ?? const Duration(seconds: 45);

  /// Creates an isolated [DebridService] instance (useful for unit tests).
  @visibleForTesting
  DebridService.forTesting({
    HttpClient Function()? httpClientFactory,
    Map<DebridProvider, String>? baseUrlOverrides,
    Duration? pollInterval,
    Duration? resolveTimeout,
  })  : _httpClientFactory = httpClientFactory ?? _defaultHttpClient,
        _baseUrlOverrides = baseUrlOverrides ?? const {},
        _pollInterval = pollInterval ?? const Duration(milliseconds: 20),
        _resolveTimeout = resolveTimeout ?? const Duration(seconds: 5);

  final HttpClient Function() _httpClientFactory;
  final Map<DebridProvider, String> _baseUrlOverrides;
  final Duration _pollInterval;
  final Duration _resolveTimeout;

  static HttpClient _defaultHttpClient() {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15);
  }

  String _baseUrlFor(DebridProvider provider) {
    final override = _baseUrlOverrides[provider];
    if (override != null && override.isNotEmpty) {
      return override.endsWith('/')
          ? override.substring(0, override.length - 1)
          : override;
    }
    switch (provider) {
      case DebridProvider.none:
        return '';
      case DebridProvider.alldebrid:
        return 'https://api.alldebrid.com';
      case DebridProvider.debridlink:
        return 'https://debrid-link.com/api/v2';
      case DebridProvider.offcloud:
        return 'https://offcloud.com/api';
      case DebridProvider.premiumize:
        return 'https://www.premiumize.me/api';
      case DebridProvider.realdebrid:
        return 'https://api.real-debrid.com/rest/1.0';
      case DebridProvider.torbox:
        return 'https://api.torbox.app/v1/api';
    }
  }

  /// Validates [apiKey] against [provider]'s account endpoint.
  Future<DebridValidationResult> validateApiKey(
    DebridProvider provider,
    String apiKey,
  ) async {
    final trimmedKey = apiKey.trim();
    if (provider == DebridProvider.none) {
      return DebridValidationResult(
        provider: provider,
        isValid: false,
        message: 'Select a Debrid service first.',
      );
    }
    if (trimmedKey.isEmpty) {
      return DebridValidationResult(
        provider: provider,
        isValid: false,
        message: 'API key cannot be empty.',
      );
    }

    try {
      switch (provider) {
        case DebridProvider.none:
          return DebridValidationResult(
            provider: provider,
            isValid: false,
            message: 'No Debrid provider selected.',
          );
        case DebridProvider.alldebrid:
          return await _validateAllDebrid(trimmedKey);
        case DebridProvider.debridlink:
          return await _validateDebridLink(trimmedKey);
        case DebridProvider.offcloud:
          return await _validateOffcloud(trimmedKey);
        case DebridProvider.premiumize:
          return await _validatePremiumize(trimmedKey);
        case DebridProvider.realdebrid:
          return await _validateRealDebrid(trimmedKey);
        case DebridProvider.torbox:
          return await _validateTorBox(trimmedKey);
      }
    } on DebridException catch (e) {
      return DebridValidationResult(
        provider: provider,
        isValid: false,
        message: e.message,
      );
    } catch (e) {
      return DebridValidationResult(
        provider: provider,
        isValid: false,
        message: 'Failed to reach ${provider.displayName}: $e',
      );
    }
  }

  /// Resolves a torrent magnet URI / infohash via [provider] to a direct HTTP
  /// stream URL for the requested audio file.
  Future<DebridResolvedFile> resolveAudioFile({
    required DebridProvider provider,
    required String apiKey,
    required String magnetOrInfoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final trimmedKey = apiKey.trim();
    if (provider == DebridProvider.none || trimmedKey.isEmpty) {
      throw const DebridException('Debrid provider or API key is not configured.');
    }

    final magnetUri = TorrentEngineService.normalizeToMagnetUri(magnetOrInfoHash);
    final infoHash = TorrentEngineService.extractInfoHash(magnetUri);

    DebridResolvedFile resolved;
    switch (provider) {
      case DebridProvider.none:
        throw const DebridException('Debrid provider is disabled.');
      case DebridProvider.alldebrid:
        resolved = await _resolveAllDebrid(
          apiKey: trimmedKey,
          magnetUri: magnetUri,
          infoHash: infoHash,
          filePath: filePath,
          fileIndex: fileIndex,
        );
        break;
      case DebridProvider.debridlink:
        resolved = await _resolveDebridLink(
          apiKey: trimmedKey,
          magnetUri: magnetUri,
          infoHash: infoHash,
          filePath: filePath,
          fileIndex: fileIndex,
        );
        break;
      case DebridProvider.offcloud:
        resolved = await _resolveOffcloud(
          apiKey: trimmedKey,
          magnetUri: magnetUri,
          infoHash: infoHash,
          filePath: filePath,
          fileIndex: fileIndex,
        );
        break;
      case DebridProvider.premiumize:
        resolved = await _resolvePremiumize(
          apiKey: trimmedKey,
          magnetUri: magnetUri,
          infoHash: infoHash,
          filePath: filePath,
          fileIndex: fileIndex,
        );
        break;
      case DebridProvider.realdebrid:
        resolved = await _resolveRealDebrid(
          apiKey: trimmedKey,
          magnetUri: magnetUri,
          infoHash: infoHash,
          filePath: filePath,
          fileIndex: fileIndex,
        );
        break;
      case DebridProvider.torbox:
        resolved = await _resolveTorBox(
          apiKey: trimmedKey,
          magnetUri: magnetUri,
          infoHash: infoHash,
          filePath: filePath,
          fileIndex: fileIndex,
        );
        break;
    }

    if (resolved.fileSize <= 0 && resolved.directUrl.isNotEmpty) {
      final probedSize = await _probeContentLength(resolved.directUrl);
      if (probedSize > 0) {
        return DebridResolvedFile(
          provider: resolved.provider,
          directUrl: resolved.directUrl,
          fileName: resolved.fileName,
          filePath: resolved.filePath,
          fileSize: probedSize,
          mimeType: resolved.mimeType,
          infoHash: resolved.infoHash,
          fileIndex: resolved.fileIndex,
          availableAudioFiles: resolved.availableAudioFiles,
        );
      }
    }

    return resolved;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. ALLDEBRID
  // ═══════════════════════════════════════════════════════════════════════════

  Future<DebridValidationResult> _validateAllDebrid(String apiKey) async {
    final base = _baseUrlFor(DebridProvider.alldebrid);
    final res = await _requestJson(
      DebridProvider.alldebrid,
      'GET',
      '$base/v4/user',
      headers: _bearerHeaders(apiKey),
    );
    final map = _asMap(res.body, DebridProvider.alldebrid);
    if (res.statusCode >= 400 || map['status'] != 'success') {
      final errMsg = _nestedString(map, ['error', 'message']) ??
          'Invalid AllDebrid API key (HTTP ${res.statusCode}).';
      return DebridValidationResult(
        provider: DebridProvider.alldebrid,
        isValid: false,
        message: errMsg,
      );
    }

    final user = _asOptionalMap(map['data']?['user']);
    final username = user?['username']?.toString();
    final isPremium = user?['isPremium'] == true;
    return DebridValidationResult(
      provider: DebridProvider.alldebrid,
      isValid: true,
      username: username,
      isPremium: isPremium,
      message: username != null && username.isNotEmpty
          ? 'Connected as $username (${isPremium ? "Premium" : "Free"})'
          : 'AllDebrid API key is valid.',
    );
  }

  Future<DebridResolvedFile> _resolveAllDebrid({
    required String apiKey,
    required String magnetUri,
    required String infoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final base = _baseUrlFor(DebridProvider.alldebrid);
    final headers = _bearerHeaders(apiKey);

    final uploadRes = await _requestJson(
      DebridProvider.alldebrid,
      'POST',
      '$base/v4/magnet/upload',
      headers: headers,
      formBody: {'magnets[]': magnetUri},
    );
    final uploadMap = _expectAllDebridSuccess(uploadRes);
    final magnetsList = uploadMap['data']?['magnets'];
    if (magnetsList is! List || magnetsList.isEmpty) {
      throw const DebridException(
        'AllDebrid returned no magnet entry.',
        provider: DebridProvider.alldebrid,
      );
    }

    final uploaded = _asMap(magnetsList.first, DebridProvider.alldebrid);
    if (uploaded['error'] is Map) {
      throw DebridException(
        uploaded['error']['message']?.toString() ?? 'Magnet upload rejected.',
        provider: DebridProvider.alldebrid,
      );
    }

    final magnetId = uploaded['id'];
    if (magnetId == null) {
      throw const DebridException(
        'Missing magnet ID in AllDebrid upload response.',
        provider: DebridProvider.alldebrid,
      );
    }

    var isReady = uploaded['ready'] == true;
    if (!isReady) {
      final deadline = DateTime.now().add(_resolveTimeout);
      while (!isReady) {
        if (DateTime.now().isAfter(deadline)) {
          throw const DebridException(
            'Timed out waiting for AllDebrid magnet processing.',
            provider: DebridProvider.alldebrid,
          );
        }
        await Future<void>.delayed(_pollInterval);
        final statusRes = await _requestJson(
          DebridProvider.alldebrid,
          'POST',
          '$base/v4.1/magnet/status',
          headers: headers,
          formBody: {'id': magnetId.toString()},
        );
        final statusMap = _expectAllDebridSuccess(statusRes);
        final magnetObj = statusMap['data']?['magnets'];
        Map<String, dynamic>? item;
        if (magnetObj is Map<String, dynamic>) {
          item = magnetObj;
        } else if (magnetObj is List && magnetObj.isNotEmpty) {
          item = _asOptionalMap(magnetObj.first);
        }
        if (item == null) continue;
        final code = (item['statusCode'] as num?)?.toInt() ?? -1;
        if (code == 4) {
          isReady = true;
          break;
        }
        if (code >= 5 && code <= 15) {
          throw DebridException(
            item['status']?.toString() ?? 'AllDebrid magnet error ($code).',
            provider: DebridProvider.alldebrid,
          );
        }
      }
    }

    final filesRes = await _requestJson(
      DebridProvider.alldebrid,
      'POST',
      '$base/v4/magnet/files',
      headers: headers,
      formBody: {'id[]': magnetId.toString()},
    );
    final filesMap = _expectAllDebridSuccess(filesRes);
    final fileMagnets = filesMap['data']?['magnets'];
    if (fileMagnets is! List || fileMagnets.isEmpty) {
      throw const DebridException(
        'No files returned by AllDebrid for magnet.',
        provider: DebridProvider.alldebrid,
      );
    }
    final firstMagnet = _asMap(fileMagnets.first, DebridProvider.alldebrid);
    final rawTree = firstMagnet['files'];
    if (rawTree is! List || rawTree.isEmpty) {
      throw const DebridException(
        'AllDebrid returned an empty file tree.',
        provider: DebridProvider.alldebrid,
      );
    }

    final candidates = <_DebridCandidate>[];
    void walkTree(dynamic node, String prefix) {
      if (node is! Map) return;
      final name = node['n']?.toString() ?? '';
      final fullPath = prefix.isEmpty ? name : '$prefix/$name';
      final children = node['e'];
      if (children is List && children.isNotEmpty) {
        for (final child in children) {
          walkTree(child, fullPath);
        }
        return;
      }
      final link = node['l']?.toString() ?? '';
      if (link.isNotEmpty) {
        final size = (node['s'] as num?)?.toInt() ?? 0;
        final idx = candidates.length;
        candidates.add(
          _DebridCandidate(
            entry: AudioFileEntry.fromPathAndSize(
              index: idx,
              path: fullPath.isNotEmpty ? fullPath : 'audio_$idx',
              size: size,
            ),
            rawRef: link,
          ),
        );
      }
    }

    for (final rootNode in rawTree) {
      walkTree(rootNode, '');
    }

    final selected = _pickCandidate(
      candidates,
      provider: DebridProvider.alldebrid,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    final unlockRes = await _requestJson(
      DebridProvider.alldebrid,
      'POST',
      '$base/v4/link/unlock',
      headers: headers,
      formBody: {'link': selected.rawRef},
    );
    final unlockMap = _expectAllDebridSuccess(unlockRes);
    var unlockData = _asMap(unlockMap['data'], DebridProvider.alldebrid);
    var directUrl = unlockData['link']?.toString() ?? '';

    if (directUrl.isEmpty && unlockData['delayed'] != null) {
      final delayedId = unlockData['delayed'].toString();
      final deadline = DateTime.now().add(_resolveTimeout);
      while (directUrl.isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw const DebridException(
            'Timed out waiting for AllDebrid delayed link unlock.',
            provider: DebridProvider.alldebrid,
          );
        }
        await Future<void>.delayed(_pollInterval);
        final delayedRes = await _requestJson(
          DebridProvider.alldebrid,
          'POST',
          '$base/v4/link/delayed',
          headers: headers,
          formBody: {'id': delayedId},
        );
        final delayedMap = _expectAllDebridSuccess(delayedRes);
        final d = _asMap(delayedMap['data'], DebridProvider.alldebrid);
        final status = (d['status'] as num?)?.toInt() ?? 1;
        if (status == 2 && d['link'] != null) {
          directUrl = d['link'].toString();
          break;
        }
        if (status == 3) {
          throw const DebridException(
            'AllDebrid delayed link failed.',
            provider: DebridProvider.alldebrid,
          );
        }
      }
    }

    if (directUrl.isEmpty) {
      throw const DebridException(
        'AllDebrid unlock returned no direct URL.',
        provider: DebridProvider.alldebrid,
      );
    }

    final unlockedSize = (unlockData['filesize'] as num?)?.toInt() ?? 0;
    return _buildResolvedFile(
      provider: DebridProvider.alldebrid,
      directUrl: directUrl,
      selected: selected.entry,
      allCandidates: candidates,
      infoHash: infoHash,
      overrideSize: unlockedSize > 0 ? unlockedSize : null,
    );
  }

  Map<String, dynamic> _expectAllDebridSuccess(_HttpJsonResponse res) {
    final map = _asMap(res.body, DebridProvider.alldebrid);
    if (res.statusCode >= 400 || map['status'] != 'success') {
      final msg = _nestedString(map, ['error', 'message']) ??
          'AllDebrid API request failed (HTTP ${res.statusCode}).';
      throw DebridException(
        msg,
        statusCode: res.statusCode,
        provider: DebridProvider.alldebrid,
      );
    }
    return map;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. DEBRID-LINK
  // ═══════════════════════════════════════════════════════════════════════════

  Future<DebridValidationResult> _validateDebridLink(String apiKey) async {
    final base = _baseUrlFor(DebridProvider.debridlink);
    final res = await _requestJson(
      DebridProvider.debridlink,
      'GET',
      '$base/account/infos',
      headers: _bearerHeaders(apiKey),
    );
    final map = _asMap(res.body, DebridProvider.debridlink);
    if (res.statusCode >= 400 || map['success'] != true) {
      final err = map['error']?.toString() ??
          'Invalid Debrid-Link API key (HTTP ${res.statusCode}).';
      return DebridValidationResult(
        provider: DebridProvider.debridlink,
        isValid: false,
        message: err,
      );
    }

    final value = _asOptionalMap(map['value']);
    final username =
        value?['username']?.toString() ?? value?['email']?.toString();
    final accountType = (value?['accountType'] as num?)?.toInt();
    final isPremium = accountType != null ? accountType > 0 : null;
    return DebridValidationResult(
      provider: DebridProvider.debridlink,
      isValid: true,
      username: username,
      isPremium: isPremium,
      message: username != null && username.isNotEmpty
          ? 'Connected as $username'
          : 'Debrid-Link API key is valid.',
    );
  }

  Future<DebridResolvedFile> _resolveDebridLink({
    required String apiKey,
    required String magnetUri,
    required String infoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final base = _baseUrlFor(DebridProvider.debridlink);
    final headers = _bearerHeaders(apiKey);

    final addRes = await _requestJson(
      DebridProvider.debridlink,
      'POST',
      '$base/seedbox/add',
      headers: headers,
      jsonBody: {'url': magnetUri, 'async': true},
    );
    final addMap = _expectDebridLinkSuccess(addRes);
    var torrentObj = _asMap(addMap['value'], DebridProvider.debridlink);
    final torrentId = torrentObj['id']?.toString() ?? '';
    if (torrentId.isEmpty) {
      throw const DebridException(
        'Debrid-Link returned no torrent ID.',
        provider: DebridProvider.debridlink,
      );
    }

    final deadline = DateTime.now().add(_resolveTimeout);
    while (!_isDebridLinkReady(torrentObj)) {
      if (DateTime.now().isAfter(deadline)) {
        throw const DebridException(
          'Timed out waiting for Debrid-Link torrent.',
          provider: DebridProvider.debridlink,
        );
      }
      await Future<void>.delayed(_pollInterval);
      final listRes = await _requestJson(
        DebridProvider.debridlink,
        'GET',
        '$base/seedbox/list?ids=${Uri.encodeQueryComponent(torrentId)}',
        headers: headers,
      );
      final listMap = _expectDebridLinkSuccess(listRes);
      final valueList = listMap['value'];
      if (valueList is List && valueList.isNotEmpty) {
        final match = valueList.cast<dynamic>().firstWhere(
              (item) => item is Map && item['id']?.toString() == torrentId,
              orElse: () => valueList.first,
            );
        if (match is Map) {
          torrentObj = Map<String, dynamic>.from(match);
        }
      }
      final errNum = (torrentObj['error'] as num?)?.toInt() ?? 0;
      if (errNum != 0) {
        throw DebridException(
          torrentObj['errorString']?.toString() ??
              'Debrid-Link torrent error ($errNum).',
          provider: DebridProvider.debridlink,
        );
      }
    }

    final rawFiles = torrentObj['files'];
    if (rawFiles is! List || rawFiles.isEmpty) {
      throw const DebridException(
        'Debrid-Link torrent has no files.',
        provider: DebridProvider.debridlink,
      );
    }

    final candidates = <_DebridCandidate>[];
    for (var i = 0; i < rawFiles.length; i++) {
      final f = _asOptionalMap(rawFiles[i]);
      if (f == null) continue;
      final url =
          (f['downloadUrl'] ?? f['link'])?.toString().trim() ?? '';
      if (url.isEmpty) continue;
      final name = f['name']?.toString() ?? 'audio_$i';
      final path = f['path']?.toString().isNotEmpty == true
          ? f['path'].toString()
          : name;
      final size = (f['size'] as num?)?.toInt() ?? 0;
      candidates.add(
        _DebridCandidate(
          entry: AudioFileEntry.fromPathAndSize(
            index: candidates.length,
            path: path,
            size: size,
          ),
          rawRef: url,
        ),
      );
    }

    final selected = _pickCandidate(
      candidates,
      provider: DebridProvider.debridlink,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    return _buildResolvedFile(
      provider: DebridProvider.debridlink,
      directUrl: selected.rawRef,
      selected: selected.entry,
      allCandidates: candidates,
      infoHash: infoHash,
    );
  }

  bool _isDebridLinkReady(Map<String, dynamic> torrentObj) {
    final pct = (torrentObj['downloadPercent'] as num?)?.toDouble() ?? 0.0;
    final files = torrentObj['files'];
    if (files is! List || files.isEmpty) return false;
    final hasAnyUrl = files.any(
      (f) =>
          f is Map &&
          ((f['downloadUrl']?.toString().isNotEmpty ?? false) ||
              (f['link']?.toString().isNotEmpty ?? false)),
    );
    return pct >= 100.0 && hasAnyUrl;
  }

  Map<String, dynamic> _expectDebridLinkSuccess(_HttpJsonResponse res) {
    final map = _asMap(res.body, DebridProvider.debridlink);
    if (res.statusCode >= 400 || map['success'] != true) {
      throw DebridException(
        map['error']?.toString() ??
            'Debrid-Link API request failed (HTTP ${res.statusCode}).',
        statusCode: res.statusCode,
        provider: DebridProvider.debridlink,
      );
    }
    return map;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. OFFCLOUD
  // ═══════════════════════════════════════════════════════════════════════════

  Future<DebridValidationResult> _validateOffcloud(String apiKey) async {
    final base = _baseUrlFor(DebridProvider.offcloud);
    final res = await _requestJson(
      DebridProvider.offcloud,
      'GET',
      '$base/cloud/history?key=${Uri.encodeQueryComponent(apiKey)}',
    );
    if (res.statusCode >= 400) {
      final errMsg = res.body is Map
          ? (res.body['error']?.toString() ??
              'Invalid Offcloud API key (HTTP ${res.statusCode}).')
          : 'Invalid Offcloud API key (HTTP ${res.statusCode}).';
      return DebridValidationResult(
        provider: DebridProvider.offcloud,
        isValid: false,
        message: errMsg,
      );
    }

    if (res.body is Map) {
      final map = Map<String, dynamic>.from(res.body as Map);
      if (map['error'] != null || map['not_available'] != null) {
        return DebridValidationResult(
          provider: DebridProvider.offcloud,
          isValid: false,
          message: map['error']?.toString() ??
              'Offcloud key error (${map['not_available']}).',
        );
      }
      final email = map['email']?.toString() ?? map['username']?.toString();
      return DebridValidationResult(
        provider: DebridProvider.offcloud,
        isValid: true,
        username: email,
        message: email != null && email.isNotEmpty
            ? 'Connected as $email'
            : 'Offcloud API key is valid.',
      );
    }

    if (res.body is List) {
      return DebridValidationResult(
        provider: DebridProvider.offcloud,
        isValid: true,
        message: 'Offcloud API key is valid.',
      );
    }

    return DebridValidationResult(
      provider: DebridProvider.offcloud,
      isValid: false,
      message: 'Unexpected response from Offcloud.',
    );
  }

  Future<DebridResolvedFile> _resolveOffcloud({
    required String apiKey,
    required String magnetUri,
    required String infoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final base = _baseUrlFor(DebridProvider.offcloud);
    final keyParam = Uri.encodeQueryComponent(apiKey);

    final cloudRes = await _requestJson(
      DebridProvider.offcloud,
      'POST',
      '$base/cloud?key=$keyParam',
      jsonBody: {'url': magnetUri},
    );
    if (cloudRes.statusCode >= 400) {
      throw DebridException(
        'Offcloud cloud request failed (HTTP ${cloudRes.statusCode}).',
        statusCode: cloudRes.statusCode,
        provider: DebridProvider.offcloud,
      );
    }
    var cloudMap = _asMap(cloudRes.body, DebridProvider.offcloud);
    _checkOffcloudError(cloudMap);

    final requestId = cloudMap['requestId']?.toString() ?? '';
    if (requestId.isEmpty) {
      throw const DebridException(
        'Offcloud returned no requestId.',
        provider: DebridProvider.offcloud,
      );
    }

    var statusObj = cloudMap;
    var statusStr = (statusObj['status']?.toString() ?? '').toLowerCase();
    final deadline = DateTime.now().add(_resolveTimeout);

    while (statusStr != 'downloaded') {
      if (statusStr == 'error' ||
          statusStr == 'canceled' ||
          statusStr == 'not_available') {
        throw DebridException(
          'Offcloud transfer failed ($statusStr).',
          provider: DebridProvider.offcloud,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const DebridException(
          'Timed out waiting for Offcloud cloud download.',
          provider: DebridProvider.offcloud,
        );
      }
      await Future<void>.delayed(_pollInterval);
      final pollRes = await _requestJson(
        DebridProvider.offcloud,
        'POST',
        '$base/cloud/status?key=$keyParam',
        jsonBody: {'requestId': requestId},
      );
      if (pollRes.statusCode >= 400) {
        throw DebridException(
          'Offcloud status check failed (HTTP ${pollRes.statusCode}).',
          provider: DebridProvider.offcloud,
        );
      }
      final pollMap = _asMap(pollRes.body, DebridProvider.offcloud);
      _checkOffcloudError(pollMap);
      statusObj = pollMap['status'] is Map
          ? Map<String, dynamic>.from(pollMap['status'] as Map)
          : pollMap;
      statusStr = (statusObj['status']?.toString() ?? '').toLowerCase();
    }

    final candidates = <_DebridCandidate>[];
    final exploreRes = await _requestJson(
      DebridProvider.offcloud,
      'GET',
      '$base/cloud/explore/${Uri.encodeComponent(requestId)}?key=$keyParam',
      throwOnInvalidJson: false,
    );

    if (exploreRes.statusCode < 400 && exploreRes.body is List) {
      for (final item in (exploreRes.body as List)) {
        if (item is String && item.trim().isNotEmpty) {
          final parsedUri = Uri.tryParse(item.trim());
          final name = (parsedUri != null && parsedUri.pathSegments.isNotEmpty)
              ? Uri.decodeComponent(parsedUri.pathSegments.last)
              : 'audio_${candidates.length}';
          candidates.add(
            _DebridCandidate(
              entry: AudioFileEntry.fromPathAndSize(
                index: candidates.length,
                path: name,
                size: 0,
              ),
              rawRef: item.trim(),
            ),
          );
        } else if (item is Map) {
          final url = item['url']?.toString().trim() ?? '';
          if (url.isEmpty) continue;
          final name = item['fileName']?.toString().isNotEmpty == true
              ? item['fileName'].toString()
              : (Uri.tryParse(url)?.pathSegments.lastOrNull ??
                  'audio_${candidates.length}');
          final size = (item['fileSize'] as num? ?? item['size'] as num?)
                  ?.toInt() ??
              0;
          candidates.add(
            _DebridCandidate(
              entry: AudioFileEntry.fromPathAndSize(
                index: candidates.length,
                path: name,
                size: size,
              ),
              rawRef: url,
            ),
          );
        }
      }
    }

    if (candidates.isEmpty) {
      final singleUrl = statusObj['url']?.toString().trim() ?? '';
      if (singleUrl.isNotEmpty) {
        final name = statusObj['fileName']?.toString().isNotEmpty == true
            ? statusObj['fileName'].toString()
            : (Uri.tryParse(singleUrl)?.pathSegments.lastOrNull ?? 'audio_0');
        final size = (statusObj['fileSize'] as num?)?.toInt() ?? 0;
        candidates.add(
          _DebridCandidate(
            entry: AudioFileEntry.fromPathAndSize(
              index: 0,
              path: name,
              size: size,
            ),
            rawRef: singleUrl,
          ),
        );
      }
    }

    final selected = _pickCandidate(
      candidates,
      provider: DebridProvider.offcloud,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    return _buildResolvedFile(
      provider: DebridProvider.offcloud,
      directUrl: selected.rawRef,
      selected: selected.entry,
      allCandidates: candidates,
      infoHash: infoHash,
    );
  }

  void _checkOffcloudError(Map<String, dynamic> map) {
    if (map['error'] != null) {
      throw DebridException(
        map['error'].toString(),
        provider: DebridProvider.offcloud,
      );
    }
    if (map['not_available'] != null) {
      throw DebridException(
        'Offcloud unavailable: ${map['not_available']}',
        provider: DebridProvider.offcloud,
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. PREMIUMIZE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<DebridValidationResult> _validatePremiumize(String apiKey) async {
    final base = _baseUrlFor(DebridProvider.premiumize);
    final res = await _requestJson(
      DebridProvider.premiumize,
      'GET',
      '$base/account/info',
      headers: _bearerHeaders(apiKey),
    );
    final map = _asMap(res.body, DebridProvider.premiumize);
    if (res.statusCode >= 400 || map['status'] != 'success') {
      return DebridValidationResult(
        provider: DebridProvider.premiumize,
        isValid: false,
        message: map['message']?.toString() ??
            'Invalid Premiumize API key (HTTP ${res.statusCode}).',
      );
    }

    final customerId = map['customer_id']?.toString();
    final premiumUntil = (map['premium_until'] as num?)?.toDouble();
    final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final isPremium = premiumUntil != null ? premiumUntil > nowSec : null;
    return DebridValidationResult(
      provider: DebridProvider.premiumize,
      isValid: true,
      username: customerId != null ? 'ID $customerId' : null,
      isPremium: isPremium,
      message: customerId != null
          ? 'Connected (Customer #$customerId)'
          : 'Premiumize API key is valid.',
    );
  }

  Future<DebridResolvedFile> _resolvePremiumize({
    required String apiKey,
    required String magnetUri,
    required String infoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final base = _baseUrlFor(DebridProvider.premiumize);
    final headers = _bearerHeaders(apiKey);

    // 1. Try instant / directdl endpoint first
    final directRes = await _requestJson(
      DebridProvider.premiumize,
      'POST',
      '$base/transfer/directdl',
      headers: headers,
      formBody: {'src': magnetUri},
    );
    final directMap = _asMap(directRes.body, DebridProvider.premiumize);
    if (directRes.statusCode >= 400 || directMap['status'] == 'error') {
      final code = directMap['code']?.toString() ?? '';
      if (code == 'authentication_failed') {
        throw DebridException(
          directMap['message']?.toString() ?? 'Premiumize authentication failed.',
          provider: DebridProvider.premiumize,
        );
      }
    }

    final candidates = <_DebridCandidate>[];
    if (directMap['status'] == 'success' && directMap['content'] is List) {
      for (final item in (directMap['content'] as List)) {
        if (item is! Map) continue;
        final link =
            (item['link'] ?? item['stream_link'])?.toString().trim() ?? '';
        final path = item['path']?.toString() ?? '';
        if (link.isEmpty || path.isEmpty) continue;
        final size = (item['size'] as num?)?.toInt() ?? 0;
        candidates.add(
          _DebridCandidate(
            entry: AudioFileEntry.fromPathAndSize(
              index: candidates.length,
              path: path,
              size: size,
            ),
            rawRef: link,
          ),
        );
      }
    }

    if (candidates.isEmpty) {
      // 2. Fall back to transfer/create + folder/item lookup
      final createRes = await _requestJson(
        DebridProvider.premiumize,
        'POST',
        '$base/transfer/create',
        headers: headers,
        formBody: {'src': magnetUri},
      );
      final createMap = _asMap(createRes.body, DebridProvider.premiumize);
      if (createRes.statusCode >= 400 || createMap['status'] != 'success') {
        throw DebridException(
          createMap['message']?.toString() ??
              'Premiumize transfer creation failed.',
          provider: DebridProvider.premiumize,
        );
      }
      final transferId = createMap['id']?.toString() ?? '';
      if (transferId.isEmpty) {
        throw const DebridException(
          'Premiumize returned no transfer ID.',
          provider: DebridProvider.premiumize,
        );
      }

      String? folderId;
      String? fileId;
      final deadline = DateTime.now().add(_resolveTimeout);

      while (folderId == null && fileId == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw const DebridException(
            'Timed out waiting for Premiumize transfer.',
            provider: DebridProvider.premiumize,
          );
        }
        await Future<void>.delayed(_pollInterval);
        final listRes = await _requestJson(
          DebridProvider.premiumize,
          'GET',
          '$base/transfer/list',
          headers: headers,
        );
        final listMap = _asMap(listRes.body, DebridProvider.premiumize);
        if (listMap['status'] != 'success') {
          throw DebridException(
            listMap['message']?.toString() ?? 'Premiumize transfer list failed.',
            provider: DebridProvider.premiumize,
          );
        }
        final transfers = listMap['transfers'];
        if (transfers is! List) continue;
        final match = transfers.cast<dynamic>().firstWhere(
              (t) => t is Map && t['id']?.toString() == transferId,
              orElse: () => null,
            );
        if (match is! Map) continue;
        final status = (match['status']?.toString() ?? '').toLowerCase();
        if (status == 'error' || status == 'banned' || status == 'deleted') {
          throw DebridException(
            match['message']?.toString() ?? 'Premiumize transfer $status.',
            provider: DebridProvider.premiumize,
          );
        }
        if (status == 'finished' || status == 'seeding') {
          folderId = match['folder_id']?.toString();
          fileId = match['file_id']?.toString();
          if (folderId != null && folderId.isEmpty) folderId = null;
          if (fileId != null && fileId.isEmpty) fileId = null;
          if (folderId == null && fileId == null) {
            throw const DebridException(
              'Premiumize transfer finished with no folder or file ID.',
              provider: DebridProvider.premiumize,
            );
          }
        }
      }

      if (fileId != null) {
        final itemRes = await _requestJson(
          DebridProvider.premiumize,
          'GET',
          '$base/item/details?id=${Uri.encodeQueryComponent(fileId)}',
          headers: headers,
        );
        final itemMap = _asMap(itemRes.body, DebridProvider.premiumize);
        if (itemMap['status'] == 'error') {
          throw DebridException(
            itemMap['message']?.toString() ?? 'Premiumize item lookup failed.',
            provider: DebridProvider.premiumize,
          );
        }
        final link = (itemMap['link'] ?? itemMap['stream_link'])
                ?.toString()
                .trim() ??
            '';
        if (link.isNotEmpty) {
          candidates.add(
            _DebridCandidate(
              entry: AudioFileEntry.fromPathAndSize(
                index: 0,
                path: itemMap['name']?.toString() ?? 'audio_0',
                size: (itemMap['size'] as num?)?.toInt() ?? 0,
              ),
              rawRef: link,
            ),
          );
        }
      } else if (folderId != null) {
        await _collectPremiumizeFolder(
          base: base,
          headers: headers,
          folderId: folderId,
          prefix: '',
          out: candidates,
        );
      }
    }

    final selected = _pickCandidate(
      candidates,
      provider: DebridProvider.premiumize,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    return _buildResolvedFile(
      provider: DebridProvider.premiumize,
      directUrl: selected.rawRef,
      selected: selected.entry,
      allCandidates: candidates,
      infoHash: infoHash,
    );
  }

  Future<void> _collectPremiumizeFolder({
    required String base,
    required Map<String, String> headers,
    required String folderId,
    required String prefix,
    required List<_DebridCandidate> out,
  }) async {
    final res = await _requestJson(
      DebridProvider.premiumize,
      'GET',
      '$base/folder/list?id=${Uri.encodeQueryComponent(folderId)}',
      headers: headers,
    );
    final map = _asMap(res.body, DebridProvider.premiumize);
    if (map['status'] != 'success') return;
    final content = map['content'];
    if (content is! List) return;
    for (final item in content) {
      if (item is! Map) continue;
      final name = item['name']?.toString() ?? '';
      final fullPath = prefix.isEmpty ? name : '$prefix/$name';
      final type = item['type']?.toString() ?? '';
      if (type == 'folder') {
        final subId = item['id']?.toString() ?? '';
        if (subId.isNotEmpty) {
          await _collectPremiumizeFolder(
            base: base,
            headers: headers,
            folderId: subId,
            prefix: fullPath,
            out: out,
          );
        }
      } else if (type == 'file') {
        final link =
            (item['link'] ?? item['stream_link'])?.toString().trim() ?? '';
        if (link.isEmpty) continue;
        final size = (item['size'] as num?)?.toInt() ?? 0;
        out.add(
          _DebridCandidate(
            entry: AudioFileEntry.fromPathAndSize(
              index: out.length,
              path: fullPath,
              size: size,
            ),
            rawRef: link,
          ),
        );
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 5. REAL-DEBRID
  // ═══════════════════════════════════════════════════════════════════════════

  Future<DebridValidationResult> _validateRealDebrid(String apiKey) async {
    final base = _baseUrlFor(DebridProvider.realdebrid);
    final res = await _requestJson(
      DebridProvider.realdebrid,
      'GET',
      '$base/user',
      headers: _bearerHeaders(apiKey),
    );
    final map = _asMap(res.body, DebridProvider.realdebrid);
    if (res.statusCode >= 400 || map.containsKey('error')) {
      return DebridValidationResult(
        provider: DebridProvider.realdebrid,
        isValid: false,
        message: map['error']?.toString() ??
            'Invalid Real-Debrid API key (HTTP ${res.statusCode}).',
      );
    }

    final username =
        map['username']?.toString() ?? map['email']?.toString();
    final type = (map['type']?.toString() ?? '').toLowerCase();
    final isPremium = type == 'premium' || ((map['premium'] as num?)?.toInt() ?? 0) > 0;
    return DebridValidationResult(
      provider: DebridProvider.realdebrid,
      isValid: true,
      username: username,
      isPremium: isPremium,
      message: username != null && username.isNotEmpty
          ? 'Connected as $username (${isPremium ? "Premium" : "Free"})'
          : 'Real-Debrid API key is valid.',
    );
  }

  Future<DebridResolvedFile> _resolveRealDebrid({
    required String apiKey,
    required String magnetUri,
    required String infoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final base = _baseUrlFor(DebridProvider.realdebrid);
    final headers = _bearerHeaders(apiKey);

    final addRes = await _requestJson(
      DebridProvider.realdebrid,
      'POST',
      '$base/torrents/addMagnet',
      headers: headers,
      formBody: {'magnet': magnetUri},
    );
    final addMap = _asMap(addRes.body, DebridProvider.realdebrid);
    if (addRes.statusCode >= 400 || addMap.containsKey('error')) {
      throw DebridException(
        addMap['error']?.toString() ??
            'Real-Debrid addMagnet failed (HTTP ${addRes.statusCode}).',
        statusCode: addRes.statusCode,
        provider: DebridProvider.realdebrid,
      );
    }
    final torrentId = addMap['id']?.toString() ?? '';
    if (torrentId.isEmpty) {
      throw const DebridException(
        'Real-Debrid returned no torrent ID.',
        provider: DebridProvider.realdebrid,
      );
    }

    Map<String, dynamic> infoMap = await _fetchRealDebridInfo(
      base: base,
      headers: headers,
      torrentId: torrentId,
    );

    final deadline = DateTime.now().add(_resolveTimeout);
    while ((infoMap['files'] is! List || (infoMap['files'] as List).isEmpty)) {
      final st = (infoMap['status']?.toString() ?? '').toLowerCase();
      if (_isRealDebridFatalStatus(st)) {
        throw DebridException(
          'Real-Debrid torrent failed ($st).',
          provider: DebridProvider.realdebrid,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const DebridException(
          'Timed out waiting for Real-Debrid torrent metadata.',
          provider: DebridProvider.realdebrid,
        );
      }
      await Future<void>.delayed(_pollInterval);
      infoMap = await _fetchRealDebridInfo(
        base: base,
        headers: headers,
        torrentId: torrentId,
      );
    }

    final rawFiles = (infoMap['files'] as List).cast<dynamic>();
    final rdCandidates = <_DebridCandidate>[];
    for (var i = 0; i < rawFiles.length; i++) {
      final f = _asOptionalMap(rawFiles[i]);
      if (f == null) continue;
      final rdFileId = f['id']?.toString() ?? '${i + 1}';
      final path = f['path']?.toString() ?? 'file_$i';
      final size = (f['bytes'] as num?)?.toInt() ?? 0;
      rdCandidates.add(
        _DebridCandidate(
          entry: AudioFileEntry.fromPathAndSize(
            index: i,
            path: path,
            size: size,
          ),
          rawRef: rdFileId,
        ),
      );
    }

    final selected = _pickCandidate(
      rdCandidates,
      provider: DebridProvider.realdebrid,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    if ((infoMap['status']?.toString() ?? '').toLowerCase() ==
        'waiting_files_selection') {
      final selRes = await _requestJson(
        DebridProvider.realdebrid,
        'POST',
        '$base/torrents/selectFiles/$torrentId',
        headers: headers,
        formBody: {'files': selected.rawRef},
        throwOnInvalidJson: false,
      );
      if (selRes.statusCode >= 400) {
        final err = selRes.body is Map ? selRes.body['error']?.toString() : null;
        throw DebridException(
          err ?? 'Real-Debrid selectFiles failed (HTTP ${selRes.statusCode}).',
          statusCode: selRes.statusCode,
          provider: DebridProvider.realdebrid,
        );
      }
      infoMap = await _fetchRealDebridInfo(
        base: base,
        headers: headers,
        torrentId: torrentId,
      );
    }

    while ((infoMap['status']?.toString() ?? '').toLowerCase() != 'downloaded' ||
        (infoMap['links'] is! List) ||
        (infoMap['links'] as List).isEmpty) {
      final st = (infoMap['status']?.toString() ?? '').toLowerCase();
      if (_isRealDebridFatalStatus(st)) {
        throw DebridException(
          'Real-Debrid torrent error ($st).',
          provider: DebridProvider.realdebrid,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const DebridException(
          'Timed out waiting for Real-Debrid download.',
          provider: DebridProvider.realdebrid,
        );
      }
      await Future<void>.delayed(_pollInterval);
      infoMap = await _fetchRealDebridInfo(
        base: base,
        headers: headers,
        torrentId: torrentId,
      );
    }

    final links = (infoMap['links'] as List).map((e) => e.toString()).toList();
    String targetHostLink = links.first;

    // Match the ordinal position of selected file among selected==1 files
    if (links.length > 1 && infoMap['files'] is List) {
      var selectedOrdinal = 0;
      for (final item in (infoMap['files'] as List)) {
        if (item is! Map) continue;
        final isSel = (item['selected'] as num?)?.toInt() == 1;
        if (!isSel) continue;
        if (item['id']?.toString() == selected.rawRef) {
          if (selectedOrdinal < links.length) {
            targetHostLink = links[selectedOrdinal];
          }
          break;
        }
        selectedOrdinal++;
      }
    }

    final unrestrictRes = await _requestJson(
      DebridProvider.realdebrid,
      'POST',
      '$base/unrestrict/link',
      headers: headers,
      formBody: {'link': targetHostLink},
    );
    final unrestrictMap = _asMap(unrestrictRes.body, DebridProvider.realdebrid);
    if (unrestrictRes.statusCode >= 400 || unrestrictMap.containsKey('error')) {
      throw DebridException(
        unrestrictMap['error']?.toString() ??
            'Real-Debrid unrestrict failed (HTTP ${unrestrictRes.statusCode}).',
        statusCode: unrestrictRes.statusCode,
        provider: DebridProvider.realdebrid,
      );
    }

    final directUrl = unrestrictMap['download']?.toString().trim() ?? '';
    if (directUrl.isEmpty) {
      throw const DebridException(
        'Real-Debrid unrestrict returned empty download URL.',
        provider: DebridProvider.realdebrid,
      );
    }

    final unrestrictedSize = (unrestrictMap['filesize'] as num?)?.toInt() ?? 0;
    return _buildResolvedFile(
      provider: DebridProvider.realdebrid,
      directUrl: directUrl,
      selected: selected.entry,
      allCandidates: rdCandidates,
      infoHash: infoHash,
      overrideSize: unrestrictedSize > 0 ? unrestrictedSize : null,
    );
  }

  Future<Map<String, dynamic>> _fetchRealDebridInfo({
    required String base,
    required Map<String, String> headers,
    required String torrentId,
  }) async {
    final res = await _requestJson(
      DebridProvider.realdebrid,
      'GET',
      '$base/torrents/info/$torrentId',
      headers: headers,
    );
    final map = _asMap(res.body, DebridProvider.realdebrid);
    if (res.statusCode >= 400 || map.containsKey('error')) {
      throw DebridException(
        map['error']?.toString() ??
            'Real-Debrid torrents/info failed (HTTP ${res.statusCode}).',
        statusCode: res.statusCode,
        provider: DebridProvider.realdebrid,
      );
    }
    return map;
  }

  bool _isRealDebridFatalStatus(String status) {
    return status == 'magnet_error' ||
        status == 'error' ||
        status == 'virus' ||
        status == 'dead';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 6. TORBOX
  // ═══════════════════════════════════════════════════════════════════════════

  Future<DebridValidationResult> _validateTorBox(String apiKey) async {
    final base = _baseUrlFor(DebridProvider.torbox);
    final res = await _requestJson(
      DebridProvider.torbox,
      'GET',
      '$base/user/me',
      headers: _bearerHeaders(apiKey),
    );
    final map = _asMap(res.body, DebridProvider.torbox);
    if (res.statusCode >= 400 || map['success'] != true) {
      return DebridValidationResult(
        provider: DebridProvider.torbox,
        isValid: false,
        message: map['detail']?.toString() ??
            map['error']?.toString() ??
            'Invalid TorBox API key (HTTP ${res.statusCode}).',
      );
    }

    final data = _asOptionalMap(map['data']);
    final email = data?['email']?.toString();
    final plan = (data?['plan'] as num?)?.toInt();
    final isPremium = plan != null ? plan > 0 : null;
    return DebridValidationResult(
      provider: DebridProvider.torbox,
      isValid: true,
      username: email,
      isPremium: isPremium,
      message: email != null && email.isNotEmpty
          ? 'Connected as $email'
          : 'TorBox API key is valid.',
    );
  }

  Future<DebridResolvedFile> _resolveTorBox({
    required String apiKey,
    required String magnetUri,
    required String infoHash,
    String? filePath,
    int? fileIndex,
  }) async {
    final base = _baseUrlFor(DebridProvider.torbox);
    final headers = _bearerHeaders(apiKey);

    final createRes = await _requestJson(
      DebridProvider.torbox,
      'POST',
      '$base/torrents/createtorrent',
      headers: headers,
      multipartFields: {'magnet': magnetUri},
    );
    final createMap = _asMap(createRes.body, DebridProvider.torbox);
    if (createRes.statusCode >= 400 || createMap['success'] != true) {
      throw DebridException(
        createMap['detail']?.toString() ??
            createMap['error']?.toString() ??
            'TorBox createtorrent failed (HTTP ${createRes.statusCode}).',
        statusCode: createRes.statusCode,
        provider: DebridProvider.torbox,
      );
    }

    final data = _asMap(createMap['data'], DebridProvider.torbox);
    final torrentId = data['torrent_id']?.toString() ?? '';
    if (torrentId.isEmpty) {
      throw const DebridException(
        'TorBox returned no torrent_id.',
        provider: DebridProvider.torbox,
      );
    }

    Map<String, dynamic>? torrentObj;
    final deadline = DateTime.now().add(_resolveTimeout);

    while (true) {
      final listRes = await _requestJson(
        DebridProvider.torbox,
        'GET',
        '$base/torrents/mylist?id=${Uri.encodeQueryComponent(torrentId)}',
        headers: headers,
      );
      final listMap = _asMap(listRes.body, DebridProvider.torbox);
      if (listRes.statusCode >= 400 || listMap['success'] != true) {
        throw DebridException(
          listMap['detail']?.toString() ??
              listMap['error']?.toString() ??
              'TorBox mylist failed.',
          statusCode: listRes.statusCode,
          provider: DebridProvider.torbox,
        );
      }

      final rawData = listMap['data'];
      if (rawData is Map<String, dynamic>) {
        torrentObj = rawData;
      } else if (rawData is List && rawData.isNotEmpty) {
        final found = rawData.cast<dynamic>().firstWhere(
              (item) => item is Map && item['id']?.toString() == torrentId,
              orElse: () => rawData.first,
            );
        if (found is Map) {
          torrentObj = Map<String, dynamic>.from(found);
        }
      }

      final isPresent = torrentObj?['download_present'] == true ||
          torrentObj?['download_finished'] == true;
      final hasFiles = torrentObj?['files'] is List &&
          (torrentObj!['files'] as List).isNotEmpty;
      if (isPresent && hasFiles) {
        break;
      }

      final state =
          (torrentObj?['download_state']?.toString() ?? '').toLowerCase();
      if (state == 'error' || state == 'reported') {
        throw DebridException(
          'TorBox download failed ($state).',
          provider: DebridProvider.torbox,
        );
      }

      if (DateTime.now().isAfter(deadline)) {
        throw const DebridException(
          'Timed out waiting for TorBox torrent download.',
          provider: DebridProvider.torbox,
        );
      }
      await Future<void>.delayed(_pollInterval);
    }

    final rawFiles = (torrentObj['files'] as List).cast<dynamic>();
    final candidates = <_DebridCandidate>[];
    for (var i = 0; i < rawFiles.length; i++) {
      final f = _asOptionalMap(rawFiles[i]);
      if (f == null) continue;
      final fid = f['id']?.toString() ?? '$i';
      final path = (f['name'] ?? f['short_name'])?.toString() ?? 'file_$i';
      final size = (f['size'] as num?)?.toInt() ?? 0;
      candidates.add(
        _DebridCandidate(
          entry: AudioFileEntry.fromPathAndSize(
            index: i,
            path: path,
            size: size,
          ),
          rawRef: fid,
        ),
      );
    }

    final selected = _pickCandidate(
      candidates,
      provider: DebridProvider.torbox,
      filePath: filePath,
      fileIndex: fileIndex,
    );

    final dlRes = await _requestJson(
      DebridProvider.torbox,
      'GET',
      '$base/torrents/requestdl'
      '?token=${Uri.encodeQueryComponent(apiKey)}'
      '&torrent_id=${Uri.encodeQueryComponent(torrentId)}'
      '&file_id=${Uri.encodeQueryComponent(selected.rawRef)}'
      '&redirect=false',
      headers: headers,
    );
    final dlMap = _asMap(dlRes.body, DebridProvider.torbox);
    if (dlRes.statusCode >= 400 || dlMap['success'] != true) {
      throw DebridException(
        dlMap['detail']?.toString() ??
            dlMap['error']?.toString() ??
            'TorBox requestdl failed (HTTP ${dlRes.statusCode}).',
        statusCode: dlRes.statusCode,
        provider: DebridProvider.torbox,
      );
    }

    final directUrl = dlMap['data']?.toString().trim() ?? '';
    if (directUrl.isEmpty) {
      throw const DebridException(
        'TorBox requestdl returned empty download URL.',
        provider: DebridProvider.torbox,
      );
    }

    return _buildResolvedFile(
      provider: DebridProvider.torbox,
      directUrl: directUrl,
      selected: selected.entry,
      allCandidates: candidates,
      infoHash: infoHash,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED SELECTION & HTTP HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  _DebridCandidate _pickCandidate(
    List<_DebridCandidate> candidates, {
    required DebridProvider provider,
    String? filePath,
    int? fileIndex,
  }) {
    if (candidates.isEmpty) {
      throw DebridException(
        'No downloadable files found on ${provider.displayName}.',
        provider: provider,
      );
    }

    final entries = candidates.map((c) => c.entry).toList();
    final chosen = TorrentEngineService.selectAudioFile(
      entries,
      filePath: filePath,
      fileIndex: fileIndex,
    );
    return candidates.firstWhere(
      (c) => c.entry.index == chosen.index,
      orElse: () => candidates.first,
    );
  }

  DebridResolvedFile _buildResolvedFile({
    required DebridProvider provider,
    required String directUrl,
    required AudioFileEntry selected,
    required List<_DebridCandidate> allCandidates,
    required String infoHash,
    int? overrideSize,
  }) {
    return DebridResolvedFile(
      provider: provider,
      directUrl: directUrl,
      fileName: selected.name,
      filePath: selected.path,
      fileSize: overrideSize ?? selected.size,
      mimeType: selected.mimeType,
      infoHash: infoHash,
      fileIndex: selected.index,
      availableAudioFiles: allCandidates
          .map((c) => c.entry)
          .where((e) => e.isAudioFile)
          .toList(),
    );
  }

  Future<int> _probeContentLength(String url) async {
    final client = _httpClientFactory();
    try {
      final req = await client.openUrl('HEAD', Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 6));
      await res.drain<void>();
      return math.max(0, res.contentLength);
    } catch (_) {
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, String> _bearerHeaders(String apiKey) => {
        HttpHeaders.authorizationHeader: 'Bearer $apiKey',
      };

  Future<_HttpJsonResponse> _requestJson(
    DebridProvider provider,
    String method,
    String url, {
    Map<String, String>? headers,
    Map<String, String>? formBody,
    Map<String, dynamic>? jsonBody,
    Map<String, String>? multipartFields,
    bool throwOnInvalidJson = true,
  }) async {
    final client = _httpClientFactory();
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      req.followRedirects = true;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      headers?.forEach(req.headers.set);

      if (multipartFields != null) {
        final boundary =
            '----TorrentBridge${DateTime.now().microsecondsSinceEpoch}';
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary',
        );
        final buf = StringBuffer();
        multipartFields.forEach((key, value) {
          buf.write('--$boundary\r\n');
          buf.write('Content-Disposition: form-data; name="$key"\r\n\r\n');
          buf.write('$value\r\n');
        });
        buf.write('--$boundary--\r\n');
        req.add(utf8.encode(buf.toString()));
      } else if (jsonBody != null) {
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        req.add(utf8.encode(jsonEncode(jsonBody)));
      } else if (formBody != null) {
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded',
        );
        final encoded = formBody.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&');
        req.add(utf8.encode(encoded));
      }

      final res = await req.close().timeout(const Duration(seconds: 25));
      final rawBody = await utf8.decoder.bind(res).join();
      dynamic decoded;
      if (rawBody.trim().isNotEmpty) {
        try {
          decoded = jsonDecode(rawBody);
        } catch (e) {
          if (throwOnInvalidJson) {
            throw DebridException(
              'Invalid JSON response from ${provider.displayName} (HTTP ${res.statusCode}).',
              statusCode: res.statusCode,
              provider: provider,
            );
          }
          decoded = rawBody;
        }
      }
      return _HttpJsonResponse(statusCode: res.statusCode, body: decoded);
    } on DebridException {
      rethrow;
    } on TimeoutException {
      throw DebridException(
        '${provider.displayName} request timed out.',
        provider: provider,
      );
    } catch (e) {
      throw DebridException(
        '${provider.displayName} connection failed: $e',
        provider: provider,
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _asMap(dynamic value, DebridProvider provider) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    throw DebridException(
      'Unexpected response format from ${provider.displayName}.',
      provider: provider,
    );
  }

  Map<String, dynamic>? _asOptionalMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  String? _nestedString(Map<String, dynamic> map, List<String> path) {
    dynamic cur = map;
    for (final key in path) {
      if (cur is Map && cur.containsKey(key)) {
        cur = cur[key];
      } else {
        return null;
      }
    }
    final str = cur?.toString().trim();
    return (str == null || str.isEmpty) ? null : str;
  }
}

class _DebridCandidate {
  final AudioFileEntry entry;
  final String rawRef;

  const _DebridCandidate({
    required this.entry,
    required this.rawRef,
  });
}

class _HttpJsonResponse {
  final int statusCode;
  final dynamic body;

  const _HttpJsonResponse({
    required this.statusCode,
    required this.body,
  });
}
