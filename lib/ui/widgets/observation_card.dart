import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import '../../models/observation.dart';

class DragData {
  final int obsIndex;
  final List<int>? indIndices;

  DragData({required this.obsIndex, this.indIndices});
}

class ObservationCard extends StatefulWidget {
  final Observation obs;
  final int index;
  final bool isSelected;
  final bool isDragging;
  final List<int> selectedIndividualIndices;
  final int? lastSelectedIndividualIndex;
  
  final Function() onTapCard;
  final Function(int) onTapIndividual;
  final Function(String) onSpeciesChanged;
  final Function(String) onSpeciesSelected;
  final Function(int) onCountChanged;
  final Function(int, int) onMergeObservations;
  final Function(int, List<int>, int) onMergeIndividuals;
  final Function(int) onDragStarted;
  final Function() onDragEnded;

  const ObservationCard({
    super.key,
    required this.obs,
    required this.index,
    required this.isSelected,
    required this.isDragging,
    required this.selectedIndividualIndices,
    required this.lastSelectedIndividualIndex,
    required this.onTapCard,
    required this.onTapIndividual,
    required this.onSpeciesChanged,
    required this.onSpeciesSelected,
    required this.onCountChanged,
    required this.onMergeObservations,
    required this.onMergeIndividuals,
    required this.onDragStarted,
    required this.onDragEnded,
  });

  @override
  State<ObservationCard> createState() => _ObservationCardState();
}

class _ObservationCardState extends State<ObservationCard> {
  bool _isExpanded = false;

  Widget _buildSplitButtonHalf({required bool isTop}) {
    return InkWell(
      onTap: () {
        setState(() {
          _isExpanded = !_isExpanded;
        });
      },
      child: Container(
        width: double.infinity,
        height: 20,
        margin: EdgeInsets.only(
          top: isTop ? 0 : 4,
          bottom: isTop ? 4 : 0,
        ),
        color: Colors.transparent,
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildDot(),
              _buildDot(),
              _buildDot(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDot() {
    return Container(
      width: 4,
      height: 4,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        shape: BoxShape.circle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget cardChild = Card(
      clipBehavior: Clip.antiAlias,
      shape: const SuperellipseBorder(m: 200.0, n: 20.0),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: widget.isSelected ? Colors.blue.withValues(alpha: 0.1) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          ListTile(
            shape: const SuperellipseBorder(m: 200.0, n: 20.0),
            onTap: widget.onTapCard,
            leading: widget.obs.displayPath != null
                ? Image.file(
                    File(widget.obs.displayPath!),
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                  )
                : const Icon(Icons.image),
            title: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey("${widget.obs.imagePath}_${widget.obs.speciesName}"),
                    initialValue: widget.obs.speciesName,
                    decoration: const InputDecoration(labelText: "Species"),
                    onChanged: widget.onSpeciesChanged,
                  ),
                ),
                if (widget.obs.possibleSpecies.length > 1)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.arrow_drop_down),
                    tooltip: "AI Alternatives",
                    onSelected: widget.onSpeciesSelected,
                    itemBuilder: (BuildContext context) {
                      return widget.obs.possibleSpecies
                          .map((String choice) => PopupMenuItem<String>(
                                value: choice,
                                child: Text(choice),
                              ))
                          .toList();
                    },
                  ),
              ],
            ),
            subtitle: Text(
              'Date: ${widget.obs.exifData.dateTime?.toLocal().toString().split(".")[0] ?? "?"}\nLat: ${widget.obs.exifData.latitude?.toStringAsFixed(4) ?? "?"}, Lon: ${widget.obs.exifData.longitude?.toStringAsFixed(4) ?? "?"}',
            ),
            trailing: SizedBox(
              width: 45,
              child: TextFormField(
                key: ValueKey("count_${widget.obs.hashCode}_${widget.obs.count}"),
                initialValue: widget.obs.count.toString(),
                decoration: const InputDecoration(labelText: "Count"),
                keyboardType: TextInputType.number,
                onChanged: (val) {
                  widget.onCountChanged(int.tryParse(val) ?? 1);
                },
              ),
            ),
          ),
          
          if (widget.obs.count > 1) _buildSplitButtonHalf(isTop: true),
          
          if (widget.obs.count > 1)
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: Container(
                constraints: _isExpanded 
                    ? const BoxConstraints() 
                    : const BoxConstraints(maxHeight: 0),
                child: Column(
                  children: [
                    for (int i = 0; i < widget.obs.count; i++)
                      Draggable<DragData>(
                        data: DragData(
                          obsIndex: widget.index,
                          indIndices: (widget.isSelected && widget.selectedIndividualIndices.contains(i))
                              ? widget.selectedIndividualIndices.toList()
                              : [i],
                        ),
                        onDragStarted: () => widget.onDragStarted(widget.index),
                        onDragEnd: (_) => widget.onDragEnded(),
                        onDraggableCanceled: (velocity, offset) => widget.onDragEnded(),
                        feedback: Material(
                          elevation: 6,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              (widget.isSelected && widget.selectedIndividualIndices.contains(i) && widget.selectedIndividualIndices.length > 1)
                                  ? "${widget.selectedIndividualIndices.length} Individuals"
                                  : "Individual ${i + 1}",
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        childWhenDragging: Opacity(
                          opacity: 0.5,
                          child: ListTile(
                            contentPadding: const EdgeInsets.only(left: 82, right: 16),
                            title: Text(
                              (widget.isSelected && widget.selectedIndividualIndices.contains(i) && widget.selectedIndividualIndices.length > 1)
                                  ? "${widget.selectedIndividualIndices.length} Individuals"
                                  : "Individual ${i + 1}",
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.only(left: 82, right: 16),
                          title: Text(
                            "Individual ${i + 1}",
                            style: const TextStyle(fontSize: 13),
                          ),
                          selected: widget.isSelected && widget.selectedIndividualIndices.contains(i),
                          selectedColor: Theme.of(context).colorScheme.primary,
                          selectedTileColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                          onTap: () => widget.onTapIndividual(i),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            
          if (widget.obs.count > 1 && _isExpanded) _buildSplitButtonHalf(isTop: false),
        ],
      ),
    );

    Widget observationItem = DragTarget<DragData>(
      onWillAcceptWithDetails: (details) =>
          details.data.obsIndex != widget.index &&
          true, // Replaced the burstId check temporally to resolve previous issue
      onAcceptWithDetails: (details) {
        if (details.data.indIndices == null) {
          widget.onMergeObservations(details.data.obsIndex, widget.index);
        } else {
          widget.onMergeIndividuals(details.data.obsIndex, details.data.indIndices!, widget.index);
        }
      },
      builder: (context, candidateData, rejectedData) {
        return Draggable<DragData>(
          data: DragData(obsIndex: widget.index),
          onDragStarted: () => widget.onDragStarted(widget.index),
          onDragEnd: (_) => widget.onDragEnded(),
          onDraggableCanceled: (velocity, offset) => widget.onDragEnded(),
          feedback: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Opacity(
                opacity: 0.85,
                child: Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: widget.obs.displayPath != null
                        ? Image.file(
                            File(widget.obs.displayPath!),
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          )
                        : const Icon(Icons.image),
                    title: Text(widget.obs.speciesName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      'Date: ${widget.obs.exifData.dateTime?.toLocal().toString().split(".")[0] ?? "?"}',
                    ),
                    trailing: Text("x${widget.obs.count}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.2, child: cardChild),
          child: cardChild,
        );
      },
    );

    return Opacity(
      opacity: widget.isDragging ? 0.4 : 1.0,
      child: observationItem,
    );
  }
}

class SuperellipseBorder extends OutlinedBorder {
  final double m;
  final double n;

  const SuperellipseBorder({
    required this.m,
    required this.n,
    super.side,
  });

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _getPath(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _getPath(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side != BorderSide.none) {
      final paint = side.toPaint();
      canvas.drawPath(_getPath(rect), paint);
    }
  }

  Path _getPath(Rect rect) {
    final Path path = Path();
    final a = rect.width / 2;
    final b = rect.height / 2;
    final cx = rect.center.dx;
    final cy = rect.center.dy;

    const segments = 100;
    for (int i = 0; i <= segments; i++) {
        final t = i * 2 * pi / segments;
        // Use signum to ensure the shape stays properly formed across all quadrants
        final cosT = cos(t);
        final sinT = sin(t);
        
        final x = cx + a * (cosT.sign * pow(cosT.abs(), 2 / m));
        final y = cy + b * (sinT.sign * pow(sinT.abs(), 2 / n));

        if (i == 0) {
            path.moveTo(x, y);
        } else {
            path.lineTo(x, y);
        }
    }
    path.close();
    return path;
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) => SuperellipseBorder(m: m, n: n, side: side.scale(t));
  
  @override
  OutlinedBorder copyWith({BorderSide? side, double? m, double? n}) {
    return SuperellipseBorder(
      m: m ?? this.m,
      n: n ?? this.n,
      side: side ?? this.side,
    );
  }
}
