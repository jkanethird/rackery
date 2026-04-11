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

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:rackery/models/observation.dart';
import 'package:rackery/models/burst_group.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/services/bird_detector.dart';
import 'package:rackery/services/image_converter.dart';
import 'package:rackery/services/ebird_api_service.dart';

/// Drives the unified native pipeline for a batch of image files organised
/// into bursts.
///
/// The entire detect → classify flow runs in Rust. Dart only handles:
/// - File I/O / JPEG conversion
/// - EXIF extraction
/// - eBird geographic species mask (network call)
/// - Assembling Observations from pipeline results
class PhotoProcessor {
  final NativePipeline pipeline;

  const PhotoProcessor({required this.pipeline});

  /// Snapshot the current [burstGroupsBySpecies] state, emitting new species
  /// and updating already-emitted observations in-place.
  static void _emitBurstUpdates(
    Map<String, BurstGroup> burstGroupsBySpecies,
    Map<String, Observation> emittedObs,
    String burstId,
    void Function(List<Observation>) onObservationAdded,
    void Function() onObservationsChanged,
    void Function(Observation obs, Map<int, int> oldToNew)? onIndicesRemapped,
  ) {
    final List<Observation> newlyEmitted = [];
    bool existingUpdated = false;

    for (final entry in burstGroupsBySpecies.entries) {
      final species = entry.key;
      final bg = entry.value;
      if (bg.observations.isEmpty) continue;

      if (emittedObs.containsKey(species)) {
        // Update existing observation in-place from BurstGroup
        final existing = emittedObs[species]!;

        // Update fields.
        final updated = bg.toObservation(burstId: burstId);
        existing.count = updated.count;
        existing.sourceImages = updated.sourceImages;
        existing.boxesByImagePath = updated.boxesByImagePath;
        existing.boundingBoxes = updated.boundingBoxes;
        existing.possibleSpecies = updated.possibleSpecies;
        existing.individualNames = updated.individualNames;

        existingUpdated = true;
      } else {
        // New species — emit
        final obs = bg.toObservation(burstId: burstId);
        emittedObs[species] = obs;
        newlyEmitted.add(obs);
      }
    }

    if (newlyEmitted.isNotEmpty) onObservationAdded(newlyEmitted);
    if (existingUpdated) onObservationsChanged();
  }

  Future<void> run({
    required List<String> newPaths,
    required List<List<String>> bursts,
    required List<String> burstIds,
    required void Function(double) onProgress,
    required void Function(String) onProgressMessage,
    required void Function(List<Observation>) onObservationAdded,
    required void Function() onObservationsChanged,
    required void Function(String filePath) onFileStarted,
    required void Function(String filePath) onFileCompleted,
    required void Function(String filePath, dynamic error) onError,
    void Function(Observation obs, Map<int, int> oldToNew)? onIndicesRemapped,
  }) async {
    final newPathSet = newPaths.toSet();

    // Progress accounting
    int totalFiles = newPaths.length;
    int completedFiles = 0;

    onProgressMessage('Processing photos...');
    onProgress(0.0);

    final Map<String, PhotoProfile> photoProfiles = {};

    // Process bursts sequentially, files within burst sequentially
    // (pipeline is fully sequential in Rust due to Mutex<Session>)
    for (int i = 0; i < bursts.length; i++) {
      final burstFiles = bursts[i];
      final burstHasNew = burstFiles.any(newPathSet.contains);
      if (!burstHasNew) continue;

      final Map<String, BurstGroup> burstGroupsBySpecies = {};
      final Map<String, Observation> emittedObs = {};

      for (final filePath in burstFiles) {
        if (!newPathSet.contains(filePath)) continue;
        onFileStarted(filePath);

        try {
          // Pre-process: JPEG conversion + EXIF
          final t1 = Stopwatch()..start();
          final processedPath = await ImageConverter.convertToJpegIfNeeded(filePath);
          final jpegTime = t1.elapsed;
          final exifData = await ExifService.extractExif(filePath);

          // Fetch eBird geographic mask (Dart network call)
          Set<String>? allowedMask;
          if (exifData.latitude != null && exifData.longitude != null) {
            allowedMask = await EbirdApiService.getSpeciesMask(
              exifData.latitude!,
              exifData.longitude!,
              exifData.dateTime,
            );
          }

          // Run full native pipeline (detect + classify)
          final pipelineOutput = await pipeline.processPhoto(
            processedPath,
            allowedSpecies: allowedMask,
            onProgress: onProgressMessage,
          );

          photoProfiles[filePath] = PhotoProfile()
            ..jpegConvertTime = jpegTime
            ..detectionTime = pipelineOutput.detectionTime
            ..classificationTime = pipelineOutput.classificationTime;

          if (pipelineOutput.birds.isEmpty) {
            // Fallback: classify entire image
            onProgressMessage('Fallback classification for ${p.basename(filePath)}...');

            final fallbackSpecies = await pipeline.classifyFile(
              processedPath,
              allowedSpecies: allowedMask,
              isFallback: true,
            );

            if (fallbackSpecies.isNotEmpty) {
              final species = fallbackSpecies.first;

              burstGroupsBySpecies
                  .putIfAbsent(species, BurstGroup.new)
                  .addObservation(
                    Observation(
                      imagePath: filePath,
                      displayPath: processedPath,
                      fullImageDisplayPath: processedPath,
                      speciesName: species,
                      possibleSpecies: fallbackSpecies,
                      exifData: exifData,
                      count: 1,
                      boundingBoxes: [Rectangle<int>(0, 0, 0, 0)], // Full image
                    ),
                  );

              _emitBurstUpdates(
                burstGroupsBySpecies, emittedObs, burstIds[i],
                onObservationAdded, onObservationsChanged, onIndicesRemapped,
              );
            }
          } else {
            // Process each identified bird
            for (int ci = 0; ci < pipelineOutput.birds.length; ci++) {
              final bird = pipelineOutput.birds[ci];
              final species = bird.species;

              // Write crop file
              final bool isNewSpeciesInFile =
                  !burstGroupsBySpecies.containsKey(species) ||
                  !burstGroupsBySpecies[species]!.observations.any(
                    (o) => o.imagePath == filePath,
                  );

              String cropPath;
              if (isNewSpeciesInFile) {
                final tempDir = await Directory.systemTemp.createTemp();
                final filename = p.basename(filePath);
                cropPath = '${tempDir.path}/crop_${ci}_$filename';
                await File(cropPath).writeAsBytes(bird.cropJpgBytes);
              } else {
                cropPath = burstGroupsBySpecies[species]!.observations
                    .firstWhere((o) => o.imagePath == filePath)
                    .displayPath!;
              }

              burstGroupsBySpecies
                  .putIfAbsent(species, BurstGroup.new)
                  .addObservation(
                    Observation(
                      imagePath: filePath,
                      displayPath: cropPath,
                      fullImageDisplayPath: processedPath,
                      speciesName: species,
                      possibleSpecies: bird.possibleSpecies,
                      exifData: exifData,
                      count: 1,
                      boundingBoxes: [bird.box],
                    ),
                  );

              _emitBurstUpdates(
                burstGroupsBySpecies, emittedObs, burstIds[i],
                onObservationAdded, onObservationsChanged, onIndicesRemapped,
              );
            }
          }
        } catch (e) {
          onError(filePath, e);
        }

        completedFiles++;
        onProgress(completedFiles / totalFiles);
        onFileCompleted(filePath);
        photoProfiles[filePath]?.printProfile(filePath);
      }
    }
  }
}

class PhotoProfile {
  Duration jpegConvertTime = Duration.zero;
  Duration detectionTime = Duration.zero;
  Duration classificationTime = Duration.zero;

  Duration get totalTime =>
      jpegConvertTime + detectionTime + classificationTime;

  void printProfile(String filePath) {
    if (totalTime == Duration.zero) return;
    int totalMs = totalTime.inMilliseconds;
    if (totalMs == 0) totalMs = 1;

    double percent(Duration d) => (d.inMilliseconds / totalMs) * 100;

    debugPrint('--- Profile for $filePath ---');
    debugPrint(
      'Convert to JPEG: ${jpegConvertTime.inMilliseconds}ms (${percent(jpegConvertTime).toStringAsFixed(1)}%)',
    );
    debugPrint(
      'Detection: ${detectionTime.inMilliseconds}ms (${percent(detectionTime).toStringAsFixed(1)}%)',
    );
    debugPrint(
      'Classification: ${classificationTime.inMilliseconds}ms (${percent(classificationTime).toStringAsFixed(1)}%)',
    );
    debugPrint('Total Time: ${totalMs}ms');
    debugPrint('-----------------------------------');
  }
}
