import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class BirdCrop {
  final img.Image croppedImage;
  final double confidence;
  final Rectangle<int> box;

  BirdCrop(this.croppedImage, this.confidence, this.box);
}

class _RawDetection {
  final Rectangle<int> box;
  final double score;

  _RawDetection(this.box, this.score);
}

class BirdDetector {
  Interpreter? _interpreter;

  // For EfficientDet-Lite0 Task Library model from TF Hub
  // Usually bird is 16 (0-indexed background might shift it)
  Future<void> init() async {
    _interpreter = await Interpreter.fromAsset(
      'assets/efficientdet_task.tflite',
    );
  }

  Future<List<BirdCrop>> detectAndCrop(String imagePath) async {
    if (_interpreter == null) {
      throw Exception('Detector not initialized');
    }

    final fileBytes = await File(imagePath).readAsBytes();
    final originalImage = img.decodeImage(fileBytes);
    if (originalImage == null) return [];

    // EfficientDet-Lite0 expects 320x320 RGB input
    final inputShape = _interpreter!.getInputTensor(0).shape;
    final int targetW = inputShape[1]; // 320
    final int targetH = inputShape[2]; // 320

    List<_RawDetection> rawDetections = [];

    // Tiling strategy: 3x3 grid with 50% overlap to catch birds on seams
    // We'll iterate row and cols.
    // 3 steps across width means we have 3 tiles: 0..w/2, w/4..3w/4, w/2..w
    // Example: tile size = original/2
    int tileW = originalImage.width ~/ 2;
    int tileH = originalImage.height ~/ 2;
    // Step size is tile/2
    int stepX = tileW ~/ 2;
    int stepY = tileH ~/ 2;

    List<int> xOffsets = [0, stepX, originalImage.width - tileW];
    List<int> yOffsets = [0, stepY, originalImage.height - tileH];

    for (int yOffset in yOffsets) {
      for (int xOffset in xOffsets) {
        // Crop tile from original
        img.Image tile = img.copyCrop(
          originalImage,
          x: xOffset,
          y: yOffset,
          width: tileW,
          height: tileH,
        );

        // Resize to target
        img.Image imageInput = img.copyResize(
          tile,
          width: targetW,
          height: targetH,
        );

        final List<List<List<List<int>>>> input = List.generate(
          1,
          (_) => List.generate(
            targetH,
            (y) => List.generate(targetW, (x) {
              final pixel = imageInput.getPixel(x, y);
              return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
            }),
          ),
        );

        // Safer to just map identically to the test we ran:
        // StatefulPartitionedCall:3 [1, 25, 4] -> Box
        // StatefulPartitionedCall:2 [1, 25] -> Classes
        // StatefulPartitionedCall:1 [1, 25] -> Scores
        // StatefulPartitionedCall:0 [1] -> Count
        Map<int, Object> dynamicOutputs = {
          0: List<List<List<double>>>.filled(
            1,
            List.filled(25, List.filled(4, 0.0)),
          ),
          1: List<List<double>>.filled(1, List.filled(25, 0.0)),
          2: List<List<double>>.filled(1, List.filled(25, 0.0)),
          3: List<double>.filled(1, 0.0),
        };

        _interpreter!.runForMultipleInputs([input], dynamicOutputs);

        var locations = dynamicOutputs[0] as List<List<List<double>>>;
        var classes = dynamicOutputs[1] as List<List<double>>;
        var scores = dynamicOutputs[2] as List<List<double>>;
        var counts = dynamicOutputs[3] as List<double>;

        int count = counts[0].toInt();

        for (int i = 0; i < count; i++) {
          double score = scores[0][i];
          int detectedClass = classes[0][i].toInt();

          // Bird is 16 in COCO.
          // Lowering confidence threshold to 0.25 to catch distant birds but suppress noise (like stray tails).
          if (score > 0.25 && (detectedClass == 16 || detectedClass == 15)) {
            List<double> box = locations[0][i];
            double ymin = box[0];
            double xmin = box[1];
            double ymax = box[2];
            double xmax = box[3];

            // Local tile coordinates
            int localX = (xmin * tileW).toInt();
            int localY = (ymin * tileH).toInt();
            int localW = ((xmax - xmin) * tileW).toInt();
            int localH = ((ymax - ymin) * tileH).toInt();

            // Global image coordinates
            int globalX = xOffset + localX;
            int globalY = yOffset + localY;

            // Constrain
            globalX = globalX.clamp(0, originalImage.width - 1);
            globalY = globalY.clamp(0, originalImage.height - 1);
            localW = localW.clamp(1, originalImage.width - globalX);
            localH = localH.clamp(1, originalImage.height - globalY);

            Rectangle<int> birdRect = Rectangle<int>(
              globalX,
              globalY,
              localW,
              localH,
            );

            // Basic deduplication is deferred to after all crops are collected
            rawDetections.add(_RawDetection(birdRect, score));
          }
        }
      }
    }

    // Sort by confidence descending for proper NMS
    rawDetections.sort((a, b) => b.score.compareTo(a.score));

    List<_RawDetection> finalDetections = [];
    for (var current in rawDetections) {
      bool isDuplicate = false;
      for (var existing in finalDetections) {
        var intersect = existing.box.intersection(current.box);
        if (intersect != null && intersect.width > 0 && intersect.height > 0) {
          double intersectArea = (intersect.width * intersect.height).toDouble();
          double area1 = (current.box.width * current.box.height).toDouble();
          double area2 = (existing.box.width * existing.box.height).toDouble();
          
          double iou = intersectArea / (area1 + area2 - intersectArea);
          double ioMin = intersectArea / min(area1, area2);
          
          // Use typical NMS IoU threshold (0.35) 
          // Use ioMin (0.35) aggressively to catch and destroy small sub-crops (tails/wings) 
          // detected at tile boundaries that are mostly contained within a larger bounding box.
          if (iou > 0.35 || ioMin > 0.35) {
            isDuplicate = true;
            break;
          }
        }
      }
      
      if (!isDuplicate) {
        finalDetections.add(current);
      }
    }

    List<BirdCrop> allCrops = [];
    for (var det in finalDetections) {
      final cropped = img.copyCrop(
        originalImage,
        x: det.box.left,
        y: det.box.top,
        width: det.box.width,
        height: det.box.height,
      );
      allCrops.add(BirdCrop(cropped, det.score, det.box));
    }

    return allCrops;
  }

  void dispose() {
    _interpreter?.close();
  }
}
