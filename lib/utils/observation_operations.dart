import 'dart:math';
import 'package:ebird_generator/models/observation.dart';

class ObservationOperations {
  static void mergeObservations(List<Observation> observations, int fromIdx, int intoIdx) {
    if (fromIdx == intoIdx) return;
    final from = observations[fromIdx];
    final into = observations[intoIdx];
    into.count += from.count;
    into.boundingBoxes.addAll(from.boundingBoxes);
    for (final s in from.possibleSpecies) {
      if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
    }
    final existingPaths = into.sourceImages.map((s) => s.imagePath).toSet();
    for (final src in from.sourceImages) {
      if (existingPaths.add(src.imagePath)) into.sourceImages.add(src);
    }
    for (final entry in from.boxesByImagePath.entries) {
      into.boxesByImagePath.putIfAbsent(entry.key, () => []).addAll(entry.value);
    }
    observations.removeAt(fromIdx);
  }

  static void mergeIndividuals(List<Observation> observations, int fromObsIdx, List<int> indIndices, int intoIdx) {
    if (fromObsIdx == intoIdx || indIndices.isEmpty) return;
    final from = observations[fromObsIdx];
    final into = observations[intoIdx];
    into.count += indIndices.length;
    from.count -= indIndices.length;

    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    for (final src in List.from(from.sourceImages)) {
      final path = src.imagePath;
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null && fromBoxes.isNotEmpty) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
          ..sort((a, b) => a.left.compareTo(b.left));
        for (final idx in sortedIndices) {
          if (idx < sortedBoxes.length) {
            final box = sortedBoxes[idx];
            fromBoxes.remove(box);
            into.boxesByImagePath.putIfAbsent(path, () => []).add(box);
            from.boundingBoxes.remove(box);
            into.boundingBoxes.add(box);
          }
        }
      }
      into.boxesByImagePath.putIfAbsent(path, () => []);
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

  static Observation? extractIndividuals(List<Observation> observations, int fromObsIdx, List<int> indIndices, int insertAtIdx) {
    if (indIndices.isEmpty) return null;
    final from = observations[fromObsIdx];

    final newObs = Observation(
      imagePath: from.imagePath,
      displayPath: from.displayPath,
      fullImageDisplayPath: from.fullImageDisplayPath,
      speciesName: from.speciesName,
      possibleSpecies: List.from(from.possibleSpecies),
      exifData: from.exifData,
      count: indIndices.length,
      boundingBoxes: [],
      sourceImages: [],
      boxesByImagePath: {},
      burstId: from.burstId,
    );
    from.count -= indIndices.length;

    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    for (final src in List.from(from.sourceImages)) {
      final path = src.imagePath;
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null && fromBoxes.isNotEmpty) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
          ..sort((a, b) => a.left.compareTo(b.left));
        for (final idx in sortedIndices) {
          if (idx < sortedBoxes.length) {
            final box = sortedBoxes[idx];
            fromBoxes.remove(box);
            newObs.boxesByImagePath.putIfAbsent(path, () => []).add(box);
            from.boundingBoxes.remove(box);
            newObs.boundingBoxes.add(box);
          }
        }
      }
      if (newObs.boxesByImagePath.containsKey(path) &&
          newObs.boxesByImagePath[path]!.isNotEmpty) {
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
}
