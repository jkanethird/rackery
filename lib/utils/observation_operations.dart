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

  static Map<int, ({String imagePath, int localIndex})> _buildGlobalIndexMap(Observation obs) {
    final Map<int, ({String imagePath, int localIndex})> map = {};
    int gi = 0;
    for (final src in obs.sourceImages) {
      final boxes = List<Rectangle<int>>.from(
        obs.boxesByImagePath[src.imagePath] ?? [],
      )..sort((a, b) => a.left.compareTo(b.left));
      for (int li = 0; li < boxes.length; li++) {
        map[gi++] = (imagePath: src.imagePath, localIndex: li);
      }
    }
    return map;
  }

  static void mergeIndividuals(List<Observation> observations, int fromObsIdx, List<int> indIndices, int intoIdx) {
    if (fromObsIdx == intoIdx || indIndices.isEmpty) return;
    final from = observations[fromObsIdx];
    final into = observations[intoIdx];
    into.count += indIndices.length;
    from.count -= indIndices.length;

    final globalIndexMap = _buildGlobalIndexMap(from);
    final sortedIndices = List<int>.from(indIndices)..sort((a, b) => b.compareTo(a));

    final Map<String, List<int>> localIndicesToRemove = {};
    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        localIndicesToRemove.putIfAbsent(loc.imagePath, () => []).add(loc.localIndex);
      }
    }

    for (final entry in localIndicesToRemove.entries) {
      final path = entry.key;
      final localIndices = entry.value..sort((a, b) => b.compareTo(a));
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)..sort((a, b) => a.left.compareTo(b.left));
        for (final li in localIndices) {
          if (li < sortedBoxes.length) {
            final box = sortedBoxes[li];
            fromBoxes.remove(box);
            into.boxesByImagePath.putIfAbsent(path, () => []).add(box);
            from.boundingBoxes.remove(box);
            into.boundingBoxes.add(box);
          }
        }
      }
    }

    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        final src = from.sourceImages.firstWhere((s) => s.imagePath == loc.imagePath);
        into.boxesByImagePath.putIfAbsent(loc.imagePath, () => []);
        if (!into.sourceImages.any((s) => s.imagePath == src.imagePath)) {
          into.sourceImages.add(src);
        }
      }
    }
    
    if (localIndicesToRemove.isEmpty && from.sourceImages.isNotEmpty) {
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

    final globalIndexMap = _buildGlobalIndexMap(from);
    final sortedIndices = List<int>.from(indIndices)..sort((a, b) => b.compareTo(a));

    final Map<String, List<int>> localIndicesToRemove = {};
    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        localIndicesToRemove.putIfAbsent(loc.imagePath, () => []).add(loc.localIndex);
      }
    }

    for (final entry in localIndicesToRemove.entries) {
      final path = entry.key;
      final localIndices = entry.value..sort((a, b) => b.compareTo(a));
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)..sort((a, b) => a.left.compareTo(b.left));
        for (final li in localIndices) {
          if (li < sortedBoxes.length) {
            final box = sortedBoxes[li];
            fromBoxes.remove(box);
            newObs.boxesByImagePath.putIfAbsent(path, () => []).add(box);
            from.boundingBoxes.remove(box);
            newObs.boundingBoxes.add(box);
          }
        }
      }
    }

    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        final src = from.sourceImages.firstWhere((s) => s.imagePath == loc.imagePath);
        if (!newObs.sourceImages.any((s) => s.imagePath == src.imagePath)) {
          newObs.sourceImages.add(src);
        }
      }
    }
    
    if (localIndicesToRemove.isEmpty && from.sourceImages.isNotEmpty) {
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
}
