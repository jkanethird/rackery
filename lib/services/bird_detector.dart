import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class BirdCrop {
  final Uint8List croppedJpgBytes;
  final List<double> centerColor;
  final double confidence;
  final Rectangle<int> box;

  BirdCrop(this.croppedJpgBytes, this.centerColor, this.confidence, this.box);
}

class _RawDetection {
  final Rectangle<int> box;
  final double score;

  _RawDetection(this.box, this.score);
}

class _DetectorRequest {
  final Uint8List fileBytes;
  final int? interpreterAddress;
  final Uint8List? modelBytes;
  final int targetW;
  final int targetH;

  _DetectorRequest(
    this.fileBytes,
    this.interpreterAddress,
    this.modelBytes,
    this.targetW,
    this.targetH,
  );
}

List<BirdCrop> _detectorWorker(_DetectorRequest data) {
  final originalImage = img.decodeImage(data.fileBytes);
  if (originalImage == null) return [];

  late Interpreter interpreter;
  bool closeInterpreter = false;

  if (Platform.isWindows) {
    interpreter = Interpreter.fromBuffer(data.modelBytes!);
    closeInterpreter = true;
  } else {
    interpreter = Interpreter.fromAddress(data.interpreterAddress!);
  }

  final int origW = originalImage.width;
  final int origH = originalImage.height;

  int tileSize = 1536;
  int stride = tileSize ~/ 2;

  List<Rectangle<int>> tiles = [];
  tiles.add(Rectangle<int>(0, 0, origW, origH));

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

  tiles = tiles.toSet().toList();
  List<_RawDetection> rawDetections = [];

  for (var tile in tiles) {
    img.Image tileImage = img.copyCrop(
      originalImage,
      x: tile.left,
      y: tile.top,
      width: tile.width,
      height: tile.height,
    );

    img.Image imageInput = img.copyResize(
      tileImage,
      width: data.targetW,
      height: data.targetH,
      interpolation: img.Interpolation.linear,
    );

    var tensor = List.generate(
      1,
      (_) => List.generate(
        data.targetH,
        (y) => List.generate(data.targetW, (x) {
          final pixel = imageInput.getPixel(x, y);
          return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        }),
      ),
    );

    Map<int, Object> dynamicOutputs = {
      0: List<List<List<double>>>.filled(
        1,
        List.filled(25, List.filled(4, 0.0)),
      ),
      1: List<List<double>>.filled(1, List.filled(25, 0.0)),
      2: List<List<double>>.filled(1, List.filled(25, 0.0)),
      3: List<double>.filled(1, 0.0),
    };

    interpreter.runForMultipleInputs([tensor], dynamicOutputs);

    var locations = dynamicOutputs[0] as List<List<List<double>>>;
    var classes = dynamicOutputs[1] as List<List<double>>;
    var scores = dynamicOutputs[2] as List<List<double>>;
    var counts = dynamicOutputs[3] as List<double>;

    int count = counts[0].toInt();

    for (int i = 0; i < count; i++) {
      double score = scores[0][i];
      int detectedClass = classes[0][i].toInt();

      if (score > 0.25 && (detectedClass == 16 || detectedClass == 15)) {
        List<double> box = locations[0][i];

        double ymin = box[0].clamp(0.0, 1.0);
        double xmin = box[1].clamp(0.0, 1.0);
        double ymax = box[2].clamp(0.0, 1.0);
        double xmax = box[3].clamp(0.0, 1.0);

        bool touchesLeftSeam = (xmin <= 0.02 && tile.left > 0);
        bool touchesTopSeam = (ymin <= 0.02 && tile.top > 0);
        bool touchesRightSeam = (xmax >= 0.98 && tile.right < origW);
        bool touchesBottomSeam = (ymax >= 0.98 && tile.bottom < origH);

        if (touchesLeftSeam ||
            touchesTopSeam ||
            touchesRightSeam ||
            touchesBottomSeam) {
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

        double aspectRatio = localW / localH;
        if (localW < 10 ||
            localH < 10 ||
            aspectRatio > 5.0 ||
            aspectRatio < 0.20) {
          continue;
        }

        Rectangle<int> birdRect = Rectangle<int>(
          globalX,
          globalY,
          localW,
          localH,
        );
        rawDetections.add(_RawDetection(birdRect, score));
      }
    }
  }

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

        double cx1 = current.box.left + current.box.width / 2;
        double cy1 = current.box.top + current.box.height / 2;
        double cx2 = existing.box.left + existing.box.width / 2;
        double cy2 = existing.box.top + existing.box.height / 2;

        double centerDist = sqrt(pow(cx1 - cx2, 2) + pow(cy1 - cy2, 2));
        double distThreshold =
            (current.box.width +
                existing.box.width +
                current.box.height +
                existing.box.height) /
            8;

        if (iou > 0.20 ||
            ioMin > 0.40 ||
            (intersectArea > 0 && centerDist < distThreshold * 1.5)) {
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

    // Extract center color for clustering
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
    allCrops.add(BirdCrop(jpgBytes, color, det.score, det.box));
  }

  if (closeInterpreter) {
    interpreter.close();
  }

  return allCrops;
}

class BirdDetector {
  Interpreter? _interpreter;
  Uint8List? _modelBytes;

  Future<void> init() async {
    final byteData = await rootBundle.load('assets/efficientdet_lite4.tflite');
    _modelBytes = byteData.buffer.asUint8List();

    final options = InterpreterOptions()
      ..threads = min(4, Platform.numberOfProcessors);
    _interpreter = Interpreter.fromBuffer(
      _modelBytes!,
      options: options,
    );
  }

  Future<List<BirdCrop>> detectAndCrop(String imagePath) async {
    if (_interpreter == null) {
      throw Exception('Detector not initialized');
    }

    final fileBytes = await File(imagePath).readAsBytes();

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final int targetW = inputShape[1];
    final int targetH = inputShape[2];

    final request = _DetectorRequest(
      fileBytes,
      Platform.isWindows ? null : _interpreter!.address,
      Platform.isWindows ? _modelBytes : null,
      targetW,
      targetH,
    );

    return await compute(_detectorWorker, request);
  }

  void dispose() {
    _interpreter?.close();
  }
}
