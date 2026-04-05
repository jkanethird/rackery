// Rackery - Automatic bird identification and eBird checklist generation.
// Copyright (C) 2026 Joseph J. Kane III
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'ffi_heif.dart';

class ImageConverter {
  static Future<String> convertToJpegIfNeeded(String imagePath) async {
    final extension = p.extension(imagePath).toLowerCase();

    // If it's already a JPEG/PNG, just return the original path
    if (extension == '.jpg' || extension == '.jpeg' || extension == '.png') {
      return imagePath;
    }

    // Try to convert HEIC/HEIF
    if (extension == '.heic' || extension == '.heif') {
      final cacheDir = await getApplicationSupportDirectory();
      final heicCacheDir = Directory(p.join(cacheDir.path, 'heic_cache'));
      if (!await heicCacheDir.exists()) {
        await heicCacheDir.create(recursive: true);
      }

      final fileNameWithoutExt = p.basenameWithoutExtension(imagePath);
      final cachedJpgPath = p.join(
        heicCacheDir.path,
        '$fileNameWithoutExt.jpg',
      );

      if (await File(cachedJpgPath).exists()) {
        return cachedJpgPath;
      }

      try {
        // Use Native FFI
        return await compute(
          _processHeicWrapper,
          _HeicJob(imagePath, cachedJpgPath),
        );
      } catch (e) {
        debugPrint('ImageConverter FFI exception for $imagePath: $e');
        // fallback to returning original if we absolutely can't decode it
        return imagePath;
      }
    }

    return imagePath;
  }

  static Future<String> getDisplayPath(String imagePath) async {
    return convertToJpegIfNeeded(imagePath);
  }
}

class _HeicJob {
  final String sourcePath;
  final String destPath;
  _HeicJob(this.sourcePath, this.destPath);
}

Future<String> _processHeicWrapper(_HeicJob job) async {
  final libHeif = LibHeif(); // singleton isolated safely in compute spawn
  final heicData = libHeif.decodeHeic(job.sourcePath);

  final image = img.Image.fromBytes(
    width: heicData.width,
    height: heicData.height,
    bytes: heicData.pixels.buffer,
    rowStride: heicData.stride,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );

  final jpgBytes = img.encodeJpg(image, quality: 90);
  await File(job.destPath).writeAsBytes(jpgBytes);
  return job.destPath;
}
