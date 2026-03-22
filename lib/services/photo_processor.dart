import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/models/burst_group.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/services/bird_clusterer.dart';
import 'package:ebird_generator/services/bird_detector.dart';
import 'package:ebird_generator/services/image_converter.dart';

/// Intermediate result from Phase 1 (detection).
class Phase1Result {
  final String processedPath;
  final ExifData exifData;
  final List<List<BirdCrop>> clusters;
  final bool isFallback;
  final img.Image? fallbackImg;

  Phase1Result({
    required this.processedPath,
    required this.exifData,
    required this.clusters,
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
  final BirdClusterer clusterer;

  const PhotoProcessor({
    required this.classifier,
    required this.detector,
    required this.clusterer,
  });

  /// Process [newPaths] organised into [bursts].
  ///
  /// Callbacks:
  /// - [onProgress] — called with a value in [0, 1].
  /// - [onProgressMessage] — human-readable status string.
  /// - [onObservationAdded] — called once per burst with the observations
  ///   from that burst so the UI can display them immediately.
  /// - [onFileCompleted] — called when a single file finishes phase 1 + 2.
  /// - [onError] — called with (filePath, error) when a file fails.
  Future<void> run({
    required List<String> newPaths,
    required List<List<String>> bursts,
    required List<String> burstIds,
    required void Function(double) onProgress,
    required void Function(String) onProgressMessage,
    required void Function(List<Observation>) onObservationAdded,
    required void Function(String filePath) onFileStarted,
    required void Function(String filePath) onFileCompleted,
    required void Function(String filePath, dynamic error) onError,
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
        for (final filePath in bursts[i]) {
          if (!newPathSet.contains(filePath)) continue;
          onFileStarted(filePath);
          try {
            final processedPath = await ImageConverter.convertToJpegIfNeeded(filePath);
            final exifData = await ExifService.extractExif(filePath);
            final detectedBirds = await detector.detectAndCrop(processedPath);

            if (detectedBirds.isEmpty) {
              final fallbackBytes = await File(processedPath).readAsBytes();
              final fallbackImg =
                  await compute(img.decodeImage, fallbackBytes);
              phase1Results[filePath] = Phase1Result(
                processedPath: processedPath,
                exifData: exifData,
                clusters: [],
                isFallback: true,
                fallbackImg: fallbackImg,
              );
            } else {
              phase1Results[filePath] = Phase1Result(
                processedPath: processedPath,
                exifData: exifData,
                clusters: clusterer.cluster(detectedBirds),
                isFallback: false,
              );
            }
          } catch (e) {
            debugPrint('Error in phase 1 for $filePath: $e');
          } finally {
            processedBytesPhase1 += File(filePath).lengthSync();
            final p1 = totalBytesPhase1 > 0
                ? processedBytesPhase1 / totalBytesPhase1
                : 1.0;
            final p2 =
                totalBursts > 0 ? completedBurstsPhase2 / totalBursts : 1.0;
            onProgress(p1 * 0.5 + p2 * 0.5);
          }
        }
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
          burstIdentifications +=
              res.isFallback ? (res.fallbackImg != null ? 1 : 0) : res.clusters.length;
        }
        totalIdentifications += burstIdentifications;
        onProgressMessage(
          'Classifying... ($completedIdentifications of $totalIdentifications birds)',
        );

        final Map<String, BurstGroup> burstGroupsBySpecies = {};

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
                final speciesList = await classifier.classifyFile(
                  res.processedPath,
                  latitude: res.exifData.latitude,
                  longitude: res.exifData.longitude,
                  photoDate: res.exifData.dateTime,
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
                }
                completedIdentifications++;
                if (completedIdentifications % 15 == 0) {
                  await classifier.unloadModel();
                }
                onProgressMessage(
                  'Classifying... ($completedIdentifications of $totalIdentifications birds)',
                );
              }
            } else {
              // Cluster-level classification
              final Map<String, Observation> photoObservations = {};

              for (int ci = 0; ci < res.clusters.length; ci++) {
                final clusterCrops = res.clusters[ci];
                final clusterBoxes =
                    clusterCrops.map((c) => c.box).toList();

                final speciesList = await classifier.classifyCluster(
                  res.processedPath,
                  boxes: clusterBoxes,
                  latitude: res.exifData.latitude,
                  longitude: res.exifData.longitude,
                  photoDate: res.exifData.dateTime,
                );
                // Empty list = model said this crop isn't a bird — skip it.
                if (speciesList.isEmpty) {
                  completedIdentifications++;
                  if (completedIdentifications % 15 == 0) {
                    await classifier.unloadModel();
                  }
                  onProgressMessage(
                    'Classifying... ($completedIdentifications of $totalIdentifications birds)',
                  );
                  continue;
                }

                final species = speciesList.first;

                if (photoObservations.containsKey(species)) {
                  photoObservations[species]!.count += clusterCrops.length;
                  photoObservations[species]!.boundingBoxes
                      .addAll(clusterBoxes);
                  photoObservations[species]!.boxesByImagePath
                      .putIfAbsent(filePath, () => [])
                      .addAll(clusterBoxes);
                } else {
                  final cropBytes = clusterCrops.first.croppedJpgBytes;
                  final tempDir = await Directory.systemTemp.createTemp();
                  final filename = p.basename(filePath);
                  final cropPath = '${tempDir.path}/cluster_${ci}_$filename';
                  await File(cropPath).writeAsBytes(cropBytes);

                  photoObservations[species] = Observation(
                    imagePath: filePath,
                    displayPath: cropPath,
                    fullImageDisplayPath: res.processedPath,
                    speciesName: species,
                    possibleSpecies: speciesList,
                    exifData: res.exifData,
                    count: clusterCrops.length,
                    boundingBoxes: clusterBoxes,
                  );
                }

                completedIdentifications++;
                if (completedIdentifications % 15 == 0) {
                  await classifier.unloadModel();
                }
                onProgressMessage(
                  'Classifying... ($completedIdentifications of $totalIdentifications birds)',
                );
              }

              for (final obs in photoObservations.values) {
                burstGroupsBySpecies
                    .putIfAbsent(obs.speciesName, BurstGroup.new)
                    .addObservation(obs);
              }
            }
          } catch (e) {
            onError(filePath, e);
          }

          onFileCompleted(filePath);
        } // end for filePath

        // Emit completed burst observations
        final newObs = <Observation>[];
        for (final bg in burstGroupsBySpecies.values) {
          if (bg.observations.isNotEmpty) {
            newObs.add(bg.toObservation(burstId: burstIds[i]));
          }
        }
        if (newObs.isNotEmpty) onObservationAdded(newObs);

        // Unload logic handled per-15 birds and at the end of the batch

        completedBurstsPhase2++;
        final p1 = totalBytesPhase1 > 0
            ? processedBytesPhase1 / totalBytesPhase1
            : 1.0;
        final p2 =
            totalBursts > 0 ? completedBurstsPhase2 / totalBursts : 1.0;
        onProgress(p1 * 0.5 + p2 * 0.5);
      } // end for burst

      // Unload after the entire selected batch of photos is processed
      await classifier.unloadModel();
    });

    await Future.wait([phase1Worker, phase2Worker]);
  }
}


