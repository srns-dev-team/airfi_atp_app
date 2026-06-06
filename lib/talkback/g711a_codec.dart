/// G.711A (a-law) codec — PCM16 <-> 8-bit a-law. Talkback wire format is
/// 8 kHz mono a-law both directions; the device + server relay speak it natively.
class G711ACodec {
  static const int _maxPcmValue = 32768;

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

  static int _pcm16ToAlaw8(int pcm16) {
    int sign = 0;
    int magnitude = pcm16;
    if (pcm16 < 0) {
      sign = 0x80;
      magnitude = -pcm16;
    }
    if (magnitude > (_maxPcmValue - 1)) magnitude = _maxPcmValue - 1;

    int exponent = 7;
    int stepSize = 256;
    for (int e = 7; e >= 0; e--) {
      if (magnitude < stepSize) {
        exponent = e;
        break;
      }
      stepSize *= 2;
    }
    int mantissa;
    if (exponent < 1) {
      mantissa = (magnitude >> 4) & 0x0F;
    } else {
      mantissa = (magnitude >> (exponent + 3)) & 0x0F;
    }
    return (sign | (exponent << 4) | mantissa) ^ 0x55;
  }

  static int _alaw8ToPcm16(int alawByte) {
    alawByte ^= 0x55;
    final sign = alawByte & 0x80;
    final exponent = (alawByte >> 4) & 0x07;
    final mantissa = alawByte & 0x0F;
    int pcm16 = (mantissa << 4) | 0x08;
    if (exponent > 0) {
      pcm16 <<= (exponent + 2);
    } else {
      pcm16 >>= 2;
    }
    if (sign == 0) pcm16 = -pcm16;
    if (pcm16 > 32767) pcm16 = 32767;
    if (pcm16 < -32768) pcm16 = -32768;
    return pcm16;
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
