import "dart:io";

import "package:flutter/foundation.dart";

import "startup.dart";

StartupController getStartupController() => _IoStartupController();

class _IoStartupController implements StartupController {
  static const _runKey = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
  static const _valueName = "WorkTrace";

  @override
  bool get isAvailable => !kIsWeb && Platform.isWindows;

  @override
  Future<bool> isEnabled() async {
    if (!isAvailable) return false;
    return _hasValue(_valueName);
  }

  Future<bool> _hasValue(String name) async {
    if (!isAvailable) return false;
    try {
      final res = await Process.run("reg", ["query", _runKey, "/v", name],
          runInShell: false);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteValue(String name) async {
    try {
      await Process.run(
        "reg",
        ["delete", _runKey, "/v", name, "/f"],
        runInShell: false,
      );
    } catch (_) {
      // ignore
    }
  }

  String _startupCommand({required bool startHidden}) {
    final exe = Platform.resolvedExecutable;
    final quotedExe = exe.contains(" ") ? "\"$exe\"" : exe;
    if (!startHidden) return quotedExe;
    return "$quotedExe --minimized";
  }

  @override
  Future<void> setEnabled(bool enabled, {bool startHidden = true}) async {
    if (!isAvailable) return;
    if (enabled) {
      final cmd = _startupCommand(startHidden: startHidden);
      final res = await Process.run(
        "reg",
        ["add", _runKey, "/v", _valueName, "/t", "REG_SZ", "/d", cmd, "/f"],
        runInShell: false,
      );
      if (res.exitCode != 0) {
        final err = (res.stderr ?? "").toString().trim();
        throw Exception(err.isEmpty ? "reg_add_failed_${res.exitCode}" : err);
      }
      return;
    }

    await _deleteValue(_valueName);
  }
}
