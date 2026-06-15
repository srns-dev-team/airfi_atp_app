import 'dart:io';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// Downloads a finished recording (S3 presigned URL) to a temp file with
/// progress, then saves it into the device Photos library. Used by the
/// Download button in Playback + Download Centre.
class ClipDownloader {
  /// Fetch [url] (resolved against apiBase if relative), reporting fractional
  /// progress [0..1] via [onProgress], then add the .mp4 to Photos.
  /// Returns the saved temp file path. Throws on HTTP / save failure.
  static Future<String> downloadToGallery({
    required String url,
    required String filename,
    void Function(double progress)? onProgress,
  }) async {
    final resolved = Config.resolveMediaUrl(url);
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(resolved));
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      final total = resp.contentLength ?? 0;

      final dir = await getTemporaryDirectory();
      final safe = filename.endsWith('.mp4') ? filename : '$filename.mp4';
      final path = '${dir.path}/$safe';
      final file = File(path);
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      onProgress?.call(1.0);

      // Save into Photos. NO album: saving to a named album needs FULL library
      // access (NSPhotoLibraryUsageDescription) and hard-crashes under the
      // add-only grant we request — camera roll only needs add-only.
      final hasAccess = await Gal.hasAccess(toAlbum: false);
      if (!hasAccess) {
        await Gal.requestAccess(toAlbum: false);
      }
      await Gal.putVideo(path);
      return path;
    } finally {
      client.close();
    }
  }
}
