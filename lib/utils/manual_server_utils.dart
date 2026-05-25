import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../profiles/active_profile_binder.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../profiles/profile_connection.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_registry.dart';
import '../services/plex_auth_service.dart';
import '../services/storage_service.dart';
import 'app_logger.dart';

class ManualServerUtils {
  const ManualServerUtils._();

  static ({String protocol, String address, int port, String uri})? parseServerUrl(String url) {
    try {
      var normalizedUrl = url;
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        normalizedUrl = 'http://$url';
      }

      final uri = Uri.parse(normalizedUrl);
      final protocol = uri.scheme.toLowerCase();
      if (uri.host.isEmpty || (protocol != 'http' && protocol != 'https')) {
        return null;
      }

      final port = uri.hasPort ? uri.port : (protocol == 'https' ? 443 : 80);
      final connectionUri = Uri(scheme: protocol, host: uri.host, port: port).toString();

      return (protocol: protocol, address: uri.host, port: port, uri: connectionUri);
    } catch (error) {
      appLogger.w('Failed to parse manual Plex server URL', error: error);
      return null;
    }
  }

  static String generateServerId() {
    return 'manual_${DateTime.now().microsecondsSinceEpoch}';
  }

  static Future<({bool connected, bool cancelled, String? error})> addManualServer({
    required String url,
    required String displayName,
    required String token,
    required ConnectionRegistry connectionRegistry,
    required ProfileRegistry profileRegistry,
    required ProfileConnectionRegistry profileConnectionRegistry,
    required ActiveProfileProvider activeProfiles,
    required ActiveProfileBinder activeProfileBinder,
    required bool Function() shouldCancelConnection,
    bool enableGuestMode = true,
  }) async {
    if (url.isEmpty) {
      return (connected: false, cancelled: false, error: 'Please enter a server URL');
    }

    final parsed = parseServerUrl(url);
    if (parsed == null) {
      return (connected: false, cancelled: false, error: 'Invalid server URL format');
    }

    final storage = await StorageService.getInstance();
    if (enableGuestMode) {
      await storage.setGuestModeEnabled(true);
    }
    final clientIdentifier = await storage.getOrCreateClientIdentifier();
    final serverName = displayName.isNotEmpty ? displayName : 'Local Server';
    final manualId = generateServerId();
    final now = DateTime.now();

    final connection = PlexConnection(
      protocol: parsed.protocol,
      address: parsed.address,
      port: parsed.port,
      uri: parsed.uri,
      local: true,
      relay: false,
      ipv6: parsed.address.contains(':'),
    );
    final server = PlexServer(
      name: serverName,
      clientIdentifier: manualId,
      accessToken: token,
      connections: [connection],
      owned: false,
      presence: false,
    );
    final accountConnection = PlexAccountConnection(
      id: '$manualPlexIdPrefix$manualId',
      accountToken: '',
      clientIdentifier: clientIdentifier,
      accountLabel: serverName,
      servers: [server],
      createdAt: now,
      lastAuthenticatedAt: now,
    );
    final profile = Profile.local(
      id: 'local.$manualId',
      displayName: serverName,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
    );

    await connectionRegistry.upsert(accountConnection);
    await profileRegistry.upsert(profile);
    await profileConnectionRegistry.upsert(
      ProfileConnection(profileId: profile.id, connectionId: accountConnection.id, userIdentifier: manualId),
      makeDefault: true,
    );

    if (shouldCancelConnection()) {
      return (connected: false, cancelled: true, error: null);
    }

    await activeProfiles.reloadFromStorage();
    final activated = await activeProfiles.activate(profile);
    if (!activated) {
      return (connected: false, cancelled: false, error: null);
    }

    await activeProfileBinder.rebindActive();
    final connected = await activeProfiles.awaitBindingSettle();

    if (shouldCancelConnection()) {
      return (connected: false, cancelled: true, error: null);
    }

    return (connected: connected, cancelled: false, error: null);
  }
}