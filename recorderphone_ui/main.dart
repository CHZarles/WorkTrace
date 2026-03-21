import "package:flutter/material.dart";

import "screens/app_shell.dart";
import "theme/recorder_theme.dart";

void main() {
  runApp(const WorkTraceApp());
}

class WorkTraceApp extends StatelessWidget {
  const WorkTraceApp({super.key});

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
