import 'dart:math';
import 'package:flutter/material.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/controllers/checklist_controller.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/ui/widgets/photo_canvas.dart';
import 'package:ebird_generator/ui/widgets/photo_header.dart';

/// The centre pane: shows the full photo(s) for the selected observation with
/// bounding-box overlays. Supports single-image and multi-image (PageView) modes.
class CenterPane extends StatelessWidget {
  final Observation? selectedObservation;
  final Set<int> selectedIndividualIndices;
  final String? currentlyDisplayedImage;
  final Map<String, ExifData> imageExifData;
  final BoundingBoxVisibility boxVisibility;
  final List<Observation> allObservations;
  final ValueChanged<BoundingBoxVisibility> onSetBoxVisibility;
  final Set<String> processingFiles;
  final Future<String?> Function(String imagePath) getDisplayPath;
  final Future<Size> Function(String path) getImageSize;
  final void Function(Observation obs, int globalIndex)? onIndividualSelected;
  final void Function(String imagePath, Rectangle<int> box)? onDrawBoundingBox;

  const CenterPane({
    super.key,
    required this.selectedObservation,
    required this.selectedIndividualIndices,
    required this.currentlyDisplayedImage,
    required this.imageExifData,
    required this.boxVisibility,
    required this.allObservations,
    required this.onSetBoxVisibility,
    required this.processingFiles,
    required this.getDisplayPath,
    required this.getImageSize,
    this.onIndividualSelected,
    this.onDrawBoundingBox,
  });

  @override
  Widget build(BuildContext context) {
    final obs = selectedObservation;

    // Build a global individual index → (imagePath, perPhotoBoxIndex) mapping.
    // Global indices are assigned by iterating sourceImages in order — first
    // photo's boxes get indices 0..n0-1, second photo's get n0..n0+n1-1, etc.
    // Within each photo, boxes are sorted left-to-right to match the order
    // ObservationCard assigns "Individual 1", "Individual 2", etc.
    final Map<int, ({String imagePath, int localIndex})> globalIndexMap = {};
    if (obs != null) {
      int gi = 0;
      for (final src in obs.sourceImages) {
        final boxes = List<Rectangle<int>>.from(
          obs.boxesByImagePath[src.imagePath] ?? [],
        )..sort((a, b) => a.left.compareTo(b.left));
        for (int li = 0; li < boxes.length; li++) {
          globalIndexMap[gi++] = (imagePath: src.imagePath, localIndex: li);
        }
      }
    }

    SourceImage? activeSource;
    if (currentlyDisplayedImage != null) {
      activeSource = obs?.sourceImages
              .where((s) => s.imagePath == currentlyDisplayedImage)
              .firstOrNull ??
          (
            imagePath: currentlyDisplayedImage!,
            fullImageDisplayPath: obs?.fullImageDisplayPath,
          );
    } else if (obs != null && obs.sourceImages.isNotEmpty) {
      activeSource = obs.sourceImages.first;
    }

    if (activeSource == null) {
      return const Expanded(
        flex: 2,
        child: Center(child: Text('Select photos to begin')),
      );
    }

    final rawPath = activeSource.imagePath;
    final resolvedFuture = activeSource.fullImageDisplayPath != null &&
            !activeSource.fullImageDisplayPath!.toLowerCase().endsWith('.heic')
        ? Future.value(activeSource.fullImageDisplayPath)
        : getDisplayPath(rawPath);

    final String filename = rawPath.split('/').last.split('\\').last;
    final exif = imageExifData[rawPath];
    final double? lat = exif?.latitude;
    final double? lon = exif?.longitude;

    List<PhotoBoxData> boxData = [];

    if (boxVisibility == BoundingBoxVisibility.all) {
      for (final o in allObservations) {
        final oBoxes = List<Rectangle<int>>.from(
          o.boxesByImagePath[rawPath] ??
              (o.imagePath == rawPath ? o.boundingBoxes : const []),
        )..sort((a, b) => a.left.compareTo(b.left));

        if (oBoxes.isNotEmpty) {
          int offset = 0;
          for (final src in o.sourceImages) {
            if (src.imagePath == rawPath) break;
            offset += (o.boxesByImagePath[src.imagePath] ?? []).length;
          }
          
          for (int li = 0; li < oBoxes.length; li++) {
            final idx = offset + li;
            final name = idx < o.individualNames.length ? o.individualNames[idx] : '?';
            boxData.add(PhotoBoxData(
              box: oBoxes[li],
              name: name,
              species: o.speciesName,
              globalIndex: idx,
              obs: o,
            ));
          }
        }
      }
    } else {
      final allPhotoBoxes = List<Rectangle<int>>.from(
        obs?.boxesByImagePath[rawPath] ??
            (obs?.imagePath == rawPath ? obs!.boundingBoxes : const []),
      );
      allPhotoBoxes.sort((a, b) => a.left.compareTo(b.left));

      if (obs != null) {
        Set<int> localSelected;
        if (selectedIndividualIndices.isNotEmpty) {
          localSelected = selectedIndividualIndices
              .where((gi) => globalIndexMap[gi]?.imagePath == rawPath)
              .map((gi) => globalIndexMap[gi]!.localIndex)
              .toSet();
        } else {
          localSelected = {for (int i=0; i < allPhotoBoxes.length; i++) i};
        }

        for (int li = 0; li < allPhotoBoxes.length; li++) {
          if (!localSelected.contains(li) && selectedIndividualIndices.isNotEmpty) continue;
          
          final entry = globalIndexMap.entries.firstWhere(
            (e) => e.value.imagePath == rawPath && e.value.localIndex == li,
            orElse: () => const MapEntry(-1, (imagePath: '', localIndex: -1)),
          );
          final gIdx = entry.key;
          final name = (gIdx >= 0 && gIdx < obs.individualNames.length) 
              ? obs.individualNames[gIdx] : '?';

          boxData.add(PhotoBoxData(
            box: allPhotoBoxes[li],
            name: name,
            species: obs.speciesName,
            globalIndex: gIdx,
            obs: obs,
          ));
        }
      }
    }

    return Expanded(
      flex: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder<String?>(
                future: resolvedFuture,
                builder: (context, pathSnap) {
                  final displayPath = pathSnap.data;
                  if (displayPath == null ||
                      displayPath.toLowerCase().endsWith('.heic')) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return FutureBuilder<Size>(
                    future: getImageSize(displayPath),
                    builder: (context, sizeSnap) {
                      if (!sizeSnap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return PhotoCanvas(
                        displayPath: displayPath,
                        rawPath: rawPath,
                        imageSize: sizeSnap.data!,
                        boxData: boxData,
                        boxVisibility: boxVisibility,
                        onSetBoxVisibility: onSetBoxVisibility,
                        isPhotoProcessing: processingFiles.contains(rawPath),
                        onIndividualSelected: onIndividualSelected != null ? (data) {
                          onIndividualSelected!(data.obs, data.globalIndex);
                        } : null,
                        onDrawBoundingBox: onDrawBoundingBox,
                      );
                    },
                  );
                },
              ),
            ),
            PhotoHeader(
              filename: filename,
              latitude: lat,
              longitude: lon,
            ),
          ],
        ),
      ),
    );
  }
}
