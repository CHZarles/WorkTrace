import "update_manager.dart";

UpdateManager getUpdateManager() => _StubUpdateManager();

class _StubUpdateManager implements UpdateManager {
  @override
  bool get isAvailable => false;

  @override
  void exitApp() {}

  @override
  Future<BuildInfo?> readBuildInfo() async => null;

  @override
  Future<String?> defaultGitHubRepo() async => null;

  @override
  Future<UpdateCheckResult> checkLatest({required String gitHubRepo}) async {
    return const UpdateCheckResult(
        ok: false, error: "not_supported", updateAvailable: false);
  }

  @override
  Future<UpdateInstallResult> installUpdate({
    required UpdateRelease latest,
    required String installAssetUrl,
    bool startMinimized = false,
    void Function(UpdateInstallProgress progress)? onProgress,
  }) async {
    return const UpdateInstallResult(ok: false, error: "not_supported");
  }
}
