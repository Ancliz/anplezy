import 'dart:convert';

import 'package:dio/dio.dart';

import '../utils/app_logger.dart';
import 'plex_auth_service.dart';
import 'storage_service.dart';

enum ServerRefreshResult { success, networkError, authError, noToken }

/// Centralized server configuration registry
/// Manages which servers are available and their configurations
class ServerRegistry {
  final StorageService _storage;

  ServerRegistry(this._storage);

  /// Get all registered servers
  Future<List<PlexServer>> getServers() async {
    try {
      final serversJson = _storage.getServersListJson();
      if (serversJson == null || serversJson.isEmpty) {
        return [];
      }

      final List<dynamic> serversList = jsonDecode(serversJson);
      final validServers = <PlexServer>[];
      
      for (final json in serversList) {
        try {
          final server = PlexServer.fromJson(json as Map<String, dynamic>);
          validServers.add(server);
        } catch (e) {
          appLogger.w('Skipping invalid server data in storage', error: e);
          // Continue with other servers instead of failing completely
        }
      }
      
      return validServers;
    } catch (e, stackTrace) {
      appLogger.e('Failed to load servers from storage', error: e, stackTrace: stackTrace);
      return [];
    }
  }

  /// Save all servers to storage
  Future<void> saveServers(List<PlexServer> servers) async {
    try {
      final serversJson = jsonEncode(servers.map((s) => s.toJson()).toList());
      await _storage.saveServersListJson(serversJson);
      appLogger.d('Saved ${servers.length} servers to storage');
    } catch (e, stackTrace) {
      appLogger.e('Failed to save servers to storage', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Get a specific server by ID
  Future<PlexServer?> getServer(String serverId) async {
    final servers = await getServers();
    try {
      return servers.firstWhere((s) => s.clientIdentifier == serverId);
    } catch (e) {
      return null;
    }
  }

  static const String _localServerPrefix = 'manual_';

  /// Add or update a single server
  Future<void> upsertServer(PlexServer server) async {
    final servers = await getServers();
    final index = servers.indexWhere((s) => s.clientIdentifier == server.clientIdentifier);

    if (index >= 0) {
      servers[index] = server;
      appLogger.d('Updated server: ${server.name}');
    } else {
      servers.add(server);
      appLogger.d('Added new server: ${server.name}');
    }

    await saveServers(servers);
  }

  /// Remove a server and any associated stored endpoints/order entries.
  Future<void> removeServer(String serverId) async {
    final servers = await getServers();
    servers.removeWhere((s) => s.clientIdentifier == serverId);
    await saveServers(servers);
    await _storage.clearServerEndpoint(serverId);

    final order = _storage.getServerOrder();
    if (order != null && order.isNotEmpty) {
      final updatedOrder = order.where((id) => id != serverId).toList();
      if (updatedOrder.isEmpty) {
        await _storage.clearServerOrder();
      } else {
        await _storage.saveServerOrder(updatedOrder);
      }
    }

    appLogger.i('Removed server: $serverId');
  }

  /// Keep only manually added local servers and remove all Plex account servers.
  Future<void> keepOnlyLocalServers() async {
    final servers = await getServers();
    final localServers = servers.where((s) => s.clientIdentifier.startsWith(_localServerPrefix)).toList();

    final removedServerIds = servers
        .where((s) => !s.clientIdentifier.startsWith(_localServerPrefix))
        .map((s) => s.clientIdentifier)
        .toList();

    for (final serverId in removedServerIds) {
      await _storage.clearServerEndpoint(serverId);
    }

    await saveServers(localServers);

    final order = _storage.getServerOrder();
    if (order != null) {
      final updatedOrder = order.where((id) => localServers.any((s) => s.clientIdentifier == id)).toList();
      if (updatedOrder.isEmpty) {
        await _storage.clearServerOrder();
      } else {
        await _storage.saveServerOrder(updatedOrder);
      }
    }
  }

  /// Clear all servers
  Future<void> clearAllServers() async {
    await _storage.clearServersList();
    appLogger.i('Cleared all servers from registry');
  }

  /// Refresh servers from Plex API and update storage.
  /// This updates connection info (IPs, ports) that may have changed.
  /// Returns [ServerRefreshResult.authError] when the stored token is rejected
  /// (e.g. after removing a Plex profile PIN), so the caller can redirect to re-auth.
  Future<ServerRefreshResult> refreshServersFromApi() async {
    final token = _storage.getPlexToken();
    if (token == null || token.isEmpty) {
      appLogger.d('No Plex token available, skipping server refresh');
      return ServerRefreshResult.noToken;
    }

    try {
      appLogger.d('Refreshing servers from Plex API...');
      final authService = await PlexAuthService.create();
      final freshServers = await authService.fetchServers(token);

      if (freshServers.isEmpty) {
        appLogger.w('API returned no servers, keeping existing data');
        return ServerRefreshResult.success;
      }

      // Get existing servers to preserve any local-only data
      final existingServers = await getServers();
      final existingIds = existingServers.map((s) => s.clientIdentifier).toSet();

      // Update existing servers with fresh connection info, add new ones
      final updatedServers = <PlexServer>[];
      for (final fresh in freshServers) {
        if (existingIds.contains(fresh.clientIdentifier)) {
          // Server exists - use fresh data (updated IPs, connections)
          updatedServers.add(fresh);
        } else {
          // New server - add it
          updatedServers.add(fresh);
          appLogger.i('Discovered new server: ${fresh.name}');
        }
      }

      await saveServers(updatedServers);
      appLogger.i('Refreshed ${updatedServers.length} servers from API');
      return ServerRefreshResult.success;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        appLogger.w('Plex token is invalid (401), re-authentication required');
        return ServerRefreshResult.authError;
      }
      appLogger.w('Failed to refresh servers from API, using cached data', error: e);
      return ServerRefreshResult.networkError;
    } catch (e, stackTrace) {
      appLogger.w('Failed to refresh servers from API, using cached data', error: e, stackTrace: stackTrace);
      return ServerRefreshResult.networkError;
    }
  }
}
