import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/geo_region_service.dart';
import 'package:ebird_generator/ui/widgets/bounding_box_painter.dart';
import 'package:ebird_generator/ui/widgets/superellipse_border.dart';

/// The centre pane: shows the full photo(s) for the selected observation with
/// bounding-box overlays. Supports single-image and multi-image (PageView) modes.

class _DrawingBoxPainter extends CustomPainter {
  final Offset start;
  final Offset end;

  _DrawingBoxPainter(this.start, this.end);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(start, end);
    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, paint);

    final borderPaint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(rect, borderPaint);
  }

  @override
  bool shouldRepaint(_DrawingBoxPainter oldDelegate) {
    return oldDelegate.start != start || oldDelegate.end != end;
  }
}

class CenterPane extends StatefulWidget {
  final Observation? selectedObservation;
  final Set<int> selectedIndividualIndices;
  final String? currentlyDisplayedImage;
  final Map<String, ExifData> imageExifData;
  final int currentPage;
  final PageController pageController;
  final Future<String?> Function(String imagePath) getDisplayPath;
  final Future<Size> Function(String path) getImageSize;
  final void Function(int page, String imagePath) onPageChanged;
  final void Function(String imagePath, Rectangle<int> box)? onDrawBoundingBox;

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
    this.onDrawBoundingBox,
  });

  @override
  State<CenterPane> createState() => _CenterPaneState();
}

class _CenterPaneState extends State<CenterPane> {
  bool _isDrawingMode = false;
  bool _showBoundingBoxes = true;
  Offset? _drawStart;
  Offset? _drawCurrent;

  @override
  Widget build(BuildContext context) {
    final obs = widget.selectedObservation;
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
      if (widget.selectedIndividualIndices.isNotEmpty) {
        // Find the set of photos that contain any selected individual.
        final selectedPaths = widget.selectedIndividualIndices
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
    } else if (widget.currentlyDisplayedImage != null) {
      sources = [
        (
          imagePath: widget.currentlyDisplayedImage!,
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
          : widget.getDisplayPath(rawPath);

      final filename = rawPath.split('/').last.split('\\').last;
      final exif = widget.imageExifData[rawPath];
      final lat = exif?.latitude;
      final lon = exif?.longitude;

      Widget buildStack(
        String displayPath,
        Size imgSize,
        BoxConstraints constraints,
      ) {
        final allPhotoBoxes = List<Rectangle<int>>.from(
          obs?.boxesByImagePath[rawPath] ??
              (obs?.imagePath == rawPath ? obs!.boundingBoxes : const []),
        );
        allPhotoBoxes.sort((a, b) => a.left.compareTo(b.left));

        List<Rectangle<int>> photoBoxes = allPhotoBoxes;
        List<String>? photoNames;

        if (obs != null) {
          photoNames = [];
          for (int li = 0; li < allPhotoBoxes.length; li++) {
            final entry = globalIndexMap.entries.firstWhere(
              (e) => e.value.imagePath == rawPath && e.value.localIndex == li,
              orElse: () => const MapEntry(-1, (imagePath: '', localIndex: -1)),
            );
            if (entry.key >= 0 && entry.key < obs.individualNames.length) {
              photoNames.add(obs.individualNames[entry.key]);
            } else {
              photoNames.add('?');
            }
          }
        }

        if (widget.selectedIndividualIndices.isNotEmpty &&
            allPhotoBoxes.isNotEmpty) {
          // Map selected global indices to the local box indices for THIS photo.
          final localSelected = widget.selectedIndividualIndices
              .where((gi) => globalIndexMap[gi]?.imagePath == rawPath)
              .map((gi) => globalIndexMap[gi]!.localIndex)
              .toSet();
          if (localSelected.isNotEmpty) {
            photoBoxes = [
              for (int li = 0; li < allPhotoBoxes.length; li++)
                if (localSelected.contains(li)) allPhotoBoxes[li],
            ];
            if (photoNames != null) {
              photoNames = [
                for (int li = 0; li < allPhotoBoxes.length; li++)
                  if (localSelected.contains(li)) photoNames[li],
              ];
            }
          }
        }

        Widget stack = Stack(
          alignment: Alignment.center,
          fit: StackFit.loose,
          children: [
            Image.file(
              File(displayPath),
              width: double.infinity,
              fit: BoxFit.contain,
            ),
            if (obs != null && photoBoxes.isNotEmpty && _showBoundingBoxes)
              Positioned.fill(
                child: CustomPaint(
                  painter: BoundingBoxPainter(
                    boxes: photoBoxes,
                    names: photoNames,
                    imageSize: imgSize,
                  ),
                ),
              ),
            if (_isDrawingMode && _drawStart != null && _drawCurrent != null)
              Positioned.fill(
                child: CustomPaint(
                  painter: _DrawingBoxPainter(_drawStart!, _drawCurrent!),
                ),
              ),
          ],
        );

        if (_isDrawingMode) {
          stack = MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: GestureDetector(
              onPanStart: (details) {
                setState(() {
                  _drawStart = details.localPosition;
                  _drawCurrent = details.localPosition;
                });
              },
              onPanUpdate: (details) {
                setState(() {
                  _drawCurrent = details.localPosition;
                });
              },
              onPanEnd: (details) {
                if (_drawStart != null && _drawCurrent != null) {
                  // Map local coordinates to image pixel coordinates
                  final s = min(
                    constraints.maxWidth / imgSize.width,
                    constraints.maxHeight / imgSize.height,
                  );
                  final dw = imgSize.width * s;
                  final dh = imgSize.height * s;
                  final dx = (constraints.maxWidth - dw) / 2;
                  final dy = (constraints.maxHeight - dh) / 2;

                  int mapX(double x) =>
                      ((x - dx) / s).clamp(0, imgSize.width).toInt();
                  int mapY(double y) =>
                      ((y - dy) / s).clamp(0, imgSize.height).toInt();

                  final left = min(_drawStart!.dx, _drawCurrent!.dx);
                  final right = max(_drawStart!.dx, _drawCurrent!.dx);
                  final top = min(_drawStart!.dy, _drawCurrent!.dy);
                  final bottom = max(_drawStart!.dy, _drawCurrent!.dy);

                  final imgLeft = mapX(left);
                  final imgRight = mapX(right);
                  final imgTop = mapY(top);
                  final imgBottom = mapY(bottom);

                  if (imgRight - imgLeft > 5 && imgBottom - imgTop > 5) {
                    final box = Rectangle<int>(
                      imgLeft,
                      imgTop,
                      imgRight - imgLeft,
                      imgBottom - imgTop,
                    );
                    if (widget.onDrawBoundingBox != null) {
                      widget.onDrawBoundingBox!(rawPath, box);
                    }
                  }
                }
                setState(() {
                  _drawStart = null;
                  _drawCurrent = null;
                  _isDrawingMode = false;
                });
              },
              child: stack,
            ),
          );
        }
        return stack;
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
              panEnabled: !_isDrawingMode,
              scaleEnabled: !_isDrawingMode,
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
                      future: widget.getImageSize(displayPath),
                      builder: (context, sizeSnap) {
                        if (!sizeSnap.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        return buildStack(
                          displayPath,
                          sizeSnap.data!,
                          constraints,
                        );
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

    Widget mainContent;
    if (!isMulti) {
      mainContent = Padding(
        padding: const EdgeInsets.all(16),
        child: photoCard(sources.first),
      );
    } else {
      // Multi-source: PageView with keyboard navigation
      mainContent = Stack(
        children: [
          PageView.builder(
            controller: widget.pageController,
            itemCount: sources.length,
            onPageChanged: (i) =>
                widget.onPageChanged(i, sources![i].imagePath),
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
                  const Icon(
                    Icons.photo_library,
                    size: 14,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${widget.currentPage + 1} / ${sources.length}',
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
          if (widget.currentPage > 0)
            Positioned(
              left: 16,
              bottom: 16,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.grey.shade800.withValues(alpha: 0.5),
                  hoverColor: Colors.grey.shade900.withValues(alpha: 0.7),
                  shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                ),
                tooltip: 'Previous photo',
                onPressed: () => widget.pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                ),
              ),
            ),
          if (widget.currentPage < sources.length - 1)
            Positioned(
              right: 16,
              bottom: 16,
              child: IconButton(
                icon: const Icon(Icons.arrow_forward, color: Colors.white),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.grey.shade800.withValues(alpha: 0.5),
                  hoverColor: Colors.grey.shade900.withValues(alpha: 0.7),
                  shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                ),
                tooltip: 'Next photo',
                onPressed: () => widget.pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                ),
              ),
            ),
        ],
      );
    }

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

            if (event.logicalKey == LogicalKeyboardKey.escape &&
                _isDrawingMode) {
              setState(() {
                _isDrawingMode = false;
                _drawStart = null;
                _drawCurrent = null;
              });
              return KeyEventResult.handled;
            }

            if (isMulti) {
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                if (widget.currentPage > 0) {
                  widget.pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                  return KeyEventResult.handled;
                }
              } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                if (widget.currentPage < sources!.length - 1) {
                  widget.pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                  return KeyEventResult.handled;
                }
              }
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            Positioned.fill(child: mainContent),
            if (sources.isNotEmpty)
              Positioned(
                top: 16,
                left: 16,
                child: Row(
                  children: [
                    Tooltip(
                      message: _showBoundingBoxes
                          ? 'Hide Bounding Boxes'
                          : 'Show Bounding Boxes',
                      child: IconButton(
                        icon: Icon(
                          _showBoundingBoxes
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () => setState(
                          () => _showBoundingBoxes = !_showBoundingBoxes,
                        ),
                        color: Theme.of(context).colorScheme.primary,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey.shade800.withValues(
                            alpha: 0.5,
                          ),
                          hoverColor: Colors.grey.shade900.withValues(
                            alpha: 0.7,
                          ),
                          shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: _isDrawingMode
                          ? 'Cancel Drawing'
                          : 'Draw Boundary Box',
                      child: IconButton(
                        icon: Icon(
                          _isDrawingMode ? Icons.close : Icons.add_box,
                        ),
                        onPressed: () {
                          setState(() {
                            _isDrawingMode = !_isDrawingMode;
                            _drawStart = null;
                            _drawCurrent = null;
                          });
                        },
                        color: _isDrawingMode
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey.shade800.withValues(
                            alpha: 0.5,
                          ),
                          hoverColor: Colors.grey.shade900.withValues(
                            alpha: 0.7,
                          ),
                          shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
