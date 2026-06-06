import 'package:flutter/material.dart';

import '../api/atp_api.dart';
import '../models/device.dart';
import '../widgets/atp_stream_view.dart';
import 'fullscreen_screen.dart';

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
  DateTime? _from;
  DateTime? _to;
  bool _loadingAvail = false;
  DayAvailability? _avail;
  String? _error;

  // Active playback request (null = not playing). Bumped to force re-boot.
  bool _playing = false;

  @override
  bool get wantKeepAlive => true;

  String _two(int n) => n.toString().padLeft(2, '0');
  String _fmtDate(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
  String _fmtTime(DateTime t) =>
      '${_fmtDate(t)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

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
    setState(() => _date = d);
    _loadAvailability();
  }

  Future<void> _pickRange({required bool from}) async {
    final init = (from ? _from : _to) ?? _date;
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(init));
    if (t == null) return;
    final dt = DateTime(_date.year, _date.month, _date.day, t.hour, t.minute);
    setState(() {
      if (from) {
        _from = dt;
      } else {
        _to = dt;
      }
    });
  }

  void _play() {
    if (_from == null || _to == null) return;
    setState(() => _playing = true);
  }

  void _openFullscreen() {
    if (_from == null || _to == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FullscreenScreen(
        deviceId: widget.device.deviceId,
        channel: _channel,
        live: false,
        startTime: _fmtTime(_from!),
        endTime: _fmtTime(_to!),
        audioOn: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Video surface (playback). Keyed on params so a new range re-boots it.
        AspectRatio(
          aspectRatio: 16 / 9,
          child: _playing && _from != null && _to != null
              ? AtpStreamView(
                  key: ValueKey(
                      'pb-${widget.device.deviceId}-$_channel-${_from!.millisecondsSinceEpoch}-${_to!.millisecondsSinceEpoch}'),
                  deviceId: widget.device.deviceId,
                  channel: _channel,
                  streamType: 0, // playback = main stream
                  live: false,
                  startTime: _fmtTime(_from!),
                  endTime: _fmtTime(_to!),
                  muted: false,
                  onTap: _openFullscreen,
                )
              : const ColoredBox(
                  color: Colors.black,
                  child: Center(
                      child: Text('Pick a range and press Play',
                          style: TextStyle(color: Colors.white38))),
                ),
        ),
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
            label: const Text('Load'),
          ),
        ]),
        const SizedBox(height: 12),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        if (_avail != null) ...[
          _coverageBar(_avail!),
          const SizedBox(height: 12),
          _intervalsList(_avail!),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pickRange(from: true),
              child: Text(_from == null ? 'From' : _fmtTime(_from!).substring(11)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pickRange(from: false),
              child: Text(_to == null ? 'To' : _fmtTime(_to!).substring(11)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (_from != null && _to != null) ? _play : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play recording'),
          ),
        ),
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
          onSelected: (_) => setState(() => _channel = ch),
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
      Text('coverage ${a.coverage.toStringAsFixed(1)}%  ·  ${a.intervals.length} intervals',
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

  Widget _intervalsList(DayAvailability a) {
    if (a.intervals.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Tap an interval to fill range:',
            style: TextStyle(fontSize: 11, color: Colors.white60)),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 140),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: a.intervals.length,
            itemBuilder: (_, i) {
              final iv = a.intervals[i];
              final s = iv['startTime'] as String? ?? '';
              final e = iv['endTime'] as String? ?? '';
              final dur = (iv['durationSec'] as num?)?.toInt() ?? 0;
              return InkWell(
                onTap: () {
                  try {
                    setState(() {
                      _from = DateTime.parse(s.replaceAll(' ', 'T'));
                      _to = DateTime.parse(e.replaceAll(' ', 'T'));
                    });
                  } catch (_) {}
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white12)),
                  ),
                  child: Text('$s → $e  (${(dur / 60).toStringAsFixed(0)} min)',
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
