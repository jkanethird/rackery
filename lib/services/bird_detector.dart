import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
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

class _TensorPrepData {
  final img.Image image;
  final int targetW;
  final int targetH;
  _TensorPrepData(this.image, this.targetW, this.targetH);
}

// Prepares the entire image as a single tensor for EfficientDet-Lite4
List<List<List<List<int>>>> _prepareSingleTensor(_TensorPrepData data) {
  img.Image imageInput = img.copyResize(
    data.image,
    width: data.targetW,
    height: data.targetH,
    interpolation: img.Interpolation.linear,
  );

  return List.generate(
    1,
    (_) => List.generate(
      data.targetH,
      (y) => List.generate(data.targetW, (x) {
        final pixel = imageInput.getPixel(x, y);
        return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
      }),
    ),
  );
}

class BirdDetector {
  Interpreter? _interpreter;

  Future<void> init() async {
    _interpreter = await Interpreter.fromAsset(
      'assets/efficientdet_lite4.tflite',
    );
  }

  Future<List<BirdCrop>> detectAndCrop(String imagePath) async {
    if (_interpreter == null) {
      throw Exception('Detector not initialized');
    }

    final fileBytes = await File(imagePath).readAsBytes();
    final originalImage = await compute(img.decodeImage, fileBytes);
    if (originalImage == null) return [];

    // EfficientDet-Lite4 expects 512x512 RGB input
    final inputShape = _interpreter!.getInputTensor(0).shape;
    final int targetW = inputShape[1];
    final int targetH = inputShape[2];

    final tensor = await compute(
      _prepareSingleTensor,
      _TensorPrepData(originalImage, targetW, targetH),
    );

    // EfficientDet-Lite4 output map:
    // 0: Locations [1, 25, 4]
    // 1: Classes [1, 25]
    // 2: Scores [1, 25]
    // 3: Count [1]
    Map<int, Object> dynamicOutputs = {
      0: List<List<List<double>>>.filled(
        1,
        List.filled(25, List.filled(4, 0.0)),
      ),
      1: List<List<double>>.filled(1, List.filled(25, 0.0)),
      2: List<List<double>>.filled(1, List.filled(25, 0.0)),
      3: List<double>.filled(1, 0.0),
    };

    _interpreter!.runForMultipleInputs([tensor], dynamicOutputs);

    var locations = dynamicOutputs[0] as List<List<List<double>>>;
    var classes = dynamicOutputs[1] as List<List<double>>;
    var scores = dynamicOutputs[2] as List<List<double>>;
    var counts = dynamicOutputs[3] as List<double>;

    int count = counts[0].toInt();
    List<_RawDetection> rawDetections = [];

    for (int i = 0; i < count; i++) {
      double score = scores[0][i];
      int detectedClass = classes[0][i].toInt();

      // Bird class is 16 in COCO.
      // Lite4 is very accurate, we can trust 0.20 score securely.
      if (score > 0.20 && (detectedClass == 16 || detectedClass == 15)) {
        List<double> box = locations[0][i];

        // EfficientDet outputs coordinates normalized to [0, 1] as [ymin, xmin, ymax, xmax]
        double ymin = box[0].clamp(0.0, 1.0);
        double xmin = box[1].clamp(0.0, 1.0);
        double ymax = box[2].clamp(0.0, 1.0);
        double xmax = box[3].clamp(0.0, 1.0);

        int localX = (xmin * originalImage.width).toInt();
        int localY = (ymin * originalImage.height).toInt();
        int localW = ((xmax - xmin) * originalImage.width).toInt();
        int localH = ((ymax - ymin) * originalImage.height).toInt();

        localX = localX.clamp(0, originalImage.width - 1);
        localY = localY.clamp(0, originalImage.height - 1);
        localW = localW.clamp(1, originalImage.width - localX);
        localH = localH.clamp(1, originalImage.height - localY);

        // Sanity checks
        double aspectRatio = localW / localH;
        if (localW < 10 ||
            localH < 10 ||
            aspectRatio > 5.0 ||
            aspectRatio < 0.20) {
          continue;
        }

        Rectangle<int> birdRect = Rectangle<int>(
          localX,
          localY,
          localW,
          localH,
        );
        rawDetections.add(_RawDetection(birdRect, score));
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
          double intersectArea = (intersect.width * intersect.height)
              .toDouble();
          double area1 = (current.box.width * current.box.height).toDouble();
          double area2 = (existing.box.width * existing.box.height).toDouble();
          double iou = intersectArea / (area1 + area2 - intersectArea);
          double ioMin = intersectArea / min(area1, area2);

          // Since we process the whole image at once, we don't have tile-split fragmentation anymore.
          // Standard IoU / ioMin check is now extremely robust.
          if (iou > 0.30 || ioMin > 0.50) {
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
