import "update_manager_stub.dart" if (dart.library.io) "update_manager_io.dart";

abstract class UpdateManager {
  static UpdateManager get instance => getUpdateManager();

  bool get isAvailable;

  /// Terminates the current UI process.
  ///
  /// The packaged updater will restart the app after installing.
  void exitApp();

  Future<BuildInfo?> readBuildInfo();

  /// Returns the default GitHub repo (owner/name) if embedded in build-info.json.
  Future<String?> defaultGitHubRepo();

  Future<UpdateCheckResult> checkLatest({required String gitHubRepo});

  /// Starts an external updater process, then the caller should exit the app.
  ///
  /// Only supported in packaged Windows builds.
  Future<UpdateInstallResult> installUpdate({
    required UpdateRelease latest,
    required String installAssetUrl,
    bool startMinimized = false,
    void Function(UpdateInstallProgress progress)? onProgress,
  });
}

class BuildInfo {
  const BuildInfo({
    this.builtAt,
    this.git,
    this.gitTag,
    this.gitDescribe,
    this.coreVersion,
    this.collectorVersion,
    this.updateGitHubRepo,
    this.updateAssetSuffix,
  });

  final String? builtAt;
  final String? git;
  final String? gitTag;
  final String? gitDescribe;
  final String? coreVersion;
  final String? collectorVersion;
  final String? updateGitHubRepo;
  final String? updateAssetSuffix;
}

class UpdateRelease {
  const UpdateRelease({
    required this.tag,
    this.name,
    this.publishedAt,
    this.body,
    this.assetName,
    this.assetUrl,
    this.assetSizeBytes,
    this.htmlUrl,
  });

  final String tag;
  final String? name;
  final String? publishedAt;
  final String? body;
  final String? assetName;
  final String? assetUrl;
  final int? assetSizeBytes;
  final String? htmlUrl;
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.ok,
    this.error,
    this.current,
    this.latest,
    required this.updateAvailable,
  });

  final bool ok;
  final String? error;
  final BuildInfo? current;
  final UpdateRelease? latest;
  final bool updateAvailable;
}

class UpdateInstallResult {
  const UpdateInstallResult({required this.ok, this.error});

  final bool ok;
  final String? error;
}

enum UpdateInstallPhase {
  preparing,
  downloading,
  launchingInstaller,
}

class UpdateInstallProgress {
  const UpdateInstallProgress({
    required this.phase,
    this.downloadedBytes = 0,
    this.totalBytes,
  });

  final UpdateInstallPhase phase;
  final int downloadedBytes;
  final int? totalBytes;

  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final value = downloadedBytes / total;
    return value.clamp(0.0, 1.0);
  }
}
