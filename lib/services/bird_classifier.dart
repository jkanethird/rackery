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

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

/// Confidence threshold below which an auto-detected crop is rejected as
/// "not a bird".  Tunable — start conservative and lower if real birds
/// are being dropped.
const double _kMinConfidence = 0.18;

/// Standard CLIP image-normalisation constants (mean / std per channel).
const _kMean = [0.48145466, 0.4578275, 0.40821073];
const _kStd = [0.26862954, 0.26130258, 0.27577711];

/// How many top-K species to return.
const int _kTopK = 5;

/// Bonus added to the cosine similarity score for species present on the local checklist.
const double _kLocalBonus = 0.08;

class BirdClassifier {
  final _ort = OnnxRuntime();
  OrtSession? _session;

  /// Pre-computed L2-normalised text embeddings, shape [N × D], stored
  /// row-major.
  Float32List? _speciesEmbeddings;

  /// Ordered list of common names parallel to [_speciesEmbeddings].
  List<String>? _speciesLabels;

  /// Embedding dimensionality (typically 512).
  int _embeddingDim = 0;

  /// Number of species.
  int _numSpecies = 0;

  /// Name of the ONNX model input node.
  String? _inputName;

  /// Name of the ONNX model output node.
  String? _outputName;

  bool get isReady => _session != null;

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  Future<void> init() async {
    // 1. Load ONNX session with CUDA → CPU fallback.
    final available = await _ort.getAvailableProviders();
    final providers = <OrtProvider>[];
    if (available.contains(OrtProvider.CUDA)) {
      providers.add(OrtProvider.CUDA);
      debugPrint('BioCLIP: CUDA execution provider available');
    }
    providers.add(OrtProvider.CPU);

    _session = await _ort.createSessionFromAsset(
      'assets/bioclip_vision.onnx',
      options: OrtSessionOptions(providers: providers),
    );
    _inputName = _session!.inputNames.first;
    _outputName = _session!.outputNames.first;
    debugPrint(
      'BioCLIP session loaded (inputs=${_session!.inputNames}, '
      'outputs=${_session!.outputNames})',
    );

    // 2. Load pre-computed species embeddings from binary asset.
    //    Format: [int32 numSpecies, int32 dim, float32 × numSpecies × dim]
    final embData = await rootBundle.load('assets/species_embeddings.bin');
    final header = embData.buffer.asByteData();
    _numSpecies = header.getInt32(0, Endian.little);
    _embeddingDim = header.getInt32(4, Endian.little);
    _speciesEmbeddings = embData.buffer.asFloat32List(8); // skip 8-byte header
    debugPrint(
      'BioCLIP embeddings loaded: $_numSpecies species × $_embeddingDim dim',
    );

    // 3. Load ordered species labels.
    final labelsJson = await rootBundle.loadString(
      'assets/species_labels.json',
    );
    _speciesLabels = List<String>.from(jsonDecode(labelsJson) as List);
    if (_speciesLabels!.length != _numSpecies) {
      throw StateError(
        'Label count (${_speciesLabels!.length}) != embedding count ($_numSpecies)',
      );
    }
  }

  void dispose() {
    _session?.close();
    _session = null;
  }

  // ─── Public API (matches old BirdClassifier signature) ────────────────

  /// Classifies the bird in the image at [imagePath].
  ///
  /// When [allowNoBird] is true (auto-detection pipeline), the classifier
  /// will return an empty list if the best-match confidence is below the
  /// threshold — the crop is considered to not contain a bird.
  ///
  /// When [allowNoBird] is false (manual bounding box), species suggestions
  /// are always returned regardless of confidence.
  Future<List<String>> classifyFile(
    String imagePath, {
    Rectangle<int>? box,
    double? latitude,
    double? longitude,
    DateTime? photoDate,
    bool allowNoBird = false,
    bool isFallback = false,
    Set<String>? allowedSpeciesKeys,
  }) async {
    final bytes = await File(imagePath).readAsBytes();
    final decoded = await compute(img.decodeImage, bytes);
    if (decoded == null) return ['Unknown Bird'];

    // Crop to bounding box if provided.
    final cropped = box != null
        ? img.copyCrop(
            decoded,
            x: box.left,
            y: box.top,
            width: box.width,
            height: box.height,
          )
        : decoded;

    return _classifyImage(
      cropped,
      allowNoBird: allowNoBird,
      isFallback: isFallback,
      allowedSpeciesKeys: allowedSpeciesKeys,
    );
  }

  /// Classifies a single detected bird crop.
  ///
  /// Uses [cropBytes] (JPEG of the crop) for high-resolution input.
  Future<List<String>> classifyCrop(
    String imagePath, {
    required Rectangle<int> box,
    double? latitude,
    double? longitude,
    DateTime? photoDate,
    bool allowNoBird = false,
    Set<String>? allowedSpeciesKeys,
    Uint8List? cropBytes,
  }) async {
    img.Image? image;
    if (cropBytes != null) {
      image = await compute(img.decodeImage, cropBytes);
    }
    if (image == null) {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = await compute(img.decodeImage, bytes);
      if (decoded == null) return ['Unknown Bird'];
      image = img.copyCrop(
        decoded,
        x: box.left,
        y: box.top,
        width: box.width,
        height: box.height,
      );
    }

    return _classifyImage(
      image,
      allowNoBird: allowNoBird,
      allowedSpeciesKeys: allowedSpeciesKeys,
    );
  }

  // ─── Core inference ───────────────────────────────────────────────────

  Future<List<String>> _classifyImage(
    img.Image image, {
    required bool allowNoBird,
    bool isFallback = false,
    Set<String>? allowedSpeciesKeys,
  }) async {
    if (!isReady) return ['Unknown Bird'];

    try {
      // 1. Preprocess: resize → normalise → CHW Float32List.
      final tensor = await compute(_preprocessImage, image);

      // 2. Run ONNX inference.
      final inputOrt = await OrtValue.fromList(tensor, [1, 3, 224, 224]);
      final outputs = await _session!.run({_inputName!: inputOrt});
      final outputOrt = outputs[_outputName]!;

      // 3. Extract raw embedding and L2-normalise.
      final rawEmbedding = await outputOrt.asFlattenedList();
      final embedding = Float32List.fromList(
        rawEmbedding.map((e) => (e as num).toDouble()).toList(),
      );
      _l2Normalize(embedding);

      // 4. Compute cosine similarities against all species.
      final similarities = _cosineSimilarities(embedding, allowedSpeciesKeys);

      // 5. Dispose ORT resources.
      inputOrt.dispose();
      outputOrt.dispose();
      for (final v in outputs.values) {
        if (v != outputOrt) v.dispose();
      }

      // 6. Rank and threshold.
      final indices = List<int>.generate(_numSpecies, (i) => i);
      indices.retainWhere((i) {
        final label = _speciesLabels![i];
        if (label.contains('/')) return false;
        if (label.contains(' x ')) return false;
        if (label.contains('(hybrid)')) return false;
        return true;
      });
      indices.sort((a, b) => similarities[b].compareTo(similarities[a]));

      final topScore = similarities[indices[0]];
      debugPrint(
        'BioCLIP top-1: ${_speciesLabels![indices[0]]} '
        '(score=${topScore.toStringAsFixed(3)})',
      );

      // Check confidence based on raw score (without local bonus)
      final topSpeciesLabel = _speciesLabels![indices[0]];
      final bool hasBonus =
          allowedSpeciesKeys != null &&
          allowedSpeciesKeys.contains(topSpeciesLabel);
      final rawScore = topScore - (hasBonus ? _kLocalBonus : 0.0);
      final threshold = isFallback ? 0.25 : _kMinConfidence;

      // If auto-detect and confidence is too low, reject as non-bird.
      if (allowNoBird && rawScore < threshold) {
        debugPrint(
          'BioCLIP: raw confidence $rawScore < $threshold (fallback=$isFallback) → rejected',
        );
        return [];
      }

      return indices.take(_kTopK).map((i) => _speciesLabels![i]).toList();
    } catch (e) {
      debugPrint('BioCLIP inference error: $e');
      return ['Unknown Bird'];
    }
  }

  // ─── Cosine similarity ─────────────────────────────────────────────────

  /// Dot product of the image embedding against every species embedding.
  /// Both are assumed to be L2-normalised, so dot = cosine similarity.
  /// If [allowedSpeciesKeys] is provided, applies a bonus to those species.
  Float32List _cosineSimilarities(
    Float32List imageEmb,
    Set<String>? allowedSpeciesKeys,
  ) {
    final sims = Float32List(_numSpecies);
    final emb = _speciesEmbeddings!;

    for (int i = 0; i < _numSpecies; i++) {
      double dot = 0.0;
      final offset = i * _embeddingDim;
      for (int j = 0; j < _embeddingDim; j++) {
        dot += imageEmb[j] * emb[offset + j];
      }

      // Apply local bird bonus (Soft Masking)
      if (allowedSpeciesKeys != null &&
          allowedSpeciesKeys.contains(_speciesLabels![i])) {
        dot += _kLocalBonus;
      }

      sims[i] = dot;
    }
    return sims;
  }

  /// In-place L2-normalisation.
  void _l2Normalize(Float32List v) {
    double norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < v.length; i++) {
        v[i] /= norm;
      }
    }
  }
}

// ─── Image preprocessing (runs in isolate via compute()) ─────────────────

/// Resizes to 224×224, converts to CHW float32 with CLIP normalisation.
/// This is a top-level function so it can be used with [compute].
Float32List _preprocessImage(img.Image image) {
  // Resize to 224×224 using bilinear interpolation.
  final resized = img.copyResize(
    image,
    width: 224,
    height: 224,
    interpolation: img.Interpolation.linear,
  );

  // Convert to CHW float32 with CLIP mean/std normalisation.
  final result = Float32List(3 * 224 * 224);
  int idx = 0;
  for (int c = 0; c < 3; c++) {
    for (int y = 0; y < 224; y++) {
      for (int x = 0; x < 224; x++) {
        final pixel = resized.getPixel(x, y);
        final double raw;
        switch (c) {
          case 0:
            raw = pixel.r / 255.0;
          case 1:
            raw = pixel.g / 255.0;
          case 2:
            raw = pixel.b / 255.0;
          default:
            raw = 0.0;
        }
        result[idx++] = (raw - _kMean[c]) / _kStd[c];
      }
    }
  }
  return result;
}
