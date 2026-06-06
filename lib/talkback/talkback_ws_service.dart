import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'g711a_codec.dart';

typedef OnAlawFrame = void Function(Uint8List alaw);
typedef OnStatus = void Function(String status, String message);
typedef OnWsError = void Function(String error);

/// WebSocket transport for two-way talkback. Binary frames = G.711A audio;
/// text frames = status JSON. Linear-backoff reconnect (3 tries, matches server).
class TalkbackWsService {
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  bool _connected = false;
  bool _disposed = false;
  bool _disconnecting = false;
  int _gen = 0;

  final String _url;
  int _reconnectAttempts = 0;
  static const int _maxReconnect = 3;
  Timer? _reconnectTimer;

  OnAlawFrame? _onAlaw;
  OnStatus? _onStatus;
  OnWsError? _onError;

  int framesReceived = 0;
  int framesSent = 0;
  int _rxLog = 0;
  int _txLog = 0;

  TalkbackWsService(this._url);

  bool get isConnected => _connected;

  void setCallbacks({
    required OnAlawFrame onAlaw,
    required OnStatus onStatus,
    required OnWsError onError,
  }) {
    _onAlaw = onAlaw;
    _onStatus = onStatus;
    _onError = onError;
  }

  void clearCallbacks() {
    _onAlaw = null;
    _onStatus = null;
    _onError = null;
  }

  Future<void> connect() async {
    if (_disposed || _connected) return;
    try {
      final uri = Uri.parse(_url);
      _disconnecting = false;
      final gen = ++_gen;
      debugPrint('[TalkbackWS] connecting $_url');
      _ch = WebSocketChannel.connect(uri);
      _sub?.cancel();
      _sub = _ch!.stream.listen(
        (m) => _onMessage(m, gen),
        onDone: () => _onClosed(gen),
        onError: (e) => _onWsError(e, gen),
      );
      _connected = true;
      _reconnectAttempts = 0;
      _onStatus?.call('connected', 'WebSocket connected');
    } catch (e) {
      if (_disposed) return;
      _onWsError(e, _gen);
    }
  }

  Future<void> disconnect() async {
    if (_disposed || _disconnecting) return;
    _disconnecting = true;
    _gen++;
    _reconnectTimer?.cancel();
    final sub = _sub;
    _sub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    _connected = false;
    _disconnecting = false;
  }

  void sendAlaw(Uint8List alaw) {
    if (!_connected || _ch == null) return;
    try {
      _ch!.sink.add(alaw);
      framesSent++;
      if (++_txLog % 50 == 0) debugPrint('[TalkbackWS] sent frames=$framesSent');
    } catch (e) {
      _onError?.call('send: $e');
    }
  }

  void _onMessage(dynamic msg, int gen) {
    if (_disposed || _disconnecting || gen != _gen) return;
    try {
      if (msg is String) {
        final s = TalkbackStatusMessage.fromJson(
            jsonDecode(msg) as Map<String, dynamic>);
        _onStatus?.call(s.status, s.message);
        if (s.status == 'error') _onError?.call(s.message);
      } else if (msg is List<int>) {
        final alaw = Uint8List.fromList(msg);
        framesReceived++;
        if (++_rxLog % 50 == 0) {
          debugPrint('[TalkbackWS] received frames=$framesReceived');
        }
        _onAlaw?.call(alaw);
      }
    } catch (e) {
      if (!_disposed) _onError?.call('parse: $e');
    }
  }

  void _onClosed(int gen) {
    if (_disposed || _disconnecting || gen != _gen) return;
    _connected = false;
    _onStatus?.call('closed', 'Connection closed');
    _reconnect();
  }

  void _onWsError(dynamic e, int gen) {
    if (_disposed || _disconnecting || gen != _gen) return;
    _connected = false;
    _onStatus?.call('error', e.toString());
    _onError?.call('ws: $e');
    _reconnect();
  }

  void _reconnect() {
    if (_disposed || _disconnecting) return;
    if (_reconnectAttempts >= _maxReconnect) {
      _onStatus?.call('failed', 'reconnect exhausted');
      _onError?.call('Max reconnect attempts reached');
      return;
    }
    _reconnectAttempts++;
    final delay = _reconnectAttempts; // 1s, 2s, 3s
    _onStatus?.call('reconnecting', 'retry in ${delay}s');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (_disposed || _disconnecting) return;
      connect();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disconnecting = true;
    _reconnectTimer?.cancel();
    clearCallbacks();
    _sub?.cancel();
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    _connected = false;
  }
}
