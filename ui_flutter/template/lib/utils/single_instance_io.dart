import "dart:async";
import "dart:convert";
import "dart:io";

import "single_instance.dart";

const int _uiControlPort = 17611;
const String _cmdShow = "__show__";

bool _hasFlag(List<String> args, List<String> flags) {
  final set = flags.map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toSet();
  for (final a in args) {
    final s = a.trim().toLowerCase();
    if (set.contains(s)) return true;
  }
  return false;
}

String? _extractDeepLink(List<String> args) {
  for (final a in args) {
    final s = a.trim();
    if (s.startsWith("worktrace://")) return s;
  }
  return null;
}

Future<bool> _forwardToPrimary(List<String> args) async {
  final msg = _extractDeepLink(args) ?? _cmdShow;

  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _uiControlPort,
      timeout: const Duration(milliseconds: 250),
    );
    socket.write("$msg\n");
    await socket.flush();
    try {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(milliseconds: 250))
          .first;
      if (line.trim() == "ok") {
        socket.destroy();
        return true;
      }
    } catch (_) {
      // ignore
    }
    socket.destroy();
  } catch (_) {
    // If forwarding fails, fall back to starting a new instance (best effort).
  }
  return false;
}

Future<SingleInstanceHandle?> ensureSingleInstanceImpl(List<String> args) async {
  // Allow overriding for debugging/troubleshooting.
  if (_hasFlag(args, const ["--no-single-instance"])) {
    return SingleInstanceHandle(messages: const Stream.empty(), dispose: () async {});
  }

  // Only enforce on Windows (where it prevents double-tracking and makes deep links work reliably).
  if (!Platform.isWindows) {
    return SingleInstanceHandle(messages: const Stream.empty(), dispose: () async {});
  }

  // In debug runs it is common to restart the app frequently; keep it enabled by default,
  // but do not hard-fail if something is weird (e.g. port collision).
  // Use a single-subscription stream so messages are buffered until the UI attaches a listener.
  final controller = StreamController<String>();

  ServerSocket? server;
  try {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _uiControlPort);
  } on SocketException {
    // Another instance is likely already running: forward and exit.
    final forwarded = await _forwardToPrimary(args);
    await controller.close();
    if (forwarded) return null;
    // If forwarding didn't succeed (e.g. port collision with another app),
    // do not block startup; run without single-instance enforcement.
    return SingleInstanceHandle(messages: const Stream.empty(), dispose: () async {});
  } catch (_) {
    // Unexpected error: do not block startup.
    await controller.close();
    return SingleInstanceHandle(messages: const Stream.empty(), dispose: () async {});
  }

  unawaited(() async {
    await for (final socket in server!) {
      unawaited(() async {
        try {
          final bytes = await socket
              .timeout(const Duration(seconds: 3))
              .fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
          final text = utf8.decode(bytes, allowMalformed: true).trim();
          if (text.isNotEmpty) controller.add(text);
          socket.write("ok\n");
          await socket.flush();
        } catch (_) {
          // ignore
        } finally {
          try {
            socket.destroy();
          } catch (_) {
            // ignore
          }
        }
      }());
    }
  }());

  return SingleInstanceHandle(
    messages: controller.stream,
    dispose: () async {
      try {
        await server?.close();
      } catch (_) {
        // ignore
      }
      try {
        await controller.close();
      } catch (_) {
        // ignore
      }
    },
  );
}
