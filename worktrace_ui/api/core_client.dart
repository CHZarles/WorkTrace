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
    required this.doing,
    required this.output,
    required this.next,
    required this.tags,
    required this.updatedAt,
  });

  final String? doing;
  final String? output;
  final String? next;
  final List<String> tags;
  final String updatedAt;

  factory BlockReview.fromJson(Map<String, dynamic> json) {
    return BlockReview(
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
    this.doing,
    this.output,
    this.next,
    this.tags = const [],
  });

  final String blockId;
  final String? doing;
  final String? output;
  final String? next;
  final List<String> tags;

  Map<String, dynamic> toJson() => {
        "block_id": blockId,
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
