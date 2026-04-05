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
import 'package:csv/csv.dart';
import 'package:rackery/models/observation.dart';
import 'package:rackery/services/bird_names.dart';

class CsvService {
  static Future<void> generateEbirdCsv(
    List<Observation> observations,
    String outputPath,
  ) async {
    List<List<dynamic>> rows = [];

    // eBird Record Format Headers
    rows.add([
      "Common Name",
      "Genus",
      "Species",
      "Number",
      "Species Comments",
      "Location Name",
      "Latitude",
      "Longitude",
      "Date",
      "Start Time",
      "State/Province",
      "Country",
      "Protocol",
      "Number of Observers",
      "Duration",
      "All Observations Reported?",
      "Distance Covered",
      "Area Covered",
      "Elevation",
    ]);

    for (var obs in observations) {
      String dateStr = '';
      String timeStr = '';

      if (obs.exifData.dateTime != null) {
        final dt = obs.exifData.dateTime!;
        dateStr = '${dt.month}/${dt.day}/${dt.year}';
        timeStr =
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }

      String genus = "";
      String species = "";

      final match = scientificToCommon.entries.where(
        (e) => e.value == obs.speciesName,
      );
      if (match.isNotEmpty) {
        final scientificName = match.first.key;
        final parts = scientificName.split(' ');
        if (parts.isNotEmpty) {
          genus = parts.first;
          if (parts.length > 1) {
            species = parts.sublist(1).join(' ');
          }
        }
      }

      rows.add([
        obs.speciesName, // Common Name
        genus, // Genus
        species, // Species
        obs.count.toString(), // Number
        "Identified via local AI from photo: ${obs.imagePath.split('/').last}", // Comments
        "Generated Location", // Location Name
        obs.exifData.latitude?.toStringAsFixed(6) ?? "", // Latitude
        obs.exifData.longitude?.toStringAsFixed(6) ?? "", // Longitude
        dateStr, // Date
        timeStr, // Start Time
        "", // State/Province
        "", // Country
        "Incidental", // Protocol
        "1", // Number of Observers
        "", // Duration
        "N", // All Observations Reported?
        "", // Distance
        "", // Area
        "", // Elevation
      ]);
    }

    String csvStr = const CsvEncoder().convert(rows);
    final file = File(outputPath);
    await file.writeAsString(csvStr);
  }
}
