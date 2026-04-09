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
      final trimmedUrl = url.trim();
      if (trimmedUrl.isEmpty) {
        return null;
      }

      final hasProtocol = trimmedUrl.startsWith('http://') || trimmedUrl.startsWith('https://');
      final normalizedUrl = hasProtocol ? trimmedUrl : 'https://$trimmedUrl';
      final uri = Uri.tryParse(normalizedUrl);

      if (uri == null || uri.host.isEmpty) {
        return null;
      }
      
      final port = uri.hasPort ? uri.port : plexDefaultPort;

      return (protocol: uri.scheme, address: uri.host, port: port);
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
  /// Returns a tuple of (success, errorMessage, serverName, savedServer)
  static Future<(bool success, String? error, String serverName, PlexServer? savedServer)> addManualServer({
    required BuildContext context,
    required String url,
    required String displayName,
    required String token,
    required PlexAuthService authService,
    bool shouldCancelConnection = false,
  }) async {
    if (url.isEmpty) {
      return (false, t.serverSelection.manualServerUrlRequired, '', null);
    }

    final parsed = parseServerUrl(url);
    if (parsed == null) {
      return (false, t.serverSelection.manualServerUrlInvalid, '', null);
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
        return (false, 'Connection cancelled', serverName, null);
      }

      if (result.connectedCount > 0) {
        try {
          final storage = await StorageService.getInstance();
          final registry = ServerRegistry(storage);

          // Persist the manual server after it has proved it can connect
          await registry.upsertServer(server);
          return (true, null, serverName, server);
        } catch (error, stackTrace) {
          appLogger.e(
            'Failed to persist manual server after successful connection',
            error: error,
            stackTrace: stackTrace,
          );
          // Roll back the live connection so add behaves atomically
          multiServerProvider.serverManager.removeServer(generatedId);
          return (false, t.serverSelection.manualServerSaveFailed, serverName, null);
        }
      } else {
        // Clean up any offline/failed entry the connection manager recorded
        multiServerProvider.serverManager.removeServer(generatedId);
        return (false, t.serverSelection.manualServerConnectionFailed, serverName, null);
      }
    } catch (e) {
      final errorMsg = e.toString();
      final displayError = errorMsg.length > 200 ? '${errorMsg.substring(0, 200)}...' : errorMsg;
      return (false, displayError, '', null);
    }
  }
}
