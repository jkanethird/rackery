import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:ebird_generator/services/image_annotation.dart';
import 'package:ebird_generator/services/species_name_resolver.dart';
import 'package:ebird_generator/services/geo_region_service.dart';

const _kOllamaUrl = 'http://localhost:11434/api/generate';
const _kModel = 'llama3.2-vision';

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

  /// Classifies a cluster of birds in [imagePath], all highlighted with red
  /// rectangles. Prompts the model to identify all highlighted birds
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
        annotateAndEncode,
        AnnotationParams(fullImage, boxes, fullImage.width, fullImage.height),
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

      final String locationGuide =
          (latitude != null && longitude != null)
          ? ' This photo was taken in ${GeoRegionService.describe(latitude, longitude)}.'
                ' Prioritize species known to occur in that region.'
          : '';

      final String dateGuide;
      if (photoDate != null) {
        const months = [
          '',
          'January', 'February', 'March', 'April', 'May', 'June',
          'July', 'August', 'September', 'October', 'November', 'December',
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
        Uri.parse(_kOllamaUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': _kModel,
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {'temperature': 0.1, 'num_predict': 96},
        }),
      );

      if (response.statusCode == 200) {
        return SpeciesNameResolver.parseOllamaResponse(response.body);
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

  Future<void> unloadModel() async {
    try {
      final response = await http.post(
        Uri.parse(_kOllamaUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'model': _kModel, 'keep_alive': 0}),
      );
      if (response.statusCode != 200) {
        debugPrint('Failed to unload Ollama model: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error unloading Ollama model: $e');
    }
  }

  void dispose() {}
}
