/// A server-side download job as returned by POST /history/download
/// (under "downloadJob") and GET /download/status?jobId=... (under "job").
///
/// Downloads are async: POST returns the job immediately (status="queued"
/// or "running"); the client polls /download/status until [isTerminal].
/// On success [downloadUrl] holds the S3 (or local /downloads/) URL.
class DownloadJob {
  final String jobId;
  final String status; // queued, waiting_for_device, running, done, error, cancelled
  final double progressPct;
  final int etaSec;
  final int durationSec;
  final int elapsedSec;
  final String? downloadUrl;
  final String? error;
  final int? outputSizeBytes;
  final int rxBytes; // bytes received so far (FTP-pull liveness/progress)
  final bool partial;

  // Source params (from job.params.playback) — used for labels + retry.
  final String deviceId;
  final int channel;
  final int streamType;
  final String startTime;
  final String endTime;
  final String backendUsed; // "ftp" | "bridge" | "playback" | ""

  const DownloadJob({
    required this.jobId,
    required this.status,
    required this.progressPct,
    required this.etaSec,
    required this.durationSec,
    required this.elapsedSec,
    this.downloadUrl,
    this.error,
    this.outputSizeBytes,
    this.rxBytes = 0,
    this.partial = false,
    this.deviceId = '',
    this.channel = 0,
    this.streamType = 0,
    this.startTime = '',
    this.endTime = '',
    this.backendUsed = '',
  });

  bool get isDone => status == 'done';
  bool get isFailed => status == 'error' || status == 'cancelled';
  bool get isTerminal => isDone || isFailed;

  String _clock(String iso) => iso.length >= 19 ? iso.substring(11, 19) : iso;

  /// "CAM1 · 00:00:00 → 00:00:40" for the centre list.
  String get clipLabel {
    final cam = channel > 0 ? 'CAM$channel' : 'CAM?';
    if (startTime.isEmpty) return cam;
    return '$cam · ${_clock(startTime)} → ${_clock(endTime)}';
  }

  String get dateLabel =>
      startTime.length >= 10 ? startTime.substring(0, 10) : '';

  /// Human size of the finished file, "" when unknown.
  String get sizeLabel => _human(outputSizeBytes ?? 0);

  /// Human bytes-received-so-far, "" when none yet.
  String get rxLabel => rxBytes > 0 ? _human(rxBytes) : '';

  static String _human(int b) {
    if (b <= 0) return '';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  factory DownloadJob.fromJson(Map<String, dynamic> j) {
    final params = (j['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    final pb = (params['playback'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DownloadJob(
      jobId: j['jobId']?.toString() ?? '',
      status: j['status']?.toString() ?? '',
      progressPct: (j['progressPct'] as num?)?.toDouble() ?? 0,
      etaSec: (j['etaSec'] as num?)?.toInt() ?? 0,
      durationSec: (j['durationSec'] as num?)?.toInt() ?? 0,
      elapsedSec: (j['elapsedSec'] as num?)?.toInt() ?? 0,
      downloadUrl: (j['downloadUrl'] as String?)?.isNotEmpty == true
          ? j['downloadUrl'] as String
          : null,
      error: (j['error'] as String?)?.isNotEmpty == true
          ? j['error'] as String
          : null,
      outputSizeBytes: (j['outputSizeBytes'] as num?)?.toInt(),
      rxBytes: (j['rxBytes'] as num?)?.toInt() ?? 0,
      partial: j['partial'] == true,
      deviceId: pb['deviceId']?.toString() ?? '',
      channel: (pb['channel'] as num?)?.toInt() ?? 0,
      streamType: (pb['streamType'] as num?)?.toInt() ?? 0,
      startTime: pb['startTime']?.toString() ?? '',
      endTime: pb['endTime']?.toString() ?? '',
      backendUsed: params['backendUsed']?.toString() ?? '',
    );
  }
}
