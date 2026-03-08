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
  img.Image region;

  final boxes = params.boxes;
  final isSingleBox = boxes.length == 1;

  if (isSingleBox) {
    final box = boxes.first;
    // Use generous 80% padding so small birds have plenty of context
    final padX = (box.width * 0.8).round();
    final padY = (box.height * 0.8).round();

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

    // Translate the box to crop-relative coords
    final relBox = Rectangle<int>(
      box.left - cropX1,
      box.top - cropY1,
      box.width,
      box.height,
    );

    // Upscale very small crops to at least 400px
    if (region.width < 400 || region.height < 400) {
      final scale = 400 / max(region.width, region.height);
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
    // For clusters of 2+ birds, use the full image (downscaled if needed)
    // so the model sees all highlighted birds together.
    region = source;
  }

  // Downscale to at most 1280px on longest edge
  if (region.width > 1280 || region.height > 1280) {
    final scale = 1280 / max(region.width, region.height);
    final newW = (region.width * scale).round();
    final newH = (region.height * scale).round();
    final scaleX = newW / region.width;
    final scaleY = newH / region.height;

    if (!isSingleBox) {
      // Draw boxes BEFORE downscale so coordinates can be scaled
      final scaledBoxes = boxes
          .map(
            (b) => Rectangle<int>(
              (b.left * scaleX).round(),
              (b.top * scaleY).round(),
              (b.width * scaleX).round(),
              (b.height * scaleY).round(),
            ),
          )
          .toList();
      region = img.copyResize(region, width: newW, height: newH);
      _drawBoxes(region, scaledBoxes);
    } else {
      region = img.copyResize(region, width: newW, height: newH);
    }
  } else if (!isSingleBox) {
    // Full image at original resolution: draw boxes directly
    _drawBoxes(region, boxes);
  }

  return img.encodeJpg(region, quality: 90);
}

void _drawBoxes(img.Image image, List<Rectangle<int>> boxes) {
  final red = img.ColorRgb8(255, 50, 50);
  for (final box in boxes) {
    for (int t = 0; t < 4; t++) {
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

  /// Pass 1 — Scene scan: sends the whole resized image (no boxes) to the LLM
  /// and asks it to enumerate ALL distinct bird species it can see. Returns a
  /// deduplicated list such as ["Mute Swan (Cygnus olor)", "Mallard (Anas platyrhynchos)"].
  Future<List<String>> scanScene(
    String imagePath, {
    double? latitude,
    double? longitude,
  }) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final fullImage = await compute(img.decodeImage, bytes);
      if (fullImage == null) return [];

      // Encode the whole image (downscaled) — no boxes
      final jpgBytes = await compute(
        _annotateAndEncode,
        _AnnotationParams(fullImage, [], fullImage.width, fullImage.height),
      );
      final base64Image = base64Encode(jpgBytes);

      final String locationGuide = (latitude != null && longitude != null)
          ? ' This photo was taken in ${GeoRegionService.describe(latitude, longitude)}. '
                'Prioritize species known to occur in that region.'
          : '';

      final prompt =
          'You are an expert ornithologist helping build an eBird checklist.$locationGuide\n'
          'Carefully examine this photograph and identify the DISTINCT bird species you can see.\n'
          'Rules:\n'
          '- List at most 5 species (the most visually prominent ones).\n'
          '- Use the most specific common name you are confident about (e.g. "Ruddy Turnstone", not just "Sandpiper").\n'
          '- Do NOT list subspecies or multiple variants of the same species.\n'
          '- Return ONLY a compact JSON array: ["Common Name (Scientific Name)", ...]\n'
          '- Example: ["Mute Swan (Cygnus olor)", "Mallard (Anas platyrhynchos)"]\n'
          '- If no birds are visible, return [].\n'
          'OUTPUT ONLY THE JSON ARRAY, NOTHING ELSE.';

      final response = await http.post(
        Uri.parse('http://localhost:11434/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'llava:13b',
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {'temperature': 0.1, 'num_predict': 512},
        }),
      );

      if (response.statusCode == 200) {
        return _parseResponse(response.body);
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Pass 2 — Constrained classification: classifies the bird in [box] but
  /// tells the LLM to choose from [knownSpecies] seen elsewhere in the image.
  /// Falls back to unconstrained classification if [knownSpecies] is empty.
  Future<String> classifyInContext(
    String imagePath, {
    required Rectangle<int> box,
    required List<String> knownSpecies,
    double? latitude,
    double? longitude,
  }) async {
    if (knownSpecies.isEmpty) {
      final result = await classifyFile(
        imagePath,
        box: box,
        latitude: latitude,
        longitude: longitude,
      );
      return result.isNotEmpty ? result.first : 'Unknown';
    }

    try {
      final bytes = await File(imagePath).readAsBytes();
      final fullImage = await compute(img.decodeImage, bytes);
      if (fullImage == null) return 'Unknown';

      final jpgBytes = await compute(
        _annotateAndEncode,
        _AnnotationParams(fullImage, [box], fullImage.width, fullImage.height),
      );
      final base64Image = base64Encode(jpgBytes);

      final speciesList = knownSpecies.map((s) => '"$s"').join(', ');
      final String locationGuide = (latitude != null && longitude != null)
          ? ' This photo was taken in ${GeoRegionService.describe(latitude, longitude)}.'
          : '';

      final prompt =
          'You are an expert ornithologist.$locationGuide\n'
          'A red rectangle highlights one bird in this image.\n'
          'The following species have already been identified elsewhere in this photo: [$speciesList]\n'
          'Which ONE of those species is the bird inside the red box? '
          'Consider size, plumage, and shape relative to other birds in the scene.\n'
          'Respond with ONLY the exact species name from the list above (e.g. "Mute Swan (Cygnus olor)"). '
          'OUTPUT ONLY THE SPECIES NAME, NOTHING ELSE.';

      final response = await http.post(
        Uri.parse('http://localhost:11434/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'llava:13b',
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {'temperature': 0.1, 'num_predict': 64},
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final raw = data['response'].toString().trim();
        // Try to match the response to one of the known species
        for (final species in knownSpecies) {
          if (raw.toLowerCase().contains(
            species.split('(').first.trim().toLowerCase(),
          )) {
            return species;
          }
        }
        // Fallback: just return the first known species if nothing matched
        return knownSpecies.first;
      }
      return knownSpecies.first;
    } catch (e) {
      return knownSpecies.isNotEmpty ? knownSpecies.first : 'Unknown';
    }
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
      if (isCluster && boxes.length > 1) {
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
          'Identify the bird species using visible features: body shape, plumage color '
          'and pattern, beak shape, leg color, size relative to surroundings, and habitat.\n'
          'List your top 1-5 species guesses as a JSON array. '
          'Use this format when possible: '
          '["Mallard (Anas platyrhynchos)", "American Black Duck (Anas rubripes)"]\n'
          'Be specific: distinguish between similar species (e.g. Mallard vs. Gadwall, '
          'Ruddy Turnstone vs. Sanderling, Canada Goose vs. Cackling Goose, etc.).\n'
          'Only respond with ["Unknown Bird"] if there is NO bird visible at all. '
          'OUTPUT ONLY THE JSON ARRAY, NOTHING ELSE.';

      final response = await http.post(
        Uri.parse('http://localhost:11434/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'llava:13b',
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {'temperature': 0.2, 'num_predict': 256},
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

      // Strip markdown fences
      if (responseText.startsWith('```json')) {
        responseText = responseText.substring(7);
        if (responseText.endsWith('```')) {
          responseText = responseText.substring(0, responseText.length - 3);
        }
      } else if (responseText.startsWith('```')) {
        responseText = responseText.substring(3);
        if (responseText.endsWith('```')) {
          responseText = responseText.substring(0, responseText.length - 3);
        }
      }
      responseText = responseText.trim();

      // Robustly extract the first JSON array found in the response
      final arrayRegex = RegExp(r'\[.*?\]', dotAll: true);
      final match = arrayRegex.firstMatch(responseText);
      if (match != null) responseText = match.group(0)!;

      final List<dynamic> jsonList = jsonDecode(responseText);
      List<String> rawSpeciesList = jsonList
          .map((e) => e.toString().trim())
          .toList();

      if (rawSpeciesList.isEmpty) return ["Unknown Bird"];

      List<String> processedSpecies = [];
      Set<String> seenScientifics = {};

      for (String raw in rawSpeciesList) {
        if (raw.isEmpty) continue;
        final lowerRaw = raw.toLowerCase();
        if (lowerRaw.contains('unknown') && !lowerRaw.contains('(')) continue;

        final sciRegex = RegExp(r'\(([^)]+)\)');
        final sciMatch = sciRegex.firstMatch(raw);

        if (sciMatch != null) {
          String sciName = sciMatch.group(1)!.trim();
          if (seenScientifics.contains(sciName)) continue;
          seenScientifics.add(sciName);
          String commonName =
              scientificToCommon[sciName] ?? raw.split('(')[0].trim();
          processedSpecies.add("$commonName ($sciName)");
        } else {
          if (!processedSpecies.contains(raw)) processedSpecies.add(raw);
        }
      }

      if (processedSpecies.isEmpty) return ["Unknown Bird"];
      return processedSpecies;
    } catch (e) {
      debugPrint('Failed to parse LLM JSON response: $body');
      return ["Unknown Bird"];
    }
  }

  void dispose() {}
}
