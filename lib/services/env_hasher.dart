import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class EnvHasher {
  /// Spawns a Python subprocess to rapidly calculate an Average Hash (64-bit boolean array
  /// mapped to a 16-character hex string) for every image in the provided list.
  /// Used for grouping photos that physically share the exact same environmental background.
  static Future<Map<String, String>> computeHashes(List<String> filePaths) async {
    if (filePaths.isEmpty) return {};

    final pythonCode = '''
import sys
import json
from PIL import Image

try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:
    pass

def ahash(img):
    img = img.resize((8, 8), Image.Resampling.LANCZOS).convert('L')
    pixels = list(img.getdata())
    avg = sum(pixels) / len(pixels)
    bits = "".join(['1' if p > avg else '0' for p in pixels])
    return hex(int(bits, 2))[2:].zfill(16)

results = {}
for path in sys.argv[1:]:
    try:
        img = Image.open(path)
        img.thumbnail((256, 256)) # Fast low-res decode if supported by codec
        results[path] = ahash(img)
    except Exception as e:
        results[path] = None

print(json.dumps(results))
''';

    try {
      final result = await Process.run('python3', [
        '-c',
        pythonCode,
        ...filePaths,
      ]);

      if (result.exitCode == 0) {
        final Map<String, dynamic> output = jsonDecode(result.stdout.toString().trim());
        final Map<String, String> finalHashes = {};
        for (final entry in output.entries) {
          if (entry.value != null && entry.value.toString().isNotEmpty) {
            finalHashes[entry.key] = entry.value.toString();
          }
        }
        return finalHashes;
      } else {
        debugPrint('EnvHasher Failed: \${result.stderr}');
      }
    } catch (e) {
      debugPrint('EnvHasher Exception: \$e');
    }

    return {};
  }
}
