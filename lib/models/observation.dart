import 'dart:math';
import 'package:ebird_generator/services/exif_service.dart';

class Observation {
  String imagePath;
  String? displayPath; // Crop icon
  String? fullImageDisplayPath; // Full converted JPEG for painter
  String speciesName;
  List<String> possibleSpecies;
  int count;
  ExifData exifData;
  List<Rectangle<int>> boundingBoxes;

  Observation({
    required this.imagePath,
    this.displayPath,
    this.fullImageDisplayPath,
    required this.speciesName,
    this.possibleSpecies = const [],
    required this.exifData,
    this.count = 1,
    this.boundingBoxes = const [],
  });
}
