import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class BirdClassifier {
  Interpreter? _interpreter;
  List<String>? _labels;

  Future<void> init() async {
    _interpreter = await Interpreter.fromAsset(
      'assets/aiy_vision_classifier_birds_v1.tflite',
    );
    final labelData = await rootBundle.loadString(
      'assets/aiy_birds_labels.txt',
    );
    _labels = labelData
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<String?> classify(img.Image image) async {
    if (_interpreter == null || _labels == null) {
      throw Exception('Classifier not initialized');
    }

    // MobileNet V1 224 expects 224x224 RGB
    final imageInput = img.copyResize(image, width: 224, height: 224);

    // Create a 4D tensor: [1, 224, 224, 3] of type uint8
    final inputShape = _interpreter!.getInputTensor(0).shape;
    if (inputShape[1] != 224 || inputShape[2] != 224 || inputShape[3] != 3) {
      throw Exception('Unexpected input shape: $inputShape');
    }

    // Prepare input buffer (flat list) since tflite_flutter works well with flat buffers sometimes,
    // or nested lists. We'll use flat 1D list and reshape if needed.
    final List<List<List<List<int>>>> input = List.generate(
      1,
      (_) => List.generate(
        224,
        (y) => List.generate(224, (x) {
          final pixel = imageInput.getPixel(x, y);
          return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        }),
      ),
    );

    // Prepare output buffer [1, 1001] for quantized mobilenet
    final outputShape = _interpreter!.getOutputTensor(0).shape;
    final numClasses = outputShape[1];
    var output = List<List<int>>.filled(1, List<int>.filled(numClasses, 0));

    // Run inference
    _interpreter!.run(input, output);

    // Find highest probability
    int bestIndex = 0;
    int maxProb = 0;
    for (int i = 0; i < numClasses; i++) {
      if (output[0][i] > maxProb) {
        maxProb = output[0][i];
        bestIndex = i;
      }
    }

    // Low confidence threshold handling (quant returns 0-255 mapped to probabilities)
    if (maxProb < 50) return "Unknown Bird (Low Confidence)";

    // AIY Birds model has 965 classes, but 964 labels (index 0 is Background)
    if (numClasses == _labels!.length + 1) {
      if (bestIndex == 0) return "Background / No Bird Detected";
      return _labels![bestIndex - 1];
    }

    return _labels![bestIndex];
  }

  void dispose() {
    _interpreter?.close();
  }
}
