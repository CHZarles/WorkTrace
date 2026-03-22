import "dart:convert";

import "package:http/http.dart" as http;

class CoreClient {
  CoreClient({required this.baseUrl});

  final String baseUrl;

  Uri _u(String path, [Map<String, String>? q]) {
    final trimmed = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse("$trimmed$path").replace(queryParameters: q);
  }

  Future<bool> health() async {
    final res = await http.get(_u("/health"));
    return res.statusCode == 200;
  }

  Future<List<BlockSummary>> blocksToday({required String date, required int tzOffsetMinutes}) async {
    final res = await http.get(
      _u("/blocks/today", {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data.map((e) => BlockSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> upsertReview(ReviewUpsert r) async {
    final res = await http.post(
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
    final res = await http.get(_u("/events", {"limit": l}));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data.map((e) => EventRecord.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<TrackingStatus> trackingStatus() async {
    final res = await http.get(_u("/tracking/status"));
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
    final res = await http.post(
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
    final res = await http.post(_u("/tracking/resume"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return TrackingStatus.fromJson(data);
  }

  Future<CoreSettings> settings() async {
    final res = await http.get(_u("/settings"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = obj["data"] as Map<String, dynamic>?;
    if (data == null) throw Exception("invalid_response");
    return CoreSettings.fromJson(data);
  }

  Future<CoreSettings> updateSettings({int? blockSeconds, int? idleCutoffSeconds}) async {
    final body = <String, dynamic>{};
    if (blockSeconds != null) body["block_seconds"] = blockSeconds;
    if (idleCutoffSeconds != null) body["idle_cutoff_seconds"] = idleCutoffSeconds;

    final res = await http.post(
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

  Future<DeleteRangeResult> deleteBlock({required String startTs, required String endTs}) async {
    final res = await http.post(
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

  Future<DeleteDayResult> deleteDay({required String date, required int tzOffsetMinutes}) async {
    final res = await http.post(
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

  Future<List<PrivacyRule>> privacyRules() async {
    final res = await http.get(_u("/privacy/rules"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (obj["data"] as List<dynamic>? ?? const []);
    return data.map((e) => PrivacyRule.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PrivacyRule> upsertPrivacyRule(PrivacyRuleUpsert r) async {
    final res = await http.post(
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
    final res = await http.delete(_u("/privacy/rules/$id"));
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
  }

  Future<String> exportMarkdown({required String date, required int tzOffsetMinutes}) async {
    final res = await http.get(
      _u("/export/markdown", {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    return res.body;
  }

  Future<String> exportCsv({required String date, required int tzOffsetMinutes}) async {
    final res = await http.get(
      _u("/export/csv", {"date": date, "tz_offset_minutes": tzOffsetMinutes.toString()}),
    );
    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    return res.body;
  }
}

class BlockSummary {
  BlockSummary({
    required this.id,
    required this.startTs,
    required this.endTs,
    required this.totalSeconds,
    required this.topItems,
    required this.review,
  });

  final String id;
  final String startTs;
  final String endTs;
  final int totalSeconds;
  final List<TopItem> topItems;
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
      review: json["review"] == null ? null : BlockReview.fromJson(json["review"] as Map<String, dynamic>),
    );
  }
}

class TopItem {
  TopItem({required this.kind, required this.name, required this.seconds});

  final String kind; // "app" | "domain" | "unknown"
  final String name;
  final int seconds;

  factory TopItem.fromJson(Map<String, dynamic> json) {
    return TopItem(
      kind: (json["kind"] as String?) ?? "unknown",
      name: json["name"] as String,
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
      tags: (json["tags"] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
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
  });

  final int id;
  final String ts;
  final String source;
  final String event;
  final String? entity;
  final String? title;

  factory EventRecord.fromJson(Map<String, dynamic> json) {
    return EventRecord(
      id: json["id"] as int,
      ts: json["ts"] as String,
      source: json["source"] as String,
      event: json["event"] as String,
      entity: json["entity"] as String?,
      title: json["title"] as String?,
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
  });

  final int blockSeconds;
  final int idleCutoffSeconds;

  factory CoreSettings.fromJson(Map<String, dynamic> json) {
    return CoreSettings(
      blockSeconds: (json["block_seconds"] as int?) ?? (45 * 60),
      idleCutoffSeconds: (json["idle_cutoff_seconds"] as int?) ?? (5 * 60),
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
  });

  final String date;
  final int tzOffsetMinutes;
  final String startTs;
  final String endTs;
  final int eventsDeleted;
  final int reviewsDeleted;

  factory DeleteDayResult.fromJson(Map<String, dynamic> json) {
    return DeleteDayResult(
      date: (json["date"] as String?) ?? "",
      tzOffsetMinutes: (json["tz_offset_minutes"] as int?) ?? 0,
      startTs: (json["start_ts"] as String?) ?? "",
      endTs: (json["end_ts"] as String?) ?? "",
      eventsDeleted: (json["events_deleted"] as int?) ?? 0,
      reviewsDeleted: (json["reviews_deleted"] as int?) ?? 0,
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
