import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef OnAudioDataRecorded = void Function(Uint8List pcm);
typedef OnError = void Function(String error);

/// Dart wrapper around the native `com.airfi.talkback/audio` MethodChannel.
/// Native side captures mic (Int16 PCM, 8 kHz mono) and plays downlink PCM
/// through one shared AVAudioEngine. Dart converts to/from G.711A on top.
class TalkbackAudioService {
  static const _ch = MethodChannel('com.airfi.talkback/audio');

  bool _recording = false;
  bool _disposed = false;
  int _playLog = 0;

  OnAudioDataRecorded? _onData;
  OnError? _onError;

  bool get isRecording => _recording;

  void setCallbacks({OnAudioDataRecorded? onData, OnError? onError}) {
    _onData = onData;
    _onError = onError;
  }

  Future<bool> initialize({int sampleRate = 8000, int channels = 1}) async {
    if (_disposed) return false;
    try {
      _ch.setMethodCallHandler(_handle);
      final ok = await _ch.invokeMethod<bool>('initialize', {
        'sampleRate': sampleRate,
        'channels': channels,
      });
      return ok ?? true;
    } catch (e) {
      _onError?.call('init: $e');
      return false;
    }
  }

  Future<bool> startRecording() async {
    if (_disposed || _recording) return _recording;
    try {
      final ok = await _ch.invokeMethod<bool>('startRecording');
      _recording = ok ?? false;
      debugPrint('[Talkback] recording started=$_recording');
      return _recording;
    } catch (e) {
      _onError?.call('startRecording: $e');
      return false;
    }
  }

  Future<bool> stopRecording() async {
    if (_disposed || !_recording) return true;
    try {
      await _ch.invokeMethod<bool>('stopRecording');
    } catch (_) {}
    _recording = false;
    return true;
  }

  Future<bool> playAudio(Uint8List pcm) async {
    if (_disposed || pcm.isEmpty) return false;
    try {
      await _ch.invokeMethod<bool>('playAudio', {'audioData': pcm});
      if (++_playLog % 50 == 0) debugPrint('[Talkback] played chunks=$_playLog');
      return true;
    } catch (e) {
      _onError?.call('play: $e');
      return false;
    }
  }

  Future<void> enableSpeaker(bool on) async {
    try {
      await _ch.invokeMethod('enableSpeaker', {'enable': on});
    } catch (_) {}
  }

  Future<void> setVolume(int v) async {
    try {
      await _ch.invokeMethod('setVolume', {'volume': v.clamp(0, 100)});
    } catch (_) {}
  }

  Future<void> release() async {
    await stopRecording();
    try {
      await _ch.invokeMethod('release');
    } catch (_) {}
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (_disposed) return false;
    switch (call.method) {
      case 'tbDiag':
        // Native diagnostics routed through Dart (NSLog doesn't surface in
        // `flutter run` console). Shows tap-fire + engine state for b→d debug.
        debugPrint('[TalkbackNative] ${call.arguments}');
        return true;
      case 'onAudioChunk':
        final pcm = call.arguments as Uint8List?;
        if (pcm != null) _onData?.call(pcm);
        return true;
    }
    return false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _onData = null;
    _onError = null;
    _ch.setMethodCallHandler(null);
    unawaited(release());
  }
}
