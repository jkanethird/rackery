import 'dart:math';
import 'package:ebird_generator/services/exif_service.dart';

/// A single (imagePath, display JPEG path) pair representing one source photo.
typedef SourceImage = ({String imagePath, String? fullImageDisplayPath});

class Observation {
  String imagePath;
  String? displayPath; // Crop icon
  String? fullImageDisplayPath; // Full converted JPEG for painter
  String speciesName;
  List<String> possibleSpecies;
  int count;
  ExifData exifData;
  List<Rectangle<int>> boundingBoxes;
  String burstId;

  /// All source photos that contributed to this observation (across burst/merge).
  List<SourceImage> sourceImages;

  /// Bounding boxes keyed by the source imagePath they belong to.
  /// Allows the center pane to draw boxes correctly on each contributing photo.
  Map<String, List<Rectangle<int>>> boxesByImagePath;

  Observation({
    required this.imagePath,
    this.displayPath,
    this.fullImageDisplayPath,
    required this.speciesName,
    this.possibleSpecies = const [],
    required this.exifData,
    this.count = 1,
    this.boundingBoxes = const [],
    this.burstId = "",
    List<SourceImage>? sourceImages,
    Map<String, List<Rectangle<int>>>? boxesByImagePath,
  }) : sourceImages =
           sourceImages ??
           [(imagePath: imagePath, fullImageDisplayPath: fullImageDisplayPath)],
       boxesByImagePath =
           boxesByImagePath ??
           {if (boundingBoxes.isNotEmpty) imagePath: List.of(boundingBoxes)};
}

class BurstGroup {
  final List<Observation> observations = [];
  String dominantSpecies = "Unknown";
  int totalCount = 0;

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

    // Ebird prefers the *maximum* count seen at one time, rather than
    // summing counts across a timeline which overcounts the same bird.
    totalCount = maxBirdsInSingleFrame;
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
    if (observations.isEmpty) throw Exception("Cannot convert empty BurstGroup");

    // Start with the first observation as the base
    final base = observations.first;

    List<SourceImage> sourceImages = [];
    Map<String, List<Rectangle<int>>> boxesByImagePath = {};
    List<Rectangle<int>> boxes = [];
    List<String> possibleSpecies = [];


    for (var obs in observations) {
      sourceImages.addAll(obs.sourceImages);

      for (final entry in obs.boxesByImagePath.entries) {
        boxesByImagePath.putIfAbsent(entry.key, () => []).addAll(entry.value);
      }
      boxes.addAll(obs.boundingBoxes);
      for (final s in obs.possibleSpecies) {
        if (!possibleSpecies.contains(s)) possibleSpecies.add(s);
      }
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
      burstId: burstId,
    );
  }
}
