import 'package:flutter/material.dart';

import '../api/atp_api.dart';
import '../config.dart';
import '../models/device.dart';
import 'device_screen.dart';
import 'download_center_screen.dart';

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  List<Device> _devices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await AtpApi.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = d;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Management'),
        actions: [
          IconButton(
            tooltip: 'Download Centre',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadCenterScreen()),
            ),
            icon: const Icon(Icons.download_for_offline),
          ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(children: [
        const SizedBox(height: 120),
        const Icon(Icons.cloud_off, size: 48, color: Colors.white30),
        const SizedBox(height: 12),
        Center(
          child: Text('Could not reach ${Config.apiBase}\n$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54)),
        ),
        const SizedBox(height: 12),
        Center(child: FilledButton(onPressed: _refresh, child: const Text('Retry'))),
      ]);
    }
    if (_devices.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 160),
        Center(child: Text('No devices online', style: TextStyle(color: Colors.white54))),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _devices.length,
      separatorBuilder: (_, i) => const Divider(height: 1, color: Colors.white10),
      itemBuilder: (_, i) => _tile(_devices[i]),
    );
  }

  Widget _tile(Device d) {
    final online = d.online;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: online ? Colors.greenAccent.withValues(alpha: 0.18) : Colors.white12,
        child: Icon(Icons.videocam,
            color: online ? Colors.greenAccent : Colors.white38),
      ),
      title: Text(d.label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${d.deviceId}\n'
        '${online ? "online" : "offline"} · ign ${d.ignition ? "ON" : "off"} · '
        'csq ${d.csq} · sd ${d.sdStatus.isEmpty ? "?" : d.sdStatus}',
        style: const TextStyle(fontSize: 11.5, color: Colors.white54, height: 1.4),
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DeviceScreen(device: d)),
      ),
    );
  }
}
