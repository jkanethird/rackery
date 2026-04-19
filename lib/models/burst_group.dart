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

import 'dart:math';
import 'package:rackery/models/observation.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/utils/name_generator.dart';

class BurstGroup {
  final List<Observation> observations = [];
  String dominantSpecies = "Unknown";
  int totalCount = 0;
  List<String> individualNames = [];

  // The very first observation sets the baseline EXIF data for the group
  ExifData? get baseExifData =>
      observations.isNotEmpty ? observations.first.exifData : null;

  void addObservation(Observation obs) {
    observations.add(obs);
    _recalculateDominantSpecies();
    _recalculateTotalCount();
  }

  void _recalculateTotalCount() {
    // Group observations by imagePath to find the total number of birds in each frame
    // This prevents undercounting when a single photo has multiple conflicting AI species predictions
    Map<String, int> birdsPerFrame = {};
    for (var obs in observations) {
      birdsPerFrame[obs.imagePath] =
          (birdsPerFrame[obs.imagePath] ?? 0) + obs.count;
    }

    int maxBirdsInSingleFrame = 0;
    for (var count in birdsPerFrame.values) {
      if (count > maxBirdsInSingleFrame) {
        maxBirdsInSingleFrame = count;
      }
    }

    totalCount = maxBirdsInSingleFrame;

    while (individualNames.length < totalCount) {
      individualNames.add(generatePronounceableName());
    }
    if (individualNames.length > totalCount) {
      individualNames.removeRange(totalCount, individualNames.length);
    }
  }

  void _recalculateDominantSpecies() {
    if (observations.isEmpty) return;

    Map<String, int> speciesCounts = {};
    for (var obs in observations) {
      speciesCounts[obs.speciesName] =
          (speciesCounts[obs.speciesName] ?? 0) + obs.count;
    }

    // Find the species name that occurred the most frequently across all frames/crops
    String mostFrequent = "Unknown";
    int highestCount = 0;

    speciesCounts.forEach((species, count) {
      if (count > highestCount && species != "Unknown") {
        highestCount = count;
        mostFrequent = species;
      }
    });

    dominantSpecies = mostFrequent;
  }

  Observation toObservation({String burstId = ""}) {
    if (observations.isEmpty) {
      throw Exception("Cannot convert empty BurstGroup");
    }

    // Start with the first observation as the base
    final base = observations.first;

    List<SourceImage> sourceImages = [];
    Map<String, List<Rectangle<int>>> boxesByImagePath = {};
    List<Rectangle<int>> boxes = [];
    List<String> possibleSpecies = [];

    for (var obs in observations) {
      for (final src in obs.sourceImages) {
        if (!sourceImages.any((s) => s.imagePath == src.imagePath)) {
          sourceImages.add(src);
        }
      }

      for (final entry in obs.boxesByImagePath.entries) {
        boxesByImagePath.putIfAbsent(entry.key, () => []).addAll(entry.value);
      }
      boxes.addAll(obs.boundingBoxes);
      for (final s in obs.possibleSpecies) {
        if (!possibleSpecies.contains(s)) possibleSpecies.add(s);
      }
    }

    // Sort each photo's boxes left-to-right so that local index 0 is always
    // the leftmost bird, index 1 the next, etc. — consistent across photos.
    for (final entry in boxesByImagePath.entries) {
      entry.value.sort((a, b) => a.left.compareTo(b.left));
    }

    return Observation(
      imagePath: base.imagePath,
      displayPath: base.displayPath,
      fullImageDisplayPath: base.fullImageDisplayPath,
      speciesName: dominantSpecies,
      possibleSpecies: possibleSpecies,
      exifData: base.exifData,
      count: totalCount,
      boundingBoxes: boxes,
      sourceImages: sourceImages,
      boxesByImagePath: boxesByImagePath,
      individualNames: List.from(individualNames),
      burstId: burstId,
    );
  }
}
