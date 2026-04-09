import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../services/plex_auth_service.dart';
import '../services/storage_service.dart';
import '../services/server_registry.dart';
import '../services/server_connection_orchestrator.dart';
import '../providers/multi_server_provider.dart';
import '../providers/libraries_provider.dart';
import '../services/offline_watch_sync_service.dart';
import 'app_logger.dart';

const int plexDefaultPort = 32400;

/// Shared utilities for manual server addition across the app
class ManualServerUtils {
  /// Parse server URL into protocol, address, and port
  /// Returns null if URL is invalid
  static ({String protocol, String address, int port})? parseServerUrl(String url) {
    try {
      String normalizedUrl = url;
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        normalizedUrl = 'https://$url';
      }

      final uri = Uri.parse(normalizedUrl);

      if (uri.host.isEmpty) {
        return null;
      }

      final protocol = uri.scheme;
      final address = uri.host;
      final port = uri.port > 0 ? uri.port : plexDefaultPort;

      return (protocol: protocol, address: address, port: port);
    } catch (error) {
      appLogger.w('Failed to parse server URL', error: error);
      return null;
    }
  }

  /// Generate a unique server ID for manual servers
  static String generateServerId(String serverName) {
    serverName = serverName.replaceAll(' ', '_');
    return 'manual_${serverName}_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Connect to a manual server and save it to the registry
  /// Returns a tuple of (success, errorMessage, serverName)
  static Future<(bool success, String? error, String serverName)> addManualServer({
    required BuildContext context,
    required String url,
    required String displayName,
    required String token,
    required PlexAuthService authService,
    bool shouldCancelConnection = false,
  }) async {
    if (url.isEmpty) {
      return (false, t.serverSelection.manualServerUrlRequired, '');
    }

    final parsed = parseServerUrl(url);
    if (parsed == null) {
      return (false, t.serverSelection.manualServerUrlInvalid, '');
    }

    try {
      // Capture providers before any async operations
      final multiServerProvider = context.read<MultiServerProvider>();
      final librariesProvider = context.read<LibrariesProvider>();
      final syncService = context.read<OfflineWatchSyncService>();

      final connectionUri = '${parsed.protocol}://${parsed.address}:${parsed.port}';
      final connection = PlexConnection(
        protocol: parsed.protocol,
        address: parsed.address,
        port: parsed.port,
        uri: connectionUri,
        local: true,
        relay: false,
        ipv6: parsed.address.contains(':'),
      );

      final serverName = displayName.isNotEmpty ? displayName : t.serverSelection.manualServerDefaultName;
      final generatedId = generateServerId(serverName);

      final server = PlexServer(
        name: serverName,
        clientIdentifier: generatedId,
        accessToken: token.isNotEmpty ? token : '',
        connections: [connection],
        owned: false,
        presence: false,
      );

      final result = await ServerConnectionOrchestrator.connectAndInitialize(
        servers: [server],
        multiServerProvider: multiServerProvider,
        librariesProvider: librariesProvider,
        syncService: syncService,
        clientIdentifier: authService.clientIdentifier,
      );

      if (shouldCancelConnection) {
        // Connection attempts may have already registered temporary state
        multiServerProvider.serverManager.removeServer(generatedId);
        return (false, 'Connection cancelled', serverName);
      }

      if (result.connectedCount > 0) {
        try {
          final storage = await StorageService.getInstance();
          final registry = ServerRegistry(storage);

          // Persist the manual server after it has proved it can connect
          await registry.upsertServer(server);
          return (true, null, serverName);
        } catch (error, stackTrace) {
          appLogger.e(
            'Failed to persist manual server after successful connection',
            error: error,
            stackTrace: stackTrace,
          );
          // Roll back the live connection so add behaves atomically
          multiServerProvider.serverManager.removeServer(generatedId);
          return (false, t.serverSelection.manualServerSaveFailed, serverName);
        }
      } else {
        // Clean up any offline/failed entry the connection manager recorded
        multiServerProvider.serverManager.removeServer(generatedId);
        return (false, t.serverSelection.manualServerConnectionFailed, serverName);
      }
    } catch (e) {
      final errorMsg = e.toString();
      final displayError = errorMsg.length > 200 ? '${errorMsg.substring(0, 200)}...' : errorMsg;
      return (false, displayError, '');
    }
  }
}
