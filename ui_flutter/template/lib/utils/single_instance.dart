import "single_instance_stub.dart" if (dart.library.io) "single_instance_io.dart";

class SingleInstanceHandle {
  const SingleInstanceHandle({
    required this.messages,
    required this.dispose,
  });

  /// Incoming commands from secondary launches.
  ///
  /// Messages are simple strings:
  /// - `"__show__"`: bring the existing window to foreground
  /// - `"worktrace://..."`: forward deep link to the running instance
  final Stream<String> messages;
  final Future<void> Function() dispose;
}

/// Ensures there is a single UI instance.
///
/// - If this process becomes the primary instance, returns a [SingleInstanceHandle]
///   that provides a stream of forwarded commands.
/// - If another instance is already running, forwards the current args to it and
///   returns `null` (caller should exit).
Future<SingleInstanceHandle?> ensureSingleInstance(List<String> args) => ensureSingleInstanceImpl(args);
