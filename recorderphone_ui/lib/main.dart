import "package:flutter/material.dart";

import "screens/app_shell.dart";
import "theme/recorder_theme.dart";

void main() {
  runApp(const RecorderPhoneApp());
}

class RecorderPhoneApp extends StatelessWidget {
  const RecorderPhoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "WorkTrace",
      theme: RecorderTheme.light(),
      darkTheme: RecorderTheme.dark(),
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}
