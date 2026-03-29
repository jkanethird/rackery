import 'dart:math';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/utils/name_generator.dart';

class ObservationOperations {
  static void mergeObservations(
    List<Observation> observations,
    int fromIdx,
    int intoIdx,
  ) {
    if (fromIdx == intoIdx) return;
    final from = observations[fromIdx];
    final into = observations[intoIdx];

    // Merge source images first (needed for correct global index computation)
    final existingPaths = into.sourceImages.map((s) => s.imagePath).toSet();
    for (final src in from.sourceImages) {
      if (existingPaths.add(src.imagePath)) into.sourceImages.add(src);
    }

    // Build a map of (imagePath, box) → name from the 'from' observation
    // so we can insert each name at the right sorted position after merging boxes.
    final fromGlobalMap = _buildGlobalIndexMap(from);
    final Map<int, String> fromGiToName = {};
    for (int gi = 0; gi < from.individualNames.length; gi++) {
      fromGiToName[gi] = from.individualNames[gi];
    }
    // Collect (imagePath, box, name) triples from the 'from' observation
    final fromEntries =
        <({String imagePath, Rectangle<int> box, String name})>[];
    for (final entry in fromGiToName.entries) {
      final loc = fromGlobalMap[entry.key];
      if (loc != null) {
        final boxes = List<Rectangle<int>>.from(
          from.boxesByImagePath[loc.imagePath] ?? [],
        )..sort((a, b) => a.left.compareTo(b.left));
        if (loc.localIndex < boxes.length) {
          fromEntries.add((
            imagePath: loc.imagePath,
            box: boxes[loc.localIndex],
            name: entry.value,
          ));
        }
      }
    }

    // Merge boxes into the target
    into.count += from.count;
    into.boundingBoxes.addAll(from.boundingBoxes);
    for (final entry in from.boxesByImagePath.entries) {
      into.boxesByImagePath
          .putIfAbsent(entry.key, () => [])
          .addAll(entry.value);
    }

    // Now rebuild the global index map for the merged 'into' observation
    // and insert each 'from' name at the correct position.
    for (final fe in fromEntries) {
      _insertNamedBox(into, fe.imagePath, fe.box, fe.name);
    }

    for (final s in from.possibleSpecies) {
      if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
    }
    observations.removeAt(fromIdx);
  }

  static Map<int, ({String imagePath, int localIndex})> _buildGlobalIndexMap(
    Observation obs,
  ) {
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

  static void _insertNamedBox(
    Observation obs,
    String imagePath,
    Rectangle<int> box,
    String name,
  ) {
    int gi = 0;
    int insertAt = obs.individualNames.length;
    bool found = false;
    for (final src in obs.sourceImages) {
      final boxes = List<Rectangle<int>>.from(
        obs.boxesByImagePath[src.imagePath] ?? [],
      )..sort((a, b) => a.left.compareTo(b.left));
      for (int li = 0; li < boxes.length; li++) {
        if (src.imagePath == imagePath && boxes[li] == box) {
          insertAt = gi;
          found = true;
          break;
        }
        gi++;
      }
      if (found) break;
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
    _insertNamedBox(obs, imagePath, box, generatePronounceableName());
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

    final globalIndexMap = _buildGlobalIndexMap(from);
    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    final movedEntries =
        <({String imagePath, Rectangle<int> box, String name})>[];
    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        final boxes = List<Rectangle<int>>.from(
          from.boxesByImagePath[loc.imagePath] ?? [],
        )..sort((a, b) => a.left.compareTo(b.left));
        if (loc.localIndex < boxes.length) {
          movedEntries.add((
            imagePath: loc.imagePath,
            box: boxes[loc.localIndex],
            name: gi < from.individualNames.length
                ? from.individualNames[gi]
                : generatePronounceableName(),
          ));
        }
      }
    }

    for (final gi in sortedIndices) {
      if (gi < from.individualNames.length) {
        from.individualNames.removeAt(gi);
      }
    }

    final Map<String, List<int>> localIndicesToRemove = {};
    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        localIndicesToRemove
            .putIfAbsent(loc.imagePath, () => [])
            .add(loc.localIndex);
      }
    }

    for (final entry in localIndicesToRemove.entries) {
      final path = entry.key;
      final localIndices = entry.value..sort((a, b) => b.compareTo(a));
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
          ..sort((a, b) => a.left.compareTo(b.left));
        for (final li in localIndices) {
          if (li < sortedBoxes.length) {
            final box = sortedBoxes[li];
            fromBoxes.remove(box);
            from.boundingBoxes.remove(box);
          }
        }
      }
    }

    into.count += movedEntries.length;
    from.count -= movedEntries.length;

    for (final me in movedEntries.reversed) {
      into.boundingBoxes.add(me.box);
      into.boxesByImagePath.putIfAbsent(me.imagePath, () => []).add(me.box);
      final src = from.sourceImages.firstWhere(
        (s) => s.imagePath == me.imagePath,
      );
      if (!into.sourceImages.any((s) => s.imagePath == src.imagePath)) {
        into.sourceImages.add(src);
      }
      _insertNamedBox(into, me.imagePath, me.box, me.name);
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

  static void deleteIndividuals(
    List<Observation> observations,
    int obsIdx,
    List<int> indIndices,
  ) {
    if (indIndices.isEmpty) return;
    final from = observations[obsIdx];
    final globalIndexMap = _buildGlobalIndexMap(from);
    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    for (final gi in sortedIndices) {
      if (gi < from.individualNames.length) {
        from.individualNames.removeAt(gi);
      }
    }

    final Map<String, List<int>> localIndicesToRemove = {};
    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        localIndicesToRemove
            .putIfAbsent(loc.imagePath, () => [])
            .add(loc.localIndex);
      }
    }

    for (final entry in localIndicesToRemove.entries) {
      final path = entry.key;
      final localIndices = entry.value..sort((a, b) => b.compareTo(a));
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
          ..sort((a, b) => a.left.compareTo(b.left));
        for (final li in localIndices) {
          if (li < sortedBoxes.length) {
            final box = sortedBoxes[li];
            fromBoxes.remove(box);
            from.boundingBoxes.remove(box);
          }
        }
      }
    }

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

    final globalIndexMap = _buildGlobalIndexMap(from);
    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    final movedEntries =
        <({String imagePath, Rectangle<int> box, String name})>[];
    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        final boxes = List<Rectangle<int>>.from(
          from.boxesByImagePath[loc.imagePath] ?? [],
        )..sort((a, b) => a.left.compareTo(b.left));
        if (loc.localIndex < boxes.length) {
          movedEntries.add((
            imagePath: loc.imagePath,
            box: boxes[loc.localIndex],
            name: gi < from.individualNames.length
                ? from.individualNames[gi]
                : generatePronounceableName(),
          ));
        }
      }
    }

    for (final gi in sortedIndices) {
      if (gi < from.individualNames.length) {
        from.individualNames.removeAt(gi);
      }
    }

    final Map<String, List<int>> localIndicesToRemove = {};
    for (final gi in sortedIndices) {
      final loc = globalIndexMap[gi];
      if (loc != null) {
        localIndicesToRemove
            .putIfAbsent(loc.imagePath, () => [])
            .add(loc.localIndex);
      }
    }

    for (final entry in localIndicesToRemove.entries) {
      final path = entry.key;
      final localIndices = entry.value..sort((a, b) => b.compareTo(a));
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
          ..sort((a, b) => a.left.compareTo(b.left));
        for (final li in localIndices) {
          if (li < sortedBoxes.length) {
            final box = sortedBoxes[li];
            fromBoxes.remove(box);
            from.boundingBoxes.remove(box);
          }
        }
      }
    }

    newObs.count = movedEntries.length;
    from.count -= movedEntries.length;

    for (final me in movedEntries.reversed) {
      newObs.boundingBoxes.add(me.box);
      newObs.boxesByImagePath.putIfAbsent(me.imagePath, () => []).add(me.box);
      final src = from.sourceImages.firstWhere(
        (s) => s.imagePath == me.imagePath,
      );
      if (!newObs.sourceImages.any((s) => s.imagePath == src.imagePath)) {
        newObs.sourceImages.add(src);
      }
      _insertNamedBox(newObs, me.imagePath, me.box, me.name);
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
