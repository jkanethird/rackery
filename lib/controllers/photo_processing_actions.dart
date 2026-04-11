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
    final result = await IngestionPipeline.gatherFiles(
      currentSelectedFiles: selectedFiles,
      currentExifData: imageExifData,
      currentVisualHashes: imageVisualHashes,
      burstGrouper: _burstGrouper,
      onStartProcessing: () {
        isProcessing = true;
        progress = 0.0;
        progressMessage = 'Preparing files...';
        batchStartTime = DateTime.now();
        batchElapsedTime = null;
        notify();
      },
    );

    if (result == null) return;

    selectedFiles = result.allFiles;
    processingFiles.addAll(result.newPaths);
    fileBursts = result.bursts;
    imageExifData.addAll(result.exifData);
    imageVisualHashes.addAll(result.visualHashes);

    if (currentlyDisplayedImage == null && processingFiles.isNotEmpty) {
      currentlyDisplayedImage = processingFiles.first;
      notify();
    }

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

    final processor = PhotoProcessor(
      classifier: _classifier,
      detector: _detector,
    );

    await processor.run(
      newPaths: result.newPaths,
      bursts: result.bursts,
      burstIds: burstIds,
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
        fileStartTimes.putIfAbsent(filePath, () => DateTime.now());
        notify();
      },
      onFileCompleted: (filePath) {
        processingFiles.remove(filePath);
        activeFiles.remove(filePath);
        final startTime = fileStartTimes.remove(filePath);
        if (startTime != null) {
          fileElapsedTimes[filePath] = DateTime.now().difference(startTime);
        }
        notify();
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
