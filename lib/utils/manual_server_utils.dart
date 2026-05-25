import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../i18n/strings.g.dart';
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

  static Future<void> _rollbackManualServerAttempt({
    required ConnectionRegistry connectionRegistry,
    required ProfileRegistry profileRegistry,
    required ProfileConnectionRegistry profileConnectionRegistry,
    required ActiveProfileProvider activeProfiles,
    required ActiveProfileBinder activeProfileBinder,
    required StorageService storage,
    required String connectionId,
    required String profileId,
    required String? previousActiveProfileId,
    required bool previousGuestModeEnabled,
  }) async {
    Future<void> tryCleanup(String label, Future<void> Function() cleanup) async {
      try {
        await cleanup();
      } catch (error, stackTrace) {
        appLogger.w('Manual server rollback failed while $label', error: error, stackTrace: stackTrace);
      }
    }

    await tryCleanup('removing profile connection', () => profileConnectionRegistry.remove(profileId, connectionId));
    await tryCleanup('removing profile', () => profileRegistry.remove(profileId));
    await tryCleanup('removing connection', () => connectionRegistry.remove(connectionId));

    await tryCleanup('restoring guest mode', () => storage.setGuestModeEnabled(previousGuestModeEnabled));
    if (previousActiveProfileId == null) {
      await tryCleanup('clearing active profile', storage.clearActiveProfileId);
    } else {
      await tryCleanup('restoring active profile', () => storage.setActiveProfileId(previousActiveProfileId));
    }

    await tryCleanup('reloading profiles', activeProfiles.reloadFromStorage);
    await tryCleanup('rebinding active profile', activeProfileBinder.rebindActive);
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
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerUrlRequired);
    }

    final parsed = parseServerUrl(url);
    if (parsed == null) {
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerUrlInvalid);
    }

    final storage = await StorageService.getInstance();
    final previousGuestModeEnabled = storage.isGuestModeEnabled();
    final previousActiveProfileId = storage.getActiveProfileId();
    final clientIdentifier = await storage.getOrCreateClientIdentifier();
    final serverName = displayName.isNotEmpty ? displayName : t.serverSelection.manualServerDefaultName;
    final manualId = generateServerId();
    final connectionId = '$manualPlexIdPrefix$manualId';
    final profileId = 'local.$manualId';
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
      id: connectionId,
      accountToken: '',
      clientIdentifier: clientIdentifier,
      accountLabel: serverName,
      servers: [server],
      createdAt: now,
      lastAuthenticatedAt: now,
    );
    final profile = Profile.local(
      id: profileId,
      displayName: serverName,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
    );

    Future<void> rollback() => _rollbackManualServerAttempt(
      connectionRegistry: connectionRegistry,
      profileRegistry: profileRegistry,
      profileConnectionRegistry: profileConnectionRegistry,
      activeProfiles: activeProfiles,
      activeProfileBinder: activeProfileBinder,
      storage: storage,
      connectionId: connectionId,
      profileId: profileId,
      previousActiveProfileId: previousActiveProfileId,
      previousGuestModeEnabled: previousGuestModeEnabled,
    );

    var persistedAttempt = false;
    try {
      await connectionRegistry.upsert(accountConnection);
      await profileRegistry.upsert(profile);
      await profileConnectionRegistry.upsert(
        ProfileConnection(profileId: profile.id, connectionId: accountConnection.id, userIdentifier: manualId),
        makeDefault: true,
      );
      persistedAttempt = true;

      if (shouldCancelConnection()) {
        await rollback();
        return (connected: false, cancelled: true, error: null);
      }

      await activeProfiles.reloadFromStorage();
      final activated = await activeProfiles.activate(profile);
      if (!activated) {
        await rollback();
        return (connected: false, cancelled: false, error: t.serverSelection.manualServerGenericFailure);
      }

      await activeProfileBinder.rebindActive();
      final connected = await activeProfiles.awaitBindingSettle();

      if (shouldCancelConnection()) {
        await rollback();
        return (connected: false, cancelled: true, error: null);
      }

      if (!connected) {
        await rollback();
        return (connected: false, cancelled: false, error: t.serverSelection.manualServerConnectionFailed);
      }

      if (enableGuestMode) {
        await storage.setGuestModeEnabled(true);
        await activeProfiles.reloadFromStorage();
      }

      return (connected: true, cancelled: false, error: null);
    } catch (error, stackTrace) {
      appLogger.e('Failed to add manual Plex server', error: error, stackTrace: stackTrace);
      await rollback();
      return (
        connected: false,
        cancelled: false,
        error: persistedAttempt
            ? t.serverSelection.manualServerGenericFailure
            : t.serverSelection.manualServerSaveFailed,
      );
    }
  }
}
