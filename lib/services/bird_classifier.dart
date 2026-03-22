import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:ebird_generator/services/ffi_llama.dart';
import 'package:ebird_generator/services/image_annotation.dart';
import 'package:ebird_generator/services/species_name_resolver.dart';
import 'package:ebird_generator/services/geo_region_service.dart';

/// Classifies bird species in images using llama3.2-vision via direct
/// C FFI (`libllama.so` + `libmtmd.so`), bypassing the Ollama HTTP daemon.
///
/// Image pixels are passed directly to the multimodal encoder (mtmd_bitmap)
/// so there is no base64 overhead and no HTTP round-trip latency.
class BirdClassifier {
  final _llama = const FfiLlama();

  Future<void> init() async {}

  /// Classifies the bird in the image at [imagePath].
  /// An optional [box] draws a red rectangle for solo-bird context.
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
  /// simultaneously using flock-level visual context.
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
      if (fullImage == null) return ['Unknown Bird'];

      // Annotate the image (red bounding boxes) and write to a temp JPEG file.
      // FfiLlama reads this temp file to decode pixels into the mtmd_bitmap.
      final jpgBytes = await compute(
        annotateAndEncode,
        AnnotationParams(fullImage, boxes, fullImage.width, fullImage.height),
      );
      final tmpFile = File(
        '${Directory.systemTemp.path}/bird_classify_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await tmpFile.writeAsBytes(jpgBytes);

      final prompt = _buildPrompt(boxes, latitude, longitude, photoDate);

      final result = await _llama.classify(
        tmpFile.path,
        prompt,
        temperature: 0.1,
        maxTokens: 96,
      );

      // Copy the file to artifacts to inspect it
      final artifactPath = '/home/jkane/.gemini/antigravity/brain/223f541a-abf7-41d2-bca4-7c9aa467e382/bird_crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await tmpFile.copy(artifactPath);
      debugPrint('BirdClassifier saved crop to $artifactPath');

      // Clean up the temp file
      unawaited(tmpFile.delete().catchError((Object _) => tmpFile));

      if (result.isHighRisk) {
        debugPrint(
          'BirdClassifier: HALP flagged high hallucination risk '
          '(scores: ${result.halpScores.map((s) => s.toStringAsFixed(2)).join(', ')})',
        );
      }

      if (result.text.isEmpty) {
        debugPrint('BirdClassifier: empty response from FfiLlama');
        return ['Unknown Bird'];
      }

      debugPrint('BirdClassifier raw output: ${result.text}');

      return SpeciesNameResolver.parseOllamaResponse(
        // Wrap in Ollama-compatible envelope for the existing parser
        '{"response":"${result.text.replaceAll('"', '\\"').replaceAll('\n', '\\n')}"}',
      );
    } catch (e) {
      debugPrint('BirdClassifier: error during FFI inference: $e');
      return ['Unknown Bird'];
    }
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
          ' This image is a tight crop of the single bird detected in the photograph.';
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

    return 'You are an expert ornithologist helping build an eBird checklist. '
        'Carefully examine this photograph.$boxGuide$locationGuide$dateGuide\n\n'
        'First, describe the bird\'s most prominent physical characteristics in a single brief paragraph (e.g., colors, beak shape, patterns).\n'
        'Then, provide a numbered list of your top 1 to 5 species guesses using common names (e.g. "1. Species Name"). '
        'Even if you are uncertain, you MUST provide your best guesses.\n\n'
        'If the image clearly contains NO bird whatsoever '
        '(e.g. ONLY foliage, rocks, sky, or a non-bird animal), respond with exactly: 0. none';
  }

  /// Previously used to evict the Ollama model from RAM.
  /// With FFI the model is loaded/unloaded per inference call automatically.
  Future<void> unloadModel() async {}

  void dispose() {
    _llama.dispose();
  }
}
