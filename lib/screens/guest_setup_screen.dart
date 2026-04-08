import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/plex_auth_service.dart';
import '../services/manual_server_utils.dart';
import '../providers/multi_server_provider.dart';
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

  /// Connect to the manual server and save it
  Future<void> _connectToManualServer() async {
    if (!mounted) return;

    final url = _serverUrlController.text.trim();
    final displayName = _serverNameController.text.trim();
    final token = _serverTokenController.text.trim();

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
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
        setState(() => _isConnecting = false);
        Navigator.of(context).maybePop();
        return;
      }

      if (!success) {
        setState(() {
          _isConnecting = false;
          _errorMessage = error ?? t.serverSelection.allServerConnectionsFailed;
        });
        return;
      }

      if (!mounted) return;
      // Skip UserProfileProvider initialization for guest mode (no Plex token)
      // Navigate to main screen directly with the first connected client
      final multiServerProvider = context.read<MultiServerProvider>();
      final firstServerId = multiServerProvider.onlineServerIds.firstOrNull;
      
      if (firstServerId != null) {
        final client = multiServerProvider.getClientForServer(firstServerId);
        if (client != null) {
          Navigator.pushReplacement(context, fadeRoute(MainScreen(client: client)));
          return;
        }
      }

      setState(() {
        _isConnecting = false;
        _errorMessage = 'Failed to initialize connection';
      });
    } catch (error) {
      appLogger.e('Failed to connect to manual server', error: error);
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _errorMessage = 'Connection failed. Please check your server address and try again.';
      });
    }
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