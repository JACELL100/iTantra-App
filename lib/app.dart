import 'package:flutter/material.dart';

import 'di/service_locator.dart';
import 'ui/conversation_screen.dart';
import 'ui/theme.dart';

/// Root widget.
///
/// The locator is passed down explicitly rather than looked up globally, so a
/// widget test can drive the whole app against stub engines and a loopback
/// link with no global state to reset between tests.
class ItantraApp extends StatelessWidget {
  const ItantraApp({super.key, required this.locator});

  final ServiceLocator locator;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iTantra',
      debugShowCheckedModeBanner: false,
      theme: ItantraTheme.light(),
      darkTheme: ItantraTheme.dark(),
      // Field use is often at night; the system setting decides, but the dark
      // theme is the one that gets tuned first.
      themeMode: ThemeMode.system,
      home: ConversationScreen(locator: locator),
    );
  }
}
