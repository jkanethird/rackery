import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ebird_generator/ui/widgets/bounding_box_painter.dart';
import 'package:ebird_generator/ui/widgets/superellipse_border.dart';

class PhotoCanvas extends StatefulWidget {
  final String displayPath;
  final String rawPath;
  final Size imageSize;
  final List<Rectangle<int>> photoBoxes;
  final List<String>? photoNames;
  final bool showBoundingBoxes;
  final VoidCallback onToggleBoundingBoxes;
  final void Function(String imagePath, Rectangle<int> box)? onDrawBoundingBox;

  const PhotoCanvas({
    super.key,
    required this.displayPath,
    required this.rawPath,
    required this.imageSize,
    required this.photoBoxes,
    this.photoNames,
    required this.showBoundingBoxes,
    required this.onToggleBoundingBoxes,
    this.onDrawBoundingBox,
  });

  @override
  State<PhotoCanvas> createState() => _PhotoCanvasState();
}

class _PhotoCanvasState extends State<PhotoCanvas> {
  bool _isDrawingMode = false;
  Offset? _drawStart;
  Offset? _drawCurrent;

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
                      if (widget.photoBoxes.isNotEmpty &&
                          widget.showBoundingBoxes)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: BoundingBoxPainter(
                              boxes: widget.photoBoxes,
                              names: widget.photoNames,
                              imageSize: widget.imageSize,
                            ),
                          ),
                        ),
                      if (_isDrawingMode &&
                          _drawStart != null &&
                          _drawCurrent != null)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: DrawingBoxPainter(
                                _drawStart!, _drawCurrent!),
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

                            int mapX(double x) =>
                                ((x - dx) / s)
                                    .clamp(0, widget.imageSize.width)
                                    .toInt();
                            int mapY(double y) =>
                                ((y - dy) / s)
                                    .clamp(0, widget.imageSize.height)
                                    .toInt();

                            final left = min(_drawStart!.dx, _drawCurrent!.dx);
                            final right = max(_drawStart!.dx, _drawCurrent!.dx);
                            final top = min(_drawStart!.dy, _drawCurrent!.dy);
                            final bottom = max(_drawStart!.dy, _drawCurrent!.dy);

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
                Tooltip(
                  message: widget.showBoundingBoxes
                      ? 'Hide Bounding Boxes'
                      : 'Show Bounding Boxes',
                  child: IconButton(
                    icon: Icon(
                      widget.showBoundingBoxes
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                    onPressed: widget.onToggleBoundingBoxes,
                    color: Theme.of(context).colorScheme.primary,
                    style: IconButton.styleFrom(
                      backgroundColor:
                          Colors.grey.shade800.withValues(alpha: 0.5),
                      hoverColor:
                          Colors.grey.shade900.withValues(alpha: 0.7),
                      shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message:
                      _isDrawingMode ? 'Cancel Drawing' : 'Draw Boundary Box',
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
                      backgroundColor:
                          Colors.grey.shade800.withValues(alpha: 0.5),
                      hoverColor:
                          Colors.grey.shade900.withValues(alpha: 0.7),
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
