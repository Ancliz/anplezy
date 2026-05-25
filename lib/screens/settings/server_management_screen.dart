import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../i18n/strings.g.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../profiles/profile_registry.dart';
import '../../providers/download_provider.dart';
import '../../services/storage_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../utils/manual_server_utils.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/add_server_form.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/settings_section.dart';

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
  String? _errorMessage;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _serverNameController.dispose();
    _serverTokenController.dispose();
    super.dispose();
  }

  Future<void> _connectToManualServer() async {
    if (!mounted) return;

    final url = _serverUrlController.text.trim();
    final displayName = _serverNameController.text.trim();
    final token = _serverTokenController.text.trim();
    final serverName = displayName.isNotEmpty ? displayName : t.serverSelection.manualServerDefaultName;

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final result = await ManualServerUtils.addManualServer(
        url: url,
        displayName: displayName,
        token: token,
        connectionRegistry: context.read<ConnectionRegistry>(),
        profileRegistry: context.read<ProfileRegistry>(),
        profileConnectionRegistry: context.read<ProfileConnectionRegistry>(),
        activeProfiles: context.read<ActiveProfileProvider>(),
        activeProfileBinder: context.read<ActiveProfileBinder>(),
        shouldCancelConnection: () => false,
        enableGuestMode: false,
      );

      if (!mounted) return;
      if (!result.connected) {
        setState(() {
          _isConnecting = false;
          _errorMessage = result.error ?? t.serverSelection.manualServerConnectionFailed;
        });
        return;
      }

      _serverUrlController.clear();
      _serverNameController.clear();
      _serverTokenController.clear();
      setState(() {
        _isConnecting = false;
        _errorMessage = null;
      });
      showSuccessSnackBar(context, 'Server "$serverName" added successfully');
    } catch (error, stackTrace) {
      appLogger.e('Failed to add manual Plex server', error: error, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _errorMessage = t.serverSelection.manualServerGenericFailure;
      });
    }
  }

  Future<void> _removeServer(PlexAccountConnection connection) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Server?',
      message: 'Are you sure you want to remove "${connection.displayLabel}"? You will no longer be able to access it.',
      confirmText: 'Remove',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      final connectionRegistry = context.read<ConnectionRegistry>();
      final profileRegistry = context.read<ProfileRegistry>();
      final profileConnectionRegistry = context.read<ProfileConnectionRegistry>();
      final activeProfiles = context.read<ActiveProfileProvider>();
      final activeProfileBinder = context.read<ActiveProfileBinder>();
      final downloadProvider = context.read<DownloadProvider>();
      final storage = await StorageService.getInstance();
      final serverIds = connection.servers.map((server) => server.clientIdentifier).toSet();
      final links = await profileConnectionRegistry.listForConnection(connection.id);

      for (final link in links) {
        final profile = await profileRegistry.get(link.profileId);
        final profileLinks = await profileConnectionRegistry.listForProfile(link.profileId);
        final onlyConnection = profileLinks.length == 1 && profileLinks.first.connectionId == connection.id;

        if (profile != null && profile.isLocal && onlyConnection) {
          await downloadProvider.deleteDownloadsForProfile(profile.id);
          await profileConnectionRegistry.removeAllForProfile(profile.id);
          await profileRegistry.remove(profile.id);
        } else {
          await downloadProvider.releaseDownloadsForProfileServers(link.profileId, serverIds);
          await profileConnectionRegistry.remove(link.profileId, connection.id);
        }
      }

      await profileConnectionRegistry.removeAllForConnection(connection.id);
      for (final server in connection.servers) {
        await storage.clearServerEndpoint(server.clientIdentifier);
      }
      await connectionRegistry.remove(connection.id);

      await activeProfiles.reloadFromStorage();
      if (activeProfiles.active == null && activeProfiles.profiles.isNotEmpty) {
        await activeProfiles.activate(activeProfiles.profiles.first);
      }
      await activeProfileBinder.rebindActive();

      if (!mounted) return;
      showSuccessSnackBar(context, 'Server "${connection.displayLabel}" removed');
    } catch (error, stackTrace) {
      appLogger.e('Failed to remove manual Plex server', error: error, stackTrace: stackTrace);
      if (!mounted) return;
      showErrorSnackBar(context, 'Failed to remove server: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: const Text('Manage Servers'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Add Server', style: Theme.of(context).textTheme.titleMedium),
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
              const SettingsSectionHeader('Saved Servers'),
              const SizedBox(height: 8),
              StreamBuilder<List<Connection>>(
                stream: context.read<ConnectionRegistry>().watchConnections(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: LoadingIndicatorBox()),
                    );
                  }
                  final servers = (snapshot.data ?? const <Connection>[])
                      .whereType<PlexAccountConnection>()
                      .where((connection) => connection.isManual)
                      .toList();

                  if (servers.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No servers added yet',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
                        ),
                      ),
                    );
                  }

                  return Column(
                    children: [
                      for (final connection in servers)
                        Card(
                          child: ListTile(
                            leading: const AppIcon(Symbols.storage_rounded, fill: 1),
                            title: Text(connection.displayLabel),
                            subtitle: Text(_subtitleFor(connection)),
                            trailing: IconButton(
                              tooltip: 'Remove server',
                              icon: const AppIcon(Symbols.delete_rounded, fill: 1),
                              onPressed: () => _removeServer(connection),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ]),
          ),
        ),
      ],
    );
  }

  String _subtitleFor(PlexAccountConnection connection) {
    final server = connection.servers.firstOrNull;
    final endpoint = server?.connections.firstOrNull;
    if (endpoint == null) return connection.displaySubtitle ?? 'No connection info';
    return '${endpoint.protocol}://${endpoint.address}:${endpoint.port}';
  }
}
