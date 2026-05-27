import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/mono_tokens.dart';
import 'app_icon.dart';

/// Reusable form widget for adding a manual Plex server.
class AddServerForm extends StatelessWidget {
  final TextEditingController urlController;
  final TextEditingController nameController;
  final TextEditingController tokenController;
  final VoidCallback onSubmit;
  final VoidCallback? onCancel;
  final bool isConnecting;
  final String? errorMessage;
  final String submitButtonLabel;
  final bool showCancelButton;

  const AddServerForm({
    super.key,
    required this.urlController,
    required this.nameController,
    required this.tokenController,
    required this.onSubmit,
    this.onCancel,
    this.isConnecting = false,
    this.errorMessage,
    this.submitButtonLabel = 'Connect to Server',
    this.showCancelButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: urlController,
          enabled: !isConnecting,
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
          controller: nameController,
          enabled: !isConnecting,
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
          controller: tokenController,
          enabled: !isConnecting,
          decoration: const InputDecoration(
            labelText: 'Access Token (Optional)',
            hintText: 'Leave blank for guest access',
            border: OutlineInputBorder(),
            helperText: 'Required for full library access',
          ),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: isConnecting ? null : (_) => onSubmit(),
        ),
        if (errorMessage != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(tokens(context).radiusMd),
            ),
            child: Text(
              errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: isConnecting ? null : onSubmit,
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          icon: isConnecting
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.onPrimary),
                  ),
                )
              : const AppIcon(Symbols.storage_rounded, fill: 1),
          label: Text(isConnecting ? 'Connecting...' : submitButtonLabel),
        ),
        if (showCancelButton) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: isConnecting ? null : onCancel,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }
}
