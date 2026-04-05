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

/// Manual bounding-box detection actions for [ChecklistController].
extension ManualDetectionActions on ChecklistController {
  void addManualIndividual(String imagePath, Rectangle<int> box) {
    // Look up display path and burst ID from a sibling observation
    final sibling = observations.cast<Observation?>().firstWhere(
      (o) =>
          o!.imagePath == imagePath ||
          o.sourceImages.any((src) => src.imagePath == imagePath),
      orElse: () => null,
    );
    final fullDisplayPath =
        sibling?.fullImageDisplayPath ??
        sibling?.sourceImages
            .cast<SourceImage?>()
            .firstWhere((s) => s!.imagePath == imagePath, orElse: () => null)
            ?.fullImageDisplayPath;

    final newObs = Observation(
      imagePath: imagePath,
      speciesName: 'Identifying...',
      displayPath: sibling?.displayPath, // temporary until crop is generated
      exifData: imageExifData[imagePath] ?? ExifData(),
      count: 1,
      boundingBoxes: [box],
      boxesByImagePath: {
        imagePath: [box],
      },
      fullImageDisplayPath: fullDisplayPath,
    );

    if (sibling != null) {
      newObs.burstId = sibling.burstId;
      final lastIndex = observations.lastIndexOf(sibling);
      observations.insert(lastIndex + 1, newObs);
    } else {
      observations.add(newObs);
    }
    selectedObservation = newObs;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;

    observationVersion++;
    notify();

    _classifyManualIndividual(newObs, box);
    _generateCropForManualBox(newObs, box);
  }

  Future<void> _generateCropForManualBox(
    Observation obs,
    Rectangle<int> box,
  ) async {
    try {
      String sourceImagePath = obs.imagePath;
      if (sourceImagePath.toLowerCase().endsWith('.heic')) {
        final resolved = await getDisplayPath(sourceImagePath);
        if (resolved != null) sourceImagePath = resolved;
      }

      final bytes = await File(sourceImagePath).readAsBytes();
      final fullImage = await compute(img.decodeImage, bytes);
      if (fullImage == null) return;

      // 50% padding around the box — matches annotateAndEncode's single-bird crop
      final padX = (box.width * 0.5).round();
      final padY = (box.height * 0.5).round();

      final x = (box.left - padX).clamp(0, fullImage.width - 1);
      final y = (box.top - padY).clamp(0, fullImage.height - 1);
      final w = (box.width + padX * 2).clamp(1, fullImage.width - x);
      final h = (box.height + padY * 2).clamp(1, fullImage.height - y);

      final cropped = img.copyCrop(fullImage, x: x, y: y, width: w, height: h);
      final jpgBytes = img.encodeJpg(cropped, quality: 85);

      final tempDir = await Directory.systemTemp.createTemp();
      final cropPath =
          '${tempDir.path}/manual_crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(cropPath).writeAsBytes(jpgBytes);

      if (observations.contains(obs)) {
        obs.displayPath = cropPath;
        observationVersion++;
        notify();
      }
    } catch (e) {
      debugPrint('Error generating manual crop: $e');
    }
  }

  Future<void> _classifyManualIndividual(
    Observation obs,
    Rectangle<int> box,
  ) async {
    // Resolve HEIC to a converted JPEG so the classifier can decode it
    String classifyPath = obs.imagePath;
    if (classifyPath.toLowerCase().endsWith('.heic')) {
      final resolved = await getDisplayPath(classifyPath);
      if (resolved != null) classifyPath = resolved;
    }

    Set<String>? allowedMask;
    if (obs.exifData.latitude != null && obs.exifData.longitude != null) {
      allowedMask = await EbirdApiService.getSpeciesMask(
        obs.exifData.latitude!,
        obs.exifData.longitude!,
        obs.exifData.dateTime,
      );
    }

    final suggestions = await _classifier.classifyFile(
      classifyPath,
      box: box,
      latitude: obs.exifData.latitude,
      longitude: obs.exifData.longitude,
      photoDate: obs.exifData.dateTime,
      allowedSpeciesKeys: allowedMask,
    );

    // Only update if the observation wasn't deleted by the user while classifying
    if (observations.contains(obs)) {
      if (suggestions.isNotEmpty) {
        obs.speciesName = suggestions.first;
        obs.possibleSpecies = suggestions;
      } else {
        obs.speciesName = 'Unknown Bird';
      }

      // Auto-merge into an existing observation of the same species in the same burst
      final fromIdx = observations.indexOf(obs);
      final mergeTarget = observations.indexWhere(
        (o) =>
            o != obs &&
            o.burstId == obs.burstId &&
            o.burstId.isNotEmpty &&
            o.speciesName == obs.speciesName,
      );
      if (mergeTarget >= 0) {
        final wasSelected = selectedObservation == obs;
        ObservationOperations.mergeObservations(
          observations,
          fromIdx,
          mergeTarget,
        );
        if (wasSelected) {
          final adjustedTarget = fromIdx < mergeTarget
              ? mergeTarget - 1
              : mergeTarget;
          selectedObservation = observations[adjustedTarget];
          selectedIndividualIndices.clear();
          lastSelectedIndividualIndex = null;
        }
      }

      observationVersion++;
      notify();
    }
  }
}
