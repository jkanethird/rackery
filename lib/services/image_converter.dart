import 'dart:io';
import 'package:path_provider/path_provider.dart';

class ImageConverter {
  /// Converts an image (like HEIC) to a temporary JPEG file.
  /// Needs ImageMagick ('magick' or 'convert') or 'heif-convert' installed.
  static Future<String?> convertToJpegIfNeeded(String inputPath) async {
    final lowerPath = inputPath.toLowerCase();
    if (!lowerPath.endsWith('.heic') && !lowerPath.endsWith('.heif')) {
      return inputPath; // Return original if not HEIC
    }

    final tempDir = await getTemporaryDirectory();
    final filename = inputPath.split(Platform.pathSeparator).last;
    final tempPath = '${tempDir.path}/converted_$filename.jpg';

    try {
      // Try Python's pillow-heif first (Most robust, bypasses OS libheif bugs)
      final pythonCode = '''
import sys
from PIL import Image
from pillow_heif import register_heif_opener
register_heif_opener()
img = Image.open(sys.argv[1])
img.save(sys.argv[2])
''';
      var result = await Process.run('python3', [
        '-c',
        pythonCode,
        inputPath,
        tempPath,
      ]);
      if (result.exitCode == 0) return tempPath;
    } catch (_) {}

    try {
      // Try ImageMagick 'magick' command (v7+)
      var result = await Process.run('magick', [inputPath, tempPath]);
      if (result.exitCode == 0) return tempPath;
    } catch (_) {}

    try {
      // Try ImageMagick 'convert' command (v6)
      var result = await Process.run('convert', [inputPath, tempPath]);
      if (result.exitCode == 0) return tempPath;
    } catch (_) {}

    try {
      // Try 'heif-convert' from libheif-examples
      var result = await Process.run('heif-convert', [inputPath, tempPath]);
      if (result.exitCode == 0) return tempPath;
    } catch (_) {}

    throw Exception(
      'Failed to convert HEIC/HEIF file. Please ensure ImageMagick or libheif is installed on your system.',
    );
  }
}
