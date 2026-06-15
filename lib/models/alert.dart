/// An ADAS/DMS alert as returned by GET /alerts?deviceId=...&limit=...
/// Each alert carries an [evidence] list of device-uploaded files; images
/// are shown inline. Evidence URLs may be relative (/evidence/file/...) or
/// absolute S3 URLs — resolve with Config.resolveMediaUrl before fetching.
class Alert {
  final String deviceId;
  final String event; // human label ("Distracted Driving")
  final String eventName; // machine name ("Distracted_Driving")
  final String eventCode; // "E04"
  final String eventTime; // ISO-8601 with tz
  final String module; // "dms" | "adas"
  final int level;
  final double speedKmh;
  final int attachmentsCount;
  final double? lat;
  final double? lon;
  final List<EvidenceFile> evidence;

  const Alert({
    required this.deviceId,
    required this.event,
    required this.eventName,
    required this.eventCode,
    required this.eventTime,
    required this.module,
    required this.level,
    required this.speedKmh,
    required this.attachmentsCount,
    this.lat,
    this.lon,
    required this.evidence,
  });

  /// Best label for display: event, else eventName, else eventCode.
  String get title {
    if (event.trim().isNotEmpty) return event;
    if (eventName.trim().isNotEmpty) return eventName.replaceAll('_', ' ');
    return eventCode.isNotEmpty ? eventCode : 'Alert';
  }

  List<EvidenceFile> get images =>
      evidence.where((e) => e.isImage).toList(growable: false);

  factory Alert.fromJson(Map<String, dynamic> j) {
    final ev = (j['evidence'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final loc = (j['location'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Alert(
      deviceId: j['deviceId']?.toString() ?? '',
      event: j['event']?.toString() ?? '',
      eventName: j['event_name']?.toString() ?? '',
      eventCode: j['event_code']?.toString() ?? '',
      eventTime: j['event_time']?.toString() ?? '',
      module: j['module']?.toString() ?? '',
      level: (j['level'] as num?)?.toInt() ?? 0,
      speedKmh: (j['speed_kmh'] as num?)?.toDouble() ?? 0,
      attachmentsCount: (j['attachments_count'] as num?)?.toInt() ?? 0,
      lat: (loc['lat'] as num?)?.toDouble(),
      lon: (loc['lon'] as num?)?.toDouble(),
      evidence: ev.map(EvidenceFile.fromJson).toList(),
    );
  }
}

/// One evidence file attached to an alert (image / video / audio).
class EvidenceFile {
  final String type; // "image" | "video" | "audio"
  final String name;
  final String url; // relative or absolute; resolve via Config.resolveMediaUrl
  final int size;

  const EvidenceFile({
    required this.type,
    required this.name,
    required this.url,
    required this.size,
  });

  bool get isImage => type == 'image';
  bool get isVideo => type == 'video';

  factory EvidenceFile.fromJson(Map<String, dynamic> j) => EvidenceFile(
        type: j['type']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        url: j['url']?.toString() ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}
