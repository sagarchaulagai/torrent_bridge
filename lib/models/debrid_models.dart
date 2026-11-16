import 'streaming_models.dart';

/// Supported Debrid providers for Torrent Bridge.
enum DebridProvider {
  none(
    id: 'none',
    displayName: 'None (Direct Torrent)',
    keyPortalHint: '',
  ),
  alldebrid(
    id: 'alldebrid',
    displayName: 'AllDebrid',
    keyPortalHint: 'alldebrid.com/apikeys',
  ),
  debridlink(
    id: 'debridlink',
    displayName: 'Debrid-Link',
    keyPortalHint: 'debrid-link.com/webapp/apikey',
  ),
  offcloud(
    id: 'offcloud',
    displayName: 'Offcloud',
    keyPortalHint: 'offcloud.com/#/account',
  ),
  premiumize(
    id: 'premiumize',
    displayName: 'Premiumize',
    keyPortalHint: 'premiumize.me/account',
  ),
  realdebrid(
    id: 'realdebrid',
    displayName: 'Real-Debrid',
    keyPortalHint: 'real-debrid.com/apitoken',
  ),
  torbox(
    id: 'torbox',
    displayName: 'TorBox',
    keyPortalHint: 'torbox.app/settings',
  );

  final String id;
  final String displayName;
  final String keyPortalHint;

  const DebridProvider({
    required this.id,
    required this.displayName,
    required this.keyPortalHint,
  });

  bool get isConfiguredProvider => this != DebridProvider.none;

  static List<DebridProvider> get selectableProviders => const [
        DebridProvider.none,
        DebridProvider.alldebrid,
        DebridProvider.debridlink,
        DebridProvider.offcloud,
        DebridProvider.premiumize,
        DebridProvider.realdebrid,
        DebridProvider.torbox,
      ];

  static DebridProvider fromId(String? raw) {
    if (raw == null) return DebridProvider.none;
    final normalized = raw
        .trim()
        .toLowerCase()
        .replaceAll('-', '')
        .replaceAll('_', '')
        .replaceAll(' ', '');
    for (final p in DebridProvider.values) {
      if (p.id == normalized || p.name == normalized) {
        return p;
      }
    }
    return DebridProvider.none;
  }
}

/// Result of validating a user's API key against a Debrid provider.
class DebridValidationResult {
  final DebridProvider provider;
  final bool isValid;
  final String message;
  final String? username;
  final bool? isPremium;
  final DateTime checkedAt;

  DebridValidationResult({
    required this.provider,
    required this.isValid,
    required this.message,
    this.username,
    this.isPremium,
    DateTime? checkedAt,
  }) : checkedAt = checkedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'provider': provider.id,
        'provider_name': provider.displayName,
        'is_valid': isValid,
        'message': message,
        'username': username,
        'is_premium': isPremium,
        'checked_at': checkedAt.toIso8601String(),
      };
}

/// Resolved direct HTTP stream file returned by a Debrid provider for a torrent.
class DebridResolvedFile {
  final DebridProvider provider;
  final String directUrl;
  final String fileName;
  final String filePath;
  final int fileSize;
  final String mimeType;
  final String infoHash;
  final int fileIndex;
  final List<AudioFileEntry> availableAudioFiles;

  const DebridResolvedFile({
    required this.provider,
    required this.directUrl,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.mimeType,
    required this.infoHash,
    required this.fileIndex,
    this.availableAudioFiles = const [],
  });

  String get formatLabel {
    final ext = AudioFileEntry.extractExtension(fileName);
    return ext.isEmpty ? 'AUDIO' : ext.substring(1).toUpperCase();
  }
}

/// Exception thrown when a Debrid API request or resolution fails.
class DebridException implements Exception {
  final String message;
  final int? statusCode;
  final DebridProvider? provider;

  const DebridException(
    this.message, {
    this.statusCode,
    this.provider,
  });

  @override
  String toString() =>
      provider != null ? '${provider!.displayName}: $message' : message;
}
