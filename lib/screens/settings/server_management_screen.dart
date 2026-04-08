import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../services/plex_auth_service.dart';
import '../../services/storage_service.dart';
import '../../services/server_registry.dart';
import '../../utils/manual_server_utils.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/add_server_form.dart';
import '../../widgets/desktop_app_bar.dart';

class ServerManagementScreen extends StatefulWidget {
  const ServerManagementScreen({super.key});

  @override
  State<ServerManagementScreen> createState() => _ServerManagementScreenState();
}

class _ServerManagementScreenState extends State<ServerManagementScreen> {
  final _serverUrlController = TextEditingController();
  final _serverNameController = TextEditingController();
  final _serverTokenController = TextEditingController();

  bool _isConnecting = false;
  bool _isLoadingServers = true;
  String? _errorMessage;
  List<PlexServer> _savedServers = [];
  late PlexAuthService _authService;
  bool _shouldCancelConnection = false;

  @override
  void initState() {
    super.initState();
    _initializeAuthService();
    _loadSavedServers();
  }

  Future<void> _initializeAuthService() async {
    _authService = await PlexAuthService.create();
  }

  Future<void> _loadSavedServers() async {
    final storage = await StorageService.getInstance();
    final registry = ServerRegistry(storage);
    final servers = await registry.getServers();

    // Filter to only show manual servers
    final manualServers = servers.where((s) => s.clientIdentifier.startsWith('manual_')).toList();

    if (mounted) {
      setState(() {
        _savedServers = manualServers;
        _isLoadingServers = false;
      });
    }
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _serverNameController.dispose();
    _serverTokenController.dispose();
    super.dispose();
  }

  /// Connect to the manual server and save it
  Future<void> _connectToManualServer() async {
    if (!mounted) return;

    final url = _serverUrlController.text.trim();
    final displayName = _serverNameController.text.trim();
    final token = _serverTokenController.text.trim();

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
      _shouldCancelConnection = false;
    });

    try {
      final (success, error, serverName) = await ManualServerUtils.addManualServer(
        context: context,
        url: url,
        displayName: displayName,
        token: token,
        authService: _authService,
        shouldCancelConnection: _shouldCancelConnection,
      );

      if (!mounted) return;

      if (_shouldCancelConnection) {
        setState(() {
          _isConnecting = false;
        });
        return;
      }

      if (!success) {
        setState(() {
          _isConnecting = false;
          _errorMessage = error ?? 'Could not connect to server. Please check the URL and try again.';
        });
        return;
      }

      if (!mounted) return;

      // Clear the form
      _serverUrlController.clear();
      _serverNameController.clear();
      _serverTokenController.clear();

      // Reload servers
      await _loadSavedServers();

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Server "$serverName" added successfully')),
        );
      }
    } catch (error) {
      appLogger.e('Failed to add manual server', error: error);
      setState(() {
        _isConnecting = false;
        _errorMessage = 'Connection failed. Please try again.';
      });
    }
  }

  /// Remove a server
  Future<void> _removeServer(String serverId, String serverName) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Server?',
      message: 'Are you sure you want to remove "$serverName"? You will no longer be able to access it.',
      confirmText: 'Remove',
      isDestructive: true,
    );

    if (!confirmed) return;

    try {
      // Remove from storage
      final storage = await StorageService.getInstance();
      final registry = ServerRegistry(storage);
      await registry.removeServer(serverId);

      // Remove from active session
      if (mounted) {
        final multiServerProvider = context.read<MultiServerProvider>();
        multiServerProvider.serverManager.removeServer(serverId);
      }

      await _loadSavedServers();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Server "$serverName" removed')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove server: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          ExcludeFocus(
            child: CustomAppBar(
              title: const Text('Manage Servers'),
              pinned: true,
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Add Server Section
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Add Server',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            AddServerForm(
                              urlController: _serverUrlController,
                              nameController: _serverNameController,
                              tokenController: _serverTokenController,
                              onSubmit: _connectToManualServer,
                              isConnecting: _isConnecting,
                              errorMessage: _errorMessage,
                              submitButtonLabel: 'Add Server',
                              showCancelButton: false,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Saved Servers Section
                    Text(
                      'Saved Servers',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (_isLoadingServers)
                      const Center(child: CircularProgressIndicator())
                    else if (_savedServers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No servers added yet',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ),
                      )
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _savedServers.length,
                        itemBuilder: (context, index) {
                          final server = _savedServers[index];
                          final conn = server.connections.isNotEmpty ? server.connections.first : null;
                          final subtitle = conn != null ? '${conn.address}:${conn.port}' : 'No connection info';

                          return ListTile(
                            leading: const AppIcon(Symbols.storage_rounded, fill: 1),
                            title: Text(server.name),
                            subtitle: Text(subtitle),
                            trailing: IconButton(
                              icon: const AppIcon(Symbols.delete_rounded, fill: 1),
                              onPressed: () => _removeServer(server.clientIdentifier, server.name),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}