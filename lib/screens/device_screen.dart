import 'package:flutter/material.dart';

import '../models/device.dart';
import '../talkback/talkback_controller.dart';
import '../widgets/atp_stream_view.dart';
import 'alerts_tab.dart';
import 'fullscreen_screen.dart';
import 'playback_tab.dart';

class DeviceScreen extends StatefulWidget {
  final Device device;
  const DeviceScreen({super.key, required this.device});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return Scaffold(
      appBar: AppBar(
        title: Text(d.label),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.sensors), text: 'Live'),
            Tab(icon: Icon(Icons.history), text: 'Playback'),
            Tab(icon: Icon(Icons.warning_amber), text: 'Alerts'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _LiveTab(device: d),
          PlaybackTab(device: d),
          AlertsTab(device: d),
        ],
      ),
    );
  }
}


/// Live tab — 2×2 grid of all 4 channels at once. Tapping a tile focuses it
/// (highlight + audio target + intercom target). Channels with no publisher
/// just show their own buffering/error overlay; the others keep playing.
class _LiveTab extends StatefulWidget {
  final Device device;
  const _LiveTab({required this.device});

  @override
  State<_LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<_LiveTab> with AutomaticKeepAliveClientMixin {
  int _focused = 1; // 1..4
  bool _audioOn = false; // listen to the focused tile
  final TalkbackController _talkback = TalkbackController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _talkback.addListener(_onTalkback);
  }

  void _onTalkback() => setState(() {});

  @override
  void dispose() {
    _talkback.removeListener(_onTalkback);
    _talkback.dispose();
    super.dispose();
  }

  Future<void> _toggleIntercom() async {
    if (_talkback.isTalking) {
      await _talkback.stop();
    } else {
      await _talkback.start(deviceId: widget.device.deviceId, channel: _focused);
    }
  }

  void _openFullscreen(int ch) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FullscreenScreen(
        deviceId: widget.device.deviceId,
        channel: ch,
        live: true,
        audioOn: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              children: [
                Expanded(child: Row(children: [_tile(1), const SizedBox(width: 6), _tile(2)])),
                const SizedBox(height: 6),
                Expanded(child: Row(children: [_tile(3), const SizedBox(width: 6), _tile(4)])),
              ],
            ),
          ),
        ),
        _controls(),
      ],
    );
  }

  Widget _tile(int ch) {
    final focused = ch == _focused;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _focused = ch),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: focused ? const Color(0xFF00E5FF) : Colors.white12,
              width: focused ? 2 : 1,
            ),
          ),
          child: Stack(fit: StackFit.expand, children: [
            AtpStreamView(
              key: ValueKey('live-${widget.device.deviceId}-$ch'),
              deviceId: widget.device.deviceId,
              channel: ch,
              streamType: 1,
              live: true,
              fit: BoxFit.cover,
              muted: !(_audioOn && focused),
            ),
            Positioned(
              left: 4,
              top: 3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('CAM $ch',
                    style: TextStyle(
                        fontSize: 10,
                        color: focused ? const Color(0xFF00E5FF) : Colors.white70)),
              ),
            ),
            if (focused)
              Positioned(
                right: 2,
                top: 2,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _openFullscreen(ch),
                  icon: const Icon(Icons.fullscreen, size: 22, color: Colors.white70),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _controls() {
    final talking = _talkback.isTalking;
    final loading = _talkback.isLoading;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
      color: const Color(0xFF12161C),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
            child: Text('Focused: CAM $_focused',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Text('Listen', style: TextStyle(fontSize: 12, color: Colors.white60)),
          Switch(
            value: _audioOn,
            onChanged: talking ? null : (v) => setState(() => _audioOn = v),
          ),
        ]),
        if (_talkback.error != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(_talkback.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
          ),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: talking ? Colors.redAccent : null,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: loading ? null : _toggleIntercom,
            icon: loading
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(talking ? Icons.mic_off : Icons.mic),
            label: Text(talking
                ? 'Stop intercom · CAM $_focused  (tx ${_talkback.framesSent} rx ${_talkback.framesReceived})'
                : 'Start intercom · CAM $_focused'),
          ),
        ),
      ]),
    );
  }
}
