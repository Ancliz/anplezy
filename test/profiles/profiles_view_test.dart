import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/models/plex/plex_home_user.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/profiles/profiles_view.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/storage_service.dart';

import '../test_helpers/prefs.dart';

PlexHomeUser _homeUser(String uuid) {
  return PlexHomeUser(
    id: 1,
    uuid: uuid,
    title: 'Account User',
    thumb: '',
    hasPassword: false,
    restricted: false,
    updatedAt: null,
    admin: true,
    guest: false,
    protected: false,
  );
}

PlexAccountConnection _account(String id) {
  return PlexAccountConnection(
    id: id,
    accountToken: 'token-$id',
    clientIdentifier: 'client-$id',
    accountLabel: 'Plex',
    createdAt: DateTime(2026, 1, 1),
  );
}

PlexAccountConnection _manualAccount(String manualId) {
  return PlexAccountConnection(
    id: '$manualPlexConnectionIdPrefix$manualId',
    accountToken: '',
    clientIdentifier: 'client-$manualId',
    accountLabel: 'Manual Plex',
    servers: [
      PlexServer(
        name: 'Manual Plex',
        clientIdentifier: manualId,
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
        ],
        owned: false,
      ),
    ],
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  setUp(resetSharedPreferencesForTest);

  group('visibleProfileConnections', () {
    test('keeps all local profile connection rows', () {
      final profile = Profile.local(id: 'local-1', displayName: 'Owner', createdAt: DateTime(2026, 1, 1));
      const rows = [
        ProfileConnection(profileId: 'local-1', connectionId: 'plex-1', userIdentifier: 'u1'),
        ProfileConnection(profileId: 'local-1', connectionId: 'jellyfin-1', userIdentifier: 'u2'),
      ];

      expect(visibleProfileConnections(profile, rows), rows);
    });

    test('filters Plex Home parent token cache row', () {
      final profile = Profile.plexHome(
        id: 'plex-home-plex-1-user-1',
        displayName: 'Kid',
        parentConnectionId: 'plex-1',
        createdAt: DateTime(2026, 1, 1),
      );
      const rows = [
        ProfileConnection(profileId: 'plex-home-plex-1-user-1', connectionId: 'plex-1', userIdentifier: 'user-1'),
        ProfileConnection(profileId: 'plex-home-plex-1-user-1', connectionId: 'jellyfin-1', userIdentifier: 'user-2'),
      ];

      final visible = visibleProfileConnections(profile, rows);

      expect(visible, hasLength(1));
      expect(visible.single.connectionId, 'jellyfin-1');
    });
  });

  group('watchProfilesView', () {
    test('hides Plex Home profiles while guest mode is active', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final profiles = ProfileRegistry(db);
      final connections = ConnectionRegistry(db);
      final profileConnections = ProfileConnectionRegistry(db);
      final storage = await StorageService.getInstance();
      final plexHome = PlexHomeService(
        connections: connections,
        profileConnections: profileConnections,
        storage: storage,
        plexHomeUserFetcher: (_) async => const [],
      );
      addTearDown(() async {
        await plexHome.dispose();
        await db.close();
      });

      final account = _account('plex.account');
      final homeUser = _homeUser('home-user-1');
      await connections.upsert(account);
      await storage.savePlexHomeUsersCache(account.id, [homeUser.toJson()]);

      final manualConnection = _manualAccount('manual-1');
      final manualProfile = Profile.local(
        id: 'local.manual-1',
        displayName: 'Manual Plex',
        createdAt: DateTime(2026, 1, 1),
      );
      await connections.upsert(manualConnection);
      await profiles.upsert(manualProfile);
      await profileConnections.upsert(
        ProfileConnection(profileId: manualProfile.id, connectionId: manualConnection.id, userIdentifier: 'manual-1'),
      );
      await storage.setGuestModeEnabled(true);
      await plexHome.start();

      final view = await watchProfilesView(
        profiles: profiles,
        profileConnections: profileConnections,
        connections: connections,
        plexHome: plexHome,
        storage: storage,
      ).first;

      expect(view.profiles.map((profile) => profile.id), [manualProfile.id]);
    });
  });
}
