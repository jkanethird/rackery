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
import 'package:rackery/utils/name_generator.dart';

class ObservationOperations {
  static void mergeObservations(
    List<Observation> observations,
    int fromIdx,
    int intoIdx,
  ) {
    if (fromIdx == intoIdx) return;
    final from = observations[fromIdx];
    final into = observations[intoIdx];

    // Merge source images first
    final existingPaths = into.sourceImages.map((s) => s.imagePath).toSet();
    for (final src in from.sourceImages) {
      if (existingPaths.add(src.imagePath)) into.sourceImages.add(src);
    }

    // Collect each individual from 'from' with its local index and name.
    // In the local-per-photo model, individualNames[li] is the li-th
    // leftmost bird; the box at local index li in each photo represents
    // that individual.
    final fromIndividuals = <({int localIndex, String name,
        Map<String, Rectangle<int>> boxByPhoto})>[];
    for (int li = 0; li < from.count; li++) {
      final name = li < from.individualNames.length
          ? from.individualNames[li]
          : generatePronounceableName();
      final Map<String, Rectangle<int>> boxByPhoto = {};
      for (final src in from.sourceImages) {
        final boxes = List<Rectangle<int>>.from(
          from.boxesByImagePath[src.imagePath] ?? [],
        )..sort((a, b) => a.left.compareTo(b.left));
        if (li < boxes.length) {
          boxByPhoto[src.imagePath] = boxes[li];
        }
      }
      fromIndividuals.add((
        localIndex: li,
        name: name,
        boxByPhoto: boxByPhoto,
      ));
    }

    // Merge boxes into the target
    into.count += from.count;
    into.boundingBoxes.addAll(from.boundingBoxes);
    for (final entry in from.boxesByImagePath.entries) {
      into.boxesByImagePath
          .putIfAbsent(entry.key, () => [])
          .addAll(entry.value);
    }

    // Insert each individual's name at its new local index position.
    // After adding boxes, re-sort each photo's boxes and find where
    // the individual's box ended up.
    for (final ind in fromIndividuals) {
      _insertNameAtLocalIndex(into, ind.boxByPhoto, ind.name);
    }

    for (final s in from.possibleSpecies) {
      if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
    }
    observations.removeAt(fromIdx);
  }

  /// Find where a box (identified by its per-photo entries) ends up in
  /// the target observation's sorted local index, and insert the name
  /// at that position.
  static void _insertNameAtLocalIndex(
    Observation obs,
    Map<String, Rectangle<int>> boxByPhoto,
    String name,
  ) {
    // Find the local index of the box in the first photo that has it.
    // In the local-per-photo model, this local index IS the individual
    // index and should be the same across all photos.
    int insertAt = obs.individualNames.length;
    for (final entry in boxByPhoto.entries) {
      final boxes = List<Rectangle<int>>.from(
        obs.boxesByImagePath[entry.key] ?? [],
      )..sort((a, b) => a.left.compareTo(b.left));
      final li = boxes.indexOf(entry.value);
      if (li >= 0) {
        insertAt = li;
        break;
      }
    }
    if (insertAt > obs.individualNames.length) {
      insertAt = obs.individualNames.length;
    }
    obs.individualNames.insert(insertAt, name);
  }

  static void addIndividual(
    Observation obs,
    String imagePath,
    Rectangle<int> box,
  ) {
    obs.count++;
    obs.boundingBoxes.add(box);
    obs.boxesByImagePath.putIfAbsent(imagePath, () => []).add(box);
    if (!obs.sourceImages.any((s) => s.imagePath == imagePath)) {
      obs.sourceImages.add((
        imagePath: imagePath,
        fullImageDisplayPath: imagePath,
      ));
    }
    _insertNameAtLocalIndex(
      obs,
      {imagePath: box},
      generatePronounceableName(),
    );
  }

  static void mergeIndividuals(
    List<Observation> observations,
    int fromObsIdx,
    List<int> indIndices,
    int intoIdx,
  ) {
    if (fromObsIdx == intoIdx || indIndices.isEmpty) return;
    final from = observations[fromObsIdx];
    final into = observations[intoIdx];

    // In the local-per-photo model, individual index gi corresponds to
    // local index gi in every photo that has enough boxes.
    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    // Collect moved individuals: each has a name and per-photo boxes
    final movedEntries = <({String name,
        Map<String, Rectangle<int>> boxByPhoto})>[];
    for (final gi in sortedIndices) {
      final name = gi < from.individualNames.length
          ? from.individualNames[gi]
          : generatePronounceableName();
      final Map<String, Rectangle<int>> boxByPhoto = {};
      for (final src in from.sourceImages) {
        final boxes = List<Rectangle<int>>.from(
          from.boxesByImagePath[src.imagePath] ?? [],
        )..sort((a, b) => a.left.compareTo(b.left));
        if (gi < boxes.length) {
          boxByPhoto[src.imagePath] = boxes[gi];
        }
      }
      movedEntries.add((name: name, boxByPhoto: boxByPhoto));
    }

    // Remove names (highest indices first to preserve ordering)
    for (final gi in sortedIndices) {
      if (gi < from.individualNames.length) {
        from.individualNames.removeAt(gi);
      }
    }

    // Remove boxes from source (highest local indices first per photo)
    _removeBoxesByLocalIndices(from, sortedIndices);

    // Add to target
    into.count += movedEntries.length;
    from.count -= movedEntries.length;

    for (final me in movedEntries.reversed) {
      for (final entry in me.boxByPhoto.entries) {
        into.boundingBoxes.add(entry.value);
        into.boxesByImagePath
            .putIfAbsent(entry.key, () => [])
            .add(entry.value);
      }
      final src = from.sourceImages.firstWhere(
        (s) => me.boxByPhoto.containsKey(s.imagePath),
        orElse: () => from.sourceImages.first,
      );
      if (!into.sourceImages.any((s) => s.imagePath == src.imagePath)) {
        into.sourceImages.add(src);
      }
      _insertNameAtLocalIndex(into, me.boxByPhoto, me.name);
    }

    // Copy over source images from photos that had no boxes moved but
    // are part of the burst
    if (movedEntries.isEmpty && from.sourceImages.isNotEmpty) {
      final src = from.sourceImages.first;
      if (!into.sourceImages.any((s) => s.imagePath == src.imagePath)) {
        into.sourceImages.add(src);
      }
    }

    for (final s in from.possibleSpecies) {
      if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
    }
    if (from.count <= 0) {
      observations.removeAt(fromObsIdx);
    }
  }

  static void deleteIndividuals(
    List<Observation> observations,
    int obsIdx,
    List<int> indIndices,
  ) {
    if (indIndices.isEmpty) return;
    final from = observations[obsIdx];
    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    // Remove names (highest indices first)
    for (final gi in sortedIndices) {
      if (gi < from.individualNames.length) {
        from.individualNames.removeAt(gi);
      }
    }

    // Remove boxes
    _removeBoxesByLocalIndices(from, sortedIndices);

    from.count -= indIndices.length;
    if (from.count <= 0) {
      observations.removeAt(obsIdx);
    }
  }

  static Observation? extractIndividuals(
    List<Observation> observations,
    int fromObsIdx,
    List<int> indIndices,
    int insertAtIdx,
  ) {
    if (indIndices.isEmpty) return null;
    final from = observations[fromObsIdx];

    final newObs = Observation(
      imagePath: from.imagePath,
      displayPath: from.displayPath,
      fullImageDisplayPath: from.fullImageDisplayPath,
      speciesName: from.speciesName,
      possibleSpecies: List.from(from.possibleSpecies),
      exifData: from.exifData,
      boundingBoxes: [],
      sourceImages: [],
      boxesByImagePath: {},
      burstId: from.burstId,
      individualNames: [],
    );

    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    // Collect moved individuals
    final movedEntries = <({String name,
        Map<String, Rectangle<int>> boxByPhoto})>[];
    for (final gi in sortedIndices) {
      final name = gi < from.individualNames.length
          ? from.individualNames[gi]
          : generatePronounceableName();
      final Map<String, Rectangle<int>> boxByPhoto = {};
      for (final src in from.sourceImages) {
        final boxes = List<Rectangle<int>>.from(
          from.boxesByImagePath[src.imagePath] ?? [],
        )..sort((a, b) => a.left.compareTo(b.left));
        if (gi < boxes.length) {
          boxByPhoto[src.imagePath] = boxes[gi];
        }
      }
      movedEntries.add((name: name, boxByPhoto: boxByPhoto));
    }

    // Remove names from source (highest indices first)
    for (final gi in sortedIndices) {
      if (gi < from.individualNames.length) {
        from.individualNames.removeAt(gi);
      }
    }

    // Remove boxes from source
    _removeBoxesByLocalIndices(from, sortedIndices);

    newObs.count = movedEntries.length;
    from.count -= movedEntries.length;

    for (final me in movedEntries.reversed) {
      for (final entry in me.boxByPhoto.entries) {
        newObs.boundingBoxes.add(entry.value);
        newObs.boxesByImagePath
            .putIfAbsent(entry.key, () => [])
            .add(entry.value);
      }
      final src = from.sourceImages.firstWhere(
        (s) => me.boxByPhoto.containsKey(s.imagePath),
        orElse: () => from.sourceImages.first,
      );
      if (!newObs.sourceImages.any((s) => s.imagePath == src.imagePath)) {
        newObs.sourceImages.add(src);
      }
      _insertNameAtLocalIndex(newObs, me.boxByPhoto, me.name);
    }

    if (movedEntries.isEmpty && from.sourceImages.isNotEmpty) {
      final src = from.sourceImages.first;
      if (!newObs.sourceImages.any((s) => s.imagePath == src.imagePath)) {
        newObs.sourceImages.add(src);
      }
    }

    int actualInsertIdx = insertAtIdx;
    if (from.count <= 0) {
      observations.removeAt(fromObsIdx);
      if (insertAtIdx > fromObsIdx) actualInsertIdx--;
    }
    observations.insert(actualInsertIdx, newObs);
    return newObs;
  }

  /// Remove boxes at the given local indices from every photo in the
  /// observation. [sortedIndicesDesc] must be sorted descending.
  static void _removeBoxesByLocalIndices(
    Observation obs,
    List<int> sortedIndicesDesc,
  ) {
    for (final entry in obs.boxesByImagePath.entries) {
      final boxes = List<Rectangle<int>>.from(entry.value)
        ..sort((a, b) => a.left.compareTo(b.left));
      // Remove from highest local index first
      for (final li in sortedIndicesDesc) {
        if (li < boxes.length) {
          final box = boxes[li];
          entry.value.remove(box);
          obs.boundingBoxes.remove(box);
        }
      }
    }
  }
}
