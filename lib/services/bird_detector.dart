import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

part 'detection_helpers.dart';
part 'detection_reconciler.dart';
part 'detection_pipelines.dart';

// ── Public types ───────────────────────────────────────────────────────────

class BirdCrop {
  final Uint8List croppedJpgBytes;
  final List<double> centerColor;
  final double confidence;
  final Rectangle<int> box;

  BirdCrop(this.croppedJpgBytes, this.centerColor, this.confidence, this.box);
}

// ── Internal types ─────────────────────────────────────────────────────────

class _RawDetection {
  final Rectangle<int> box;
  final double score;
  final Rectangle<int>? sourceTile;

  _RawDetection(this.box, this.score, [this.sourceTile]);
}

class _DetectorRequest {
  final Uint8List fileBytes;
  final int interpreterAddress;
  final int targetW;
  final int targetH;

  _DetectorRequest(
    this.fileBytes,
    this.interpreterAddress,
    this.targetW,
    this.targetH,
  );
}

/// Request for computing all tile pixel data in a background isolate.
class _PrepareTilesRequest {
  final Uint8List fileBytes;
  final int targetW;
  final int targetH;
  final List<List<int>>? customTiles;

  _PrepareTilesRequest(
    this.fileBytes,
    this.targetW,
    this.targetH, [
    this.customTiles,
  ]);
}

/// Result from the tile preparation compute isolate.
/// Uses only primitives and Uint8List for efficient isolate transfer.
class _PrepareTilesResult {
  /// Flat pixel data (RGB) per tile, each Uint8List is targetW*targetH*3 bytes.
  final List<Uint8List> tilePixels;

  /// Tile rectangles as [x, y, w, h] per tile.
  final List<List<int>> tileRects;

  final int origW;
  final int origH;

  _PrepareTilesResult(this.tilePixels, this.tileRects, this.origW, this.origH);
}

/// Request for post-processing in a compute isolate.
class _PostProcessRequest {
  final Uint8List fileBytes;
  final List<List<int>> detections; // [x, y, w, h, score*1000]

  _PostProcessRequest(this.fileBytes, this.detections);
}

// ── BirdDetector class ─────────────────────────────────────────────────────

class BirdDetector {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;

  Future<void> init() async {
    final options = InterpreterOptions()
      ..threads = min(4, Platform.numberOfProcessors);

    // Enable XNNPack delegate for SIMD-optimized CPU inference.
    if (Platform.isWindows) {
      try {
        options.addDelegate(XNNPackDelegate());
      } catch (_) {
        // XNNPack not available in the loaded TFLite DLL
      }
    }

    _interpreter = await Interpreter.fromAsset(
      'assets/efficientdet_lite4.tflite',
      options: options,
    );

    // Use IsolateInterpreter on Windows to run inference off the main thread.
    if (Platform.isWindows) {
      _isolateInterpreter = await IsolateInterpreter.create(
        address: _interpreter!.address,
      );
    }
  }

  Future<List<BirdCrop>> detectAndCrop(String imagePath) async {
    if (_interpreter == null) {
      throw Exception('Detector not initialized');
    }

    final fileBytes = await File(imagePath).readAsBytes();

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final int targetW = inputShape[1];
    final int targetH = inputShape[2];

    if (Platform.isWindows) {
      return await _detectWindows(fileBytes, targetW, targetH);
    } else {
      final request = _DetectorRequest(
        fileBytes,
        _interpreter!.address,
        targetW,
        targetH,
      );
      return await compute(_detectorWorker, request);
    }
  }

  /// Windows pipeline — fully async, no heavy work on main isolate.
  ///
  /// 1. compute() isolate: decode + crop + resize all tiles → flat Uint8Lists
  /// 2. Main isolate: pass flat pixels to IsolateInterpreter (async inference)
  /// 3. compute() isolate: NMS + crop + JPG encode
  Future<List<BirdCrop>> _detectWindows(
    Uint8List fileBytes,
    int targetW,
    int targetH,
  ) async {
    // Step 1: All heavy image ops in compute isolate
    final prepared = await compute(
      _prepareTiles,
      _PrepareTilesRequest(fileBytes, targetW, targetH),
    );

    if (prepared.tilePixels.isEmpty) return [];

    // Step 2: Inference via IsolateInterpreter (async, no UI blocking)
    List<_RawDetection> rawDetections = [];

    for (int ti = 0; ti < prepared.tilePixels.length; ti++) {
      final pixels = prepared.tilePixels[ti];
      final outputs = _allocateOutputs();
      await _isolateInterpreter!.runForMultipleInputs([pixels], outputs);

      final rect = prepared.tileRects[ti];
      final tile = Rectangle<int>(rect[0], rect[1], rect[2], rect[3]);
      rawDetections.addAll(
        _extractDetections(outputs, tile, prepared.origW, prepared.origH),
      );
    }

    if (rawDetections.isEmpty) return [];

    final nmsDetections = _applyNms(rawDetections);

    final reconciledDetections = await _reconcileAbuttingBoxes(
      nmsDetections,
      prepared.origW,
      prepared.origH,
      (customTiles) async {
        if (customTiles.isEmpty) return [];

        final prepCust = await compute(
          _prepareTiles,
          _PrepareTilesRequest(
            fileBytes,
            targetW,
            targetH,
            customTiles.map((r) => [r.left, r.top, r.width, r.height]).toList(),
          ),
        );

        List<_RawDetection> customDets = [];
        for (int ti = 0; ti < prepCust.tilePixels.length; ti++) {
          final pixels = prepCust.tilePixels[ti];
          final outputs = _allocateOutputs();
          await _isolateInterpreter!.runForMultipleInputs([pixels], outputs);

          final rect = prepCust.tileRects[ti];
          final tile = Rectangle<int>(rect[0], rect[1], rect[2], rect[3]);
          customDets.addAll(
            _extractDetections(outputs, tile, prepCust.origW, prepCust.origH),
          );
        }
        return _applyNms(customDets);
      },
    );

    if (reconciledDetections.isEmpty) return [];

    List<List<int>> finalFormattedList = reconciledDetections
        .map(
          (d) => [
            d.box.left,
            d.box.top,
            d.box.width,
            d.box.height,
            (d.score * 1000).toInt(),
          ],
        )
        .toList();

    // Step 3: NMS (noop since already applied) + crop + encode in compute isolate
    return await compute(
      _postProcessDetections,
      _PostProcessRequest(fileBytes, finalFormattedList),
    );
  }

  void dispose() {
    _isolateInterpreter?.close();
    _interpreter?.close();
  }
}
