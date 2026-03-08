import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:ebird_generator/services/bird_names.dart';
import 'package:ebird_generator/services/geo_region_service.dart';

// Top-level function for compute() isolation: crops around the bounding box
// (with context padding) and draws a red border to highlight the target bird.
List<int> _annotateAndEncode(_AnnotationParams params) {
  img.Image source = params.image;

  img.Image region;
  int boxX1 = 0, boxY1 = 0, boxX2 = 0, boxY2 = 0;

  if (params.box != null) {
    final box = params.box!;
    // Use generous 80% padding so small birds have plenty of context
    // (key for hard-to-ID birds like mockingbirds, sparrows, warblers)
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

    // The red box is now relative to the crop origin
    boxX1 = box.left - cropX1;
    boxY1 = box.top - cropY1;
    boxX2 = boxX1 + box.width;
    boxY2 = boxY1 + box.height;
  } else {
    region = source;
  }

  // Upscale very small crops to at least 400px so small birds are legible
  if (params.box != null && (region.width < 400 || region.height < 400)) {
    final scale = 400 / max(region.width, region.height);
    final newW = (region.width * scale).round();
    final newH = (region.height * scale).round();
    final scaleX = newW / region.width;
    final scaleY = newH / region.height;
    boxX1 = (boxX1 * scaleX).round();
    boxY1 = (boxY1 * scaleY).round();
    boxX2 = (boxX2 * scaleX).round();
    boxY2 = (boxY2 * scaleY).round();
    region = img.copyResize(region, width: newW, height: newH);
  }

  // Downscale to at most 1280px on longest edge
  if (region.width > 1280 || region.height > 1280) {
    final scale = 1280 / max(region.width, region.height);
    final newW = (region.width * scale).round();
    final newH = (region.height * scale).round();

    if (params.box != null) {
      final scaleX = newW / region.width;
      final scaleY = newH / region.height;
      boxX1 = (boxX1 * scaleX).round();
      boxY1 = (boxY1 * scaleY).round();
      boxX2 = (boxX2 * scaleX).round();
      boxY2 = (boxY2 * scaleY).round();
    }

    region = img.copyResize(region, width: newW, height: newH);
  }

  // Draw a thick red rectangle to highlight the bird
  if (params.box != null) {
    final red = img.ColorRgb8(255, 50, 50);
    for (int t = 0; t < 4; t++) {
      img.drawRect(
        region,
        x1: (boxX1 - t).clamp(0, region.width - 1),
        y1: (boxY1 - t).clamp(0, region.height - 1),
        x2: (boxX2 + t).clamp(0, region.width - 1),
        y2: (boxY2 + t).clamp(0, region.height - 1),
        color: red,
      );
    }
  }

  return img.encodeJpg(region, quality: 90);
}

class _AnnotationParams {
  final img.Image image;
  final Rectangle<int>? box;
  final int originalWidth;
  final int originalHeight;

  _AnnotationParams(this.image, this.box, this.originalWidth, this.originalHeight);
}

class BirdClassifier {
  Future<void> init() async {}

  /// Classifies the bird in the image at [imagePath].
  /// If [box] is given, draws a red rectangle on the image before sending to LLaVA.
  /// If [latitude] and [longitude] are given, includes a geographic location hint.
  Future<List<String>> classifyFile(
    String imagePath, {
    Rectangle<int>? box,
    double? latitude,
    double? longitude,
  }) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final fullImage = await compute(img.decodeImage, bytes);
      if (fullImage == null) return ["Unknown Bird"];

      // Draw the bounding box on the image in a background isolate
      final jpgBytes = await compute(
        _annotateAndEncode,
        _AnnotationParams(fullImage, box, fullImage.width, fullImage.height),
      );
      final base64Image = base64Encode(jpgBytes);

      final String boxGuide = box != null
          ? ' A red rectangle has been drawn on the image to highlight the bird. '
            'Focus your identification on the bird inside the red box.'
          : '';

      final String locationGuide = (latitude != null && longitude != null)
          ? ' This photo was taken in ${GeoRegionService.describe(latitude, longitude)}. '
            'Prioritize species known to occur in that region.'
          : '';

      final prompt = 'You are an expert ornithologist helping build an eBird checklist. '
          'Carefully examine this photograph.$boxGuide$locationGuide\n'
          'Identify the bird species using visible features: body shape, plumage color '
          'and pattern, beak shape, leg color, size relative to surroundings, and habitat.\n'
          'List your top 1-5 species guesses as a JSON array. '
          'Use this format when possible: '
          '["Mallard (Anas platyrhynchos)", "American Black Duck (Anas rubripes)"]\n'
          'Be specific: distinguish between similar species (e.g. Mallard vs. Gadwall, '
          'Canada Goose vs. Cackling Goose, etc.).\n'
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
          'options': {
            'temperature': 0.2,
            'num_predict': 256,
          },
        }),
      );

      if (response.statusCode == 200) {
        return _parseResponse(response.body);
      } else {
        print("Ollama API Error: ${response.statusCode} - ${response.body}");
        return ["Unknown Bird (Ollama Error)"];
      }
    } catch (e) {
      print("Error classifying with Ollama: $e");
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
        if (responseText.endsWith('```')) responseText = responseText.substring(0, responseText.length - 3);
      } else if (responseText.startsWith('```')) {
        responseText = responseText.substring(3);
        if (responseText.endsWith('```')) responseText = responseText.substring(0, responseText.length - 3);
      }
      responseText = responseText.trim();

      // Robustly extract the first JSON array found in the response
      final arrayRegex = RegExp(r'\[.*?\]', dotAll: true);
      final match = arrayRegex.firstMatch(responseText);
      if (match != null) responseText = match.group(0)!;

      final List<dynamic> jsonList = jsonDecode(responseText);
      List<String> rawSpeciesList = jsonList.map((e) => e.toString().trim()).toList();

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
          String commonName = scientificToCommon[sciName] ?? raw.split('(')[0].trim();
          processedSpecies.add("$commonName ($sciName)");
        } else {
          if (!processedSpecies.contains(raw)) processedSpecies.add(raw);
        }
      }

      if (processedSpecies.isEmpty) return ["Unknown Bird"];
      return processedSpecies;
    } catch (e) {
      print("Failed to parse LLM JSON response: $body");
      return ["Unknown Bird"];
    }
  }

  void dispose() {}
}
