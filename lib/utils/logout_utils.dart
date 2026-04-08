import 'package:flutter/material.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/utils/dialogs.dart';
import 'package:provider/provider.dart';

import '../providers/hidden_libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../providers/playback_state_provider.dart';
import '../providers/user_profile_provider.dart';
import '../screens/auth_screen.dart';

class LogoutUtils {
  static Future<void> confirmAndLogout(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.common.logout,
      message: t.messages.logoutConfirm,
      confirmText: t.common.logout,
      isDestructive: true,
    );

    if (!confirmed || !context.mounted) return;
    await logout(context);
  }

  static Future<void> logout(BuildContext context) async {
    if (!context.mounted) return;

    final userProfileProvider = context.read<UserProfileProvider>();
    final multiServerProvider = context.read<MultiServerProvider>();
    final hiddenLibrariesProvider = context.read<HiddenLibrariesProvider>();
    final playbackStateProvider = context.read<PlaybackStateProvider>();
    final navigator = Navigator.of(context);

    await userProfileProvider.logout();
    multiServerProvider.clearAllConnections();
    await hiddenLibrariesProvider.refresh();
    playbackStateProvider.clearShuffle();

    if (!context.mounted) return;
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
      (route) => false,
    );
  }

}