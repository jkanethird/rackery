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
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:rackery/models/observation.dart';
import 'package:rackery/models/burst_group.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/services/bird_classifier.dart';
import 'package:rackery/services/bird_detector.dart';
import 'package:rackery/services/image_converter.dart';
import 'package:rackery/services/ebird_api_service.dart';

/// Intermediate result from Phase 1 (detection).
class Phase1Result {
  final String processedPath;
  final ExifData exifData;
  final List<BirdCrop> crops;
  final bool isFallback;
  final img.Image? fallbackImg;

  Phase1Result({
    required this.processedPath,
    required this.exifData,
    required this.crops,
    required this.isFallback,
    this.fallbackImg,
  });
}

/// Drives the two-phase detection + classification pipeline for a batch of
/// image files organised into bursts.
///
/// Emits progress and individual [Observation] results via callbacks so the
/// UI can update incrementally without coupling to the processing logic.
class PhotoProcessor {
  final BirdClassifier classifier;
  final BirdDetector detector;

  const PhotoProcessor({
    required this.classifier,
    required this.detector,
  });

  /// Process [newPaths] organised into [bursts].
  ///
  /// Callbacks:
  /// - [onProgress] — called with a value in [0, 1].
  /// - [onProgressMessage] — human-readable status string.
  /// - [onObservationAdded] — called with new observations as birds are
  ///   identified so the UI can display them immediately.
  /// - [onObservationsChanged] — called when existing observations are
  ///   updated in-place (e.g. count/individuals from subsequent burst photos).
  /// - [onFileCompleted] — called when a single file finishes phase 1 + 2.
  /// - [onError] — called with (filePath, error) when a file fails.

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
    int totalBytesPhase1 = 0;
    for (final p in newPaths) {
      totalBytesPhase1 += File(p).lengthSync();
    }
    int processedBytesPhase1 = 0;
    final int totalBursts = bursts.length;
    int completedBurstsPhase2 = 0;
    int totalIdentifications = 0;
    int completedIdentifications = 0;

    onProgressMessage('Detecting & Classifying...');
    onProgress(0.0);

    final Map<String, Phase1Result> phase1Results = {};
    final List<Completer<void>> burstCompleters = List.generate(
      bursts.length,
      (_) => Completer<void>(),
    );

    // ── Phase 1: Detection (sequential across bursts, parallel within burst) ──
    final Future<void> phase1Worker = Future(() async {
      for (int i = 0; i < bursts.length; i++) {
        final burstJobs = bursts[i].map((filePath) async {
          if (!newPathSet.contains(filePath)) return null;
          onFileStarted(filePath);
          try {
            final processedPath = await ImageConverter.convertToJpegIfNeeded(
              filePath,
            );
            final exifData = await ExifService.extractExif(filePath);
            return {'f': filePath, 'p': processedPath, 'e': exifData};
          } catch (e) {
            debugPrint('Error decoding $filePath: $e');
            return null;
          }
        });
        
        final prepped = await Future.wait(burstJobs);
        
        final detectionJobs = prepped.map((item) async {
          if (item == null) return;
          final filePath = item['f'] as String;
          final processedPath = item['p'] as String;
          final exifData = item['e'] as ExifData;
          
          try {
             final detectedBirds = await detector.detectAndCrop(processedPath);
             if (detectedBirds.isEmpty) {
               final fallbackBytes = await File(processedPath).readAsBytes();
               final fallbackImg = await compute(img.decodeImage, fallbackBytes);
               phase1Results[filePath] = Phase1Result(
                 processedPath: processedPath,
                 exifData: exifData,
                 crops: [],
                 isFallback: true,
                 fallbackImg: fallbackImg,
               );
             } else {
               phase1Results[filePath] = Phase1Result(
                 processedPath: processedPath,
                 exifData: exifData,
                 crops: detectedBirds,
                 isFallback: false,
               );
             }
          } catch (e) {
             debugPrint('Error in phase 1 detection for $filePath: $e');
          } finally { 
            processedBytesPhase1 += File(filePath).lengthSync();
            final p1 = totalBytesPhase1 > 0
                ? processedBytesPhase1 / totalBytesPhase1
                : 1.0;
            final p2 = totalBursts > 0
                ? completedBurstsPhase2 / totalBursts
                : 1.0;
            onProgress(p1 * 0.5 + p2 * 0.5);
          }
        });

        await Future.wait(detectionJobs);
        burstCompleters[i].complete();
      }
    });

    // ── Phase 2: Classification (waits for each burst's phase-1 to finish) ──
    final Future<void> phase2Worker = Future(() async {
      for (int i = 0; i < bursts.length; i++) {
        await burstCompleters[i].future;

        final burstFiles = bursts[i];
        final burstHasNew = burstFiles.any(newPathSet.contains);
        if (!burstHasNew) {
          completedBurstsPhase2++;
          continue;
        }

        // Count total identifications in this burst up front for progress display
        int burstIdentifications = 0;
        for (final filePath in burstFiles) {
          if (!newPathSet.contains(filePath)) continue;
          final res = phase1Results[filePath];
          if (res == null) continue;
          burstIdentifications += res.isFallback
              ? (res.fallbackImg != null ? 1 : 0)
              : res.crops.length;
        }
        totalIdentifications += burstIdentifications;
        onProgressMessage(
          'Classifying... ($completedIdentifications of $totalIdentifications birds)',
        );

        final Map<String, BurstGroup> burstGroupsBySpecies = {};
        // Track already-emitted observations so we can update them in-place
        final Map<String, Observation> emittedObs = {};

        for (final filePath in burstFiles) {
          if (!newPathSet.contains(filePath)) continue;
          onFileStarted(filePath);

          final res = phase1Results[filePath];
          if (res == null) {
            onFileCompleted(filePath);
            continue;
          }

          try {
            if (res.isFallback) {
              if (res.fallbackImg != null) {
                Set<String>? allowedMask;
                if (res.exifData.latitude != null &&
                    res.exifData.longitude != null) {
                  allowedMask = await EbirdApiService.getSpeciesMask(
                    res.exifData.latitude!,
                    res.exifData.longitude!,
                    res.exifData.dateTime,
                  );
                }

                final speciesList = await classifier.classifyFile(
                  res.processedPath,
                  latitude: res.exifData.latitude,
                  longitude: res.exifData.longitude,
                  photoDate: res.exifData.dateTime,
                  allowNoBird: true,
                  isFallback: true,
                  allowedSpeciesKeys: allowedMask,
                );
                // Empty list = model said no bird is present — skip this photo.
                if (speciesList.isNotEmpty) {
                  final species = speciesList.first;
                  final fullImageBox = Rectangle<int>(
                    0,
                    0,
                    res.fallbackImg!.width,
                    res.fallbackImg!.height,
                  );
                  burstGroupsBySpecies
                      .putIfAbsent(species, BurstGroup.new)
                      .addObservation(
                        Observation(
                          imagePath: filePath,
                          displayPath: res.processedPath,
                          fullImageDisplayPath: res.processedPath,
                          speciesName: species,
                          possibleSpecies: speciesList,
                          exifData: res.exifData,
                          count: 1,
                          boundingBoxes: [fullImageBox],
                        ),
                      );

                  // Emit / update immediately
                  _emitBurstUpdates(
                    burstGroupsBySpecies,
                    emittedObs,
                    burstIds[i],
                    onObservationAdded,
                    onObservationsChanged,
                    onIndicesRemapped,
                  );
                }
                completedIdentifications++;
                onProgressMessage(
                  'Classifying... ($completedIdentifications of $totalIdentifications birds)',
                );
              }
            } else {
              // Individual crop-level classification mapped concurrently (limited by Classifier Session Pool)
              final cropJobs = res.crops.asMap().entries.map((entry) async {
                final ci = entry.key;
                final crop = entry.value;
                final box = crop.box;

                Set<String>? allowedMask;
                if (res.exifData.latitude != null &&
                    res.exifData.longitude != null) {
                  allowedMask = await EbirdApiService.getSpeciesMask(
                    res.exifData.latitude!,
                    res.exifData.longitude!,
                    res.exifData.dateTime,
                  );
                }

                final speciesList = await classifier.classifyCrop(
                  res.processedPath,
                  box: box,
                  latitude: res.exifData.latitude,
                  longitude: res.exifData.longitude,
                  photoDate: res.exifData.dateTime,
                  allowNoBird: true,
                  allowedSpeciesKeys: allowedMask,
                  cropBytes: crop.croppedJpgBytes,
                );
                // Empty list = model said this crop isn't a bird — skip it.
                if (speciesList.isEmpty) {
                  completedIdentifications++;
                  onProgressMessage(
                    'Classifying... ($completedIdentifications of $totalIdentifications birds)',
                  );
                  return;
                }

                final species = speciesList.first;

                // Write crop file only for the first instance of this species
                // in this file (subsequent instances reuse the existing crop).
                final bool isNewSpeciesInFile =
                    !burstGroupsBySpecies.containsKey(species) ||
                    !burstGroupsBySpecies[species]!.observations.any(
                      (o) => o.imagePath == filePath,
                    );

                String cropPath;
                if (isNewSpeciesInFile) {
                  final cropBytes = crop.croppedJpgBytes;
                  final tempDir = await Directory.systemTemp.createTemp();
                  final filename = p.basename(filePath);
                  cropPath = '${tempDir.path}/crop_${ci}_$filename';
                  await File(cropPath).writeAsBytes(cropBytes);
                } else {
                  // Reuse the first observation's crop path for this species
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
                        fullImageDisplayPath: res.processedPath,
                        speciesName: species,
                        possibleSpecies: speciesList,
                        exifData: res.exifData,
                        count: 1,
                        boundingBoxes: [box],
                      ),
                    );

                // Emit / update immediately after each individual
                _emitBurstUpdates(
                  burstGroupsBySpecies,
                  emittedObs,
                  burstIds[i],
                  onObservationAdded,
                  onObservationsChanged,
                  onIndicesRemapped,
                );

                completedIdentifications++;
                onProgressMessage(
                  'Classifying... ($completedIdentifications of $totalIdentifications birds)',
                );
              });
              
              await Future.wait(cropJobs);
            }
          } catch (e) {
            onError(filePath, e);
          }

          onFileCompleted(filePath);
        } // end for filePath

        // Unload logic handled per-15 birds and at the end of the batch

        completedBurstsPhase2++;
        final p1 = totalBytesPhase1 > 0
            ? processedBytesPhase1 / totalBytesPhase1
            : 1.0;
        final p2 = totalBursts > 0 ? completedBurstsPhase2 / totalBursts : 1.0;
        onProgress(p1 * 0.5 + p2 * 0.5);
      } // end for burst

      // Unload after the entire selected batch of photos is processed
    });

    await Future.wait([phase1Worker, phase2Worker]);
  }
}
