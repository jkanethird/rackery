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

import 'dart:math';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/utils/name_generator.dart';

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
       individualNames =
           individualNames ??
           List.generate(count, (_) => generatePronounceableName());
}
