import 'dart:math';
import 'package:flutter/material.dart';
import 'package:rackery/models/observation.dart';
import 'package:rackery/controllers/checklist_controller.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/ui/widgets/photo_canvas.dart';
import 'package:rackery/ui/widgets/photo_header.dart';

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
  final void Function(Observation obs, int individualIndex)?
  onIndividualSelected;
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

    // With BurstGroup changes, individual identity is represented by the
    // left-to-right local index (li) in each photo. `individualNames` has exactly `count` items.
    if (obs != null) {
      // Nothing needed here right now, we use localIndex directly.
    }

    SourceImage? activeSource;
    if (currentlyDisplayedImage != null) {
      activeSource =
          obs?.sourceImages
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
    final resolvedFuture =
        activeSource.fullImageDisplayPath != null &&
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
          for (int li = 0; li < oBoxes.length; li++) {
            final name = li < o.individualNames.length
                ? o.individualNames[li]
                : '?';
            boxData.add(
              PhotoBoxData(
                box: oBoxes[li],
                name: name,
                species: o.speciesName,
                individualIndex: li,
                obs: o,
              ),
            );
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
          localSelected = selectedIndividualIndices;
        } else {
          localSelected = {for (int i = 0; i < allPhotoBoxes.length; i++) i};
        }

        for (int li = 0; li < allPhotoBoxes.length; li++) {
          if (!localSelected.contains(li) &&
              selectedIndividualIndices.isNotEmpty) {
            continue;
          }

          final name = li < obs.individualNames.length
              ? obs.individualNames[li]
              : '?';

          boxData.add(
            PhotoBoxData(
              box: allPhotoBoxes[li],
              name: name,
              species: obs.speciesName,
              individualIndex: li,
              obs: obs,
            ),
          );
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
                        onIndividualSelected: onIndividualSelected != null
                            ? (data) {
                                onIndividualSelected!(
                                  data.obs,
                                  data.individualIndex,
                                );
                              }
                            : null,
                        onDrawBoundingBox: onDrawBoundingBox,
                      );
                    },
                  );
                },
              ),
            ),
            PhotoHeader(filename: filename, latitude: lat, longitude: lon),
          ],
        ),
      ),
    );
  }
}
