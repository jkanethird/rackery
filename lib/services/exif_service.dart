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

import 'dart:io';
import 'package:exif/exif.dart';

class ExifData {
  final DateTime? dateTime;
  final double? latitude;
  final double? longitude;

  ExifData({this.dateTime, this.latitude, this.longitude});

  @override
  String toString() {
    return 'ExifData(dateTime: $dateTime, lat: $latitude, lon: $longitude)';
  }
}

class ExifService {
  static Future<ExifData> extractExif(String filePath) async {
    final fileBytes = await File(filePath).readAsBytes();
    final tags = await readExifFromBytes(fileBytes);

    if (tags.isEmpty) return ExifData();

    DateTime? dateTime;
    if (tags.containsKey('Image DateTime')) {
      final dateString = tags['Image DateTime']!.printable;
      dateTime = _parseExifDate(dateString);
    } else if (tags.containsKey('EXIF DateTimeOriginal')) {
      final dateString = tags['EXIF DateTimeOriginal']!.printable;
      dateTime = _parseExifDate(dateString);
    }

    double? lat;
    double? lon;

    if (tags.containsKey('GPS GPSLatitude') &&
        tags.containsKey('GPS GPSLatitudeRef') &&
        tags.containsKey('GPS GPSLongitude') &&
        tags.containsKey('GPS GPSLongitudeRef')) {
      final latValues = tags['GPS GPSLatitude']!.values.toList();
      final latRef = tags['GPS GPSLatitudeRef']!.printable;
      lat = _getCoordinate(latValues, latRef);

      final lonValues = tags['GPS GPSLongitude']!.values.toList();
      final lonRef = tags['GPS GPSLongitudeRef']!.printable;
      lon = _getCoordinate(lonValues, lonRef);
    }

    return ExifData(dateTime: dateTime, latitude: lat, longitude: lon);
  }

  static DateTime? _parseExifDate(String dateString) {
    try {
      // Standard EXIF format: 'YYYY:MM:DD HH:MM:SS'
      final formattedDate = dateString
          .replaceFirst(':', '-')
          .replaceFirst(':', '-');
      return DateTime.parse(formattedDate);
    } catch (e) {
      return null;
    }
  }

  static double? _getCoordinate(List<dynamic> values, String ref) {
    if (values.length != 3) return null;

    double degrees = _parseRatio(values[0]);
    double minutes = _parseRatio(values[1]);
    double seconds = _parseRatio(values[2]);

    double coord = degrees + (minutes / 60.0) + (seconds / 3600.0);
    if (ref == 'S' || ref == 'W') {
      coord = -coord;
    }
    return coord;
  }

  static double _parseRatio(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();

    // The exif package often returns a custom Ratio object for GPS coordinates
    try {
      if (value.denominator != 0) {
        return value.numerator / value.denominator;
      }
    } catch (_) {}

    final str = value.toString();
    if (str.contains('/')) {
      final parts = str.split('/');
      if (parts.length == 2) {
        final num = double.tryParse(parts[0]);
        final den = double.tryParse(parts[1]);
        if (num != null && den != null && den != 0) {
          return num / den;
        }
      }
    }
    return double.tryParse(str) ?? 0.0;
  }
}
