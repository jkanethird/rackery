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

part of 'bird_detector.dart';

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
      x: tile.left,
      y: tile.top,
      width: tile.width,
      height: tile.height,
    );
    final imageInput = img.copyResize(
      tileImage,
      width: data.targetW,
      height: data.targetH,
      interpolation: img.Interpolation.linear,
    );

    final tensor = _buildTensor(imageInput, data.targetW, data.targetH);
    final outputs = _allocateOutputs();
    interpreter.runForMultipleInputs([tensor], outputs);

    rawDetections.addAll(_extractDetections(outputs, tile, origW, origH));
  }

  final finalDetections = _applyNms(rawDetections);

  final reconciledDetections = await _reconcileAbuttingBoxes(
    finalDetections,
    origW,
    origH,
    (customTiles) async {
      List<_RawDetection> customDetections = [];
      for (var tile in customTiles) {
        await Future.delayed(Duration.zero);
        final tileImage = img.copyCrop(
          originalImage,
          x: tile.left,
          y: tile.top,
          width: tile.width,
          height: tile.height,
        );
        final imageInput = img.copyResize(
          tileImage,
          width: data.targetW,
          height: data.targetH,
          interpolation: img.Interpolation.linear,
        );

        final tensor = _buildTensor(imageInput, data.targetW, data.targetH);
        final outputs = _allocateOutputs();
        interpreter.runForMultipleInputs([tensor], outputs);

        customDetections.addAll(
          _extractDetections(outputs, tile, origW, origH),
        );
      }
      return _applyNms(customDetections);
    },
  );

  return _cropAndEncode(originalImage, reconciledDetections);
}

// ── Windows: tile prep in compute, inference via IsolateInterpreter ────────

/// Runs in a compute isolate: decodes image, crops/resizes all tiles,
/// packs pixel data into flat Uint8Lists for efficient transfer.
_PrepareTilesResult _prepareTiles(_PrepareTilesRequest req) {
  final image = img.decodeImage(req.fileBytes);
  if (image == null) return _PrepareTilesResult([], [], 0, 0);

  final List<Rectangle<int>> tiles;
  if (req.customTiles != null) {
    tiles = req.customTiles!
        .map((rect) => Rectangle<int>(rect[0], rect[1], rect[2], rect[3]))
        .toList();
  } else {
    tiles = _buildTiles(image.width, image.height);
  }

  final List<Uint8List> pixelData = [];
  final List<List<int>> rects = [];

  for (final tile in tiles) {
    final tileImage = img.copyCrop(
      image,
      x: tile.left,
      y: tile.top,
      width: tile.width,
      height: tile.height,
    );
    final resized = img.copyResize(
      tileImage,
      width: req.targetW,
      height: req.targetH,
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
      .map(
        (d) => _RawDetection(
          Rectangle<int>(d[0], d[1], d[2], d[3]),
          d[4] / 1000.0,
        ),
      )
      .toList();

  final finalDetections = _applyNms(rawDetections);
  return _cropAndEncode(originalImage, finalDetections);
}
