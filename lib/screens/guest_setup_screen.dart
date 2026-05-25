import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_registry.dart';
import '../i18n/strings.g.dart';
import '../profiles/active_profile_binder.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_registry.dart';
import '../utils/app_logger.dart';
import '../utils/manual_server_utils.dart';
import '../utils/navigation_transitions.dart';
import '../widgets/add_server_form.dart';
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

  Future<void> _connectToManualServer() async {
    if (!mounted) return;

    final url = _serverUrlController.text.trim();
    final displayName = _serverNameController.text.trim();
    final token = _serverTokenController.text.trim();

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
      final result = await ManualServerUtils.addManualServer(
        url: url,
        displayName: displayName,
        token: token,
        connectionRegistry: connectionRegistry,
        profileRegistry: profileRegistry,
        profileConnectionRegistry: profileConnectionRegistry,
        activeProfiles: activeProfiles,
        activeProfileBinder: activeProfileBinder,
        shouldCancelConnection: () => _shouldCancelConnection,
      );

      if (result.cancelled) {
        if (!mounted) return;
        setState(() => _isConnecting = false);
        unawaited(Navigator.of(context).maybePop());
        return;
      }

      if (!result.connected) {
        if (!mounted) return;
        setState(() {
          _isConnecting = false;
          _errorMessage = result.error ?? t.serverSelection.allServerConnectionsFailed;
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
                  AddServerForm(
                    urlController: _serverUrlController,
                    nameController: _serverNameController,
                    tokenController: _serverTokenController,
                    onSubmit: _connectToManualServer,
                    onCancel: _goBack,
                    isConnecting: _isConnecting,
                    errorMessage: _errorMessage,
                    submitButtonLabel: 'Connect to Server',
                    showCancelButton: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
