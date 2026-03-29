import 'dart:math';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/utils/name_generator.dart';

// BurstGroup has been moved to models/burst_group.dart

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

  /// Human-readable pronounceable names per individual assigned to this observation
  List<String> individualNames;

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
    List<String>? individualNames,
  }) : sourceImages =
           sourceImages ??
           [(imagePath: imagePath, fullImageDisplayPath: fullImageDisplayPath)],
       boxesByImagePath =
           boxesByImagePath ??
           {if (boundingBoxes.isNotEmpty) imagePath: List.of(boundingBoxes)},
       individualNames = individualNames ?? List.generate(count, (_) => generatePronounceableName());
}


