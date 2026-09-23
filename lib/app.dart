import 'package:flutter/material.dart';

import 'ui/conversation_screen.dart';
import 'ui/theme.dart';

/// Root widget.
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
      home: const ConversationScreen(),
    );
  }
}
