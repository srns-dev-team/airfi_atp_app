import 'dart:async';

import 'package:airfi_atp_flutter/airfi_atp_flutter.dart';
import 'package:flutter/material.dart';

import '../api/atp_api.dart';
import '../config.dart';

/// Self-contained ATP video surface. Triggers the session (/camera for live,
/// /history/start for playback), waits for the publisher to warm, then opens
/// the ATP WS and renders the native player. Re-boots when its stream params
/// change (channel / time-range switch). Draws connecting / error overlays.
class AtpStreamView extends StatefulWidget {
  final String deviceId;
  final int channel;
  final int streamType;
  final bool live;
  final String? startTime; // playback only ("YYYY-MM-DD HH:mm:ss")
  final String? endTime;
  final bool muted;
  final BoxFit fit;
  final VoidCallback? onTap;

  /// Delay before this tile starts its session. In a multi-tile grid, set a
  /// per-tile slot (e.g. index × ~900ms) so the native decoders don't all
  /// initialize in the same window — simultaneous VT init contends and stalls
  /// every-but-one tile after the first frame (single/late inits are fine).
  final Duration bootDelay;

  const AtpStreamView({
    super.key,
    required this.deviceId,
    required this.channel,
    required this.streamType,
    required this.live,
    this.startTime,
    this.endTime,
    this.muted = false,
    this.fit = BoxFit.contain,
    this.onTap,
    this.bootDelay = Duration.zero,
  });

  @override
  State<AtpStreamView> createState() => _AtpStreamViewState();
}

class _AtpStreamViewState extends State<AtpStreamView> {
  AirfiAtpController? _controller;
  int _gen = 0;
  bool _triggering = false;
  String _state = 'idle';
  String? _error;
  Timer? _diagTimer;
  Map<String, dynamic>? _diag; // native decode stats, shown on-tile

  // Anti-churn (ported from fleet AtpVideoTile). A feedless/starved channel must
  // go QUIET (dispose the controller), never sit in an upgrade→close→reconnect
  // loop — that churn wedges the MDVR's JT1078 stream slots. Manual Retry reopens.
  bool _hasMedia = false; // first NALU seen
  bool _noSignal = false; // disposed feedless channel; show Retry
  int _lastNaluCount = 0;
  DateTime? _lastNaluAt;
  bool _resyncedThisStall = false;
  bool _noSignalExtended = false; // one-shot grace extension (see _armNoSignalTimer)
  Timer? _noSignalTimer;
  Timer? _freezeTimer;
  static const _noSignalGrace = Duration(seconds: 15);
  // KEEPALIVEs seen by this many ticks (server sends ~1 / 2s) = transport
  // healthy, device just hasn't reached its next IDR yet. ~3 ≈ 6s of liveness.
  static const _keepaliveAliveThreshold = 3;

  /// Toggle the on-tile decode-stats overlay (debug). Built into every tile so
  /// the device-logging tooling (flaky on iOS 26) isn't needed.
  static const bool showDiag = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void didUpdateWidget(covariant AtpStreamView old) {
    super.didUpdateWidget(old);
    final paramsChanged = old.deviceId != widget.deviceId ||
        old.channel != widget.channel ||
        old.streamType != widget.streamType ||
        old.live != widget.live ||
        old.startTime != widget.startTime ||
        old.endTime != widget.endTime;
    if (paramsChanged) {
      _boot();
    } else if (old.muted != widget.muted) {
      _controller?.setMuted(widget.muted);
    }
  }

  Future<void> _boot() async {
    final gen = ++_gen;
    _diagTimer?.cancel();
    _noSignalTimer?.cancel();
    _freezeTimer?.cancel();
    _hasMedia = false;
    _noSignal = false;
    _lastNaluCount = 0;
    _lastNaluAt = null;
    _resyncedThisStall = false;
    _noSignalExtended = false;
    final old = _controller;
    _controller = null;
    old?.dispose();
    setState(() {
      _triggering = true;
      _state = 'starting';
      _error = null;
    });

    // Stagger multi-tile starts so the 4 native decoders don't init at once.
    if (widget.bootDelay > Duration.zero) {
      await Future.delayed(widget.bootDelay);
      if (gen != _gen || !mounted) return;
    }

    try {
      if (widget.live) {
        await AtpApi.startCamera(
          deviceId: widget.deviceId,
          channel: widget.channel,
          streamType: widget.streamType,
        );
      } else {
        await AtpApi.startHistory(
          deviceId: widget.deviceId,
          channel: widget.channel,
          streamType: widget.streamType,
          startTime: widget.startTime ?? '',
          endTime: widget.endTime ?? '',
        );
      }
    } catch (e) {
      if (gen != _gen || !mounted) return;
      setState(() {
        _triggering = false;
        _error = '$e';
      });
      return;
    }

    // Publisher warm-up: live caches a keyframe fast; playback must fetch from
    // the device SD card, so allow longer.
    await Future.delayed(Duration(milliseconds: widget.live ? 1500 : 3500));
    if (gen != _gen || !mounted) return;
    _connect(gen);
  }

  /// Open the WS + decoder for an already-triggered session. A starved tile
  /// (device won't send that channel — e.g. the N6's 3-stream cap) is left to
  /// the controller's own gentle WS reconnect; we do NOT churn controllers from
  /// the app — that reconnect storm white-screened the app on device reboot and
  /// cannot conjure a stream the device refuses to send anyway.
  void _connect(int gen) {
    _newController(gen);
    _startDiag(gen);
    _armNoSignalTimer(gen);
    _armFreezeWatchdog(gen);
  }

  /// No media within the grace window → dispose the controller so a feedless
  /// channel (sink exists, device sends nothing — e.g. wedged/over-cap) stops
  /// the upgrade→close→reconnect churn that wedges the device. Retry reopens.
  void _armNoSignalTimer(int gen) {
    _noSignalTimer?.cancel();
    _noSignalTimer = Timer(_noSignalGrace, () {
      if (gen != _gen || !mounted || _hasMedia) return;
      // Device alive but no video yet? On a long-GOP stream (HEVC N6) the next
      // IDR can be further out than the base grace, and the server sends
      // KEEPALIVEs in the meantime. If keepalives are flowing the transport is
      // healthy — extend once for another grace window to let the IDR land,
      // rather than giving up + forcing a Retry. A truly silent channel (no
      // keepalives) still goes straight to No-signal.
      final ka = _controller?.stats.keepaliveCount ?? 0;
      if (ka >= _keepaliveAliveThreshold && !_noSignalExtended) {
        _noSignalExtended = true;
        _armNoSignalTimer(gen);
        return;
      }
      _teardown(noSignal: true);
    });
  }

  /// Had media then frames stopped advancing: >8s → ask bridge to replay
  /// init+keyframe; >20s → tear down to No-signal+Retry (don't sit frozen).
  void _armFreezeWatchdog(int gen) {
    _freezeTimer?.cancel();
    _freezeTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (gen != _gen || !mounted || !_hasMedia) return;
      final last = _lastNaluAt;
      if (last == null) return;
      final stalledMs = DateTime.now().difference(last).inMilliseconds;
      if (stalledMs > 20000) {
        _teardown(noSignal: true);
      } else if (stalledMs > 8000 && !_resyncedThisStall) {
        _resyncedThisStall = true;
        _controller?.requestResync();
      }
    });
  }

  void _teardown({required bool noSignal}) {
    _noSignalTimer?.cancel();
    _freezeTimer?.cancel();
    _diagTimer?.cancel();
    _controller?.removeListener(_onStats);
    _controller?.dispose();
    _controller = null;
    if (mounted) {
      setState(() {
        _noSignal = noSignal;
        _hasMedia = false;
      });
    }
  }

  void _newController(int gen) {
    _controller?.removeListener(_onStats);
    _controller?.dispose();
    final c = AirfiAtpController(
      wsUrl: Config.streamWsUrl(
        deviceId: widget.deviceId,
        channel: widget.channel,
        streamType: widget.streamType,
        live: widget.live,
      ),
      // Gentle reconnect: a fragile MDVR (N6) wedges its JT1078 stream slots
      // under reconnect storms. Cap attempts low + slow the cadence so a
      // dropped or non-existent (404) channel backs off instead of hammering
      // the device into a wedge. Default was 20×/1s — way too aggressive here.
      reconnectMaxAttempts: 4,
      reconnectDelay: const Duration(seconds: 2),
      onState: (s) {
        if (gen != _gen || !mounted) return;
        setState(() => _state = s);
        // WS gave up (dead/feedless channel) or server ended it → go quiet,
        // don't let it keep retrying.
        if (s == 'max-reconnects' || s == 'server-bye') {
          _teardown(noSignal: true);
        }
      },
      onError: (e) {
        if (gen != _gen || !mounted) return;
        setState(() => _error = '$e');
      },
    )..setMuted(widget.muted);
    c.addListener(_onStats);
    if (gen != _gen || !mounted) {
      c.dispose();
      return;
    }
    setState(() {
      _controller = c;
      _triggering = false;
    });
    c.start();
  }

  void _startDiag(int gen) {
    _diagTimer?.cancel();
    _diagTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (gen != _gen || !mounted) return;
      final d = await _controller?.getNativeDiag();
      if (gen != _gen || !mounted) return;
      final s = _controller?.stats;
      debugPrint('[VTDiag] cam${widget.channel} codec=${d?['codec']} '
          'sess=${d?['sessionOK']} cs=${d?['createStatus']} '
          'N=${s?.vNaluCount}/IDR${s?.vNaluKey} calls=${d?['decodeCalls']} '
          'OUT=${d?['framesOut']} dErr=${d?['lastDecodeErr']} cbErr=${d?['lastCbErr']}');
      setState(() => _diag = d);
    });
  }

  void _onStats() {
    if (!mounted) return;
    final n = _controller?.stats.vNaluCount ?? 0;
    if (n > _lastNaluCount) {
      _lastNaluCount = n;
      _lastNaluAt = DateTime.now();
      _resyncedThisStall = false;
      if (!_hasMedia) {
        _noSignalTimer?.cancel(); // got media → no longer a dead channel
        _hasMedia = true;
        _noSignal = false;
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _diagTimer?.cancel();
    _noSignalTimer?.cancel();
    _freezeTimer?.cancel();
    _controller?.removeListener(_onStats);
    _controller?.dispose();
    super.dispose();
  }

  bool get _hasVideo => (_controller?.stats.vNaluCount ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    Widget overlay = const SizedBox.shrink();
    if (_noSignal) {
      // Channel went quiet (no media / froze) — disposed to stop the churn.
      overlay = _center(
        Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.videocam_off, color: Colors.white38, size: 30),
          const SizedBox(height: 6),
          const Text('No signal',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          TextButton(onPressed: _boot, child: const Text('Retry')),
        ]),
      );
    } else if (_error != null && !_hasVideo) {
      overlay = _center(
        Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 32),
          const SizedBox(height: 8),
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          TextButton(onPressed: _boot, child: const Text('Retry')),
        ]),
      );
    } else if (_triggering || c == null || !_hasVideo) {
      final label = _triggering
          ? (widget.live ? 'Starting live…' : 'Loading recording…')
          : (_state == 'closed' || _state == 'connecting'
              ? 'Reconnecting…'
              : 'Buffering…');
      overlay = _center(
        Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4)),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ]),
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(fit: StackFit.expand, children: [
          if (c != null) AirfiAtpPlayer(controller: c, fit: widget.fit),
          overlay,
          if (showDiag) _topPacketOverlay(),
        ]),
      ),
    );
  }

  /// Top banner: media PTS clock + frame-out count, so you can eyeball whether
  /// the video timeline is actually advancing (PTS + OUT both rising = live;
  /// PTS frozen = stalled even if a frame is painted).
  Widget _topPacketOverlay() {
    final s = _controller?.stats;
    final d = _diag;
    final ptsUs = s?.lastVideoPtsUs ?? 0;
    final fo = d?['framesOut'];
    final n = s?.vNaluCount ?? 0;
    final ka = s?.keepaliveCount ?? 0;
    final moving = ptsUs > _lastShownPtsUs;
    _lastShownPtsUs = ptsUs;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(children: [
          Icon(moving ? Icons.fiber_manual_record : Icons.pause_circle_filled,
              size: 11, color: moving ? Colors.greenAccent : Colors.orangeAccent),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'pts ${_fmtPts(ptsUs)}  OUT=${fo ?? '-'}  N=$n  ka=$ka',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: moving ? Colors.greenAccent : Colors.orangeAccent,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  int _lastShownPtsUs = -1;

  /// Format a microsecond PTS as mm:ss.mmm (relative stream time).
  String _fmtPts(int us) {
    if (us <= 0) return '--:--.---';
    final ms = us ~/ 1000;
    final m = ms ~/ 60000;
    final sec = (ms ~/ 1000) % 60;
    final milli = ms % 1000;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.${milli.toString().padLeft(3, '0')}';
  }

  Widget _center(Widget child) => Center(child: child);
}
