/// G.711A (a-law) codec — PCM16 <-> 8-bit a-law. Talkback wire format is
/// 8 kHz mono a-law both directions; the device + server relay speak it natively.
class G711ACodec {
  /// PCM16 (little-endian byte list) -> a-law bytes.
  static List<int> encodePcmToAlaw(List<int> pcmData) {
    final result = <int>[];
    for (int i = 0; i + 1 < pcmData.length; i += 2) {
      int sample = (pcmData[i + 1] << 8) | pcmData[i];
      if (sample > 32767) sample -= 65536;
      result.add(_pcm16ToAlaw8(sample));
    }
    return result;
  }

  /// a-law bytes -> PCM16 (little-endian byte list).
  static List<int> decodeAlawToPcm(List<int> alawData) {
    final result = <int>[];
    for (final b in alawData) {
      final pcm16 = _alaw8ToPcm16(b);
      result.add(pcm16 & 0xFF);
      result.add((pcm16 >> 8) & 0xFF);
    }
    return result;
  }

  // Standard ITU-T G.711 A-law compression. Byte-exact to ffmpeg `pcm_alaw`
  // (the server's intercom decoder), verified against ffmpeg ground truth.
  // The previous loop assigned the exponent INVERTED (small magnitude → exp 7
  // instead of 0), so ffmpeg decoded every uplink sample as garbage → noisy
  // talkback. Do not "simplify" the exponent search.
  static int _pcm16ToAlaw8(int pcm16) {
    final int sign = pcm16 < 0 ? 0x00 : 0x80;
    int magnitude = pcm16 < 0 ? -pcm16 : pcm16;
    if (magnitude > 32635) magnitude = 32635; // A-law clip point

    int alaw;
    if (magnitude >= 256) {
      int exponent = 7;
      int expMask = 0x4000;
      while ((magnitude & expMask) == 0 && exponent > 0) {
        exponent--;
        expMask >>= 1;
      }
      final int mantissa = (magnitude >> (exponent + 3)) & 0x0F;
      alaw = (exponent << 4) | mantissa;
    } else {
      alaw = magnitude >> 4;
    }
    return alaw ^ (sign ^ 0x55);
  }

  // Standard ITU-T G.711 A-law expansion. Byte-exact to ffmpeg `pcm_alaw`
  // decode (verified). Previous version mis-scaled the mantissa/exponent
  // (242/256 codes wrong) → noisy downlink. Sign bit: MSB set = positive.
  static int _alaw8ToPcm16(int alawByte) {
    final int a = alawByte ^ 0x55;
    int t = (a & 0x0F) << 4;
    final int seg = (a & 0x70) >> 4;
    if (seg == 0) {
      t += 8;
    } else if (seg == 1) {
      t += 0x108;
    } else {
      t = (t + 0x108) << (seg - 1);
    }
    return (a & 0x80) != 0 ? t : -t;
  }

  static const int sampleRate = 8000;
  static const int channels = 1;
  static const int bitDepth = 8;

  /// app -> device uplink chunk size (server contract: 1024-byte a-law frames).
  static const int uplinkChunkSize = 1024;
}

/// Opaque WS status message. Server (commit d21da04) sends `{"s":"R"}`-style
/// single-letter codes; older servers send `{"status","msg"}`. Both handled.
class TalkbackStatusMessage {
  final String status; // connecting / connected / reconnecting / error / ended
  final String message;

  const TalkbackStatusMessage({required this.status, required this.message});

  factory TalkbackStatusMessage.fromJson(Map<String, dynamic> json) {
    final code = json['s'] as String?;
    final status = code != null
        ? _statusFromCode(code)
        : (json['status'] as String? ?? 'unknown');
    return TalkbackStatusMessage(
      status: status,
      message: (json['msg'] as String?) ?? (json['message'] as String?) ?? '',
    );
  }

  static String _statusFromCode(String c) {
    switch (c) {
      case 'P':
        return 'connecting';
      case 'R':
        return 'connected';
      case 'W':
        return 'reconnecting';
      case 'X':
        return 'error';
      case 'E':
        return 'ended';
      default:
        return 'unknown';
    }
  }
}
