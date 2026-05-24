import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
import '../theme/mono_tokens.dart';
import '../utils/app_logger.dart';
import '../utils/navigation_transitions.dart';
import 'main_screen.dart';

class GuestSetupScreen extends StatefulWidget {
  const GuestSetupScreen({super.key});

  @override
  State<GuestSetupScreen> createState() => _GuestSetupScreenState();
}

class _GuestSetupScreenState extends State<GuestSetupScreen> {
  final _serverUrlController = TextEditingController();
  final _serverNameController = TextEditingController();
  final _serverTokenController = TextEditingController();

  bool _isConnecting = false;
  bool _shouldCancelConnection = false;
  String? _errorMessage;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _serverNameController.dispose();
    _serverTokenController.dispose();
    super.dispose();
  }

  ({String protocol, String address, int port, String uri})? _parseServerUrl(String url) {
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

  Future<void> _connectToManualServer() async {
    if (!mounted) return;

    final url = _serverUrlController.text.trim();
    final displayName = _serverNameController.text.trim();
    final token = _serverTokenController.text.trim();

    if (url.isEmpty) {
      setState(() => _errorMessage = 'Please enter a server URL');
      return;
    }

    final parsed = _parseServerUrl(url);
    if (parsed == null) {
      setState(() => _errorMessage = 'Invalid server URL format');
      return;
    }

    final connectionRegistry = context.read<ConnectionRegistry>();
    final profileRegistry = context.read<ProfileRegistry>();
    final profileConnectionRegistry = context.read<ProfileConnectionRegistry>();
    final activeProfiles = context.read<ActiveProfileProvider>();
    final activeProfileBinder = context.read<ActiveProfileBinder>();

    setState(() {
      _isConnecting = true;
      _shouldCancelConnection = false;
      _errorMessage = null;
    });

    try {
      final storage = await StorageService.getInstance();
      await storage.setGuestModeEnabled(true);
      final clientIdentifier = await storage.getOrCreateClientIdentifier();
      final serverName = displayName.isNotEmpty ? displayName : 'Local Server';
      final manualId = _generateServerId();
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
        id: '$manualPlexConnectionIdPrefix$manualId',
        accountToken: '',
        clientIdentifier: clientIdentifier,
        accountLabel: serverName,
        servers: [server],
        createdAt: now,
        lastAuthenticatedAt: now,
      );
      final profile = Profile.local(
        id: 'local.$manualId',
        displayName: serverName,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
      );

      await connectionRegistry.upsert(accountConnection);
      await profileRegistry.upsert(profile);
      await profileConnectionRegistry.upsert(
        ProfileConnection(profileId: profile.id, connectionId: accountConnection.id, userIdentifier: manualId),
        makeDefault: true,
      );

      if (_shouldCancelConnection) {
        if (!mounted) return;
        setState(() => _isConnecting = false);
        unawaited(Navigator.of(context).maybePop());
        return;
      }

      await activeProfiles.reloadFromStorage();
      final activated = await activeProfiles.activate(profile);
      if (!activated) {
        if (!mounted) return;
        setState(() {
          _isConnecting = false;
          _errorMessage = t.serverSelection.allServerConnectionsFailed;
        });
        return;
      }

      await activeProfileBinder.rebindActive();
      final connected = await activeProfiles.awaitBindingSettle();

      if (_shouldCancelConnection) {
        if (!mounted) return;
        setState(() => _isConnecting = false);
        unawaited(Navigator.of(context).maybePop());
        return;
      }

      if (!connected) {
        if (!mounted) return;
        setState(() {
          _isConnecting = false;
          _errorMessage = t.serverSelection.allServerConnectionsFailed;
        });
        return;
      }

      if (!mounted) return;
      unawaited(Navigator.pushReplacement(context, fadeRoute(const MainScreen())));
    } catch (error, stackTrace) {
      appLogger.e('Failed to connect to manual Plex server', error: error, stackTrace: stackTrace);
      if (!mounted) return;
      final message = error.toString().replaceAll('Exception: ', '').replaceAll('FormatException: ', '');
      final errorMessage = message.isEmpty
          ? 'Connection failed. Please check your server address and try again.'
          : message;
      setState(() {
        _isConnecting = false;
        _errorMessage = errorMessage.length > 200 ? '${errorMessage.substring(0, 200)}...' : errorMessage;
      });
    }
  }

  String _generateServerId() {
    return 'manual_${DateTime.now().microsecondsSinceEpoch}';
  }

  void _goBack() {
    setState(() {
      _errorMessage = null;
      _isConnecting = false;
    });
    unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width > 700;

    return PopScope(
      canPop: !_isConnecting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          setState(() => _shouldCancelConnection = true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _isConnecting ? null : _goBack),
          title: const Text('Manual Server Setup'),
        ),
        body: Center(
          child: Container(
            constraints: BoxConstraints(maxWidth: isDesktop ? 500 : 400),
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Connect to a Local Server',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter your server address and optional access token',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  _buildForm(),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(tokens(context).radiusMd),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _serverUrlController,
          enabled: !_isConnecting,
          decoration: const InputDecoration(
            labelText: 'Server Address *',
            hintText: '192.168.1.100:32400 or example.local',
            border: OutlineInputBorder(),
            helperText: 'IP address or hostname with optional port',
          ),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _serverNameController,
          enabled: !_isConnecting,
          decoration: const InputDecoration(
            labelText: 'Server Name',
            hintText: 'My Plex Server',
            border: OutlineInputBorder(),
            helperText: 'Leave blank for automatic naming',
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _serverTokenController,
          enabled: !_isConnecting,
          decoration: const InputDecoration(
            labelText: 'Access Token (Optional)',
            hintText: 'Leave blank for guest access',
            border: OutlineInputBorder(),
            helperText: 'Required for full library access',
          ),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: _isConnecting ? null : (_) => _connectToManualServer(),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _isConnecting ? null : _connectToManualServer,
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: _isConnecting
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.onPrimary),
                  ),
                )
              : const Text('Connect to Server'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _isConnecting ? null : _goBack,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
