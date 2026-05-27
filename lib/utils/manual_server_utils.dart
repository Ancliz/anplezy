import 'dart:io' show InternetAddress;

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
import '../services/plex_client.dart';
import '../services/storage_service.dart';
import 'app_logger.dart';

const int plexDefaultPort = 32400;

typedef ManualServerConnectionVerifier =
    Future<ManualServerConnectionVerification> Function(PlexServer server, String clientIdentifier);
typedef ManualServerHostResolver = Future<Set<String>> Function(String host);

class ManualServerConnectionVerification {
  const ManualServerConnectionVerification({required this.connected, this.machineIdentifier});

  final bool connected;
  final String? machineIdentifier;
}

class ManualServerUtils {
  const ManualServerUtils._();

  static ({String protocol, String address, int port, String uri})? parseServerUrl(String url) {
    try {
      final trimmedUrl = url.trim();
      if (trimmedUrl.isEmpty) {
        return null;
      }

      final lowerTrimmedUrl = trimmedUrl.toLowerCase();
      final hasProtocol = lowerTrimmedUrl.startsWith('http://') || lowerTrimmedUrl.startsWith('https://');
      if (!hasProtocol && trimmedUrl.contains('://')) {
        return null;
      }

      final normalizedUrl = hasProtocol ? trimmedUrl : 'http://$trimmedUrl';
      final explicitPort = _explicitPortFromUrl(normalizedUrl);
      if (explicitPort.present && explicitPort.port == null) {
        return null;
      }

      final uri = Uri.tryParse(normalizedUrl);
      if (uri == null) {
        return null;
      }

      final protocol = uri.scheme.toLowerCase();
      if (uri.host.isEmpty || (protocol != 'http' && protocol != 'https')) {
        return null;
      }
      if (uri.userInfo.isNotEmpty || uri.path.isNotEmpty || uri.hasQuery || uri.hasFragment) {
        return null;
      }

      final port = explicitPort.port ?? plexDefaultPort;
      final connectionUri = _connectionUri(protocol: protocol, host: uri.host, port: port);

      return (protocol: protocol, address: uri.host, port: port, uri: connectionUri);
    } catch (error) {
      appLogger.w('Failed to parse manual Plex server URL', error: error);
      return null;
    }
  }

  static ({bool present, int? port}) _explicitPortFromUrl(String normalizedUrl) {
    final schemeIndex = normalizedUrl.indexOf('://');
    if (schemeIndex == -1) {
      return (present: false, port: null);
    }

    final authorityStart = schemeIndex + 3;
    final authorityEnd = normalizedUrl.indexOf(RegExp(r'[/#?]'), authorityStart);
    final authority = normalizedUrl.substring(authorityStart, authorityEnd == -1 ? normalizedUrl.length : authorityEnd);
    final hostPort = authority.split('@').last;
    String? portText;
    if (hostPort.startsWith('[')) {
      final bracketEnd = hostPort.indexOf(']');
      if (bracketEnd == -1) {
        return (present: true, port: null);
      }

      final remainder = hostPort.substring(bracketEnd + 1);
      if (remainder.isEmpty) {
        return (present: false, port: null);
      }
      if (!remainder.startsWith(':')) {
        return (present: true, port: null);
      }
      portText = remainder.substring(1);
    } else {
      final colonIndex = hostPort.lastIndexOf(':');
      if (colonIndex == -1) {
        return (present: false, port: null);
      }
      if (hostPort.indexOf(':') != colonIndex) {
        return (present: true, port: null);
      }
      portText = hostPort.substring(colonIndex + 1);
    }

    if (portText.isEmpty || !RegExp(r'^\d+$').hasMatch(portText)) {
      return (present: true, port: null);
    }

    final port = int.tryParse(portText);
    if (port == null || port <= 0 || port > 65535) {
      return (present: true, port: null);
    }

    return (present: true, port: port);
  }

  static String _connectionUri({required String protocol, required String host, required int port}) {
    final formattedHost = host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
    return '$protocol://$formattedHost:$port';
  }

  static String generateServerId() {
    return 'manual_${DateTime.now().microsecondsSinceEpoch}';
  }

  static Future<ManualServerConnectionVerification> _verifyManualServerConnection(
    PlexServer server,
    String clientIdentifier,
  ) async {
    try {
      final candidateUrls = server.prioritizedEndpointUrls();
      if (candidateUrls.isEmpty) {
        return const ManualServerConnectionVerification(connected: false);
      }

      for (final candidateUrl in candidateUrls) {
        final result = await PlexClient.testConnectionWithLatency(
          candidateUrl,
          server.accessToken,
          clientIdentifier: clientIdentifier,
          expectedMachineIdentifier: server.expectedMachineIdentifier,
        );
        if (result.success && result.identity != null) {
          return ManualServerConnectionVerification(
            connected: true,
            machineIdentifier: result.identity!.machineIdentifier,
          );
        }
      }
    } catch (error, stackTrace) {
      appLogger.w('Manual Plex server preflight failed', error: error, stackTrace: stackTrace);
    }
    return const ManualServerConnectionVerification(connected: false);
  }

  static Future<Set<String>> _resolveHostAddresses(String host) async {
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      return {_normalizeDuplicateHost(address.address)};
    }

    try {
      final addresses = await InternetAddress.lookup(host).timeout(const Duration(seconds: 2));
      return addresses.map((address) => _normalizeDuplicateHost(address.address)).toSet();
    } catch (error, stackTrace) {
      appLogger.w('Manual Plex server host resolution failed', error: error, stackTrace: stackTrace);
      return const {};
    }
  }

  static String _normalizeDuplicateHost(String host) {
    final trimmed = host.trim().toLowerCase();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  static Set<String> _normalizeResolvedHosts(Set<String> hosts) {
    return hosts.map(_normalizeDuplicateHost).where((host) => host.isNotEmpty).toSet();
  }

  static Future<String?> _localNetworkAddressForHost(String host, ManualServerHostResolver hostResolver) async {
    final normalizedHost = _normalizeDuplicateHost(host);
    if (PlexServer.isPrivateOrLocalHost(normalizedHost)) {
      return normalizedHost;
    }

    final resolvedHosts = _normalizeResolvedHosts(await hostResolver(normalizedHost));
    for (final resolvedHost in resolvedHosts) {
      if (PlexServer.isPrivateOrLocalHost(resolvedHost)) {
        return resolvedHost;
      }
    }
    return null;
  }

  static Future<bool> _manualEndpointAlreadyExists({
    required ConnectionRegistry connectionRegistry,
    required PlexConnection candidate,
    required ManualServerHostResolver hostResolver,
  }) async {
    final candidateHost = _normalizeDuplicateHost(candidate.address);
    final storedConnections = await connectionRegistry.list();
    final existingEndpoints = <PlexConnection>[];
    for (final storedConnection in storedConnections.whereType<PlexAccountConnection>().where(
      (connection) => connection.isManual,
    )) {
      for (final server in storedConnection.servers) {
        for (final existing in server.connections) {
          if (existing.port != candidate.port) {
            continue;
          }

          final existingHost = _normalizeDuplicateHost(existing.address);
          if (existingHost == candidateHost) {
            return true;
          }
          existingEndpoints.add(existing);
        }
      }
    }

    if (existingEndpoints.isEmpty) {
      return false;
    }

    final candidateResolved = _normalizeResolvedHosts(await hostResolver(candidateHost));
    if (candidateResolved.isEmpty) {
      return false;
    }

    final resolvedCache = <String, Future<Set<String>>>{candidateHost: Future.value(candidateResolved)};

    Future<Set<String>> resolve(String host) {
      final normalizedHost = _normalizeDuplicateHost(host);
      return resolvedCache.putIfAbsent(
        normalizedHost,
        () async => _normalizeResolvedHosts(await hostResolver(normalizedHost)),
      );
    }

    for (final existing in existingEndpoints) {
      final existingHost = _normalizeDuplicateHost(existing.address);
      final existingResolved = await resolve(existingHost);
      if (existingResolved.intersection(candidateResolved).isNotEmpty) {
        return true;
      }
    }

    return false;
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
    required bool removeCreatedProfile,
    required bool restoreProfileState,
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
    if (removeCreatedProfile) {
      await tryCleanup('removing profile', () => profileRegistry.remove(profileId));
    }
    await tryCleanup('removing connection', () => connectionRegistry.remove(connectionId));

    if (restoreProfileState) {
      await tryCleanup('restoring guest mode', () => storage.setGuestModeEnabled(previousGuestModeEnabled));
      if (previousActiveProfileId == null) {
        await tryCleanup('clearing active profile', storage.clearActiveProfileId);
      } else {
        await tryCleanup('restoring active profile', () => storage.setActiveProfileId(previousActiveProfileId));
      }
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
    bool? createLocalProfile,
    bool requireLocalNetwork = false,
    ManualServerConnectionVerifier? connectionVerifier,
    ManualServerHostResolver? hostResolver,
  }) async {
    if (url.isEmpty) {
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerUrlRequired);
    }

    final parsed = parseServerUrl(url);
    if (parsed == null) {
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerUrlInvalid);
    }

    final effectiveHostResolver = hostResolver ?? _resolveHostAddresses;
    final localNetworkAddress = requireLocalNetwork
        ? await _localNetworkAddressForHost(parsed.address, effectiveHostResolver)
        : null;
    if (requireLocalNetwork && localNetworkAddress == null) {
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerLocalNetworkRequired);
    }
    if (shouldCancelConnection()) {
      return (connected: false, cancelled: true, error: null);
    }

    final storage = await StorageService.getInstance();
    final previousGuestModeEnabled = storage.isGuestModeEnabled();
    final previousActiveProfileId = storage.getActiveProfileId();
    final clientIdentifier = await storage.getOrCreateClientIdentifier();
    final serverName = displayName.isNotEmpty ? displayName : t.serverSelection.manualServerDefaultName;
    final manualId = generateServerId();
    final connectionId = '$manualPlexIdPrefix$manualId';
    final now = DateTime.now();
    // Guest setup owns a manual server through a new local profile; settings
    // usually adds it as an extra connection on the currently active profile.
    final shouldCreateLocalProfile = createLocalProfile ?? enableGuestMode;
    final connectionAddress = localNetworkAddress ?? parsed.address;

    final connection = PlexConnection(
      protocol: parsed.protocol,
      address: connectionAddress,
      port: parsed.port,
      uri: parsed.uri,
      local: true,
      relay: false,
      ipv6: connectionAddress.contains(':'),
    );
    final server = PlexServer(
      name: serverName,
      clientIdentifier: manualId,
      accessToken: token,
      connections: [connection],
      owned: false,
      presence: false,
    );
    final createdProfile = shouldCreateLocalProfile
        ? Profile.local(
            id: 'local.$manualId',
            displayName: serverName,
            sortOrder: now.millisecondsSinceEpoch,
            createdAt: now,
          )
        : null;

    if (!shouldCreateLocalProfile) {
      await activeProfiles.reloadFromStorage();
    }
    final targetProfile = createdProfile ?? activeProfiles.active;
    if (targetProfile == null) {
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerGenericFailure);
    }

    if (shouldCancelConnection()) {
      return (connected: false, cancelled: true, error: null);
    }

    final alreadyExists = await _manualEndpointAlreadyExists(
      connectionRegistry: connectionRegistry,
      candidate: connection,
      hostResolver: effectiveHostResolver,
    );
    if (shouldCancelConnection()) {
      return (connected: false, cancelled: true, error: null);
    }
    if (alreadyExists) {
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerAlreadyExists);
    }

    final verified = await (connectionVerifier ?? _verifyManualServerConnection)(server, clientIdentifier);
    if (shouldCancelConnection()) {
      return (connected: false, cancelled: true, error: null);
    }
    if (!verified.connected) {
      return (connected: false, cancelled: false, error: t.serverSelection.manualServerConnectionFailed);
    }

    final verifiedServer = PlexServer(
      name: server.name,
      clientIdentifier: server.clientIdentifier,
      accessToken: server.accessToken,
      machineIdentifier: verified.machineIdentifier,
      connections: server.connections,
      owned: server.owned,
      product: server.product,
      platform: server.platform,
      lastSeenAt: server.lastSeenAt,
      presence: server.presence,
    );
    final accountConnection = PlexAccountConnection(
      id: connectionId,
      accountToken: '',
      clientIdentifier: clientIdentifier,
      accountLabel: serverName,
      servers: [verifiedServer],
      createdAt: now,
      lastAuthenticatedAt: now,
    );

    Future<void> rollback() => _rollbackManualServerAttempt(
      connectionRegistry: connectionRegistry,
      profileRegistry: profileRegistry,
      profileConnectionRegistry: profileConnectionRegistry,
      activeProfiles: activeProfiles,
      activeProfileBinder: activeProfileBinder,
      storage: storage,
      connectionId: connectionId,
      profileId: targetProfile.id,
      removeCreatedProfile: createdProfile != null,
      restoreProfileState: createdProfile != null,
      previousActiveProfileId: previousActiveProfileId,
      previousGuestModeEnabled: previousGuestModeEnabled,
    );

    var persistedAttempt = false;
    try {
      await connectionRegistry.upsert(accountConnection);
      if (createdProfile != null) {
        await profileRegistry.upsert(createdProfile);
      }
      await profileConnectionRegistry.upsert(
        ProfileConnection(profileId: targetProfile.id, connectionId: accountConnection.id, userIdentifier: manualId),
        makeDefault: createdProfile != null,
      );
      persistedAttempt = true;

      if (shouldCancelConnection()) {
        await rollback();
        return (connected: false, cancelled: true, error: null);
      }

      await activeProfiles.reloadFromStorage();
      if (createdProfile != null) {
        final activated = await activeProfiles.activate(createdProfile);
        if (!activated) {
          await rollback();
          return (connected: false, cancelled: false, error: t.serverSelection.manualServerGenericFailure);
        }
      } else if (activeProfiles.active?.id != targetProfile.id) {
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
