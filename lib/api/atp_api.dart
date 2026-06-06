import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/device.dart';

/// Thin REST client for the ATP server. All session-trigger calls return the
/// raw decoded JSON so callers can inspect status; [listDevices] maps to models.
class AtpApi {
  static const _timeout = Duration(seconds: 8);

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
    });
    return (r?['ok'] as bool?) ?? (r != null);
  }

  /// POST /history/availability/day → recorded intervals + 15-min coverage.
  static Future<DayAvailability> availabilityDay({
    required String deviceId,
    required String date, // YYYY-MM-DD
  }) async {
    final r = await _post('/history/availability/day', {
      'deviceId': deviceId,
      'date': date,
      'channel': 'ALL',
    });
    final all = (r?['allChannels'] as Map?)?.cast<String, dynamic>() ?? const {};
    final intervals =
        (all['intervals'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final slots = (all['slots15m'] as List?)
            ?.cast<num>()
            .map((e) => e.toInt())
            .toList() ??
        const <int>[];
    final cov = (all['coveragePercent'] as num?)?.toDouble() ?? 0;
    return DayAvailability(intervals: intervals, slots15m: slots, coverage: cov);
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
      String path, Map<String, dynamic> body) async {
    final r = await http
        .post(
          Uri.parse('${Config.apiBase}$path'),
          headers: const {'content-type': 'application/json'},
          body: json.encode(body),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw '$path HTTP ${r.statusCode}: ${r.body}';
    }
    final d = json.decode(r.body);
    return d is Map<String, dynamic> ? d : null;
  }
}

/// One day's recorded-footage availability for a device (all channels merged).
class DayAvailability {
  final List<Map<String, dynamic>> intervals;
  final List<int> slots15m;
  final double coverage;
  const DayAvailability({
    required this.intervals,
    required this.slots15m,
    required this.coverage,
  });
}
