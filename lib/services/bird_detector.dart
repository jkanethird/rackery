import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

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

  _RawDetection(this.box, this.score);
}

class _DetectorRequest {
  final Uint8List fileBytes;
  final int interpreterAddress;
  final int targetW;
  final int targetH;

  _DetectorRequest(this.fileBytes, this.interpreterAddress, this.targetW, this.targetH);
}

/// Request for computing all tile pixel data in a background isolate.
class _PrepareTilesRequest {
  final Uint8List fileBytes;
  final int targetW;
  final int targetH;

  _PrepareTilesRequest(this.fileBytes, this.targetW, this.targetH);
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

// ── Shared helpers ─────────────────────────────────────────────────────────

/// Generates overlapping tile rectangles for a given image size.
List<Rectangle<int>> _buildTiles(int origW, int origH) {
  const int tileSize = 1536;
  const int stride = tileSize ~/ 2;

  List<Rectangle<int>> tiles = [Rectangle<int>(0, 0, origW, origH)];

  if (origW > tileSize || origH > tileSize) {
    for (int y = 0; y < origH; y += stride) {
      for (int x = 0; x < origW; x += stride) {
        int cropX = x;
        int cropY = y;

        if (cropX + tileSize > origW) cropX = max(0, origW - tileSize);
        if (cropY + tileSize > origH) cropY = max(0, origH - tileSize);

        int cropW = min(tileSize, origW - cropX);
        int cropH = min(tileSize, origH - cropY);

        tiles.add(Rectangle<int>(cropX, cropY, cropW, cropH));
      }
    }
  }

  return tiles.toSet().toList();
}

/// Builds a [1,H,W,3] int tensor from an img.Image.
List<List<List<List<int>>>> _buildTensor(
  img.Image imageInput,
  int targetW,
  int targetH,
) {
  return List.generate(
    1,
    (_) => List.generate(
      targetH,
      (y) => List.generate(targetW, (x) {
        final pixel = imageInput.getPixel(x, y);
        return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
      }),
    ),
  );
}

/// Allocates fresh TFLite output buffers.
Map<int, Object> _allocateOutputs() => {
  0: List<List<List<double>>>.filled(1, List.filled(25, List.filled(4, 0.0))),
  1: List<List<double>>.filled(1, List.filled(25, 0.0)),
  2: List<List<double>>.filled(1, List.filled(25, 0.0)),
  3: List<double>.filled(1, 0.0),
};

/// Extracts valid bird detections from TFLite inference outputs for one tile.
List<_RawDetection> _extractDetections(
  Map<int, Object> outputs,
  Rectangle<int> tile,
  int origW,
  int origH,
) {
  final locations = outputs[0] as List<List<List<double>>>;
  final classes = outputs[1] as List<List<double>>;
  final scores = outputs[2] as List<List<double>>;
  final counts = outputs[3] as List<double>;

  final int count = counts[0].toInt();
  final List<_RawDetection> detections = [];

  for (int i = 0; i < count; i++) {
    final double score = scores[0][i];
    final int detectedClass = classes[0][i].toInt();

    if (score <= 0.25 || (detectedClass != 16 && detectedClass != 15)) continue;

    final box = locations[0][i];
    final double ymin = box[0].clamp(0.0, 1.0);
    final double xmin = box[1].clamp(0.0, 1.0);
    final double ymax = box[2].clamp(0.0, 1.0);
    final double xmax = box[3].clamp(0.0, 1.0);

    if ((xmin <= 0.02 && tile.left > 0) ||
        (ymin <= 0.02 && tile.top > 0) ||
        (xmax >= 0.98 && tile.right < origW) ||
        (ymax >= 0.98 && tile.bottom < origH)) {
      continue;
    }

    int localW = ((xmax - xmin) * tile.width).toInt();
    int localH = ((ymax - ymin) * tile.height).toInt();
    int globalX = ((xmin * tile.width) + tile.left).toInt();
    int globalY = ((ymin * tile.height) + tile.top).toInt();

    globalX = globalX.clamp(0, origW - 1);
    globalY = globalY.clamp(0, origH - 1);
    localW = localW.clamp(1, origW - globalX);
    localH = localH.clamp(1, origH - globalY);

    final double aspectRatio = localW / localH;
    if (localW < 10 || localH < 10 || aspectRatio > 5.0 || aspectRatio < 0.20) {
      continue;
    }

    detections.add(_RawDetection(Rectangle<int>(globalX, globalY, localW, localH), score));
  }

  return detections;
}

/// Non-maximum suppression: removes duplicate overlapping detections.
List<_RawDetection> _applyNms(List<_RawDetection> rawDetections) {
  rawDetections.sort((a, b) => b.score.compareTo(a.score));

  final List<_RawDetection> kept = [];
  for (var current in rawDetections) {
    bool isDuplicate = false;
    for (int i = 0; i < kept.length; i++) {
      var existing = kept[i];
      final intersect = existing.box.intersection(current.box);
      if (intersect != null && intersect.width > 0 && intersect.height > 0) {
        final double intersectArea = (intersect.width * intersect.height).toDouble();
        final double area1 = (current.box.width * current.box.height).toDouble();
        final double area2 = (existing.box.width * existing.box.height).toDouble();
        final double iou = intersectArea / (area1 + area2 - intersectArea);
        final double ioMin = intersectArea / min(area1, area2);

        final double cx1 = current.box.left + current.box.width / 2;
        final double cy1 = current.box.top + current.box.height / 2;
        final double cx2 = existing.box.left + existing.box.width / 2;
        final double cy2 = existing.box.top + existing.box.height / 2;

        final double centerDist = sqrt(pow(cx1 - cx2, 2) + pow(cy1 - cy2, 2));
        final double distThreshold =
            (current.box.width + existing.box.width +
                current.box.height + existing.box.height) / 8;

        if (iou > 0.10 || ioMin > 0.25 ||
            (intersectArea > 0 && centerDist < distThreshold * 2.2)) {
            
          final int left = min(existing.box.left, current.box.left);
          final int top = min(existing.box.top, current.box.top);
          final int right = max(existing.box.left + existing.box.width, current.box.left + current.box.width);
          final int bottom = max(existing.box.top + existing.box.height, current.box.top + current.box.height);
          
          kept[i] = _RawDetection(
            Rectangle<int>(left, top, right - left, bottom - top),
            max(existing.score, current.score)
          );
          
          isDuplicate = true;
          break;
        }
      }
    }
    if (!isDuplicate) kept.add(current);
  }

  return kept;
}

/// Crops detected birds from the original image, extracts center color, and
/// JPG-encodes each crop.
List<BirdCrop> _cropAndEncode(img.Image originalImage, List<_RawDetection> detections) {
  final List<BirdCrop> crops = [];

  for (final det in detections) {
    final cropped = img.copyCrop(
      originalImage,
      x: det.box.left,
      y: det.box.top,
      width: det.box.width,
      height: det.box.height,
    );

    final w = cropped.width;
    final h = cropped.height;
    final int startX = (w * 0.4).toInt();
    final int startY = (h * 0.4).toInt();
    final int endX = (w * 0.6).toInt();
    final int endY = (h * 0.6).toInt();

    List<double> color = [0.0, 0.0, 0.0];
    if (startX < endX && startY < endY) {
      double sumR = 0, sumG = 0, sumB = 0;
      int count = 0;
      for (int y = startY; y < endY; y++) {
        for (int x = startX; x < endX; x++) {
          final pixel = cropped.getPixel(x, y);
          sumR += pixel.r.toDouble();
          sumG += pixel.g.toDouble();
          sumB += pixel.b.toDouble();
          count++;
        }
      }
      if (count > 0) {
        color = [sumR / count, sumG / count, sumB / count];
      }
    } else if (w > 0 && h > 0) {
      final centerPixel = cropped.getPixel(w ~/ 2, h ~/ 2);
      color = [
        centerPixel.r.toDouble(),
        centerPixel.g.toDouble(),
        centerPixel.b.toDouble(),
      ];
    }

    final jpgBytes = Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
    crops.add(BirdCrop(jpgBytes, color, det.score, det.box));
  }

  return crops;
}

// ── Non-Windows: full pipeline in a single compute isolate ─────────────────

Future<List<BirdCrop>> _detectorWorker(_DetectorRequest data) async {
  final originalImage = img.decodeImage(data.fileBytes);
  if (originalImage == null) return [];

  final interpreter = Interpreter.fromAddress(data.interpreterAddress);

  final int origW = originalImage.width;
  final int origH = originalImage.height;
  final tiles = _buildTiles(origW, origH);

  List<_RawDetection> rawDetections = [];

  for (var tile in tiles) {
    await Future.delayed(Duration.zero);

    final tileImage = img.copyCrop(
      originalImage,
      x: tile.left, y: tile.top, width: tile.width, height: tile.height,
    );
    final imageInput = img.copyResize(
      tileImage, width: data.targetW, height: data.targetH,
      interpolation: img.Interpolation.linear,
    );

    final tensor = _buildTensor(imageInput, data.targetW, data.targetH);
    final outputs = _allocateOutputs();
    interpreter.runForMultipleInputs([tensor], outputs);

    rawDetections.addAll(_extractDetections(outputs, tile, origW, origH));
  }

  final finalDetections = _applyNms(rawDetections);
  return _cropAndEncode(originalImage, finalDetections);
}

// ── Windows: tile prep in compute, inference via IsolateInterpreter ────────

/// Runs in a compute isolate: decodes image, crops/resizes all tiles,
/// packs pixel data into flat Uint8Lists for efficient transfer.
_PrepareTilesResult _prepareTiles(_PrepareTilesRequest req) {
  final image = img.decodeImage(req.fileBytes);
  if (image == null) return _PrepareTilesResult([], [], 0, 0);

  final tiles = _buildTiles(image.width, image.height);
  final List<Uint8List> pixelData = [];
  final List<List<int>> rects = [];

  for (final tile in tiles) {
    final tileImage = img.copyCrop(
      image,
      x: tile.left, y: tile.top, width: tile.width, height: tile.height,
    );
    final resized = img.copyResize(
      tileImage,
      width: req.targetW, height: req.targetH,
      interpolation: img.Interpolation.linear,
    );

    // Pack pixels into flat Uint8List (TypedData = efficient isolate transfer)
    final pixels = Uint8List(req.targetW * req.targetH * 3);
    int idx = 0;
    for (int y = 0; y < req.targetH; y++) {
      for (int x = 0; x < req.targetW; x++) {
        final p = resized.getPixel(x, y);
        pixels[idx++] = p.r.toInt();
        pixels[idx++] = p.g.toInt();
        pixels[idx++] = p.b.toInt();
      }
    }
    pixelData.add(pixels);
    rects.add([tile.left, tile.top, tile.width, tile.height]);
  }

  return _PrepareTilesResult(pixelData, rects, image.width, image.height);
}

/// Runs in a compute isolate: NMS + crop + JPG encode.
List<BirdCrop> _postProcessDetections(_PostProcessRequest req) {
  final originalImage = img.decodeImage(req.fileBytes);
  if (originalImage == null) return [];

  final rawDetections = req.detections
      .map((d) => _RawDetection(
            Rectangle<int>(d[0], d[1], d[2], d[3]),
            d[4] / 1000.0,
          ))
      .toList();

  final finalDetections = _applyNms(rawDetections);
  return _cropAndEncode(originalImage, finalDetections);
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
        fileBytes, _interpreter!.address, targetW, targetH,
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
    List<List<int>> rawDetections = [];

    for (int ti = 0; ti < prepared.tilePixels.length; ti++) {
      final pixels = prepared.tilePixels[ti];
      final outputs = _allocateOutputs();
      await _isolateInterpreter!.runForMultipleInputs([pixels], outputs);

      final rect = prepared.tileRects[ti];
      final tile = Rectangle<int>(rect[0], rect[1], rect[2], rect[3]);
      final tileDets = _extractDetections(
        outputs, tile, prepared.origW, prepared.origH,
      );

      for (final det in tileDets) {
        rawDetections.add([
          det.box.left, det.box.top, det.box.width, det.box.height,
          (det.score * 1000).toInt(),
        ]);
      }
    }

    if (rawDetections.isEmpty) return [];

    // Step 3: NMS + crop + encode in compute isolate
    return await compute(
      _postProcessDetections,
      _PostProcessRequest(fileBytes, rawDetections),
    );
  }

  void dispose() {
    _isolateInterpreter?.close();
    _interpreter?.close();
  }
}
