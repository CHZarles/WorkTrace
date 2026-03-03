import "dart:convert";

import "package:http/http.dart" as http;

class HealthInfo {
  HealthInfo({this.service, this.version});

  final String? service;
  final String? version;
}

class CoreClient {
  CoreClient({required this.baseUrl, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  void close() {
    _http.close();
  }

  Uri _u(String path, [Map<String, String>? q]) {
    final trimmed = baseUrl.endsWith("/")
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse("$trimmed$path").replace(queryParameters: q);
  }

  Future<bool> health() async {
    final res = await _http.get(_u("/health"));
    return res.statusCode == 200;
  }

  /// Polls `/health` until it returns 200 or timeout.
  ///
  /// This is mainly used for "packaged desktop" flows where Core is started
  /// in the background and the UI may navigate before the server is ready.
  Future<bool> waitUntilHealthy({
    Duration timeout = const Duration(seconds: 6),
    Duration requestTimeout = const Duration(milliseconds: 900),
    Duration initialDelay = const Duration(milliseconds: 200),
    Duration maxDelay = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var delay = initialDelay;

    while (true) {
      try {
        final ok = await health().timeout(requestTimeout);
        if (ok) return true;
      } catch (_) {
        // ignore and retry
      }

      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(delay);

      final nextMs = (delay.inMilliseconds * 1.6).round();
      delay = Duration(
        milliseconds: nextMs.clamp(
          initialDelay.inMilliseconds,
          maxDelay.inMilliseconds,
        ),
      );
    }
  }

  Future<HealthInfo> healthInfo() async {
    final res = await _http.get(_u("/health"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] is Map<String, dynamic>)
        ? (obj["data"] as Map<String, dynamic>)
        : obj;
    final service =
        data["service"] is String ? (data["service"] as String) : null;
    final version =
        data["version"] is String ? (data["version"] as String) : null;
    return HealthInfo(service: service, version: version);
  }

  Future<List<BlockSummary>> blocksToday(
      {required String date, required int tzOffsetMinutes}) async {
    final res = await _http.get(
      _u("/blocks/today",
          {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data
        .map((e) => BlockSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<BlockSummary?> blocksDue(
      {required String date, required int tzOffsetMinutes}) async {
    final res = await _http.get(
      _u("/blocks/due",
          {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"];
    if (data == null) return null;
    if (data is! Map<String, dynamic>) throw Exception("invalid_response");
    return BlockSummary.fromJson(data);
  }

  Future<List<TimelineSegment>> timelineDay(
      {required String date, required int tzOffsetMinutes}) async {
    final res = await _http.get(
      _u("/timeline/day",
          {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data
        .map((e) => TimelineSegment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsertReview(ReviewUpsert r) async {
    final res = await _http.post(
      _u("/blocks/review"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(r.toJson()),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
  }

  Future<List<EventRecord>> events({int limit = 50}) async {
    final l = limit.clamp(1, 500).toString();
    final res = await _http.get(_u("/events", {"limit": l}));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data
        .map((e) => EventRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<NowSnapshot> now({int limit = 200}) async {
    final l = limit.clamp(1, 2000).toString();
    final res = await _http.get(_u("/now", {"limit": l}));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return NowSnapshot.fromJson(data);
  }

  Future<TrackingStatus> trackingStatus() async {
    final res = await _http.get(_u("/tracking/status"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return TrackingStatus.fromJson(data);
  }

  Future<TrackingStatus> pauseTracking({int? minutes}) async {
    final body = minutes == null ? <String, dynamic>{} : {"minutes": minutes};
    final res = await _http.post(
      _u("/tracking/pause"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return TrackingStatus.fromJson(data);
  }

  Future<TrackingStatus> resumeTracking() async {
    final res = await _http.post(_u("/tracking/resume"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return TrackingStatus.fromJson(data);
  }

  Future<CoreSettings> settings() async {
    final res = await _http.get(_u("/settings"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return CoreSettings.fromJson(data);
  }

  Future<CoreSettings> updateSettings({
    int? blockSeconds,
    int? idleCutoffSeconds,
    bool? storeTitles,
    bool? storeExePath,
    int? reviewMinSeconds,
    int? reviewNotifyRepeatMinutes,
    bool? reviewNotifyWhenPaused,
    bool? reviewNotifyWhenIdle,
  }) async {
    final body = <String, dynamic>{};
    if (blockSeconds != null) body["block_seconds"] = blockSeconds;
    if (idleCutoffSeconds != null)
      body["idle_cutoff_seconds"] = idleCutoffSeconds;
    // Privacy-level toggles (Core controls what is persisted even if collectors send more fields).
    if (storeTitles != null) body["store_titles"] = storeTitles;
    if (storeExePath != null) body["store_exe_path"] = storeExePath;
    if (reviewMinSeconds != null) body["review_min_seconds"] = reviewMinSeconds;
    if (reviewNotifyRepeatMinutes != null) {
      body["review_notify_repeat_minutes"] = reviewNotifyRepeatMinutes;
    }
    if (reviewNotifyWhenPaused != null) {
      body["review_notify_when_paused"] = reviewNotifyWhenPaused;
    }
    if (reviewNotifyWhenIdle != null) {
      body["review_notify_when_idle"] = reviewNotifyWhenIdle;
    }

    final res = await _http.post(
      _u("/settings"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return CoreSettings.fromJson(data);
  }

  Future<DeleteRangeResult> deleteBlock(
      {required String startTs, required String endTs}) async {
    final res = await _http.post(
      _u("/blocks/delete"),
      headers: {"content-type": "application/json"},
      body: jsonEncode({"start_ts": startTs, "end_ts": endTs}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return DeleteRangeResult.fromJson(data);
  }

  Future<DeleteDayResult> deleteDay(
      {required String date, required int tzOffsetMinutes}) async {
    final res = await _http.post(
      _u("/data/delete_day"),
      headers: {"content-type": "application/json"},
      body: jsonEncode({"date": date, "tz_offset_minutes": tzOffsetMinutes}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return DeleteDayResult.fromJson(data);
  }

  Future<WipeAllResult> wipeAllData() async {
    final res = await _http.post(
      _u("/data/wipe"),
      headers: {"content-type": "application/json"},
      body: jsonEncode({}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return WipeAllResult.fromJson(data);
  }

  Future<List<PrivacyRule>> privacyRules() async {
    final res = await _http.get(_u("/privacy/rules"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data
        .map((e) => PrivacyRule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<PrivacyRule> upsertPrivacyRule(PrivacyRuleUpsert r) async {
    final res = await _http.post(
      _u("/privacy/rules"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(r.toJson()),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return PrivacyRule.fromJson(data);
  }

  Future<void> deletePrivacyRule(int id) async {
    final res = await _http.delete(_u("/privacy/rules/$id"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
  }

  Future<String> exportMarkdown(
      {required String date, required int tzOffsetMinutes}) async {
    final res = await _http.get(
      _u("/export/markdown",
          {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    return res.body;
  }

  Future<String> exportCsv(
      {required String date, required int tzOffsetMinutes}) async {
    final res = await _http.get(
      _u("/export/csv",
          {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    return res.body;
  }

  Future<List<ReportSummary>> reports({int limit = 50}) async {
    final res = await _http.get(_u("/reports", {"limit": limit.toString()}));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data
        .map((e) => ReportSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ReportSettings> reportSettings() async {
    final res = await _http.get(_u("/reports/settings"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return ReportSettings.fromJson(data);
  }

  Future<ReportSettings> updateReportSettings({
    bool? enabled,
    String? apiBaseUrl,
    String? apiKey,
    String? model,
    bool? dailyEnabled,
    int? dailyAtMinutes,
    String? dailyPrompt,
    bool? weeklyEnabled,
    int? weeklyWeekday,
    int? weeklyAtMinutes,
    String? weeklyPrompt,
    bool? saveMd,
    bool? saveCsv,
    String? outputDir,
  }) async {
    final body = <String, dynamic>{};
    if (enabled != null) body["enabled"] = enabled;
    if (apiBaseUrl != null) body["api_base_url"] = apiBaseUrl;
    if (apiKey != null) body["api_key"] = apiKey;
    if (model != null) body["model"] = model;
    if (dailyEnabled != null) body["daily_enabled"] = dailyEnabled;
    if (dailyAtMinutes != null) body["daily_at_minutes"] = dailyAtMinutes;
    if (dailyPrompt != null) body["daily_prompt"] = dailyPrompt;
    if (weeklyEnabled != null) body["weekly_enabled"] = weeklyEnabled;
    if (weeklyWeekday != null) body["weekly_weekday"] = weeklyWeekday;
    if (weeklyAtMinutes != null) body["weekly_at_minutes"] = weeklyAtMinutes;
    if (weeklyPrompt != null) body["weekly_prompt"] = weeklyPrompt;
    if (saveMd != null) body["save_md"] = saveMd;
    if (saveCsv != null) body["save_csv"] = saveCsv;
    if (outputDir != null) body["output_dir"] = outputDir;

    final res = await _http.post(
      _u("/reports/settings"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return ReportSettings.fromJson(data);
  }

  Future<ReportRecord> generateDailyReport({
    String? date,
    int? tzOffsetMinutes,
    bool force = false,
  }) async {
    final body = <String, dynamic>{
      "force": force,
    };
    if (date != null) body["date"] = date;
    if (tzOffsetMinutes != null) body["tz_offset_minutes"] = tzOffsetMinutes;

    final res = await _http.post(
      _u("/reports/generate/daily"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return ReportRecord.fromJson(data);
  }

  Future<ReportRecord> generateWeeklyReport({
    String? weekStart,
    int? tzOffsetMinutes,
    bool force = false,
  }) async {
    final body = <String, dynamic>{
      "force": force,
    };
    if (weekStart != null) body["week_start"] = weekStart;
    if (tzOffsetMinutes != null) body["tz_offset_minutes"] = tzOffsetMinutes;

    final res = await _http.post(
      _u("/reports/generate/weekly"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return ReportRecord.fromJson(data);
  }

  Future<ReportRecord> reportById(String id) async {
    final rid = id.trim();
    final res = await _http.get(_u("/reports/$rid"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return ReportRecord.fromJson(data);
  }

  Future<List<ReportTodo>> reportTodos({int limit = 200}) async {
    final l = limit.clamp(1, 500).toString();
    final res = await _http.get(_u("/reports/todos", {"limit": l}));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data
        .map((e) => ReportTodo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ReportTodo> upsertReportTodo({
    int? id,
    String? content,
    bool? done,
    String? dueDate,
    String? startTs,
    String? endTs,
    String? reminderTs,
  }) async {
    final body = <String, dynamic>{};
    if (id != null) body["id"] = id;
    if (content != null) body["content"] = content;
    if (done != null) body["done"] = done;
    if (dueDate != null) body["due_date"] = dueDate;
    if (startTs != null) body["start_ts"] = startTs;
    if (endTs != null) body["end_ts"] = endTs;
    if (reminderTs != null) body["reminder_ts"] = reminderTs;

    final res = await _http.post(
      _u("/reports/todos"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return ReportTodo.fromJson(data);
  }

  Future<void> deleteReportTodo(int id) async {
    final res = await _http.delete(_u("/reports/todos/$id"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
  }

  Future<ReportRecord> upsertReport(ReportUpsert r) async {
    final res = await _http.post(
      _u("/reports"),
      headers: {"content-type": "application/json"},
      body: jsonEncode(r.toJson()),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as Map<String, dynamic>?);
    if (data == null) throw Exception("invalid_response");
    return ReportRecord.fromJson(data);
  }

  Future<void> deleteReport(String id) async {
    final rid = id.trim();
    if (rid.isEmpty) return;
    final res = await _http.delete(_u("/reports/$rid"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
  }
}

class BlockSummary {
  BlockSummary({
    required this.id,
    required this.startTs,
    required this.endTs,
    required this.totalSeconds,
    required this.topItems,
    required this.backgroundTopItems,
    required this.backgroundSeconds,
    required this.review,
  });

  final String id;
  final String startTs;
  final String endTs;
  final int totalSeconds;
  final List<TopItem> topItems;
  final List<TopItem> backgroundTopItems;
  final int? backgroundSeconds;
  final BlockReview? review;

  factory BlockSummary.fromJson(Map<String, dynamic> json) {
    return BlockSummary(
      id: json["id"] as String,
      startTs: json["start_ts"] as String,
      endTs: json["end_ts"] as String,
      totalSeconds: json["total_seconds"] as int,
      topItems: (json["top_items"] as List<dynamic>? ?? const [])
          .map((e) => TopItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      backgroundTopItems:
          (json["background_top_items"] as List<dynamic>? ?? const [])
              .map((e) => TopItem.fromJson(e as Map<String, dynamic>))
              .toList(),
      backgroundSeconds: json["background_seconds"] as int?,
      review: json["review"] == null
          ? null
          : BlockReview.fromJson(json["review"] as Map<String, dynamic>),
    );
  }
}

class TimelineSegment {
  TimelineSegment({
    required this.kind,
    required this.entity,
    required this.title,
    required this.activity,
    required this.startTs,
    required this.endTs,
    required this.seconds,
  });

  final String kind; // "app" | "domain"
  final String entity; // app id or hostname
  final String? title;
  final String? activity; // "focus" | "audio" | null
  final String startTs;
  final String endTs;
  final int seconds;

  DateTime? _startUtc;
  DateTime? _endUtc;
  DateTime? _startLocal;
  DateTime? _endLocal;

  DateTime? get startUtc {
    return _startUtc ??= DateTime.tryParse(startTs)?.toUtc();
  }

  DateTime? get endUtc {
    return _endUtc ??= DateTime.tryParse(endTs)?.toUtc();
  }

  DateTime? get startLocal {
    final cached = _startLocal;
    if (cached != null) return cached;
    final utc = startUtc;
    if (utc == null) return null;
    return _startLocal = utc.toLocal();
  }

  DateTime? get endLocal {
    final cached = _endLocal;
    if (cached != null) return cached;
    final utc = endUtc;
    if (utc == null) return null;
    return _endLocal = utc.toLocal();
  }

  factory TimelineSegment.fromJson(Map<String, dynamic> json) {
    return TimelineSegment(
      kind: (json["kind"] as String?) ?? "",
      entity: (json["entity"] as String?) ?? "",
      title: json["title"] as String?,
      activity: json["activity"] as String?,
      startTs: (json["start_ts"] as String?) ?? "",
      endTs: (json["end_ts"] as String?) ?? "",
      seconds: (json["seconds"] as int?) ?? 0,
    );
  }
}

class TopItem {
  TopItem({
    required this.kind,
    required this.entity,
    required this.title,
    required this.seconds,
  });

  final String kind; // "app" | "domain" | "unknown"
  final String entity; // app id or hostname
  final String? title; // tab/window title (optional)
  final int seconds;

  factory TopItem.fromJson(Map<String, dynamic> json) {
    final rawEntity =
        (json["entity"] as String?) ?? (json["name"] as String?) ?? "";
    return TopItem(
      kind: (json["kind"] as String?) ?? "unknown",
      entity: rawEntity,
      title: json["title"] as String?,
      seconds: json["seconds"] as int,
    );
  }
}

class BlockReview {
  BlockReview({
    required this.skipped,
    required this.skipReason,
    required this.doing,
    required this.output,
    required this.next,
    required this.tags,
    required this.updatedAt,
  });

  final bool skipped;
  final String? skipReason;
  final String? doing;
  final String? output;
  final String? next;
  final List<String> tags;
  final String updatedAt;

  factory BlockReview.fromJson(Map<String, dynamic> json) {
    return BlockReview(
      skipped: json["skipped"] as bool? ?? false,
      skipReason: json["skip_reason"] as String?,
      doing: json["doing"] as String?,
      output: json["output"] as String?,
      next: json["next"] as String?,
      tags: (json["tags"] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      updatedAt: json["updated_at"] as String,
    );
  }
}

class ReviewUpsert {
  ReviewUpsert({
    required this.blockId,
    this.skipped = false,
    this.skipReason,
    this.doing,
    this.output,
    this.next,
    this.tags = const [],
  });

  final String blockId;
  final bool skipped;
  final String? skipReason;
  final String? doing;
  final String? output;
  final String? next;
  final List<String> tags;

  Map<String, dynamic> toJson() => {
        "block_id": blockId,
        "skipped": skipped,
        "skip_reason": skipReason,
        "doing": doing,
        "output": output,
        "next": next,
        "tags": tags,
      };
}

class EventRecord {
  EventRecord({
    required this.id,
    required this.ts,
    required this.source,
    required this.event,
    required this.entity,
    required this.title,
    required this.activity,
  });

  final int id;
  final String ts;
  final String source;
  final String event;
  final String? entity;
  final String? title;
  final String? activity; // "focus" | "audio" | null

  factory EventRecord.fromJson(Map<String, dynamic> json) {
    return EventRecord(
      id: json["id"] as int,
      ts: json["ts"] as String,
      source: json["source"] as String,
      event: json["event"] as String,
      entity: json["entity"] as String?,
      title: json["title"] as String?,
      activity: json["activity"] as String?,
    );
  }
}

class NowSnapshot {
  NowSnapshot({
    required this.serverTs,
    required this.focusTtlSeconds,
    required this.audioTtlSeconds,
    required this.latestEventId,
    required this.latestEvent,
    required this.latestEventAgeSeconds,
    required this.appActive,
    required this.appActiveAgeSeconds,
    required this.tabFocus,
    required this.tabFocusAgeSeconds,
    required this.tabAudio,
    required this.tabAudioStop,
    required this.tabAudioAgeSeconds,
    required this.tabAudioActive,
    required this.appAudio,
    required this.appAudioStop,
    required this.appAudioAgeSeconds,
    required this.appAudioActive,
    required this.nowFocusApp,
    required this.nowUsingTab,
    required this.nowBackgroundAudio,
    required this.latestTitles,
  });

  final String serverTs;
  final int focusTtlSeconds;
  final int audioTtlSeconds;
  final int? latestEventId;
  final EventRecord? latestEvent;
  final int? latestEventAgeSeconds;
  final EventRecord? appActive;
  final int? appActiveAgeSeconds;
  final EventRecord? tabFocus;
  final int? tabFocusAgeSeconds;
  final EventRecord? tabAudio;
  final EventRecord? tabAudioStop;
  final int? tabAudioAgeSeconds;
  final bool tabAudioActive;
  final EventRecord? appAudio;
  final EventRecord? appAudioStop;
  final int? appAudioAgeSeconds;
  final bool appAudioActive;
  final EventRecord? nowFocusApp;
  final EventRecord? nowUsingTab;
  final EventRecord? nowBackgroundAudio;
  final Map<String, String>
      latestTitles; // key: "app|<entity>" or "domain|<hostname>"

  factory NowSnapshot.fromJson(Map<String, dynamic> json) {
    EventRecord? parseEvent(String key) {
      final raw = json[key];
      if (raw is Map<String, dynamic>) return EventRecord.fromJson(raw);
      return null;
    }

    final titles = <String, String>{};
    final rawTitles = json["latest_titles"];
    if (rawTitles is Map<String, dynamic>) {
      for (final e in rawTitles.entries) {
        final k = e.key;
        final v = e.value;
        if (v is String) {
          titles[k] = v;
        } else if (v != null) {
          titles[k] = v.toString();
        }
      }
    }

    return NowSnapshot(
      serverTs: json["server_ts"] as String? ?? "",
      focusTtlSeconds: (json["focus_ttl_seconds"] as int?) ?? (3 * 60),
      audioTtlSeconds: (json["audio_ttl_seconds"] as int?) ?? 120,
      latestEventId: json["latest_event_id"] as int?,
      latestEvent: parseEvent("latest_event"),
      latestEventAgeSeconds: json["latest_event_age_seconds"] as int?,
      appActive: parseEvent("app_active"),
      appActiveAgeSeconds: json["app_active_age_seconds"] as int?,
      tabFocus: parseEvent("tab_focus"),
      tabFocusAgeSeconds: json["tab_focus_age_seconds"] as int?,
      tabAudio: parseEvent("tab_audio"),
      tabAudioStop: parseEvent("tab_audio_stop"),
      tabAudioAgeSeconds: json["tab_audio_age_seconds"] as int?,
      tabAudioActive: json["tab_audio_active"] as bool? ?? false,
      appAudio: parseEvent("app_audio"),
      appAudioStop: parseEvent("app_audio_stop"),
      appAudioAgeSeconds: json["app_audio_age_seconds"] as int?,
      appAudioActive: json["app_audio_active"] as bool? ?? false,
      nowFocusApp: parseEvent("now_focus_app"),
      nowUsingTab: parseEvent("now_using_tab"),
      nowBackgroundAudio: parseEvent("now_background_audio"),
      latestTitles: titles,
    );
  }
}

class TrackingStatus {
  TrackingStatus({
    required this.paused,
    required this.pausedUntilTs,
    required this.updatedAt,
  });

  final bool paused;
  final String? pausedUntilTs;
  final String updatedAt;

  factory TrackingStatus.fromJson(Map<String, dynamic> json) {
    return TrackingStatus(
      paused: json["paused"] as bool? ?? false,
      pausedUntilTs: json["paused_until_ts"] as String?,
      updatedAt: json["updated_at"] as String? ?? "",
    );
  }
}

class CoreSettings {
  CoreSettings({
    required this.blockSeconds,
    required this.idleCutoffSeconds,
    required this.storeTitles,
    required this.storeExePath,
    required this.reviewMinSeconds,
    required this.reviewNotifyRepeatMinutes,
    required this.reviewNotifyWhenPaused,
    required this.reviewNotifyWhenIdle,
  });

  final int blockSeconds;
  final int idleCutoffSeconds;
  final bool storeTitles;
  final bool storeExePath;
  final int reviewMinSeconds;
  final int reviewNotifyRepeatMinutes;
  final bool reviewNotifyWhenPaused;
  final bool reviewNotifyWhenIdle;

  factory CoreSettings.fromJson(Map<String, dynamic> json) {
    return CoreSettings(
      blockSeconds: (json["block_seconds"] as int?) ?? (45 * 60),
      idleCutoffSeconds: (json["idle_cutoff_seconds"] as int?) ?? (5 * 60),
      storeTitles: (json["store_titles"] as bool?) ?? false,
      storeExePath: (json["store_exe_path"] as bool?) ?? false,
      reviewMinSeconds: (json["review_min_seconds"] as int?) ?? (5 * 60),
      reviewNotifyRepeatMinutes:
          (json["review_notify_repeat_minutes"] as int?) ?? 10,
      reviewNotifyWhenPaused:
          (json["review_notify_when_paused"] as bool?) ?? false,
      reviewNotifyWhenIdle: (json["review_notify_when_idle"] as bool?) ?? false,
    );
  }
}

class DeleteRangeResult {
  DeleteRangeResult({
    required this.startTs,
    required this.endTs,
    required this.eventsDeleted,
    required this.reviewsDeleted,
  });

  final String startTs;
  final String endTs;
  final int eventsDeleted;
  final int reviewsDeleted;

  factory DeleteRangeResult.fromJson(Map<String, dynamic> json) {
    return DeleteRangeResult(
      startTs: (json["start_ts"] as String?) ?? "",
      endTs: (json["end_ts"] as String?) ?? "",
      eventsDeleted: (json["events_deleted"] as int?) ?? 0,
      reviewsDeleted: (json["reviews_deleted"] as int?) ?? 0,
    );
  }
}

class DeleteDayResult {
  DeleteDayResult({
    required this.date,
    required this.tzOffsetMinutes,
    required this.startTs,
    required this.endTs,
    required this.eventsDeleted,
    required this.reviewsDeleted,
    required this.reportsDeleted,
  });

  final String date;
  final int tzOffsetMinutes;
  final String startTs;
  final String endTs;
  final int eventsDeleted;
  final int reviewsDeleted;
  final int reportsDeleted;

  factory DeleteDayResult.fromJson(Map<String, dynamic> json) {
    return DeleteDayResult(
      date: (json["date"] as String?) ?? "",
      tzOffsetMinutes: (json["tz_offset_minutes"] as int?) ?? 0,
      startTs: (json["start_ts"] as String?) ?? "",
      endTs: (json["end_ts"] as String?) ?? "",
      eventsDeleted: (json["events_deleted"] as int?) ?? 0,
      reviewsDeleted: (json["reviews_deleted"] as int?) ?? 0,
      reportsDeleted: (json["reports_deleted"] as int?) ?? 0,
    );
  }
}

class WipeAllResult {
  WipeAllResult({
    required this.eventsDeleted,
    required this.reviewsDeleted,
    required this.reportsDeleted,
  });

  final int eventsDeleted;
  final int reviewsDeleted;
  final int reportsDeleted;

  factory WipeAllResult.fromJson(Map<String, dynamic> json) {
    return WipeAllResult(
      eventsDeleted: (json["events_deleted"] as int?) ?? 0,
      reviewsDeleted: (json["reviews_deleted"] as int?) ?? 0,
      reportsDeleted: (json["reports_deleted"] as int?) ?? 0,
    );
  }
}

class PrivacyRule {
  PrivacyRule({
    required this.id,
    required this.kind,
    required this.value,
    required this.action,
    required this.createdAt,
  });

  final int id;
  final String kind;
  final String value;
  final String action;
  final String createdAt;

  factory PrivacyRule.fromJson(Map<String, dynamic> json) {
    return PrivacyRule(
      id: json["id"] as int,
      kind: json["kind"] as String,
      value: json["value"] as String,
      action: json["action"] as String,
      createdAt: json["created_at"] as String,
    );
  }
}

class PrivacyRuleUpsert {
  PrivacyRuleUpsert({
    required this.kind,
    required this.value,
    required this.action,
  });

  final String kind; // "domain" | "app"
  final String value;
  final String action; // "drop" | "mask"

  Map<String, dynamic> toJson() => {
        "kind": kind,
        "value": value,
        "action": action,
      };
}

class ReportSummary {
  ReportSummary({
    required this.id,
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    required this.generatedAt,
    required this.providerUrl,
    required this.model,
    required this.hasOutput,
    required this.hasError,
  });

  final String id;
  final String kind; // "daily" | "weekly"
  final String periodStart; // YYYY-MM-DD
  final String periodEnd; // YYYY-MM-DD
  final String generatedAt; // RFC3339
  final String? providerUrl;
  final String? model;
  final bool hasOutput;
  final bool hasError;

  factory ReportSummary.fromJson(Map<String, dynamic> json) {
    return ReportSummary(
      id: (json["id"] as String?) ?? "",
      kind: (json["kind"] as String?) ?? "",
      periodStart: (json["period_start"] as String?) ?? "",
      periodEnd: (json["period_end"] as String?) ?? "",
      generatedAt: (json["generated_at"] as String?) ?? "",
      providerUrl: json["provider_url"] as String?,
      model: json["model"] as String?,
      hasOutput: (json["has_output"] as bool?) ?? false,
      hasError: (json["has_error"] as bool?) ?? false,
    );
  }
}

class ReportRecord {
  ReportRecord({
    required this.id,
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    required this.generatedAt,
    required this.providerUrl,
    required this.model,
    required this.prompt,
    required this.inputJson,
    required this.outputMd,
    required this.error,
  });

  final String id;
  final String kind;
  final String periodStart;
  final String periodEnd;
  final String generatedAt;
  final String? providerUrl;
  final String? model;
  final String? prompt;
  final String? inputJson;
  final String? outputMd;
  final String? error;

  factory ReportRecord.fromJson(Map<String, dynamic> json) {
    return ReportRecord(
      id: (json["id"] as String?) ?? "",
      kind: (json["kind"] as String?) ?? "",
      periodStart: (json["period_start"] as String?) ?? "",
      periodEnd: (json["period_end"] as String?) ?? "",
      generatedAt: (json["generated_at"] as String?) ?? "",
      providerUrl: json["provider_url"] as String?,
      model: json["model"] as String?,
      prompt: json["prompt"] as String?,
      inputJson: json["input_json"] as String?,
      outputMd: json["output_md"] as String?,
      error: json["error"] as String?,
    );
  }
}

class ReportTodo {
  ReportTodo({
    required this.id,
    required this.content,
    required this.done,
    required this.dueDate,
    required this.startTs,
    required this.endTs,
    required this.reminderTs,
    required this.createdAt,
    required this.updatedAt,
    required this.doneAt,
  });

  final int id;
  final String content;
  final bool done;
  final String? dueDate; // YYYY-MM-DD
  final String? startTs; // RFC3339
  final String? endTs; // RFC3339
  final String? reminderTs; // RFC3339
  final String createdAt;
  final String updatedAt;
  final String? doneAt;

  DateTime? _startUtc;
  DateTime? _endUtc;
  DateTime? _reminderUtc;

  DateTime? get startUtc {
    return _startUtc ??= DateTime.tryParse(startTs ?? "")?.toUtc();
  }

  DateTime? get endUtc {
    return _endUtc ??= DateTime.tryParse(endTs ?? "")?.toUtc();
  }

  DateTime? get reminderUtc {
    return _reminderUtc ??= DateTime.tryParse(reminderTs ?? "")?.toUtc();
  }

  DateTime? get startLocal {
    final start = startUtc;
    if (start == null) return null;
    return start.toLocal();
  }

  DateTime? get endLocal {
    final end = endUtc;
    if (end == null) return null;
    return end.toLocal();
  }

  DateTime? get reminderLocal {
    final reminder = reminderUtc;
    if (reminder == null) return null;
    return reminder.toLocal();
  }

  factory ReportTodo.fromJson(Map<String, dynamic> json) {
    return ReportTodo(
      id: (json["id"] as int?) ?? 0,
      content: (json["content"] as String?) ?? "",
      done: (json["done"] as bool?) ?? false,
      dueDate: json["due_date"] as String?,
      startTs: json["start_ts"] as String?,
      endTs: json["end_ts"] as String?,
      reminderTs: json["reminder_ts"] as String?,
      createdAt: (json["created_at"] as String?) ?? "",
      updatedAt: (json["updated_at"] as String?) ?? "",
      doneAt: json["done_at"] as String?,
    );
  }
}

class ReportUpsert {
  ReportUpsert({
    required this.id,
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    this.generatedAt,
    this.providerUrl,
    this.model,
    this.prompt,
    this.inputJson,
    this.outputMd,
    this.error,
  });

  final String id;
  final String kind;
  final String periodStart;
  final String periodEnd;
  final String? generatedAt;
  final String? providerUrl;
  final String? model;
  final String? prompt;
  final String? inputJson;
  final String? outputMd;
  final String? error;

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "kind": kind,
      "period_start": periodStart,
      "period_end": periodEnd,
      "generated_at": generatedAt,
      "provider_url": providerUrl,
      "model": model,
      "prompt": prompt,
      "input_json": inputJson,
      "output_md": outputMd,
      "error": error,
    };
  }
}

class ReportSettings {
  ReportSettings({
    required this.enabled,
    required this.apiBaseUrl,
    required this.apiKey,
    required this.model,
    required this.dailyEnabled,
    required this.dailyAtMinutes,
    required this.dailyPrompt,
    required this.weeklyEnabled,
    required this.weeklyWeekday,
    required this.weeklyAtMinutes,
    required this.weeklyPrompt,
    required this.saveMd,
    required this.saveCsv,
    required this.outputDir,
    required this.effectiveOutputDir,
    required this.defaultDailyPrompt,
    required this.defaultWeeklyPrompt,
    required this.updatedAt,
  });

  final bool enabled;
  final String apiBaseUrl;
  final String apiKey;
  final String model;
  final bool dailyEnabled;
  final int dailyAtMinutes;
  final String dailyPrompt;
  final bool weeklyEnabled;
  final int weeklyWeekday; // 1=Mon..7=Sun
  final int weeklyAtMinutes;
  final String weeklyPrompt;
  final bool saveMd;
  final bool saveCsv;
  final String? outputDir;
  final String? effectiveOutputDir;
  final String? defaultDailyPrompt;
  final String? defaultWeeklyPrompt;
  final String updatedAt;

  bool get isConfigured {
    if (!enabled) return false;
    if (apiBaseUrl.trim().isEmpty) return false;
    if (apiKey.trim().isEmpty) return false;
    if (model.trim().isEmpty) return false;
    final uri = Uri.tryParse(apiBaseUrl.trim());
    if (uri == null) return false;
    if (!uri.hasScheme) return false;
    if (uri.scheme != "http" && uri.scheme != "https") return false;
    if (uri.host.trim().isEmpty) return false;
    return true;
  }

  factory ReportSettings.fromJson(Map<String, dynamic> json) {
    return ReportSettings(
      enabled: (json["enabled"] as bool?) ?? false,
      apiBaseUrl: (json["api_base_url"] as String?) ?? "",
      apiKey: (json["api_key"] as String?) ?? "",
      model: (json["model"] as String?) ?? "",
      dailyEnabled: (json["daily_enabled"] as bool?) ?? false,
      dailyAtMinutes: (json["daily_at_minutes"] as num?)?.toInt() ?? 0,
      dailyPrompt: (json["daily_prompt"] as String?) ?? "",
      weeklyEnabled: (json["weekly_enabled"] as bool?) ?? false,
      weeklyWeekday: (json["weekly_weekday"] as num?)?.toInt() ?? 1,
      weeklyAtMinutes: (json["weekly_at_minutes"] as num?)?.toInt() ?? 0,
      weeklyPrompt: (json["weekly_prompt"] as String?) ?? "",
      saveMd: (json["save_md"] as bool?) ?? true,
      saveCsv: (json["save_csv"] as bool?) ?? false,
      outputDir: json["output_dir"] as String?,
      effectiveOutputDir: json["effective_output_dir"] as String?,
      defaultDailyPrompt: json["default_daily_prompt"] as String?,
      defaultWeeklyPrompt: json["default_weekly_prompt"] as String?,
      updatedAt: (json["updated_at"] as String?) ?? "",
    );
  }
}
