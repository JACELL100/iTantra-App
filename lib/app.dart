import 'package:flutter/material.dart';

import 'ui/conversation_screen.dart';
import 'ui/diagnostics_screen.dart';
import 'ui/home_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

/// Root widget.
///
/// Named routes keep navigation history clean so the back button works
/// correctly when the conversation screen replaces the pairing screens:
/// pressing back from conversation returns to home, not mid-pairing.
class ItantraApp extends StatelessWidget {
  const ItantraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iTantra',
      debugShowCheckedModeBanner: false,
      theme: ItantraTheme.light(),
      darkTheme: ItantraTheme.dark(),
      themeMode: ThemeMode.system,
      // The session setup (home) is the entry point. Users land on the
      // conversation screen only after pairing or starting a loopback demo.
      initialRoute: '/',
      routes: <String, WidgetBuilder>{
        '/': (BuildContext context) => const HomeScreen(),
        '/conversation': (BuildContext context) => const ConversationScreen(),
        '/settings': (BuildContext context) => const SettingsScreen(),
        '/diagnostics': (BuildContext context) => const DiagnosticsScreen(),
      },
    );
  }
}
