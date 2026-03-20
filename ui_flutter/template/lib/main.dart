import "package:flutter/material.dart";
import "package:flutter/foundation.dart";

import "package:shared_preferences/shared_preferences.dart";

import "utils/platform_args.dart";
import "utils/single_instance.dart";

import "screens/app_shell.dart";
import "theme/recorder_theme.dart";

const _prefWindowsDisableSemantics = "windows_disable_semantics";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final args = executableArgs();
  final deepLink = _extractDeepLink(args);
  final startMinimized =
      _hasFlag(args, const ["--minimized", "--tray", "--background"]) ||
          _isBackgroundDeepLink(deepLink);

  final disableSemantics = await _resolveDisableSemantics(args);

  final single = await ensureSingleInstance(args);
  if (single == null) {
    // Another instance is running; args have been forwarded.
    return;
  }

  runApp(
    RecorderPhoneApp(
      initialDeepLink: deepLink,
      startMinimized: startMinimized,
      externalCommands: single.messages,
      disableSemantics: disableSemantics,
    ),
  );
}

class RecorderPhoneApp extends StatelessWidget {
  const RecorderPhoneApp({
    super.key,
    this.initialDeepLink,
    this.startMinimized = false,
    this.externalCommands,
    this.disableSemantics = false,
  });

  final String? initialDeepLink;
  final bool startMinimized;
  final Stream<String>? externalCommands;
  final bool disableSemantics;

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: "RecorderPhone",
      theme: RecorderTheme.light(),
      darkTheme: RecorderTheme.dark(),
      themeMode: ThemeMode.system,
      home: AppShell(
        initialDeepLink: initialDeepLink,
        startMinimized: startMinimized,
        externalCommands: externalCommands,
      ),
    );

    if (!disableSemantics) return app;
    return ExcludeSemantics(child: app);
  }
}

String? _extractDeepLink(List<String> args) {
  for (final a in args) {
    final s = a.trim();
    if (s.startsWith("recorderphone://")) return s;
  }
  return null;
}

bool _isBackgroundDeepLink(String? raw) {
  final s = (raw ?? "").trim();
  if (s.isEmpty) return false;
  final uri = Uri.tryParse(s);
  if (uri == null || uri.scheme != "recorderphone") return false;
  final action = (uri.queryParameters["action"] ?? "").trim().toLowerCase();
  return action == "skip" || action == "pause" || action == "resume";
}

bool _hasFlag(List<String> args, List<String> flags) {
  final set = flags
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toSet();
  for (final a in args) {
    final s = a.trim().toLowerCase();
    if (set.contains(s)) return true;
  }
  return false;
}

Future<bool> _resolveDisableSemantics(List<String> args) async {
  final isWindows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  if (!isWindows) return false;

  // Opt-in flags (so you can debug with accessibility enabled when needed).
  final wantA11y =
      _hasFlag(args, const ["--a11y", "--enable-a11y", "--accessibility"]);
  if (wantA11y) return false;

  // Persisted setting (defaults to "on" in debug to avoid noisy AXTree logs).
  try {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_prefWindowsDisableSemantics);
    if (v != null) return v;
  } catch (_) {
    // ignore
  }
  return kDebugMode;
}
