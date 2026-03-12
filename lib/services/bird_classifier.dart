import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:ebird_generator/services/bird_names.dart';
import 'package:ebird_generator/services/geo_region_service.dart';

// Top-level function for compute() isolation: annotates the image with one or
// more red bounding boxes and encodes to JPEG for the vision model.
List<int> _annotateAndEncode(_AnnotationParams params) {
  img.Image source = params.image;
  final boxes = params.boxes;
  img.Image region;

  if (boxes.length == 1) {
    // For a single detected bird, crop with generous 200% padding so the bird
    // is the prominent subject but has enough habitat/environment context.
    final box = boxes.first;
    final padX = (box.width * 2.0).round();
    final padY = (box.height * 2.0).round();

    final cropX1 = (box.left - padX).clamp(0, source.width - 1);
    final cropY1 = (box.top - padY).clamp(0, source.height - 1);
    final cropX2 = (box.left + box.width + padX).clamp(1, source.width);
    final cropY2 = (box.top + box.height + padY).clamp(1, source.height);

    region = img.copyCrop(
      source,
      x: cropX1,
      y: cropY1,
      width: cropX2 - cropX1,
      height: cropY2 - cropY1,
    );

    // Box coords relative to the crop
    final relBox = Rectangle<int>(
      box.left - cropX1,
      box.top - cropY1,
      box.width,
      box.height,
    );

    // Upscale small crops so the bird is large enough to identify
    if (region.width < 640 || region.height < 640) {
      final scale = 640 / max(region.width, region.height);
      final newW = (region.width * scale).round();
      final newH = (region.height * scale).round();
      final scaleX = newW / region.width;
      final scaleY = newH / region.height;
      final scaled = Rectangle<int>(
        (relBox.left * scaleX).round(),
        (relBox.top * scaleY).round(),
        (relBox.width * scaleX).round(),
        (relBox.height * scaleY).round(),
      );
      region = img.copyResize(region, width: newW, height: newH);
      _drawBoxes(region, [scaled]);
    } else {
      _drawBoxes(region, [relBox]);
    }
  } else {
    // For multi-bird clusters use the full image so all boxes are visible.
    region = source;
    _drawBoxes(region, boxes);
  }

  // Downscale to at most 1280px on longest edge
  if (region.width > 1280 || region.height > 1280) {
    final scale = 1280 / max(region.width, region.height);
    final newW = (region.width * scale).round();
    final newH = (region.height * scale).round();
    region = img.copyResize(region, width: newW, height: newH);
  }

  return img.encodeJpg(region, quality: 90);
}

void _drawBoxes(img.Image image, List<Rectangle<int>> boxes) {
  final red = img.ColorRgb8(255, 50, 50);
  for (final box in boxes) {
    for (int t = 0; t < 12; t++) {
      img.drawRect(
        image,
        x1: (box.left - t).clamp(0, image.width - 1),
        y1: (box.top - t).clamp(0, image.height - 1),
        x2: (box.left + box.width + t).clamp(0, image.width - 1),
        y2: (box.top + box.height + t).clamp(0, image.height - 1),
        color: red,
      );
    }
  }
}

class _AnnotationParams {
  final img.Image image;
  final List<Rectangle<int>> boxes;
  final int originalWidth;
  final int originalHeight;

  _AnnotationParams(
    this.image,
    this.boxes,
    this.originalWidth,
    this.originalHeight,
  );
}

class BirdClassifier {
  Future<void> init() async {}

  /// Classifies the bird in the image at [imagePath].
  /// An optional single [box] draws a red rectangle for solo-bird context.
  /// Use [classifyCluster] for multi-bird clusters.
  Future<List<String>> classifyFile(
    String imagePath, {
    Rectangle<int>? box,
    double? latitude,
    double? longitude,
    DateTime? photoDate,
  }) async {
    final boxes = box != null ? [box] : <Rectangle<int>>[];
    return _classifyWithBoxes(
      imagePath,
      boxes: boxes,
      latitude: latitude,
      longitude: longitude,
      isCluster: false,
      photoDate: photoDate,
    );
  }

  /// Classifies a cluster of [count] birds in [imagePath], all highlighted
  /// with red rectangles. Prompts the model to identify all highlighted birds
  /// simultaneously, leveraging flock-level visual context.
  Future<List<String>> classifyCluster(
    String imagePath, {
    required List<Rectangle<int>> boxes,
    double? latitude,
    double? longitude,
    DateTime? photoDate,
  }) async {
    return _classifyWithBoxes(
      imagePath,
      boxes: boxes,
      latitude: latitude,
      longitude: longitude,
      isCluster: true,
      photoDate: photoDate,
    );
  }

  Future<List<String>> _classifyWithBoxes(
    String imagePath, {
    required List<Rectangle<int>> boxes,
    double? latitude,
    double? longitude,
    required bool isCluster,
    DateTime? photoDate,
  }) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final fullImage = await compute(img.decodeImage, bytes);
      if (fullImage == null) return ["Unknown Bird"];

      final jpgBytes = await compute(
        _annotateAndEncode,
        _AnnotationParams(fullImage, boxes, fullImage.width, fullImage.height),
      );
      final base64Image = base64Encode(jpgBytes);

      final String boxGuide;
      if (boxes.length > 1) {
        boxGuide =
            ' There are ${boxes.length} red rectangles drawn on the image, '
            'each highlighting one bird. All highlighted birds are the SAME species. '
            'Identify their species using the collective visual evidence across all boxes.';
      } else if (boxes.isNotEmpty) {
        boxGuide =
            ' A red rectangle has been drawn on the image to highlight the bird. '
            'Focus your identification on the bird inside the red box.';
      } else {
        boxGuide = '';
      }

      final String locationGuide = (latitude != null && longitude != null)
          ? ' This photo was taken in ${GeoRegionService.describe(latitude, longitude)}.'
                ' Prioritize species known to occur in that region.'
          : '';

      // Derive season/month context from the photo date
      final String dateGuide;
      if (photoDate != null) {
        const months = [
          '',
          'January',
          'February',
          'March',
          'April',
          'May',
          'June',
          'July',
          'August',
          'September',
          'October',
          'November',
          'December',
        ];
        final month = months[photoDate.month];
        final season = switch (photoDate.month) {
          12 || 1 || 2 => 'winter',
          3 || 4 || 5 => 'spring',
          6 || 7 || 8 => 'summer',
          _ => 'fall',
        };
        dateGuide =
            ' Photo taken in $month ${photoDate.year} ($season).'
            ' Consider $season plumage and $season visitors for this region.';
      } else {
        dateGuide = '';
      }

      final prompt =
          'You are an expert ornithologist helping build an eBird checklist. '
          'Carefully examine this photograph.$boxGuide$locationGuide$dateGuide\n'
          'Provide your top 1 to 5 bird species guesses formatted as a numbered list of common names.\n'
          'CRITICAL: Do not include any text other than the numbered list.';

      final response = await http.post(
        Uri.parse('http://localhost:11434/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'llama3.2-vision',
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {'temperature': 0, 'num_predict': 192},
        }),
      );

      if (response.statusCode == 200) {
        return _parseResponse(response.body);
      } else {
        debugPrint(
          'Ollama API Error: ${response.statusCode} - ${response.body}',
        );
        return ["Unknown Bird (Ollama Error)"];
      }
    } catch (e) {
      debugPrint('Error classifying with Ollama: $e');
      return ["Unknown Bird (Connection Error)"];
    }
  }

  List<String> _parseResponse(String body) {
    try {
      final data = jsonDecode(body);
      String responseText = data['response'].toString().trim();

      List<String> rawSpeciesList = [];

      // 1. Try to grab strictly formatted numbered list items first
      final listRegex = RegExp(r'^\s*\d+\.\s*(.+)$', multiLine: true);
      for (final match in listRegex.allMatches(responseText)) {
        rawSpeciesList.add(match.group(1)!.trim());
      }

      // 2. Try looking for formatted strings "Common Name (Scientific Name)"
      if (rawSpeciesList.isEmpty) {
        final speciesNameRegex = RegExp(
          r"([A-Za-z \-'\.,]+?\s*\([A-Z][a-z]+ [a-z]+\))",
        );
        final matches = speciesNameRegex.allMatches(responseText);
        for (final m in matches) {
          rawSpeciesList.add(m.group(1)!.trim());
        }
      }

      // 3. Try pulling bulleted items
      if (rawSpeciesList.isEmpty) {
        final bulletRegex = RegExp(r'[-*]\s*"?([^"\n]+)"?');
        final matches = bulletRegex.allMatches(responseText);
        for (final m in matches) {
          rawSpeciesList.add(m.group(1)!.trim());
        }
      }

      // 3. Default Unknown
      if (rawSpeciesList.isEmpty) {
        if (responseText.toLowerCase().contains("unknown bird")) {
          return ["Unknown Bird"];
        }
        debugPrint('Failed to extract any species from response text.');
        return ["Unknown Bird"];
      }

      List<String> processedSpecies = [];
      Set<String> seenScientifics = {};

      for (String raw in rawSpeciesList) {
        if (raw.isEmpty) continue;
        final lowerRaw = raw.toLowerCase();
        if (lowerRaw.contains('unknown') && !lowerRaw.contains('(')) continue;

        // Try to find the exact common name in our eBird dictionary
        String? bestCommon;
        String? bestSci;

        for (final entry in scientificToCommon.entries) {
          if (entry.value.trim().isEmpty) {
            continue; // Skip empty generic common names to prevent matching everything
          }
          if (lowerRaw.contains(entry.value.toLowerCase())) {
            if (bestCommon == null || entry.value.length > bestCommon.length) {
              bestCommon = entry.value;
              bestSci = entry.key;
            }
          }
        }

        if (bestCommon != null && bestSci != null) {
          if (!seenScientifics.contains(bestSci)) {
            seenScientifics.add(bestSci);
            processedSpecies.add("$bestCommon ($bestSci)");
          }
        }
      }

      if (processedSpecies.isEmpty) return ["Unknown Bird"];
      return processedSpecies;
    } catch (e) {
      debugPrint('Failed to parse LLM JSON response: $e');
      return ["Unknown Bird"];
    }
  }

  void dispose() {}
}
