import 'package:flutter/material.dart';

import '../api/atp_api.dart';
import '../config.dart';
import '../models/alert.dart';
import '../models/device.dart';

/// Alerts tab — lists recent ADAS/DMS alerts for the device with inline
/// evidence-image thumbnails. Pull to refresh; tap a thumbnail to view it
/// full-screen. Validates the alert→evidence→S3 pipeline end-to-end on
/// staging.
class AlertsTab extends StatefulWidget {
  final Device device;
  const AlertsTab({super.key, required this.device});

  @override
  State<AlertsTab> createState() => _AlertsTabState();
}

class _AlertsTabState extends State<AlertsTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = false;
  String? _error;
  List<Alert> _alerts = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final a = await AtpApi.listAlerts(deviceId: widget.device.deviceId);
      if (!mounted) return;
      setState(() {
        _alerts = a;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _viewImage(String url, String title) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ImageViewer(url: Config.resolveMediaUrl(url), title: title),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: _body(),
    );
  }

  Widget _body() {
    if (_loading && _alerts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _alerts.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          ),
          const Center(child: Text('Pull to retry', style: TextStyle(color: Colors.white38))),
        ],
      );
    }
    if (_alerts.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(
              child: Text('No alerts for this device',
                  style: TextStyle(color: Colors.white38))),
          SizedBox(height: 8),
          Center(child: Text('Pull to refresh', style: TextStyle(color: Colors.white24))),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _alerts.length,
      itemBuilder: (_, i) => _alertCard(_alerts[i]),
    );
  }

  Widget _alertCard(Alert a) {
    final images = a.images;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12161C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _levelBadge(a.level),
          const SizedBox(width: 8),
          Expanded(
            child: Text(a.title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          if (a.module.isNotEmpty)
            Text(a.module.toUpperCase(),
                style: const TextStyle(fontSize: 10, color: Colors.white38)),
        ]),
        const SizedBox(height: 4),
        Text(
          '${_fmtTime(a.eventTime)}'
          '${a.speedKmh > 0 ? '  ·  ${a.speedKmh.toStringAsFixed(0)} km/h' : ''}'
          '${a.eventCode.isNotEmpty ? '  ·  ${a.eventCode}' : ''}',
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
        if (images.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 90,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => _thumb(images[i], a.title),
            ),
          ),
        ] else if (a.attachmentsCount > 0) ...[
          const SizedBox(height: 8),
          Text('${a.attachmentsCount} attachment(s) pending upload',
              style: const TextStyle(fontSize: 11, color: Colors.orangeAccent)),
        ],
      ]),
    );
  }

  Widget _thumb(EvidenceFile ev, String title) {
    final url = Config.resolveMediaUrl(ev.url);
    return GestureDetector(
      onTap: () => _viewImage(ev.url, title),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          url,
          width: 120,
          height: 90,
          fit: BoxFit.cover,
          loadingBuilder: (c, child, prog) => prog == null
              ? child
              : Container(
                  width: 120,
                  height: 90,
                  color: Colors.black26,
                  child: const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                ),
          errorBuilder: (c, e, st) => Container(
            width: 120,
            height: 90,
            color: Colors.black26,
            child: const Icon(Icons.broken_image, color: Colors.white24),
          ),
        ),
      ),
    );
  }

  Widget _levelBadge(int level) {
    Color c = Colors.blueGrey;
    if (level >= 2) {
      c = Colors.redAccent;
    } else if (level == 1) {
      c = Colors.orangeAccent;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c),
      ),
      child: Text('L$level',
          style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.bold)),
    );
  }

  // Trim the ISO timestamp to "MM-DD HH:mm:ss" for compactness.
  String _fmtTime(String iso) {
    if (iso.length >= 19) return iso.substring(5, 19).replaceAll('T', ' ');
    return iso;
  }
}

/// Full-screen pinch-zoom viewer for a single evidence image.
class _ImageViewer extends StatelessWidget {
  final String url;
  final String title;
  const _ImageViewer({required this.url, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(title), backgroundColor: Colors.black),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (c, e, st) => const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Failed to load image',
                  style: TextStyle(color: Colors.white54)),
            ),
          ),
        ),
      ),
    );
  }
}
