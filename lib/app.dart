import 'package:flutter/material.dart';

import 'di/service_locator.dart';
import 'ui/app_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

/// Root widget.
///
/// The locator is passed down explicitly rather than looked up globally, so a
/// widget test can drive the whole app against stub engines and a loopback link
/// with no global state to reset between tests.
class ItantraApp extends StatefulWidget {
  const ItantraApp({super.key, required this.locator});

  final ServiceLocator locator;

  @override
  State<ItantraApp> createState() => _ItantraAppState();
}

class _ItantraAppState extends State<ItantraApp> {
  late final AppController _controller = AppController(widget.locator);

  @override
  void initState() {
    super.initState();
    // The transcript is restored before any link exists, so a user who reopens
    // the app after a crash still has the last messages in front of them even
    // if they cannot reconnect yet.
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) => MaterialApp(
        title: 'iTantra',
        debugShowCheckedModeBanner: false,
        theme: ItantraTheme.light(),
        darkTheme: ItantraTheme.dark(),
        // Field use is often at night, so the dark theme is the one that gets
        // tuned first; the system setting decides unless the user overrides it
        // in settings.
        themeMode: _controller.themeMode,
        home: AppShell(controller: _controller),
        builder: (BuildContext context, Widget? child) {
          // The text scaler is clamped once, here, rather than in every widget.
          // At the OS maximum an Indic transcript is already at the edge of
          // what a phone can show without breaking the layout, and beyond that
          // the app becomes unusable rather than merely large.
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: MediaQuery.textScalerOf(context).clamp(
                minScaleFactor: 0.85,
                maxScaleFactor: 2.0,
              ),
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}
