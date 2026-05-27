import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/manual_server_utils.dart';

import '../test_helpers/prefs.dart';

void main() {
  group('ManualServerUtils.parseServerUrl', () {
    test('defaults bare hostnames to local HTTP on the Plex port', () {
      final parsed = ManualServerUtils.parseServerUrl('example');

      expect(parsed?.protocol, 'http');
      expect(parsed?.address, 'example');
      expect(parsed?.port, plexDefaultPort);
      expect(parsed?.uri, 'http://example:32400');
    });

    test('parses common local host forms', () {
      final cases = <({String input, String protocol, String address, int port, String uri})>[
        (
          input: 'plex.local',
          protocol: 'http',
          address: 'plex.local',
          port: plexDefaultPort,
          uri: 'http://plex.local:32400',
        ),
        (
          input: 'example.home.arpa:32401',
          protocol: 'http',
          address: 'example.home.arpa',
          port: 32401,
          uri: 'http://example.home.arpa:32401',
        ),
        (
          input: 'localhost:32400',
          protocol: 'http',
          address: 'localhost',
          port: plexDefaultPort,
          uri: 'http://localhost:32400',
        ),
        (
          input: '192.168.1.20',
          protocol: 'http',
          address: '192.168.1.20',
          port: plexDefaultPort,
          uri: 'http://192.168.1.20:32400',
        ),
        (
          input: 'http://10.0.0.5:32401',
          protocol: 'http',
          address: '10.0.0.5',
          port: 32401,
          uri: 'http://10.0.0.5:32401',
        ),
      ];

      for (final testCase in cases) {
        final parsed = ManualServerUtils.parseServerUrl(testCase.input);

        expect(parsed?.protocol, testCase.protocol, reason: testCase.input);
        expect(parsed?.address, testCase.address, reason: testCase.input);
        expect(parsed?.port, testCase.port, reason: testCase.input);
        expect(parsed?.uri, testCase.uri, reason: testCase.input);
      }
    });

    test('normalizes scheme and host casing', () {
      final parsed = ManualServerUtils.parseServerUrl('HTTPS://Plex.Example:443');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, 443);
      expect(parsed?.uri, 'https://plex.example:443');
    });

    test('parses bracketed IPv6 addresses', () {
      final explicit = ManualServerUtils.parseServerUrl('http://[fd00::1]:32401');
      final defaultPort = ManualServerUtils.parseServerUrl('[fd00::1]');

      expect(explicit?.protocol, 'http');
      expect(explicit?.address, 'fd00::1');
      expect(explicit?.port, 32401);
      expect(explicit?.uri, 'http://[fd00::1]:32401');

      expect(defaultPort?.protocol, 'http');
      expect(defaultPort?.address, 'fd00::1');
      expect(defaultPort?.port, plexDefaultPort);
      expect(defaultPort?.uri, 'http://[fd00::1]:32400');
    });

    test('preserves explicit protocol and port', () {
      final parsed = ManualServerUtils.parseServerUrl('https://plex.example:34403');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, 34403);
      expect(parsed?.uri, 'https://plex.example:34403');
    });

    test('preserves explicit default protocol port', () {
      final parsed = ManualServerUtils.parseServerUrl('https://plex.example:443');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, 443);
      expect(parsed?.uri, 'https://plex.example:443');
    });

    test('uses Plex port when protocol is present but port is omitted', () {
      final parsed = ManualServerUtils.parseServerUrl('https://plex.example');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, plexDefaultPort);
      expect(parsed?.uri, 'https://plex.example:32400');
    });

    test('trims input and rejects invalid URLs', () {
      expect(ManualServerUtils.parseServerUrl('  http://example:32400  ')?.uri, 'http://example:32400');
      expect(ManualServerUtils.parseServerUrl(''), isNull);
      expect(ManualServerUtils.parseServerUrl('ftp://example:32400'), isNull);
      expect(ManualServerUtils.parseServerUrl('http://'), isNull);
    });

    test('rejects malformed URLs and unsupported schemes', () {
      final invalidInputs = [
        ' ',
        '://plex.example',
        'plex://plex.example',
        'ftp://plex.example:32400',
        'http://',
        'https://',
        'http://:32400',
        'http:///plex.example',
        'http://plex.example:',
        'http://plex.example:notaport',
        'http://plex.example:-1',
        'http://plex.example:0',
        'http://plex.example:99999',
        'http://user@plex.example:32400',
        'http://plex.example/',
        'http://plex.example:32400/',
        'http://plex.example:32400/web/index.html',
        'http://plex.example:32400?token=nope',
        'http://plex.example:32400#hash',
        'plex.example/web',
        'plex.example?token=nope',
        'plex.example#hash',
        'fd00::1',
        'https://[fd00::1',
      ];

      for (final input in invalidInputs) {
        expect(ManualServerUtils.parseServerUrl(input), isNull, reason: input);
      }
    });
  });

  group('ManualServerUtils.addManualServer', () {
    late AppDatabase db;
    late ConnectionRegistry connections;
    late ProfileRegistry profiles;
    late ProfileConnectionRegistry profileConnections;
    late PlexHomeService plexHome;
    late ActiveProfileProvider activeProfiles;
    late MultiServerManager manager;
    late MultiServerProvider multiServerProvider;
    late _RecordingActiveProfileBinder binder;
    late StorageService storage;

    setUp(() async {
      resetSharedPreferencesForTest();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      connections = ConnectionRegistry(db);
      profiles = ProfileRegistry(db);
      profileConnections = ProfileConnectionRegistry(db);
      storage = await StorageService.getInstance();
      plexHome = PlexHomeService(
        connections: connections,
        profileConnections: profileConnections,
        storage: storage,
        plexHomeUserFetcher: (_) async => const [],
      );
      activeProfiles = ActiveProfileProvider(
        registry: profiles,
        plexHome: plexHome,
        connections: connections,
        profileConnections: profileConnections,
        storage: storage,
      );
      manager = MultiServerManager();
      multiServerProvider = MultiServerProvider(manager, DataAggregationService(manager));
      binder = _RecordingActiveProfileBinder(
        activeProfile: activeProfiles,
        connections: connections,
        profileConnections: profileConnections,
        serverManager: manager,
        multiServerProvider: multiServerProvider,
      );
    });

    tearDown(() async {
      binder.dispose();
      multiServerProvider.dispose();
      await activeProfiles.resetForTesting();
      activeProfiles.dispose();
      await plexHome.dispose();
      await db.close();
    });

    test('attaches manual servers to the active profile outside guest setup', () async {
      final profile = Profile.local(id: 'local.owner', displayName: 'Owner', createdAt: DateTime(2026, 1, 1));
      await profiles.upsert(profile);
      await storage.setActiveProfileId(profile.id);
      await activeProfiles.initialize();

      final result = await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      expect(result, (connected: true, cancelled: false, error: null));
      expect(storage.isGuestModeEnabled(), isFalse);
      expect(storage.getActiveProfileId(), profile.id);
      expect((await profiles.list()).map((profile) => profile.id), [profile.id]);
      expect(binder.rebindCount, 1);

      final profileRows = await profileConnections.listForProfile(profile.id);
      expect(profileRows, hasLength(1));
      expect(profileRows.single.connectionId, startsWith(manualPlexIdPrefix));
      expect(profileRows.single.userIdentifier, startsWith('manual_'));

      final connection = await connections.get(profileRows.single.connectionId);
      expect(connection, isA<PlexAccountConnection>());
      final plexConnection = connection! as PlexAccountConnection;
      expect(plexConnection.isManual, isTrue);
      expect(plexConnection.servers.single.name, 'Wyvern');
      expect(plexConnection.servers.single.machineIdentifier, 'machine-manual');
      expect(plexConnection.servers.single.connections.single.uri, 'http://wyvern:32400');
    });

    test('does not persist a manual server before preflight connection succeeds', () async {
      final verifierCalled = Completer<void>();
      final verifier = Completer<ManualServerConnectionVerification>();

      final resultFuture = ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: (_, _) {
          verifierCalled.complete();
          return verifier.future;
        },
        hostResolver: _hostResolver(),
      );

      await verifierCalled.future;

      expect(await connections.list(), isEmpty);
      expect(await profiles.list(), isEmpty);
      expect(await profileConnections.listAll(), isEmpty);
      expect(binder.rebindCount, 0);

      verifier.complete(_connectionSucceeded);
      expect(await resultFuture, (connected: true, cancelled: false, error: null));
    });

    test('does not persist a manual server when preflight connection fails', () async {
      final result = await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: (_, _) async => const ManualServerConnectionVerification(connected: false),
        hostResolver: _hostResolver(),
      );

      expect(result.connected, isFalse);
      expect(result.cancelled, isFalse);
      expect(result.error, isNotNull);
      expect(await connections.list(), isEmpty);
      expect(await profiles.list(), isEmpty);
      expect(await profileConnections.listAll(), isEmpty);
      expect(binder.rebindCount, 0);
    });

    test('creates and activates a local manual profile for guest setup', () async {
      final result = await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      expect(result, (connected: true, cancelled: false, error: null));
      expect(storage.isGuestModeEnabled(), isTrue);
      expect(binder.rebindCount, 1);

      final storedProfiles = await profiles.list();
      expect(storedProfiles, hasLength(1));
      expect(storedProfiles.single.id, startsWith('local.manual_'));
      expect(storedProfiles.single.displayName, 'Wyvern');
      expect(storage.getActiveProfileId(), storedProfiles.single.id);

      final profileRows = await profileConnections.listForProfile(storedProfiles.single.id);
      expect(profileRows, hasLength(1));
      expect(profileRows.single.connectionId, startsWith(manualPlexIdPrefix));
      expect(profileRows.single.isDefault, isTrue);
    });

    test('can create a local manual profile outside guest setup when no profile is active', () async {
      final result = await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      expect(result, (connected: true, cancelled: false, error: null));
      expect(storage.isGuestModeEnabled(), isFalse);
      expect(binder.rebindCount, 1);

      final storedProfiles = await profiles.list();
      expect(storedProfiles, hasLength(1));
      expect(storedProfiles.single.id, startsWith('local.manual_'));
      expect(storage.getActiveProfileId(), storedProfiles.single.id);

      final profileRows = await profileConnections.listForProfile(storedProfiles.single.id);
      expect(profileRows, hasLength(1));
      expect(profileRows.single.connectionId, startsWith(manualPlexIdPrefix));
    });

    test('rejects duplicate manual servers by host and port before preflight', () async {
      await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      var verifierCalls = 0;
      final result = await ManualServerUtils.addManualServer(
        url: 'http://WYVERN:32400',
        displayName: 'Wyvern again',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: (_, _) async {
          verifierCalls++;
          return _connectionSucceeded;
        },
        hostResolver: _hostResolver(),
      );

      expect(result.connected, isFalse);
      expect(result.cancelled, isFalse);
      expect(result.error, t.serverSelection.manualServerAlreadyExists);
      expect(verifierCalls, 0);
      expect(await connections.list(), hasLength(1));
      expect(await profileConnections.listAll(), hasLength(1));
    });

    test('rejects duplicate manual servers by resolved address', () async {
      final resolver = _hostResolver({
        'wyvern.local': {'192.168.1.25'},
        'plex.home.arpa': {'192.168.1.25'},
      });

      await ManualServerUtils.addManualServer(
        url: 'wyvern.local:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: resolver,
      );

      final result = await ManualServerUtils.addManualServer(
        url: 'plex.home.arpa:32400',
        displayName: 'Wyvern alias',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: resolver,
      );

      expect(result.connected, isFalse);
      expect(result.cancelled, isFalse);
      expect(result.error, t.serverSelection.manualServerAlreadyExists);
      expect(await connections.list(), hasLength(1));
      expect(await profileConnections.listAll(), hasLength(1));
    });

    test('allows the same manual host on a different port', () async {
      await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      final result = await ManualServerUtils.addManualServer(
        url: 'wyvern:32401',
        displayName: 'Wyvern alt',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      expect(result, (connected: true, cancelled: false, error: null));
      expect(await connections.list(), hasLength(2));
      expect(await profileConnections.listAll(), hasLength(2));
    });

    test('rejects duplicate manual servers when an IP matches a resolved domain', () async {
      final resolver = _hostResolver({
        'wyvern.local': {'192.168.1.25'},
        '192.168.1.25': {'192.168.1.25'},
      });

      await ManualServerUtils.addManualServer(
        url: 'wyvern.local:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: resolver,
      );

      final result = await ManualServerUtils.addManualServer(
        url: '192.168.1.25:32400',
        displayName: 'Wyvern IP',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: resolver,
      );

      expect(result.connected, isFalse);
      expect(result.cancelled, isFalse);
      expect(result.error, t.serverSelection.manualServerAlreadyExists);
      expect(await connections.list(), hasLength(1));
      expect(await profileConnections.listAll(), hasLength(1));
    });

    test('does not treat unresolved different hosts as duplicates', () async {
      await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      final result = await ManualServerUtils.addManualServer(
        url: 'dragon:32400',
        displayName: 'Dragon',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      expect(result, (connected: true, cancelled: false, error: null));
      expect(await connections.list(), hasLength(2));
      expect(await profileConnections.listAll(), hasLength(2));
    });

    test('does not persist a duplicate manual server while duplicate check is pending', () async {
      await ManualServerUtils.addManualServer(
        url: 'wyvern:32400',
        displayName: 'Wyvern',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: _hostResolver(),
      );

      final resolverCalled = Completer<void>();
      final resolver = Completer<Set<String>>();
      final resultFuture = ManualServerUtils.addManualServer(
        url: 'dragon:32400',
        displayName: 'Dragon',
        token: '',
        connectionRegistry: connections,
        profileRegistry: profiles,
        profileConnectionRegistry: profileConnections,
        activeProfiles: activeProfiles,
        activeProfileBinder: binder,
        shouldCancelConnection: () => false,
        enableGuestMode: false,
        createLocalProfile: true,
        connectionVerifier: _connectionSucceeds,
        hostResolver: (host) {
          if (host == 'dragon') {
            resolverCalled.complete();
            return resolver.future;
          }
          return Future.value(const {});
        },
      );

      await resolverCalled.future;

      expect(await connections.list(), hasLength(1));
      expect(await profileConnections.listAll(), hasLength(1));

      resolver.complete({'10.0.0.2'});
      expect(await resultFuture, (connected: true, cancelled: false, error: null));
      expect(await connections.list(), hasLength(2));
    });
  });
}

ManualServerHostResolver _hostResolver([Map<String, Set<String>> resolvedHosts = const {}]) {
  return (host) async {
    final normalizedHost = host.toLowerCase();
    return resolvedHosts[normalizedHost] ?? const {};
  };
}

const _connectionSucceeded = ManualServerConnectionVerification(connected: true, machineIdentifier: 'machine-manual');

Future<ManualServerConnectionVerification> _connectionSucceeds(_, _) async => _connectionSucceeded;

class _RecordingActiveProfileBinder extends ActiveProfileBinder {
  _RecordingActiveProfileBinder({
    required super.activeProfile,
    required super.connections,
    required super.profileConnections,
    required super.serverManager,
    required super.multiServerProvider,
  }) : super(pinPrompt: (_, {String? errorMessage}) async => null);

  int rebindCount = 0;

  @override
  Future<void> rebindActive() async {
    rebindCount++;
    activeProfile.markBindingStarted();
    activeProfile.markBindingFinished(success: true);
  }
}
