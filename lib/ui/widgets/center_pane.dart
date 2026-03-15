import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/geo_region_service.dart';
import 'package:ebird_generator/ui/widgets/bounding_box_painter.dart';

/// The centre pane: shows the full photo(s) for the selected observation with
/// bounding-box overlays. Supports single-image and multi-image (PageView) modes.
class CenterPane extends StatelessWidget {
  final Observation? selectedObservation;
  final Set<int> selectedIndividualIndices;
  final String? currentlyDisplayedImage;
  final Map<String, ExifData> imageExifData;
  final int currentPage;
  final PageController pageController;
  final Future<String?> Function(String imagePath) getDisplayPath;
  final Future<Size> Function(String path) getImageSize;
  final void Function(int page, String imagePath) onPageChanged;

  const CenterPane({
    super.key,
    required this.selectedObservation,
    required this.selectedIndividualIndices,
    required this.currentlyDisplayedImage,
    required this.imageExifData,
    required this.currentPage,
    required this.pageController,
    required this.getDisplayPath,
    required this.getImageSize,
    required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    final obs = selectedObservation;
    List<SourceImage>? sources;

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

    if (obs != null) {
      if (selectedIndividualIndices.isNotEmpty) {
        // Find the set of photos that contain any selected individual.
        final selectedPaths = selectedIndividualIndices
            .where(globalIndexMap.containsKey)
            .map((gi) => globalIndexMap[gi]!.imagePath)
            .toSet();
        sources = obs.sourceImages
            .where((src) => selectedPaths.contains(src.imagePath))
            .toList();
        // Fallback: if the mapping produced no results (no-box individuals),
        // show all photos so the user at least sees something.
        if (sources.isEmpty) sources = obs.sourceImages;
      } else {
        sources = obs.sourceImages;
      }
    } else if (currentlyDisplayedImage != null) {
      sources = [
        (
          imagePath: currentlyDisplayedImage!,
          fullImageDisplayPath: obs?.fullImageDisplayPath,
        ),
      ];
    }

    if (sources == null || sources.isEmpty) {
      return const Expanded(
        flex: 2,
        child: Center(child: Text('Select photos to begin')),
      );
    }

    final isMulti = sources.length > 1;

    Widget photoCard(SourceImage src) {
      final rawPath = src.imagePath;
      final resolvedFuture =
          src.fullImageDisplayPath != null &&
              !src.fullImageDisplayPath!.toLowerCase().endsWith('.heic')
          ? Future.value(src.fullImageDisplayPath)
          : getDisplayPath(rawPath);

      final filename = rawPath.split('/').last.split('\\').last;
      final exif = imageExifData[rawPath];
      final lat = exif?.latitude;
      final lon = exif?.longitude;

      Widget buildStack(String displayPath, Size imgSize) {
        final allPhotoBoxes = List<Rectangle<int>>.from(
          obs?.boxesByImagePath[rawPath] ??
              (obs?.imagePath == rawPath ? obs!.boundingBoxes : const []),
        );
        allPhotoBoxes.sort((a, b) => a.left.compareTo(b.left));

        List<Rectangle<int>> photoBoxes = allPhotoBoxes;
        if (selectedIndividualIndices.isNotEmpty && allPhotoBoxes.isNotEmpty) {
          // Map selected global indices to the local box indices for THIS photo.
          final localSelected = selectedIndividualIndices
              .where((gi) => globalIndexMap[gi]?.imagePath == rawPath)
              .map((gi) => globalIndexMap[gi]!.localIndex)
              .toSet();
          if (localSelected.isNotEmpty) {
            photoBoxes = [
              for (int li = 0; li < allPhotoBoxes.length; li++)
                if (localSelected.contains(li)) allPhotoBoxes[li],
            ];
          }
        }

        return Stack(
          alignment: Alignment.center,
          fit: StackFit.loose,
          children: [
            Image.file(
              File(displayPath),
              width: double.infinity,
              fit: BoxFit.contain,
            ),
            if (obs != null && photoBoxes.isNotEmpty)
              Positioned.fill(
                child: CustomPaint(
                  painter: BoundingBoxPainter(
                    boxes: photoBoxes,
                    imageSize: imgSize,
                  ),
                ),
              ),
          ],
        );
      }

      final captions = <Widget>[
        const SizedBox(height: 4),
        if (lat != null && lon != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 12, color: Colors.blueGrey),
              const SizedBox(width: 3),
              Flexible(
                child: SelectableText(
                  GeoRegionService.describe(lat, lon),
                  style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        const SizedBox(height: 2),
        SelectableText(
          filename,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ];

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: InteractiveViewer(
              child: LayoutBuilder(
                builder: (context, constraints) => FutureBuilder<String?>(
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
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        return buildStack(displayPath, sizeSnap.data!);
                      },
                    );
                  },
                ),
              ),
            ),
          ),
          ...captions,
        ],
      );
    }

    if (!isMulti) {
      return Expanded(
        flex: 2,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: photoCard(sources.first),
        ),
      );
    }

    // Multi-source: PageView with keyboard navigation
    return Expanded(
      flex: 2,
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            final primaryFocus = FocusManager.instance.primaryFocus;
            if (primaryFocus?.context?.widget is EditableText) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              if (currentPage > 0) {
                pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
                return KeyEventResult.handled;
              }
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              if (currentPage < sources!.length - 1) {
                pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
                return KeyEventResult.handled;
              }
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            PageView.builder(
              controller: pageController,
              itemCount: sources.length,
              onPageChanged: (i) =>
                  onPageChanged(i, sources![i].imagePath),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.all(16),
                child: photoCard(sources![i]),
              ),
            ),
            // Page counter badge
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.photo_library,
                        size: 14, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      '${currentPage + 1} / ${sources.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (currentPage > 0)
              Positioned(
                left: 16,
                bottom: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    hoverColor: Colors.black87,
                  ),
                  tooltip: 'Previous photo',
                  onPressed: () => pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  ),
                ),
              ),
            if (currentPage < sources.length - 1)
              Positioned(
                right: 16,
                bottom: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_forward, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    hoverColor: Colors.black87,
                  ),
                  tooltip: 'Next photo',
                  onPressed: () => pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
