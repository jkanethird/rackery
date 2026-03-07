import 'package:ebird_generator/services/exif_service.dart';

class Observation {
  String imagePath;
  String? displayPath; // Added for converted HEIC photos
  String speciesName;
  int count;
  ExifData exifData;

  Observation({
    required this.imagePath,
    this.displayPath,
    required this.speciesName,
    required this.exifData,
    this.count = 1,
  });
}
