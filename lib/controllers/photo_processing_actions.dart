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

part of 'checklist_controller.dart';

/// Photo selection and processing actions for [ChecklistController].
extension PhotoProcessingActions on ChecklistController {
  Future<void> selectAndProcessPhotos(BuildContext context) async {
    // ── Phase 1: File picker + dedup ──────────────────────────────────────
    final pickerResult = await IngestionPipeline.pickFiles(
      currentSelectedFiles: selectedFiles,
    );

    if (pickerResult == null) return;

    isProcessing = true;
    progress = 0.0;
    progressMessage = 'Preparing files...';
    batchStartTime = DateTime.now();
    batchElapsedTime = null;
    notify();

    selectedFiles = pickerResult.allFiles;
    processingFiles.addAll(pickerResult.newPaths);

    if (currentlyDisplayedImage == null && processingFiles.isNotEmpty) {
      currentlyDisplayedImage = processingFiles.first;
      notify();
    }

    // ── Phase 2: Stream ingestion from Rust ───────────────────────────────
    //
    // EXIF extraction, perceptual hashing, and HEIC→JPEG conversion all
    // happen in Rust via Rayon parallelism. Results stream back per-file.
    progressMessage = 'Ingesting photos (Rust)...';
    notify();

    final Map<String, FileIngestionData> ingestionData = {};

    await for (final file in IngestionPipeline.streamIngestion(
      pickerResult.newPaths,
    )) {
      imageExifData[file.path] = file.exifData;
      if (file.visualHash != null) {
        imageVisualHashes[file.path] = file.visualHash!;
      }

      ingestionData[file.path] = FileIngestionData(
        processedPath: file.processedPath,
        exifData: file.exifData,
      );
    }

    // ── Phase 3: Burst grouping (deferred until all files ingested) ──────
    progressMessage = 'Grouping bursts...';
    notify();

    final ingestionResult = IngestionPipeline.buildBursts(
      newPaths: pickerResult.newPaths,
      allFiles: selectedFiles,
      exifData: imageExifData,
      visualHashes: imageVisualHashes,
      burstGrouper: _burstGrouper,
    );

    selectedFiles = ingestionResult.allFiles;
    fileBursts = ingestionResult.bursts;

    final int sessionTime = DateTime.now().millisecondsSinceEpoch;
    final List<String> burstIds = List.generate(
      fileBursts.length,
      (i) => 'burst_${sessionTime}_$i',
    );

    for (int i = 0; i < fileBursts.length; i++) {
      final burstSet = fileBursts[i];
      final bId = burstIds[i];
      for (final obs in observations) {
        if (burstSet.contains(obs.imagePath)) {
          obs.burstId = bId;
        }
      }
    }

    notify();

    // ── Phase 4: Detection + Classification ──────────────────────────────
    final processor = PhotoProcessor(
      pipeline: _pipeline,
    );

    await processor.run(
      newPaths: pickerResult.newPaths,
      bursts: ingestionResult.bursts,
      burstIds: burstIds,
      ingestionData: ingestionData,
      onProgress: (value) {
        progress = value;
        notify();
      },
      onProgressMessage: (msg) {
        progressMessage = msg;
        notify();
      },
      onObservationAdded: (newObs) {
        observations.addAll(newObs);
        observationVersion++;
        notify();
      },
      onObservationsChanged: () {
        observationVersion++;
        notify();
      },
      onFileStarted: (filePath) {
        activeFiles.add(filePath);
        fileStopwatches.putIfAbsent(filePath, Stopwatch.new).start();
        notify();
      },
      onFileCompleted: (filePath) {
        processingFiles.remove(filePath);
        activeFiles.remove(filePath);
        final sw = fileStopwatches.remove(filePath);
        if (sw != null) {
          sw.stop();
          final extra = fileExtraDurations.remove(filePath) ?? Duration.zero;
          fileElapsedTimes[filePath] = sw.elapsed + extra;
        }
        notify();
      },
      onFileTimerPause: (filePath) {
        fileStopwatches[filePath]?.stop();
      },
      onFileTimerResume: (filePath) {
        fileStopwatches[filePath]?.start();
      },
      onFileTimerAdd: (filePath, extra) {
        fileExtraDurations[filePath] =
            (fileExtraDurations[filePath] ?? Duration.zero) + extra;
      },
      onError: (filePath, error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error processing $filePath: $error')),
          );
        }
      },
      onIndicesRemapped: (obs, oldToNew) {
        if (identical(obs, selectedObservation) &&
            selectedIndividualIndices.isNotEmpty) {
          final remapped = selectedIndividualIndices
              .map((i) => oldToNew[i])
              .whereType<int>()
              .toSet();
          if (remapped.isNotEmpty) {
            selectedIndividualIndices
              ..clear()
              ..addAll(remapped);
          }
          if (lastSelectedIndividualIndex != null) {
            lastSelectedIndividualIndex =
                oldToNew[lastSelectedIndividualIndex!];
          }
        }
      },
    );

    isProcessing = false;
    activeFiles.clear();
    if (batchStartTime != null) {
      batchElapsedTime = DateTime.now().difference(batchStartTime!);
      batchStartTime = null;
    }
    if (selectedObservation == null && observations.isNotEmpty) {
      selectedObservation = observations.first;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
      currentlyDisplayedImage = selectedObservation!.imagePath;
    }
    notify();
  }
}
