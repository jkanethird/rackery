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
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/services/burst_grouper.dart';
import 'package:rackery/src/rust/api/ingestion.dart' as rust;

const _kLastPickerDirKey = 'last_picker_directory';

/// Lightweight result from the file-picker phase (no heavy processing yet).
class PickerResult {
  final List<String> newPaths;
  final List<String> allFiles;

  PickerResult({required this.newPaths, required this.allFiles});
}

/// Per-file ingestion result, converted from Rust stream into Dart types.
class IngestedFile {
  final String path;
  final String processedPath;
  final ExifData exifData;
  final String? visualHash;
  final int fileSize;

  IngestedFile({
    required this.path,
    required this.processedPath,
    required this.exifData,
    this.visualHash,
    required this.fileSize,
  });
}

/// Full ingestion result after all files are processed and burst-grouped.
class IngestionResult {
  final List<String> newPaths;
  final List<String> allFiles;
  final List<List<String>> bursts;
  final Map<String, ExifData> exifData;
  final Map<String, String> visualHashes;

  IngestionResult({
    required this.newPaths,
    required this.allFiles,
    required this.bursts,
    required this.exifData,
    required this.visualHashes,
  });
}

class IngestionPipeline {
  /// Phase 1: Open file picker, deduplicate against already-selected files.
  /// Returns the raw path lists without doing any heavy processing.
  static Future<PickerResult?> pickFiles({
    required List<String> currentSelectedFiles,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final lastDir = prefs.getString(_kLastPickerDirKey);

    final result = await openFiles(
      initialDirectory: lastDir,
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Images',
          extensions: [
            'jpg',
            'jpeg',
            'png',
            'heic',
            'heif',
            'JPG',
            'JPEG',
            'PNG',
            'HEIC',
            'HEIF',
          ],
        ),
      ],
    );

    if (result.isEmpty) return null;

    final firstPath = result.first.path;
    await prefs.setString(_kLastPickerDirKey, File(firstPath).parent.path);

    final pickedPaths = result.map((f) => f.path).toSet();
    final newPaths = pickedPaths
        .difference(currentSelectedFiles.toSet())
        .toList();
    if (newPaths.isEmpty) return null;

    final allFiles = [...currentSelectedFiles, ...newPaths];
    return PickerResult(newPaths: newPaths, allFiles: allFiles);
  }

  /// Phase 2: Stream per-file ingestion results from Rust (EXIF, hash, HEIC
  /// conversion). Each [IngestedFile] is yielded as soon as its Rust
  /// processing completes—callers can start detection immediately.
  static Stream<IngestedFile> streamIngestion(List<String> paths) async* {
    final cacheDir = await getApplicationSupportDirectory();
    final heicCacheDir = p.join(cacheDir.path, 'heic_cache');

    final rustStream = rust.ingestFiles(
      paths: paths,
      heicCacheDir: heicCacheDir,
    );

    await for (final r in rustStream) {
      final exifData = ExifData(
        dateTime: r.exifDateMs != null
            ? DateTime.fromMillisecondsSinceEpoch(r.exifDateMs!)
            : null,
        latitude: r.latitude,
        longitude: r.longitude,
      );

      yield IngestedFile(
        path: r.path,
        processedPath: r.processedPath,
        exifData: exifData,
        visualHash: r.visualHash,
        fileSize: r.fileSize.toInt(),
      );
    }
  }

  /// Phase 3: Once all files are ingested, compute burst groups.
  /// This is nearly instant and must run after all EXIF+hash data is available.
  static IngestionResult buildBursts({
    required List<String> newPaths,
    required List<String> allFiles,
    required Map<String, ExifData> exifData,
    required Map<String, String> visualHashes,
    required BurstGrouper burstGrouper,
  }) {
    final allFileData = allFiles.map((path) {
      return {
        'path': path,
        'exif': exifData[path] ?? ExifData(),
        'visualHash': visualHashes[path],
      };
    }).toList();

    allFileData.sort((a, b) {
      final dateA = (a['exif'] as ExifData).dateTime;
      final dateB = (b['exif'] as ExifData).dateTime;
      if (dateA == null && dateB == null) return 0;
      if (dateA == null) return 1;
      if (dateB == null) return -1;
      return dateA.compareTo(dateB);
    });

    final bursts = burstGrouper.group(allFileData);
    final sortedAllFiles = bursts.expand((b) => b).toList();

    return IngestionResult(
      newPaths: newPaths,
      allFiles: sortedAllFiles,
      bursts: bursts,
      exifData: exifData,
      visualHashes: visualHashes,
    );
  }
}
