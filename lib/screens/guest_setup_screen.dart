import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/plex_auth_service.dart';
import '../services/storage_service.dart';
import '../services/server_registry.dart';
import '../services/server_connection_orchestrator.dart';
import '../providers/multi_server_provider.dart';
import '../providers/libraries_provider.dart';
import '../services/offline_watch_sync_service.dart';
import '../i18n/strings.g.dart';
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
  String? _errorMessage;
  late PlexAuthService _authService;
  bool _shouldCancelConnection = false;

  @override
  void initState() {
    super.initState();
    _initializeAuthService();
  }

  Future<void> _initializeAuthService() async {
    _authService = await PlexAuthService.create();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _serverNameController.dispose();
    _serverTokenController.dispose();
    super.dispose();
  }

  /// Parse server URL into protocol, address, and port
  /// Returns null if URL is invalid
  ({String protocol, String address, int port})? _parseServerUrl(String url) {
    try {
      // Ensure URL has a protocol
      String normalizedUrl = url;
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        // Try HTTP first as default for manual entry
        normalizedUrl = 'http://$url';
      }

      final uri = Uri.parse(normalizedUrl);
      
      if (uri.host.isEmpty) {
        return null;
      }

      final protocol = uri.scheme;
      final address = uri.host;
      final port = uri.port > 0 ? uri.port : (protocol == 'https' ? 443 : 80);

      return (protocol: protocol, address: address, port: port);
    } catch (error) {
      appLogger.w('Failed to parse server URL', error: error);
      return null;
    }
  }

  /// Connect to the manual server and save it
  Future<void> _connectToManualServer() async {
    if (!mounted) return;

    final url = _serverUrlController.text.trim();
    final displayName = _serverNameController.text.trim();
    final token = _serverTokenController.text.trim();

    if (url.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a server URL';
      });
      return;
    }

    final parsed = _parseServerUrl(url);
    if (parsed == null) {
      setState(() {
        _errorMessage = 'Invalid server URL format';
      });
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      // Build the connection URI from parsed URL
      final connectionUri = '${parsed.protocol}://${parsed.address}:${parsed.port}';

      // Create PlexConnection
      final connection = PlexConnection(
        protocol: parsed.protocol,
        address: parsed.address,
        port: parsed.port,
        uri: connectionUri,
        local: true, // Assume local for manual entry
        relay: false,
        ipv6: parsed.address.contains(':'),
      );

      // Create PlexServer with optional token (can be empty for guest mode)
      final serverName = displayName.isNotEmpty ? displayName : 'Local Server';
      final generatedId = _generateServerId();
      
      final server = PlexServer(
        name: serverName,
        clientIdentifier: generatedId,
        accessToken: token.isNotEmpty ? token : '',
        connections: [connection],
        owned: false,
        presence: false,
      );

      final storage = await StorageService.getInstance();
      final registry = ServerRegistry(storage);
      await registry.upsertServer(server);

      if (!mounted) return;

      final result = await ServerConnectionOrchestrator.connectAndInitialize(
        servers: [server],
        multiServerProvider: context.read<MultiServerProvider>(),
        librariesProvider: context.read<LibrariesProvider>(),
        syncService: context.read<OfflineWatchSyncService>(),
        clientIdentifier: _authService.clientIdentifier,
      );

      if (_shouldCancelConnection) {
        if (!mounted) return;
        setState(() => _isConnecting = false);
        Navigator.of(context).maybePop();
        return;
      }

      if (!result.hasConnections || result.firstClient == null) {
        if (!mounted) return;
        setState(() {
          _isConnecting = false;
          _errorMessage = t.serverSelection.allServerConnectionsFailed;
        });
        return;
      }

      if (!mounted) return;
      // Skip UserProfileProvider initialization for guest mode (no Plex token)
      // Navigate to main screen directly
      Navigator.pushReplacement(context, fadeRoute(MainScreen(client: result.firstClient!)));
    } catch (error) {
      appLogger.e('Failed to connect to manual server', error: error);
      if (!mounted) return;
      // Safely extract error message
      final errorMsg = error is Exception 
        ? error.toString().replaceAll('Exception: ', '').replaceAll('FormatException: ', '')
        : 'Connection failed. Please check your server address and try again.';
      setState(() {
        _isConnecting = false;
        _errorMessage = errorMsg.length > 200 ? '${errorMsg.substring(0, 200)}...' : errorMsg;
      });
    }
  }

  /// Generate a unique server ID for manual servers
  String _generateServerId() {
    return 'manual_${DateTime.now().millisecondsSinceEpoch}';
  }

  void _goBack() {
    // Clear any error state and abort connection if in progress
    setState(() {
      _errorMessage = null;
      _isConnecting = false;
    });
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 700;

    return PopScope(
      canPop: !_isConnecting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          // Back button was pressed but canPop is false (still connecting)
          setState(() => _shouldCancelConnection = true);
        }
      },
      child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _isConnecting ? null : _goBack,
        ),
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
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
        // Server URL field (required)
        TextField(
          controller: _serverUrlController,
          enabled: !_isConnecting,
          decoration: InputDecoration(
            labelText: 'Server Address *',
            hintText: '192.168.1.100:32400 or example.local',
            border: const OutlineInputBorder(),
            helperText: 'IP address or hostname with optional port',
          ),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),
        // Server name field (optional)
        TextField(
          controller: _serverNameController,
          enabled: !_isConnecting,
          decoration: InputDecoration(
            labelText: 'Server Name',
            hintText: 'My Plex Server',
            border: const OutlineInputBorder(),
            helperText: 'Leave blank for automatic naming',
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),
        // Server token field (optional)
        TextField(
          controller: _serverTokenController,
          enabled: !_isConnecting,
          decoration: InputDecoration(
            labelText: 'Access Token (Optional)',
            hintText: 'Leave blank for guest access',
            border: const OutlineInputBorder(),
            helperText: 'Required for full library access',
          ),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: _isConnecting ? null : (_) => _connectToManualServer(),
        ),
        const SizedBox(height: 24),
        // Connect button
        ElevatedButton(
          onPressed: _isConnecting ? null : _connectToManualServer,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: _isConnecting
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                )
              : const Text('Connect to Server'),
        ),
        const SizedBox(height: 12),
        // Cancel button
        OutlinedButton(
          onPressed: _isConnecting ? null : _goBack,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
