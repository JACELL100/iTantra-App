import 'package:flutter/material.dart';

import '../core/session/session_launcher.dart';
import 'animation.dart';
import 'app_controller.dart';
import 'conversation_screen.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';
import 'theme.dart';

/// Decides what the app is showing.
///
/// Three states, and the transition between them is the app's story: first run
/// explains itself, then the home screen sets up a link, and the conversation
/// screen appears the moment that link is live. Nobody has to navigate.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: ItantraTheme.medium,
      switchInCurve: ItantraTheme.emphasizeCurve,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        children: <Widget>[
          ...previous,
          if (current != null) current,
        ],
      ),
      child: _build(context),
    );
  }

  Widget _build(BuildContext context) {
    if (!controller.onboarded) {
      return OnboardingScreen(
        key: const ValueKey<String>('onboarding'),
        controller: controller,
      );
    }

    final LaunchState launch = controller.launch;
    final bool live = launch is LaunchLive;

    if (live) {
      return ConversationScreen(
        key: const ValueKey<String>('conversation'),
        controller: controller,
      );
    }

    return HomeScreen(
      key: const ValueKey<String>('home'),
      controller: controller,
    );
  }
}

/// Shown while the very first frame is being prepared.
///
/// Kept deliberately plain: a splash screen that animates something elaborate
/// only makes a slow cold start feel slower.
class SplashOverlay extends StatelessWidget {
  const SplashOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return GradientBackdrop(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cell_tower_rounded,
              size: 52,
              color: context.colors.primary,
            ),
            const SizedBox(height: 16),
            Text('iTantra', style: context.texts.headlineSmall),
          ],
        ),
      ),
    );
  }
}
