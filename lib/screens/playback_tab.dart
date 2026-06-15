import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/atp_api.dart';
import '../config.dart';
import '../models/device.dart';
import '../models/download_job.dart';
import '../services/clip_downloader.dart';
import '../widgets/atp_stream_view.dart';
import 'fullscreen_screen.dart';

/// Playback tab — clip-driven. We query the device for the channel's actual
/// recording slots (0x9205) and let the user Play or Download a real clip.
/// Play/Download always use a clip's exact device-local start/end, so the
/// range can never fall in an un-recorded gap.
class PlaybackTab extends StatefulWidget {
  final Device device;
  const PlaybackTab({super.key, required this.device});

  @override
  State<PlaybackTab> createState() => _PlaybackTabState();
}

class _PlaybackTabState extends State<PlaybackTab>
    with AutomaticKeepAliveClientMixin {
  int _channel = 1;
  DateTime _date = DateTime.now();
  bool _loadingAvail = false;
  DayAvailability? _avail;
  String? _error;

  // The selected recording slot being played. Times are device-local
  // "YYYY-MM-DD HH:mm:ss" strings straight from the device's resource list.
  Clip? _selected;
  bool _playing = false;

  // Download state. _job tracks the async server-side download; _pollTimer
  // polls /download/status until terminal. _dlClipKey ties the card to the
  // clip that started it.
  DownloadJob? _job;
  String? _dlClipKey;
  bool _starting = false;
  String? _dlError;
  Timer? _pollTimer;
  // Save-to-phone state for the completed clip.
  double? _saveProgress; // non-null while saving to Photos
  bool _saved = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  String _two(int n) => n.toString().padLeft(2, '0');
  String _fmtDate(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

  String _clipKey(Clip c) => '${c.channel}|${c.startTime}|${c.endTime}';

  Future<void> _loadAvailability() async {
    setState(() {
      _loadingAvail = true;
      _error = null;
      _avail = null;
    });
    try {
      final a = await AtpApi.availabilityDay(
        deviceId: widget.device.deviceId,
        date: _fmtDate(_date),
        channel: _channel,
      );
      if (!mounted) return;
      setState(() {
        _avail = a;
        _loadingAvail = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingAvail = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
    );
    if (d == null) return;
    setState(() {
      _date = d;
      _avail = null;
      _selected = null;
      _playing = false;
    });
    _loadAvailability();
  }

  void _onChannel(int ch) {
    if (ch == _channel) return;
    setState(() {
      _channel = ch;
      _avail = null;
      _selected = null;
      _playing = false;
    });
    _loadAvailability();
  }

  void _playClip(Clip c) {
    setState(() {
      _selected = c;
      _playing = true;
    });
  }

  void _openFullscreen() {
    final c = _selected;
    if (c == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FullscreenScreen(
        deviceId: widget.device.deviceId,
        channel: _channel,
        live: false,
        startTime: c.startTime,
        endTime: c.endTime,
        audioOn: true,
      ),
    ));
  }

  Future<void> _downloadClip(Clip c, {String backend = ''}) async {
    _pollTimer?.cancel();
    setState(() {
      _starting = true;
      _dlError = null;
      _job = null;
      _dlClipKey = _clipKey(c);
      _saved = false;
      _saveProgress = null;
    });
    try {
      final job = await AtpApi.startDownload(
        deviceId: widget.device.deviceId,
        channel: _channel,
        streamType: 0, // playback = main stream
        startTime: c.startTime,
        endTime: c.endTime,
        backend: backend,
      );
      if (!mounted) return;
      setState(() {
        _job = job;
        _starting = false;
      });
      if (!job.isTerminal) _beginPolling(job.jobId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dlError = '$e';
        _starting = false;
      });
    }
  }

  void _beginPolling(String jobId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      try {
        final job = await AtpApi.downloadStatus(jobId);
        if (!mounted) return;
        setState(() => _job = job);
        if (job.isTerminal) t.cancel();
      } catch (e) {
        if (!mounted) return;
        setState(() => _dlError = '$e');
        t.cancel();
      }
    });
  }

  Future<void> _cancelDownload() async {
    final j = _job;
    if (j == null) return;
    _pollTimer?.cancel();
    await AtpApi.cancelDownload(j.jobId);
    if (!mounted) return;
    setState(() {
      _job = null;
      _dlClipKey = null;
    });
  }

  Future<void> _saveToPhone(String url) async {
    setState(() => _saveProgress = 0);
    try {
      await ClipDownloader.downloadToGallery(
        url: url,
        filename: 'airfi_${widget.device.deviceId}_ch$_channel',
        onProgress: (p) {
          if (mounted) setState(() => _saveProgress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _saveProgress = null;
        _saved = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to Photos')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveProgress = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = _selected;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Video surface — plays the selected recording slot. Keyed on the clip
        // so picking another slot re-boots it.
        AspectRatio(
          aspectRatio: 16 / 9,
          child: _playing && c != null
              ? AtpStreamView(
                  key: ValueKey(
                      'pb-${widget.device.deviceId}-$_channel-${c.startTime}-${c.endTime}'),
                  deviceId: widget.device.deviceId,
                  channel: _channel,
                  streamType: 0, // playback = main stream
                  live: false,
                  startTime: c.startTime,
                  endTime: c.endTime,
                  muted: false,
                  onTap: _openFullscreen,
                )
              : ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Text(
                      _avail == null
                          ? 'Load a day, then pick a recorded clip'
                          : 'Pick a recorded clip below',
                      style: const TextStyle(color: Colors.white38),
                    ),
                  ),
                ),
        ),
        if (c != null) ...[
          const SizedBox(height: 6),
          Text('Playing  ${c.startClock} → ${c.endClock}  ·  ${c.durationLabel}',
              style: const TextStyle(fontSize: 12, color: Colors.cyanAccent)),
        ],
        const SizedBox(height: 12),
        _channelSelector(),
        const SizedBox(height: 12),
        Row(children: [
          const Text('Date  '),
          OutlinedButton(onPressed: _pickDate, child: Text(_fmtDate(_date))),
          const Spacer(),
          FilledButton.tonalIcon(
            onPressed: _loadingAvail ? null : _loadAvailability,
            icon: _loadingAvail
                ? const SizedBox(
                    width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search, size: 18),
            label: const Text('Load clips'),
          ),
        ]),
        const SizedBox(height: 12),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        if (_avail != null) ...[
          _coverageBar(_avail!),
          const SizedBox(height: 12),
          _clipsList(_avail!),
        ],
        if (_dlError != null) ...[
          const SizedBox(height: 8),
          Text(_dlError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],
        if (_job != null) ...[
          const SizedBox(height: 12),
          _downloadCard(_job!),
        ],
      ],
    );
  }

  Widget _channelSelector() {
    return Wrap(
      spacing: 8,
      children: List.generate(4, (i) {
        final ch = i + 1;
        return ChoiceChip(
          label: Text('CAM $ch'),
          selected: ch == _channel,
          onSelected: (_) => _onChannel(ch),
        );
      }),
    );
  }

  Widget _coverageBar(DayAvailability a) {
    if (a.slots15m.isEmpty) {
      return const Text('No recordings this day',
          style: TextStyle(color: Colors.white54, fontSize: 12));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('coverage ${a.coverage.toStringAsFixed(1)}%  ·  ${a.clips.length} clips',
          style: const TextStyle(fontSize: 11, color: Colors.white60)),
      const SizedBox(height: 4),
      Container(
        height: 16,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          children: a.slots15m
              .map((v) => Expanded(
                    child: Container(
                      color: v > 0
                          ? Colors.cyanAccent.withValues(alpha: 0.7)
                          : Colors.transparent,
                    ),
                  ))
              .toList(),
        ),
      ),
      const SizedBox(height: 2),
      const Text('00 — 06 — 12 — 18 — 24',
          style: TextStyle(fontSize: 9, color: Colors.white30)),
    ]);
  }

  Widget _clipsList(DayAvailability a) {
    if (a.clips.isEmpty) {
      return const Text('No recorded clips on CAM for this day',
          style: TextStyle(fontSize: 12, color: Colors.white54));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Recorded clips — tap Play or Download:',
            style: TextStyle(fontSize: 11, color: Colors.white60)),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: a.clips.length,
            itemBuilder: (_, i) => _clipRow(a.clips[i]),
          ),
        ),
      ],
    );
  }

  Widget _clipRow(Clip c) {
    final isSel = _selected != null && _clipKey(_selected!) == _clipKey(c);
    final dlActive = _dlClipKey == _clipKey(c) && (_starting || _job != null);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isSel ? Colors.cyanAccent.withValues(alpha: 0.08) : null,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: isSel ? Colors.cyanAccent : Colors.white12,
            width: isSel ? 1.5 : 1),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${c.startClock} → ${c.endClock}',
                style: const TextStyle(
                    fontSize: 13, fontFamily: 'monospace', color: Colors.white)),
            Text(c.durationLabel,
                style: const TextStyle(fontSize: 10, color: Colors.white38)),
          ]),
        ),
        IconButton(
          tooltip: 'Play',
          visualDensity: VisualDensity.compact,
          onPressed: () => _playClip(c),
          icon: Icon(Icons.play_circle_fill,
              color: isSel ? Colors.cyanAccent : Colors.white70),
        ),
        dlActive
            ? const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : PopupMenuButton<String>(
                tooltip: 'Download method',
                icon: const Icon(Icons.download, color: Colors.white70),
                onSelected: (m) => _downloadClip(c, backend: m),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'ftp',
                      child: Text('Download · FTP-pull')),
                  PopupMenuItem(
                      value: 'record',
                      child: Text('Download · Record (0x9201)')),
                  PopupMenuItem(
                      value: '', child: Text('Download · Auto')),
                ],
              ),
      ]),
    );
  }

  Widget _downloadCard(DownloadJob j) {
    final pct = (j.progressPct.clamp(0, 100)) / 100.0;
    Color statusColor = Colors.cyanAccent;
    if (j.isDone) statusColor = Colors.greenAccent;
    if (j.isFailed) statusColor = Colors.redAccent;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12161C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            j.isDone
                ? Icons.check_circle
                : j.isFailed
                    ? Icons.error
                    : Icons.cloud_download,
            color: statusColor,
            size: 18,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Download · ${j.status}',
                style: TextStyle(
                    color: statusColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
          if (j.partial)
            const Text('partial',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 11)),
        ]),
        const SizedBox(height: 8),
        if (!j.isTerminal) ...[
          LinearProgressIndicator(value: pct > 0 ? pct : null),
          const SizedBox(height: 4),
          Text(
            '${j.progressPct.toStringAsFixed(0)}%'
            '${j.rxLabel.isNotEmpty ? '  ·  ${j.rxLabel} recvd' : ''}'
            '${j.etaSec > 0 ? '  ·  ETA ${j.etaSec}s' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.white60),
          ),
        ],
        if (j.isDone) ...[
          Text(
            'Ready${j.sizeLabel.isNotEmpty ? '  ·  ${j.sizeLabel}' : ''}'
            '${j.backendUsed.isNotEmpty ? '  ·  via ${j.backendUsed}' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          if (j.downloadUrl != null)
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_saveProgress != null || _saved)
                      ? null
                      : () => _saveToPhone(j.downloadUrl!),
                  icon: _saveProgress != null
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: _saveProgress! > 0 ? _saveProgress : null))
                      : Icon(_saved ? Icons.check_circle : Icons.download,
                          size: 18),
                  label: Text(_saveProgress != null
                      ? 'Saving ${((_saveProgress ?? 0) * 100).toStringAsFixed(0)}%'
                      : _saved
                          ? 'Saved to Photos'
                          : 'Download'),
                ),
              ),
              IconButton(
                tooltip: 'Copy URL',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(
                      text: Config.resolveMediaUrl(j.downloadUrl!)));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL copied')),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
              ),
            ])
          else
            const Text('No URL returned (check S3 upload)',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
        ],
        if (j.isFailed && j.error != null)
          Text(j.error!,
              style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
        if (!j.isTerminal) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _cancelDownload,
              child: const Text('Cancel'),
            ),
          ),
        ],
      ]),
    );
  }
}
