import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
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
  ///
  /// When [allowNoBird] is true, the model may respond that no bird is
  /// present — callers receive an empty list and should discard the crop.
  Future<List<String>> classifyFile(
    String imagePath, {
    Rectangle<int>? box,
    double? latitude,
    double? longitude,
    DateTime? photoDate,
    bool allowNoBird = false,
  }) async {
    final boxes = box != null ? [box] : <Rectangle<int>>[];
    return _classifyWithBoxes(
      imagePath,
      boxes: boxes,
      latitude: latitude,
      longitude: longitude,
      isCluster: false,
      photoDate: photoDate,
      allowNoBird: allowNoBird,
    );
  }

  Future<List<String>> classifyCluster(
    String imagePath, {
    required List<Rectangle<int>> boxes,
    double? latitude,
    double? longitude,
    DateTime? photoDate,
    bool allowNoBird = false,
    Uint8List? cropBytes,
  }) async {
    return _classifyWithBoxes(
      imagePath,
      boxes: boxes,
      latitude: latitude,
      longitude: longitude,
      isCluster: true,
      photoDate: photoDate,
      allowNoBird: allowNoBird,
      cropBytes: cropBytes,
    );
  }

  Future<List<String>> _classifyWithBoxes(
    String imagePath, {
    required List<Rectangle<int>> boxes,
    double? latitude,
    double? longitude,
    required bool isCluster,
    DateTime? photoDate,
    bool allowNoBird = false,
    Uint8List? cropBytes,
  }) async {
    try {
      // Step 1: When crop bytes are available, run a quick verification pass
      // to reject false positives BEFORE attempting species classification.
      if (allowNoBird && cropBytes != null) {
        final isConfirmedBird = await _verifyBirdPresence(cropBytes);
        if (!isConfirmedBird) return [];
      }

      // Step 2: Species classification using the full annotated image.
      final bytes = await File(imagePath).readAsBytes();
      final fullImage = await compute(img.decodeImage, bytes);
      if (fullImage == null) return ["Unknown Bird"];

      final jpgBytes = await compute(
        annotateAndEncode,
        AnnotationParams(fullImage, boxes, fullImage.width, fullImage.height),
      );
      final base64Image = base64Encode(jpgBytes);

      final prompt = _buildPrompt(boxes, latitude, longitude, photoDate);
      final response = await http.post(
        Uri.parse(_kOllamaUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': _kModel,
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {'temperature': 0.1, 'num_predict': 128},
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String resultText = data['response'].toString().trim();
        return SpeciesNameResolver.parseOllamaResponse(
          '{"response":"${resultText.replaceAll('"', '\\"').replaceAll('\n', '\\n')}"}',
        );
      } else {
        debugPrint(
          'Ollama API Error: ${response.statusCode} - ${response.body}',
        );
        return ["Unknown Bird"];
      }
    } catch (e) {
      debugPrint('Error classifying with Ollama: $e');
      return ["Unknown Bird"];
    }
  }

  /// Quick YES/NO verification: sends ONLY the crop to the model with a
  /// focused prompt. Returns true if a bird is confirmed present.
  Future<bool> _verifyBirdPresence(Uint8List cropBytes) async {
    try {
      final base64Crop = base64Encode(cropBytes);
      final response = await http.post(
        Uri.parse(_kOllamaUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': _kModel,
          'prompt':
              'Look at this close-up image carefully. Is there a bird in this image? '
              'Common false positives include dead leaves, knots in bark, rocks, '
              'shadows, and other non-bird objects on branches. '
              'Respond with ONLY "YES" or "NO".',
          'images': [base64Crop],
          'stream': false,
          'options': {'temperature': 0.0, 'num_predict': 8},
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data['response'].toString().trim().toUpperCase();
        final confirmed = answer.startsWith('YES');
        if (!confirmed) {
          debugPrint('Bird verification rejected: "$answer"');
        }
        return confirmed;
      }
    } catch (e) {
      debugPrint('Bird verification error: $e');
    }
    // On error, assume bird is present to avoid losing real detections.
    return true;
  }

  String _buildPrompt(
    List<Rectangle<int>> boxes,
    double? latitude,
    double? longitude,
    DateTime? photoDate,
  ) {
    final String boxGuide;
    if (boxes.length > 1) {
      boxGuide =
          ' There are ${boxes.length} red rectangles drawn on the image, '
          'each highlighting one bird. All highlighted birds are the SAME species. '
          'Identify their species using the collective visual evidence across all boxes.';
    } else if (boxes.isNotEmpty) {
      boxGuide =
          ' A red rectangle has been drawn on the image to highlight the bird. '
          'Focus your identification on the bird inside the red box. Consider all visual evidence.';
    } else {
      boxGuide = '';
    }

    final String locationGuide = (latitude != null && longitude != null)
        ? ' This photo was taken in ${GeoRegionService.describe(latitude, longitude)}.'
              ' ONLY suggest species that are native to, or have been introduced to'
              ' and established populations in, this region.'
              ' Do NOT suggest species found only on other continents.'
        : '';

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
          ' Only suggest species that would realistically be present in this'
          ' region during $season, including year-round residents and $season visitors.';
    } else {
      dateGuide = '';
    }

    return 'You are an expert ornithologist and birder helping build an eBird checklist. '
        'Carefully examine this photograph.$boxGuide$locationGuide$dateGuide\n'
        'Provide your top 1 to 5 bird species guesses formatted as a numbered list of common names.\n'
        'CRITICAL: Do not include any text other than the numbered list.';
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
