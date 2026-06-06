/// Runtime config. Defaults to the ATP staging server; override at build time:
///   flutter run --dart-define=ATP_API=https://atp.airfi.in \
///               --dart-define=ATP_WS=wss://atp.airfi.in
class Config {
  static const String apiBase =
      String.fromEnvironment('ATP_API', defaultValue: 'https://atp.airfi.in');
  static const String wsBase =
      String.fromEnvironment('ATP_WS', defaultValue: 'wss://atp.airfi.in');

  /// Live/playback ATP WS URL. streamType: 1=sub (live default), 0=main.
  static String streamWsUrl({
    required String deviceId,
    required int channel,
    required int streamType,
    required bool live,
  }) {
    final suffix = streamType == 0 ? 'main' : 'sub';
    final mode = live ? 'live' : 'playback';
    return '$wsBase/atp/$mode/$deviceId/cam${channel}_$suffix';
  }

  /// Talkback WS URL (server relays G.711A both ways).
  static String talkbackWsUrl({required String deviceId, required int channel}) =>
      '$wsBase/ws/talkback?deviceId=$deviceId&channel=$channel';
}
