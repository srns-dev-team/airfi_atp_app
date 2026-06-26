import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/atp_api.dart';
import '../config.dart';
import '../models/download_job.dart';
import '../services/clip_downloader.dart';

/// Download Centre — every server-side download job across all devices, with
/// live progress, Open/Save (presigned), Retry (when the whole fallback chain
/// failed) and Cancel. Auto-refreshes while any job is still running.
class DownloadCenterScreen extends StatefulWidget {
  const DownloadCenterScreen({super.key});

  @override
  State<DownloadCenterScreen> createState() => _DownloadCenterScreenState();
}

class _DownloadCenterScreenState extends State<DownloadCenterScreen> {
  bool _loading = true;
  String? _error;
  List<DownloadJob> _jobs = const [];
  Timer? _poll;
  final Set<String> _retrying = {};
  // Save-to-phone state per jobId: progress 0..1 while saving, then 'saved'.
  final Map<String, double> _saveProgress = {};
  final Set<String> _saved = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jobs = await AtpApi.listDownloads();
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _loading = false;
        _error = null;
      });
      _syncPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // Poll every 3s while at least one job is active; stop when all terminal.
  void _syncPolling() {
    final active = _jobs.any((j) => !j.isTerminal);
    if (active && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());
    } else if (!active) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _retry(DownloadJob j) async {
    if (j.deviceId.isEmpty || j.startTime.isEmpty) {
      _toast('Cannot retry — missing job params');
      return;
    }
    setState(() => _retrying.add(j.jobId));
    try {
      await AtpApi.startDownload(
        deviceId: j.deviceId,
        channel: j.channel,
        streamType: j.streamType,
        startTime: j.startTime,
        endTime: j.endTime,
      );
      if (!mounted) return;
      _toast('Retry queued');
      await _load();
    } catch (e) {
      if (!mounted) return;
      _toast('Retry failed: $e');
    } finally {
      if (mounted) setState(() => _retrying.remove(j.jobId));
    }
  }

  Future<void> _cancel(DownloadJob j) async {
    await AtpApi.cancelDownload(j.jobId);
    await _load();
  }

  Future<void> _save(DownloadJob j) async {
    final url = j.downloadUrl;
    if (url == null) return;
    setState(() => _saveProgress[j.jobId] = 0);
    try {
      await ClipDownloader.downloadToGallery(
        url: url,
        filename: 'airfi_${j.deviceId}_ch${j.channel}',
        onProgress: (p) {
          if (mounted) setState(() => _saveProgress[j.jobId] = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _saveProgress.remove(j.jobId);
        _saved.add(j.jobId);
      });
      _toast('Saved to Photos');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveProgress.remove(j.jobId));
      _toast('Download failed: $e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final active = _jobs.where((j) => !j.isTerminal).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Management'),
        actions: [
          if (active > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text('$active active',
                    style: const TextStyle(fontSize: 12, color: Colors.cyanAccent)),
              ),
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _jobs.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 120),
        Center(
            child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent)),
        )),
      ]);
    }
    if (_jobs.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 140),
        Center(
            child: Text('No downloads yet',
                style: TextStyle(color: Colors.white38))),
        SizedBox(height: 6),
        Center(
            child: Text('Start one from a clip in Playback',
                style: TextStyle(color: Colors.white24, fontSize: 12))),
      ]);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _jobs.length,
      itemBuilder: (_, i) => _card(_jobs[i]),
    );
  }

  Widget _card(DownloadJob j) {
    final pct = (j.progressPct.clamp(0, 100)) / 100.0;
    Color sc = Colors.cyanAccent;
    if (j.isDone) sc = Colors.greenAccent;
    if (j.isFailed) sc = Colors.redAccent;
    final retrying = _retrying.contains(j.jobId);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12161C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(j.deviceId.isEmpty ? j.jobId : j.deviceId,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
              Text(
                '${j.clipLabel}${j.dateLabel.isNotEmpty ? '  ·  ${j.dateLabel}' : ''}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ]),
          ),
          _statusChip(j, sc),
        ]),
        const SizedBox(height: 8),
        if (!j.isTerminal) ...[
          LinearProgressIndicator(value: pct > 0 ? pct : null),
          const SizedBox(height: 4),
          Text(
            '${j.progressPct.toStringAsFixed(0)}%'
            '${j.rxLabel.isNotEmpty ? '  ·  ${j.rxLabel}' : ''}'
            '${j.etaSec > 0 ? '  ·  ETA ${j.etaSec}s' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.white60),
          ),
        ],
        if (j.isDone) ...[
          Text(
            'Ready${j.sizeLabel.isNotEmpty ? '  ·  ${j.sizeLabel}' : ''}'
            '${j.backendUsed.isNotEmpty ? '  ·  via ${j.backendUsed}' : ''}'
            '${j.partial ? '  ·  partial' : ''}',
            style: const TextStyle(fontSize: 11.5, color: Colors.white70),
          ),
        ],
        if (j.isFailed && j.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(j.error!,
                style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
          ),
        const SizedBox(height: 8),
        _actions(j, retrying),
      ]),
    );
  }

  Widget _statusChip(DownloadJob j, Color sc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: sc.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: sc),
      ),
      child: Text(j.status,
          style: TextStyle(fontSize: 10, color: sc, fontWeight: FontWeight.bold)),
    );
  }

  Widget _actions(DownloadJob j, bool retrying) {
    final btns = <Widget>[];
    if (j.isDone && j.downloadUrl != null) {
      final saving = _saveProgress.containsKey(j.jobId);
      final saved = _saved.contains(j.jobId);
      final prog = _saveProgress[j.jobId] ?? 0;
      btns.add(Expanded(
        child: FilledButton.icon(
          onPressed: (saving || saved) ? null : () => _save(j),
          icon: saving
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, value: prog > 0 ? prog : null))
              : Icon(saved ? Icons.check_circle : Icons.download, size: 18),
          label: Text(saving
              ? 'Saving ${(prog * 100).toStringAsFixed(0)}%'
              : saved
                  ? 'Saved'
                  : 'Download'),
        ),
      ));
      btns.add(IconButton(
        tooltip: 'Copy URL',
        onPressed: () async {
          await Clipboard.setData(
              ClipboardData(text: Config.resolveMediaUrl(j.downloadUrl!)));
          _toast('URL copied');
        },
        icon: const Icon(Icons.copy, size: 18),
      ));
    }
    if (j.isFailed) {
      btns.add(Expanded(
        child: FilledButton.tonalIcon(
          onPressed: retrying ? null : () => _retry(j),
          icon: retrying
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh, size: 18),
          label: const Text('Retry'),
        ),
      ));
    }
    if (!j.isTerminal) {
      btns.add(Expanded(
        child: OutlinedButton.icon(
          onPressed: () => _cancel(j),
          icon: const Icon(Icons.stop, size: 18),
          label: const Text('Cancel'),
        ),
      ));
    }
    if (btns.isEmpty) return const SizedBox.shrink();
    return Row(children: btns);
  }
}
