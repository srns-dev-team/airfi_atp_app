import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/atp_stream_view.dart';

/// Landscape single-channel fullscreen player (live or playback).
class FullscreenScreen extends StatefulWidget {
  final String deviceId;
  final int channel;
  final bool live;
  final String? startTime;
  final String? endTime;
  final bool audioOn;

  const FullscreenScreen({
    super.key,
    required this.deviceId,
    required this.channel,
    required this.live,
    this.startTime,
    this.endTime,
    this.audioOn = true,
  });

  @override
  State<FullscreenScreen> createState() => _FullscreenScreenState();
}

class _FullscreenScreenState extends State<FullscreenScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: AtpStreamView(
            deviceId: widget.deviceId,
            channel: widget.channel,
            streamType: widget.live ? 1 : 0,
            live: widget.live,
            startTime: widget.startTime,
            endTime: widget.endTime,
            muted: !widget.audioOn,
            fit: BoxFit.contain,
          ),
        ),
        Positioned(
          left: 8,
          top: 8,
          child: SafeArea(
            child: IconButton.filledTonal(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ),
      ]),
    );
  }
}
