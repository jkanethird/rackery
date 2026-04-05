import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/services/burst_grouper.dart';
import 'package:rackery/services/env_hasher.dart';

const _kLastPickerDirKey = 'last_picker_directory';

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
  static Future<IngestionResult?> gatherFiles({
    required List<String> currentSelectedFiles,
    required Map<String, ExifData> currentExifData,
    required Map<String, String> currentVisualHashes,
    required BurstGrouper burstGrouper,
    void Function()? onStartProcessing,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final lastDir = prefs.getString(_kLastPickerDirKey);

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      initialDirectory: lastDir,
      allowedExtensions: [
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
    );

    if (result == null) return null;

    final firstPath = result.files.first.path;
    if (firstPath != null) {
      await prefs.setString(_kLastPickerDirKey, File(firstPath).parent.path);
    }

    final pickedPaths = result.files.map((f) => f.path!).toSet();
    final newPaths = pickedPaths
        .difference(currentSelectedFiles.toSet())
        .toList();
    if (newPaths.isEmpty) return null;

    if (onStartProcessing != null) onStartProcessing();

    newPaths.sort(
      (a, b) => File(a).lengthSync().compareTo(File(b).lengthSync()),
    );

    final Map<String, ExifData> updatedExifData = Map.of(currentExifData);
    for (final path in newPaths) {
      try {
        updatedExifData[path] = await ExifService.extractExif(path);
      } catch (_) {
        updatedExifData[path] = ExifData();
      }
    }

    final Map<String, String> newHashes = await EnvHasher.computeHashes(
      newPaths,
    );
    final Map<String, String> updatedVisualHashes = Map.of(currentVisualHashes)
      ..addAll(newHashes);

    final allFiles = [...currentSelectedFiles, ...newPaths];
    final allFileData = allFiles.map((path) {
      return {
        'path': path,
        'exif': updatedExifData[path] ?? ExifData(),
        'visualHash': updatedVisualHashes[path],
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
      exifData: updatedExifData,
      visualHashes: updatedVisualHashes,
    );
  }
}
