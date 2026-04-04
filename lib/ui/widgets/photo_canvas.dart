import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/controllers/checklist_controller.dart';
import 'package:ebird_generator/ui/widgets/bounding_box_painter.dart';
import 'package:ebird_generator/ui/widgets/superellipse_border.dart';

class PhotoBoxData {
  final Rectangle<int> box;
  final String name;
  final String species;
  final int individualIndex;
  final Observation obs;

  const PhotoBoxData({
    required this.box,
    required this.name,
    required this.species,
    required this.individualIndex,
    required this.obs,
  });
}

class PhotoCanvas extends StatefulWidget {
  final String displayPath;
  final String rawPath;
  final Size imageSize;
  final List<PhotoBoxData> boxData;
  final BoundingBoxVisibility boxVisibility;
  final ValueChanged<BoundingBoxVisibility> onSetBoxVisibility;
  final bool isPhotoProcessing;
  final void Function(PhotoBoxData data)? onIndividualSelected;
  final void Function(String imagePath, Rectangle<int> box)? onDrawBoundingBox;

  const PhotoCanvas({
    super.key,
    required this.displayPath,
    required this.rawPath,
    required this.imageSize,
    required this.boxData,
    required this.boxVisibility,
    required this.onSetBoxVisibility,
    this.isPhotoProcessing = false,
    this.onIndividualSelected,
    this.onDrawBoundingBox,
  });

  @override
  State<PhotoCanvas> createState() => _PhotoCanvasState();
}

class _PhotoCanvasState extends State<PhotoCanvas> {
  bool _isDrawingMode = false;
  Offset? _drawStart;
  Offset? _drawCurrent;
  BoundingBoxVisibility? _hoveredVisibility;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final primaryFocus = FocusManager.instance.primaryFocus;
          if (primaryFocus?.context?.widget is EditableText) {
            return KeyEventResult.ignored;
          }

          if (event.logicalKey == LogicalKeyboardKey.escape && _isDrawingMode) {
            setState(() {
              _isDrawingMode = false;
              _drawStart = null;
              _drawCurrent = null;
            });
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              panEnabled: !_isDrawingMode,
              scaleEnabled: !_isDrawingMode,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  Widget stack = Stack(
                    alignment: Alignment.center,
                    fit: StackFit.loose,
                    children: [
                      Image.file(
                        File(widget.displayPath),
                        width: double.infinity,
                        fit: BoxFit.contain,
                      ),
                      if (widget.boxData.isNotEmpty &&
                          widget.boxVisibility != BoundingBoxVisibility.hidden)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: BoundingBoxPainter(
                              boxes: widget.boxData.map((d) => d.box).toList(),
                              names: widget.boxData.map((d) => d.name).toList(),
                              imageSize: widget.imageSize,
                            ),
                          ),
                        ),
                      if (widget.boxData.isNotEmpty &&
                          widget.boxVisibility !=
                              BoundingBoxVisibility.hidden &&
                          !_isDrawingMode)
                        ...widget.boxData.map((data) {
                          final s = min(
                            constraints.maxWidth / widget.imageSize.width,
                            constraints.maxHeight / widget.imageSize.height,
                          );
                          final dx =
                              (constraints.maxWidth -
                                  widget.imageSize.width * s) /
                              2;
                          final dy =
                              (constraints.maxHeight -
                                  widget.imageSize.height * s) /
                              2;

                          final rectLeft = dx + data.box.left * s;
                          final rectTop = dy + data.box.top * s;
                          final rectWidth = data.box.width * s;
                          final rectHeight = data.box.height * s;

                          return Positioned(
                            left: rectLeft,
                            top: rectTop,
                            width: rectWidth,
                            height: rectHeight,
                            child: Tooltip(
                              message: '${data.name} (${data.species})',
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    widget.onIndividualSelected?.call(data);
                                  },
                                ),
                              ),
                            ),
                          );
                        }),
                      if (_isDrawingMode &&
                          _drawStart != null &&
                          _drawCurrent != null)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: DrawingBoxPainter(
                              _drawStart!,
                              _drawCurrent!,
                            ),
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
                            final s = min(
                              constraints.maxWidth / widget.imageSize.width,
                              constraints.maxHeight / widget.imageSize.height,
                            );
                            final dw = widget.imageSize.width * s;
                            final dh = widget.imageSize.height * s;
                            final dx = (constraints.maxWidth - dw) / 2;
                            final dy = (constraints.maxHeight - dh) / 2;

                            int mapX(double x) => ((x - dx) / s)
                                .clamp(0, widget.imageSize.width)
                                .toInt();
                            int mapY(double y) => ((y - dy) / s)
                                .clamp(0, widget.imageSize.height)
                                .toInt();

                            final left = min(_drawStart!.dx, _drawCurrent!.dx);
                            final right = max(_drawStart!.dx, _drawCurrent!.dx);
                            final top = min(_drawStart!.dy, _drawCurrent!.dy);
                            final bottom = max(
                              _drawStart!.dy,
                              _drawCurrent!.dy,
                            );

                            final imgLeft = mapX(left);
                            final imgRight = mapX(right);
                            final imgTop = mapY(top);
                            final imgBottom = mapY(bottom);

                            if (imgRight - imgLeft > 5 &&
                                imgBottom - imgTop > 5) {
                              final box = Rectangle<int>(
                                imgLeft,
                                imgTop,
                                imgRight - imgLeft,
                                imgBottom - imgTop,
                              );
                              if (widget.onDrawBoundingBox != null) {
                                widget.onDrawBoundingBox!(widget.rawPath, box);
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
                },
              ),
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: Row(
              children: [
                Container(
                  height: 40,
                  decoration: ShapeDecoration(
                    color: Colors.grey.shade800.withValues(alpha: 0.5),
                    shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in [
                        (
                          BoundingBoxVisibility.focused,
                          Icons.filter_center_focus,
                          'Show Focused Boundary Boxes',
                        ),
                        (
                          BoundingBoxVisibility.all,
                          Icons.border_all,
                          'Show All Boundary Boxes',
                        ),
                        (
                          BoundingBoxVisibility.hidden,
                          Icons.visibility_off,
                          'Hide Boundary Boxes',
                        ),
                      ])
                        Tooltip(
                          message: entry.$3,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            onEnter: (_) =>
                                setState(() => _hoveredVisibility = entry.$1),
                            onExit: (_) => setState(() {
                              if (_hoveredVisibility == entry.$1) {
                                _hoveredVisibility = null;
                              }
                            }),
                            child: GestureDetector(
                              onTap: () => widget.onSetBoxVisibility(entry.$1),
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: ShapeDecoration(
                                  color: widget.boxVisibility == entry.$1
                                      ? Theme.of(context).colorScheme.primary
                                            .withValues(alpha: 0.3)
                                      : _hoveredVisibility == entry.$1
                                      ? Colors.grey.shade900.withValues(
                                          alpha: 0.7,
                                        )
                                      : Colors.transparent,
                                  shape: const SuperellipseBorder(
                                    m: 200.0,
                                    n: 20.0,
                                  ),
                                ),
                                child: Icon(
                                  entry.$2,
                                  size: 20,
                                  color: widget.boxVisibility == entry.$1
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: _isDrawingMode
                      ? 'Cancel Drawing'
                      : 'Draw Boundary Box',
                  child: IconButton(
                    icon: Icon(_isDrawingMode ? Icons.close : Icons.add_box),
                    onPressed: widget.isPhotoProcessing
                        ? null
                        : () {
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
                      hoverColor: Colors.grey.shade900.withValues(alpha: 0.7),
                      shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
