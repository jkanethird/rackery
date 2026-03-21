import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'ffi_heif.dart';
import 'package:path/path.dart' as p;

class EnvHasher {
  static Future<Map<String, String>> computeHashes(List<String> imagePaths) async {
    final Map<String, String> hashes = {};
    if (imagePaths.isEmpty) return hashes;

    try {
      final results = await compute(_hashImagesWrapper, imagePaths);
      hashes.addAll(results);
    } catch (e) {
      debugPrint("EnvHasher FFI Exception: $e");
    }

    return hashes;
  }
}

Future<Map<String, String>> _hashImagesWrapper(List<String> paths) async {
  final Map<String, String> results = {};
  
  // Instance is lazy loaded per isolate, safely
  LibHeif? libHeif;

  for (final path in paths) {
    try {
      img.Image image;
      final ext = p.extension(path).toLowerCase();
      
      if (ext == '.heic' || ext == '.heif') {
        libHeif ??= LibHeif();
        final heicData = libHeif.decodeHeic(path);
        image = img.Image.fromBytes(
          width: heicData.width,
          height: heicData.height,
          bytes: heicData.pixels.buffer,
          rowStride: heicData.stride,
          numChannels: 3,
          order: img.ChannelOrder.rgb,
        );
      } else {
        final bytes = await File(path).readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded == null) throw Exception("Could not decode image");
        image = decoded;
      }
      
      results[path] = _calculateAHash(image);
      
    } catch (e) {
      debugPrint("EnvHasher error hashing $path: $e");
    }
  }
  
  return results;
}

String _calculateAHash(img.Image image) {
  // 1. Resize to 8x8 using average interpolation
  final small = img.copyResize(image, width: 8, height: 8, interpolation: img.Interpolation.average);
  
  // 2. Grayscale and collect luminances
  final luminances = <int>[];
  var totalLuminance = 0;
  
  for (final p in small) {
    // Perceptual grayscale
    final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
    luminances.add(lum);
    totalLuminance += lum;
  }
  
  // 3. Average
  final avg = totalLuminance / luminances.length;
  
  // 4. Compute 64-bit hash
  BigInt hash = BigInt.zero;
  for (int i = 0; i < luminances.length; i++) {
    if (luminances[i] >= avg) {
      hash |= (BigInt.one << (63 - i));
    }
  }
  
  return hash.toRadixString(16).padLeft(16, '0');
}
