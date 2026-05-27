import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/main.dart';
import 'package:plezy/screens/main_screen.dart';
import 'package:plezy/services/plex_auth_service.dart';

void main() {
  group('startup bind recovery', () {
    test('enters offline mode only when initial bind failed with no online servers', () {
      expect(shouldEnterOfflineModeAfterStartupBind(bindingSucceeded: false, hasOnlineServers: false), isTrue);
      expect(shouldEnterOfflineModeAfterStartupBind(bindingSucceeded: true, hasOnlineServers: false), isFalse);
      expect(shouldEnterOfflineModeAfterStartupBind(bindingSucceeded: false, hasOnlineServers: true), isFalse);
    });

    test('detects manual Plex server ids in startup connections', () {
      final manualConnection = PlexAccountConnection(
        id: '${manualPlexIdPrefix}one',
        accountToken: '',
        clientIdentifier: 'client-manual',
        accountLabel: 'Manual',
        servers: [
          PlexServer(
            name: 'Manual Server',
            clientIdentifier: 'manual-server',
            accessToken: '',
            connections: const [],
            owned: false,
          ),
        ],
        createdAt: DateTime(2026),
      );
      final accountConnection = PlexAccountConnection(
        id: 'plex.account.one',
        accountToken: 'token',
        clientIdentifier: 'client-account',
        accountLabel: 'Account',
        servers: [
          PlexServer(
            name: 'Account Server',
            clientIdentifier: 'account-server',
            accessToken: 'token',
            connections: const [],
            owned: true,
          ),
        ],
        createdAt: DateTime(2026),
      );

      expect(manualPlexServerIdsForConnections([manualConnection, accountConnection]), {'manual-server'});
    });

    test('ignores non-manual and empty manual startup connections', () {
      final emptyManualConnection = PlexAccountConnection(
        id: '${manualPlexIdPrefix}empty',
        accountToken: '',
        clientIdentifier: 'client-manual',
        accountLabel: 'Manual',
        servers: const [],
        createdAt: DateTime(2026),
      );
      final jellyfinConnection = JellyfinConnection(
        id: 'jellyfin.one',
        baseUrl: 'http://jellyfin.local',
        serverName: 'Jellyfin',
        serverMachineId: 'jellyfin-server',
        userId: 'user',
        userName: 'User',
        accessToken: 'token',
        deviceId: 'device',
        createdAt: DateTime(2026),
      );
      final accountConnection = PlexAccountConnection(
        id: 'plex.account.one',
        accountToken: 'token',
        clientIdentifier: 'client-account',
        accountLabel: 'Account',
        servers: [
          PlexServer(
            name: 'Account Server',
            clientIdentifier: 'account-server',
            accessToken: 'token',
            connections: const [],
            owned: true,
          ),
        ],
        createdAt: DateTime(2026),
      );

      expect(
        manualPlexServerIdsForConnections([emptyManualConnection, jellyfinConnection, accountConnection]),
        isEmpty,
      );
    });

    test('deduplicates repeated manual Plex server ids during startup', () {
      final firstManualConnection = PlexAccountConnection(
        id: '${manualPlexIdPrefix}one',
        accountToken: '',
        clientIdentifier: 'client-manual-a',
        accountLabel: 'Manual',
        servers: [
          PlexServer(
            name: 'Manual Server',
            clientIdentifier: 'manual-server',
            accessToken: '',
            connections: const [],
            owned: false,
          ),
        ],
        createdAt: DateTime(2026),
      );
      final secondManualConnection = PlexAccountConnection(
        id: '${manualPlexIdPrefix}two',
        accountToken: '',
        clientIdentifier: 'client-manual-b',
        accountLabel: 'Manual',
        servers: [
          PlexServer(
            name: 'Manual Server',
            clientIdentifier: 'manual-server',
            accessToken: '',
            connections: const [],
            owned: false,
          ),
        ],
        createdAt: DateTime(2026),
      );

      expect(manualPlexServerIdsForConnections([firstManualConnection, secondManualConnection]), {'manual-server'});
    });

    test('guest startup keeps only manual Plex servers with local endpoints', () {
      final localManualConnection = PlexAccountConnection(
        id: '${manualPlexIdPrefix}local',
        accountToken: '',
        clientIdentifier: 'client-manual',
        accountLabel: 'Manual',
        servers: [
          PlexServer(
            name: 'Manual Server',
            clientIdentifier: 'manual-server',
            accessToken: '',
            connections: [
              PlexConnection(
                protocol: 'http',
                address: 'wyvern',
                port: 32400,
                uri: 'http://wyvern:32400',
                local: true,
                relay: false,
                ipv6: false,
              ),
              PlexConnection(
                protocol: 'https',
                address: 'media.example.com',
                port: 32400,
                uri: 'https://media.example.com:32400',
                local: false,
                relay: false,
                ipv6: false,
              ),
            ],
            owned: false,
          ),
        ],
        createdAt: DateTime(2026),
      );
      final remoteManualConnection = PlexAccountConnection(
        id: '${manualPlexIdPrefix}remote',
        accountToken: '',
        clientIdentifier: 'client-remote',
        accountLabel: 'Remote Manual',
        servers: [
          PlexServer(
            name: 'Remote Manual',
            clientIdentifier: 'remote-server',
            accessToken: '',
            connections: [
              PlexConnection(
                protocol: 'https',
                address: 'media.example.com',
                port: 32400,
                uri: 'https://media.example.com:32400',
                local: false,
                relay: false,
                ipv6: false,
              ),
            ],
            owned: false,
          ),
        ],
        createdAt: DateTime(2026),
      );
      final accountConnection = PlexAccountConnection(
        id: 'plex.account.one',
        accountToken: 'token',
        clientIdentifier: 'client-account',
        accountLabel: 'Account',
        servers: const [],
        createdAt: DateTime(2026),
      );

      final guestConnections = guestStartupConnectionsFor([
        localManualConnection,
        remoteManualConnection,
        accountConnection,
      ]);

      expect(guestConnections, hasLength(1));
      final localOnlyConnection = guestConnections.single as PlexAccountConnection;
      expect(localOnlyConnection.id, localManualConnection.id);
      expect(localOnlyConnection.servers.single.clientIdentifier, 'manual-server');
      expect(localOnlyConnection.servers.single.connections.map((connection) => connection.uri), [
        'http://wyvern:32400',
      ]);
    });

    test('retries active profile bind when reconnect has no visible servers', () {
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: true,
          hasKnownOfflineServers: false,
        ),
        isTrue,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: false,
          hasKnownOfflineServers: false,
        ),
        isTrue,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: true,
          hasManagerOnlineServers: true,
          hasKnownOfflineServers: false,
        ),
        isFalse,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: false,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: true,
          hasKnownOfflineServers: false,
        ),
        isFalse,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: false,
          hasKnownOfflineServers: true,
        ),
        isFalse,
      );
    });

    test('explicit offline startup stays offline until a visible server connects', () {
      expect(
        shouldRenderMainScreenOffline(
          providerOffline: false,
          startupOfflineUntilConnected: true,
          hasVisibleConnectedServers: false,
        ),
        isTrue,
      );
      expect(
        shouldRenderMainScreenOffline(
          providerOffline: false,
          startupOfflineUntilConnected: true,
          hasVisibleConnectedServers: true,
        ),
        isFalse,
      );
      expect(
        shouldRenderMainScreenOffline(
          providerOffline: true,
          startupOfflineUntilConnected: false,
          hasVisibleConnectedServers: true,
        ),
        isTrue,
      );
    });
  });
}
