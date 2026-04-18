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
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:rackery/src/rust/api/pipeline.dart' as rust;

// ── Public Types ───────────────────────────────────────────────────────────

class BirdCrop {
  final Uint8List croppedJpgBytes;
  final List<double> centerColor;
  final double confidence;
  final Rectangle<int> box;

  BirdCrop(this.croppedJpgBytes, this.centerColor, this.confidence, this.box);
}

class DetectionResult {
  final List<BirdCrop> crops;
  final Duration createTilesTime;
  final Duration birdDetectionTime;
  DetectionResult(this.crops, this.createTilesTime, this.birdDetectionTime);
}

/// Result from the full native pipeline: detection + classification in one call.
class PipelineOutput {
  final List<IdentifiedBird> birds;
  final Duration detectionTime;
  final Duration classificationTime;

  PipelineOutput({
    required this.birds,
    required this.detectionTime,
    required this.classificationTime,
  });
}

/// A fully-identified bird from the native pipeline.
class IdentifiedBird {
  final String species;
  final List<String> possibleSpecies;
  final double confidence;
  final Rectangle<int> box;
  final List<double> centerColor;
  final Uint8List cropJpgBytes;

  IdentifiedBird({
    required this.species,
    required this.possibleSpecies,
    required this.confidence,
    required this.box,
    required this.centerColor,
    required this.cropJpgBytes,
  });
}

// ── NativePipeline ─────────────────────────────────────────────────────────

/// Thin Dart wrapper around the unified Rust detection + classification pipeline.
///
/// The entire pipeline (decode → tile → detect → NMS → classify → crop → encode)
/// runs natively in Rust. Only lightweight results cross the FFI boundary.
class NativePipeline {
  bool _isInit = false;
  String _executionProvider = 'Unknown';

  bool get isReady => _isInit;
  String get executionProvider => _executionProvider;

  Future<void> init() async {
    if (_isInit) return;

    // Load all model/data assets in parallel
    final futures = await Future.wait([
      rootBundle.load('assets/efficientdet_lite4.onnx'),
      rootBundle.load('assets/bioclip_vision_int8.onnx'),
      rootBundle.load('assets/species_embeddings.bin'),
      rootBundle.loadString('assets/species_labels.json'),
    ]);

    final detectorBytes = (futures[0] as ByteData).buffer.asUint8List();
    final classifierBytes = (futures[1] as ByteData).buffer.asUint8List();
    final embeddingsBytes = (futures[2] as ByteData).buffer.asUint8List();
    final labelsJson = futures[3] as String;

    _executionProvider = await rust.initPipeline(
      detectorModelBytes: detectorBytes,
      classifierModelBytes: classifierBytes,
      embeddingsBytes: embeddingsBytes,
      labelsJson: labelsJson,
    );

    _isInit = true;
    debugPrint('NativePipeline initialized (detector + classifier + embeddings)');
  }

  /// Run the full detection + classification pipeline on a single image file.
  ///
  /// Returns identified birds with species names, bounding boxes, and thumbnails.
  /// The [allowedSpecies] set enables geographic soft-boosting from eBird.
  Future<PipelineOutput> processPhoto(
    String imagePath, {
    Set<String>? allowedSpecies,
    void Function(String)? onProgress,
  }) async {
    if (!_isInit) throw Exception('Pipeline not initialized');

    final fileBytes = await File(imagePath).readAsBytes();

    final eventStream = rust.processPipeline(
      fileBytes: fileBytes,
      allowedSpecies: allowedSpecies?.toList(),
    );

    PipelineOutput? result;

    await for (final event in eventStream) {
      event.when(
        progress: (msg) => onProgress?.call(msg),
        complete: (rustResult) {
          result = PipelineOutput(
            birds: rustResult.birds.map((b) => IdentifiedBird(
              species: b.species,
              possibleSpecies: b.possibleSpecies,
              confidence: b.confidence,
              box: Rectangle<int>(b.boxX, b.boxY, b.boxW, b.boxH),
              centerColor: b.centerColor.toList(),
              cropJpgBytes: b.cropJpgBytes,
            )).toList(),
            detectionTime: Duration(milliseconds: rustResult.detectionMs.toInt()),
            classificationTime: Duration(milliseconds: rustResult.classificationMs.toInt()),
          );
        },
      );
    }

    return result ?? PipelineOutput(
      birds: [],
      detectionTime: Duration.zero,
      classificationTime: Duration.zero,
    );
  }

  /// Classify a single crop image (for manual bounding box, re-classification, etc.)
  ///
  /// Returns ordered list of species names (top-K). Empty list = not a bird.
  Future<List<String>> classifyCrop(
    Uint8List cropBytes, {
    Set<String>? allowedSpecies,
    bool isFallback = false,
  }) async {
    if (!_isInit) return ['Unknown Bird'];

    final result = await rust.classifyCrop(
      cropBytes: cropBytes,
      allowedSpecies: allowedSpecies?.toList(),
      isFallback: isFallback,
    );

    return result.species;
  }

  /// Classify a full image file (for fallback when no birds detected).
  Future<List<String>> classifyFile(
    String imagePath, {
    Set<String>? allowedSpecies,
    bool isFallback = false,
  }) async {
    final bytes = await File(imagePath).readAsBytes();
    return classifyCrop(bytes, allowedSpecies: allowedSpecies, isFallback: isFallback);
  }

  void dispose() {
    _isInit = false;
  }
}
