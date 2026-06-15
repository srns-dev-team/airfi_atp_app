import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/alert.dart';
import '../models/device.dart';
import '../models/download_job.dart';

/// Thin REST client for the ATP server. All session-trigger calls return the
/// raw decoded JSON so callers can inspect status; [listDevices] maps to models.
class AtpApi {
  static const _timeout = Duration(seconds: 8);
  // History (SD-card) calls are inherently slow: the device must seek the clip
  // and a playback SWITCH does an ACK-gated 0x9202 STOP + ~3s settle server-side
  // before the new 0x9201. 8s is not enough → TimeoutException. The ATP client
  // doesn't consume the server's HLS readiness anyway (it opens the ATP WS and
  // rides its own no-signal grace), so we also pass waitReady:false to stop the
  // server blocking the HTTP on an HLS path_ready loop it doesn't need.
  static const _historyTimeout = Duration(seconds: 25);
  // Availability (0x9205 resource query) can take longer: the server collects
  // device packets up to ~90s (firstPacket 15s + idle gaps). 25s cut valid but
  // slow responses → "recording list not loading". 45s covers the common case;
  // availabilityDay also retries once when the first pass comes back empty.
  static const _availabilityTimeout = Duration(seconds: 45);

  /// GET /devices → connected device list.
  static Future<List<Device>> listDevices() async {
    final r = await http
        .get(Uri.parse('${Config.apiBase}/devices'))
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw 'devices HTTP ${r.statusCode}';
    }
    final j = json.decode(r.body) as Map<String, dynamic>;
    final arr = (j['devices'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return arr.map(Device.fromJson).toList();
  }

  /// POST /camera → start a live publisher. Returns true on ok.
  static Future<bool> startCamera({
    required String deviceId,
    required int channel,
    required int streamType,
  }) async {
    final r = await _post('/camera', {
      'deviceId': deviceId,
      'channel': channel,
      'streamType': streamType,
    });
    return (r?['ok'] as bool?) ?? false;
  }

  /// POST /history/start → start an SD playback session for a time range.
  /// Times are device-local "YYYY-MM-DD HH:mm:ss".
  static Future<bool> startHistory({
    required String deviceId,
    required int channel,
    required int streamType,
    required String startTime,
    required String endTime,
  }) async {
    final r = await _post('/history/start', {
      'deviceId': deviceId,
      'channel': channel,
      'streamType': streamType,
      'startTime': startTime,
      'endTime': endTime,
      // ATP client opens the WS itself; don't make the server block the HTTP
      // on an HLS path_ready wait the app never reads.
      'waitReady': false,
    }, timeout: _historyTimeout);
    return (r?['ok'] as bool?) ?? (r != null);
  }

  /// POST /history/availability/day → the actual recording slots (clips) the
  /// device holds for [channel] on [date], plus a 15-min coverage map. Querying
  /// a specific channel (not "ALL") returns per-channel intervals under
  /// `availability.intervals`, each carrying the exact device-local start/end
  /// that /history/start and /history/download consume verbatim.
  static Future<DayAvailability> availabilityDay({
    required String deviceId,
    required String date, // YYYY-MM-DD
    required int channel,
  }) async {
    // The 0x9205 query is flaky: a device can miss/ignore the first request and
    // reply with nothing. Retry once on an empty (but error-free) result before
    // declaring "no clips".
    DayAvailability last =
        const DayAvailability(intervals: [], clips: [], slots15m: [], coverage: 0);
    for (var attempt = 0; attempt < 2; attempt++) {
      final a = await _availabilityOnce(deviceId, date, channel);
      if (a.clips.isNotEmpty) return a;
      last = a;
      if (attempt == 0) await Future.delayed(const Duration(seconds: 2));
    }
    return last;
  }

  static Future<DayAvailability> _availabilityOnce(
      String deviceId, String date, int channel) async {
    final r = await _post('/history/availability/day', {
      'deviceId': deviceId,
      'date': date,
      'channel': channel,
    }, timeout: _availabilityTimeout);
    final av = (r?['availability'] as Map?)?.cast<String, dynamic>() ?? const {};
    final slots = (av['slots15m'] as List?)
            ?.cast<num>()
            .map((e) => e.toInt())
            .toList() ??
        const <int>[];
    final cov = (av['coveragePercent'] as num?)?.toDouble() ?? 0;

    // Use the RAW per-file records ("files"), not "intervals". The server
    // merges adjacent ~10-min device files into long continuous intervals
    // (a 35-min block = 3-4 merged files); the user wants the actual clips.
    // Each ResourceRecord is one real on-device recording file.
    final files =
        (r?['files'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    var clips = files
        .map(Clip.fromRecord)
        .where((c) => c.startTime.isNotEmpty && c.endTime.isNotEmpty)
        .toList();
    // Prefer main-stream files (streamType 0 = playback target); fall back to
    // all if a device reports only sub.
    final main = clips.where((c) => c.streamType == 0).toList();
    if (main.isNotEmpty) clips = main;
    clips.sort((a, b) => a.startTime.compareTo(b.startTime));
    return DayAvailability(
        intervals: files, slots15m: slots, coverage: cov, clips: clips);
  }

  /// POST /history/download → start an async server-side download of an SD
  /// clip. Returns the initial [DownloadJob] (status queued/running); poll
  /// [downloadStatus] with its jobId until terminal. Times are device-local
  /// "YYYY-MM-DD HH:mm:ss". quality: "full" (720p) or "mobile" (540p).
  /// backend forces the download method (for testing): 'ftp' = FTP-pull only,
  /// 'record' = bridge/playback record only, '' / 'auto' = default chain.
  static Future<DownloadJob> startDownload({
    required String deviceId,
    required int channel,
    required String startTime,
    required String endTime,
    int streamType = 0,
    String quality = 'full',
    String backend = '',
  }) async {
    final body = {
      'deviceId': deviceId,
      'channel': channel,
      'streamType': streamType,
      'startTime': startTime,
      'endTime': endTime,
      'quality': quality,
    };
    if (backend.isNotEmpty) body['backend'] = backend;
    final r = await _post('/history/download', body, timeout: _historyTimeout);
    final job = (r?['downloadJob'] as Map?)?.cast<String, dynamic>();
    if (job == null) throw 'download did not start: ${r ?? 'null'}';
    return DownloadJob.fromJson(job);
  }

  /// GET /download/jobs → all download jobs (server-side, newest-first after
  /// client sort). Powers the Download Centre.
  static Future<List<DownloadJob>> listDownloads() async {
    final r = await http
        .get(Uri.parse('${Config.apiBase}/download/jobs'))
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw 'download/jobs HTTP ${r.statusCode}';
    }
    final j = json.decode(r.body) as Map<String, dynamic>;
    final arr = (j['jobs'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final jobs = arr.map(DownloadJob.fromJson).toList();
    jobs.sort((a, b) => b.startTime.compareTo(a.startTime));
    return jobs;
  }

  /// GET /download/status?jobId=... → current job state.
  static Future<DownloadJob> downloadStatus(String jobId) async {
    final r = await http
        .get(Uri.parse('${Config.apiBase}/download/status?jobId=$jobId'))
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw 'download/status HTTP ${r.statusCode}';
    }
    final j = json.decode(r.body) as Map<String, dynamic>;
    final job = (j['job'] as Map?)?.cast<String, dynamic>();
    if (job == null) throw 'no job in status response';
    return DownloadJob.fromJson(job);
  }

  /// POST /download/cancel → cancel one job. Best-effort.
  static Future<bool> cancelDownload(String jobId) async {
    try {
      final r = await _post('/download/cancel', {'jobId': jobId});
      return r == null ? false : (r['ok'] != false);
    } catch (_) {
      return false;
    }
  }

  /// GET /alerts?deviceId=...&limit=... → recent ADAS/DMS alerts for a device,
  /// newest first, each with its evidence-image list.
  static Future<List<Alert>> listAlerts({
    required String deviceId,
    int limit = 50,
  }) async {
    final r = await http
        .get(Uri.parse('${Config.apiBase}/alerts?deviceId=$deviceId&limit=$limit'))
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw 'alerts HTTP ${r.statusCode}';
    }
    final j = json.decode(r.body) as Map<String, dynamic>;
    final arr = (j['alerts'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return arr.map(Alert.fromJson).toList();
  }

  /// POST /talkback/start → returns wsPort (server relays G.711A on /ws/talkback).
  static Future<int?> startTalkback({
    required String deviceId,
    required int channel,
  }) async {
    final r = await _post('/talkback/start', {
      'deviceId': deviceId,
      'channel': channel,
    });
    if (r == null || r['ok'] != true) return null;
    return (r['wsPort'] as num?)?.toInt();
  }

  /// POST /talkback/stop. Best-effort; returns true on 2xx + ok!=false.
  static Future<bool> stopTalkback({
    required String deviceId,
    required int channel,
  }) async {
    try {
      final r = await _post('/talkback/stop', {
        'deviceId': deviceId,
        'channel': channel,
      });
      return r == null ? false : (r['ok'] != false);
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> _post(
      String path, Map<String, dynamic> body,
      {Duration? timeout}) async {
    final r = await http
        .post(
          Uri.parse('${Config.apiBase}$path'),
          headers: const {'content-type': 'application/json'},
          body: json.encode(body),
        )
        .timeout(timeout ?? _timeout);
    if (r.statusCode != 200) {
      throw '$path HTTP ${r.statusCode}: ${r.body}';
    }
    final d = json.decode(r.body);
    return d is Map<String, dynamic> ? d : null;
  }
}

/// One day's recorded-footage availability for a device on one channel.
class DayAvailability {
  final List<Map<String, dynamic>> intervals; // raw server intervals
  final List<Clip> clips; // typed, playable recording slots
  final List<int> slots15m;
  final double coverage;
  const DayAvailability({
    required this.intervals,
    required this.clips,
    required this.slots15m,
    required this.coverage,
  });
}

/// A single real recording slot on the device SD card. start/end are
/// device-local "YYYY-MM-DD HH:mm:ss" — fed verbatim into play + download so
/// the range always matches actual footage (no manual-pick gaps).
class Clip {
  final String startTime;
  final String endTime;
  final int durationSec;
  final int channel;
  final int streamType; // 0=main, 1=sub
  const Clip({
    required this.startTime,
    required this.endTime,
    required this.durationSec,
    required this.channel,
    this.streamType = 0,
  });

  /// "HH:mm:ss" portion of the start, for compact display.
  String get startClock =>
      startTime.length >= 19 ? startTime.substring(11, 19) : startTime;
  String get endClock =>
      endTime.length >= 19 ? endTime.substring(11, 19) : endTime;
  String get durationLabel {
    if (durationSec >= 60) return '${(durationSec / 60).toStringAsFixed(0)} min';
    return '${durationSec}s';
  }

  /// From a merged interval (carries durationSec).
  factory Clip.fromJson(Map<String, dynamic> j) => Clip(
        startTime: j['startTime']?.toString() ?? '',
        endTime: j['endTime']?.toString() ?? '',
        durationSec: (j['durationSec'] as num?)?.toInt() ?? 0,
        channel: (j['channel'] as num?)?.toInt() ?? 0,
        streamType: (j['streamType'] as num?)?.toInt() ?? 0,
      );

  /// From a raw ResourceRecord ("files"): no durationSec field, so derive it
  /// from start/end (device-local "YYYY-MM-DD HH:mm:ss").
  factory Clip.fromRecord(Map<String, dynamic> j) {
    final s = j['startTime']?.toString() ?? '';
    final e = j['endTime']?.toString() ?? '';
    int dur = 0;
    try {
      final st = DateTime.parse(s.replaceAll(' ', 'T'));
      final et = DateTime.parse(e.replaceAll(' ', 'T'));
      dur = et.difference(st).inSeconds;
      if (dur < 0) dur = 0;
    } catch (_) {}
    return Clip(
      startTime: s,
      endTime: e,
      durationSec: dur,
      channel: (j['channel'] as num?)?.toInt() ?? 0,
      streamType: (j['streamType'] as num?)?.toInt() ?? 0,
    );
  }
}
