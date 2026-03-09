import 'package:ebird_generator/services/exif_service.dart';

void main() async {
  final exifs = [
    '/home/jkane/test photos/IMG_3834.HEIC',
    '/home/jkane/test photos/IMG_3835.HEIC',
    '/home/jkane/test photos/IMG_3836.HEIC',
  ];
  for (final path in exifs) {
    final exif = await ExifService.extractExif(path);
    print('$path: $exif');
  }
}
