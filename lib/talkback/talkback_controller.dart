import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api/atp_api.dart';
import '../config.dart';
import 'g711a_codec.dart';
import 'talkback_audio_service.dart';
import 'talkback_ws_service.dart';

/// Two-way push-to-talk intercom over the ATP server's /ws/talkback relay.
///
/// Audio ownership is EXCLUSIVE: starting talkback first releases every live
/// ATP tile's audio engine ([AirfiAtpController.pauseAllAudio]) so the talkback
/// AVAudioEngine is the sole owner of the mic HAL — the multi-engine contention
/// is what silently killed the app→device uplink before. Video keeps playing.
class TalkbackController extends ChangeNotifier {
  bool _isTalking = false;
  bool _isLoading = false;
  String? _error;
  String _status = 'idle';

  String? _deviceId;
  int? _channel;

  final TalkbackAudioService _audio = TalkbackAudioService();
  TalkbackWsService? _ws;

  bool _txEnabled = false; // app -> device (mic uplink)
  bool _rxEnabled = false; // device -> app (downlink playback)
  final List<int> _uplink = <int>[];
  bool _disposed = false;

  bool get isTalking => _isTalking;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get status => _status;
  int get framesSent => _ws?.framesSent ?? 0;
  int get framesReceived => _ws?.framesReceived ?? 0;

  Future<void> start({required String deviceId, required int channel}) async {
    if (_disposed || _isLoading || _isTalking) return;
    _deviceId = deviceId;
    _channel = channel;
    _set(loading: true, error: null, status: 'starting');

    // 1. Mic permission.
    if (!await _ensureMicPermission()) {
      _set(loading: false, status: 'idle', error: 'Microphone permission denied');
      return;
    }

    // 2. Native audio (8 kHz mono PCM) — single shared engine, mic + playback.
    //    The talkback native plugin owns its own AVAudioEngine; the ATP tile
    //    players keep running (their audio coexists). b→d mic ownership is the
    //    native plugin's concern, handled there — kept off the video path.
    if (!await _audio.initialize(
        sampleRate: G711ACodec.sampleRate, channels: G711ACodec.channels)) {
      _set(loading: false, status: 'idle', error: 'Audio init failed');
      return;
    }
    _uplink.clear();

    // 4. Tell the server to dial the device back for talkback.
    int? wsPort;
    try {
      wsPort = await AtpApi.startTalkback(deviceId: deviceId, channel: channel);
    } catch (e) {
      _set(loading: false, status: 'idle', error: 'talkback/start: $e');
      await _cleanup();
      return;
    }
    if (wsPort == null) {
      _set(loading: false, status: 'idle', error: 'talkback/start returned no port');
      await _cleanup();
      return;
    }

    // 5. Connect the relay WS.
    _ws = TalkbackWsService(
      Config.talkbackWsUrl(deviceId: deviceId, channel: channel),
    )..setCallbacks(
        onAlaw: _onAlawFromDevice,
        onStatus: _onWsStatus,
        onError: (e) => _set(error: e),
      );
    await _ws!.connect();

    // 6. Wire mic capture -> a-law uplink, downlink a-law -> PCM playback.
    _audio.setCallbacks(onData: _onMicPcm, onError: (e) => _set(error: e));
    await _audio.enableSpeaker(true);
    await _audio.setVolume(90);
    _rxEnabled = true;
    _txEnabled = await _audio.startRecording();

    _set(loading: false, status: 'talking');
    _isTalking = true;
    _notify();
    debugPrint('[Talkback] started dev=$deviceId ch=$channel wsPort=$wsPort tx=$_txEnabled');
  }

  Future<void> stop() async {
    if (_disposed || _isLoading || !_isTalking) {
      // Still attempt backend cleanup if we have a session.
      if (_deviceId != null && _channel != null) {
        await AtpApi.stopTalkback(deviceId: _deviceId!, channel: _channel!);
      }
      return;
    }
    _set(loading: true, status: 'stopping');
    final dev = _deviceId, ch = _channel;
    await _cleanup();
    if (dev != null && ch != null) {
      await AtpApi.stopTalkback(deviceId: dev, channel: ch);
    }
    _deviceId = null;
    _channel = null;
    _isTalking = false;
    _set(loading: false, status: 'idle', error: null);
    debugPrint('[Talkback] stopped');
  }

  Future<void> _cleanup() async {
    _txEnabled = false;
    _rxEnabled = false;
    _uplink.clear();
    final ws = _ws;
    _ws = null;
    ws?.clearCallbacks();
    await ws?.disconnect();
    ws?.dispose();
    await _audio.release();
  }

  // device -> app: a-law frame in, decode to PCM, play.
  void _onAlawFromDevice(Uint8List alaw) {
    if (_disposed || !_rxEnabled) return;
    final pcm = G711ACodec.decodeAlawToPcm(alaw.toList());
    _audio.playAudio(Uint8List.fromList(pcm));
  }

  // app -> device: mic PCM in, encode to a-law, chunk to 1024 bytes, send.
  void _onMicPcm(Uint8List pcm) {
    if (_disposed || !_txEnabled || !(_ws?.isConnected ?? false)) return;
    _uplink.addAll(G711ACodec.encodePcmToAlaw(pcm.toList()));
    while (_uplink.length >= G711ACodec.uplinkChunkSize) {
      final chunk =
          Uint8List.fromList(_uplink.sublist(0, G711ACodec.uplinkChunkSize));
      _ws?.sendAlaw(chunk);
      _uplink.removeRange(0, G711ACodec.uplinkChunkSize);
    }
  }

  void _onWsStatus(String status, String message) {
    if (_disposed) return;
    debugPrint('[Talkback] ws status=$status $message');
    _set(status: _isTalking ? 'talking' : status);
  }

  Future<bool> _ensureMicPermission() async {
    var s = await Permission.microphone.status;
    if (s.isGranted) return true;
    if (s.isPermanentlyDenied || s.isRestricted) return false;
    s = await Permission.microphone.request();
    return s.isGranted;
  }

  void _set({bool? loading, bool? talking, String? status, String? error}) {
    if (_disposed) return;
    if (loading != null) _isLoading = loading;
    if (talking != null) _isTalking = talking;
    if (status != null) _status = status;
    _error = error;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final dev = _deviceId, ch = _channel;
    if (dev != null && ch != null) {
      unawaited(AtpApi.stopTalkback(deviceId: dev, channel: ch));
    }
    unawaited(_cleanup());
    _audio.dispose();
    super.dispose();
  }
}
