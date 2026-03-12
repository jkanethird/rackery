import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import '../../models/observation.dart';
import '../../services/bird_names.dart';

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
  late final TextEditingController _speciesController;
  late final FocusNode _speciesFocusNode;

  @override
  void initState() {
    super.initState();
    _speciesController = TextEditingController(text: widget.obs.speciesName);
    _speciesFocusNode = FocusNode();
    _speciesFocusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_speciesFocusNode.hasFocus) {
      // Delay the focus lost save slightly so that if the user is clicking an option
      // in the Autocomplete dropdown, the InkWell's onTap (which fires on PointerUp)
      // has time to execute BEFORE the focus loss triggers a parent rebuild!
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) {
          widget.onSpeciesChanged(_speciesController.text);
        }
      });
    }
  }

  @override
  void didUpdateWidget(ObservationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.obs.speciesName != oldWidget.obs.speciesName &&
        _speciesController.text != widget.obs.speciesName) {
      _speciesController.text = widget.obs.speciesName;
    }
  }

  @override
  void dispose() {
    _speciesFocusNode.removeListener(_onFocusChanged);
    _speciesController.dispose();
    _speciesFocusNode.dispose();
    super.dispose();
  }

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
    String? scientificName;
    if (widget.obs.speciesName != "Unknown Bird") {
      final match = scientificToCommon.entries.where((e) => e.value == widget.obs.speciesName);
      if (match.isNotEmpty) {
        scientificName = match.first.key;
      }
    }

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RawAutocomplete<String>(
                        key: ValueKey("raw_auto_${widget.obs.imagePath}_${widget.index}"),
                        textEditingController: _speciesController,
                        focusNode: _speciesFocusNode,
                        optionsBuilder: (TextEditingValue textEditingValue) {
                          final query = textEditingValue.text.toLowerCase();
                          
                          List<String> modelCommons = widget.obs.possibleSpecies
                              .where((s) => s.toLowerCase().contains(query) && s != "Unknown Bird")
                              .toList();
                              
                          Iterable<String> taxonomyCommons = [];
                          if (query.isNotEmpty) {
                            taxonomyCommons = scientificToCommon.values
                                .where((s) => s.toLowerCase().contains(query) && !modelCommons.contains(s))
                                .take(15);
                          }
                              
                          return [...modelCommons, ...taxonomyCommons];
                        },
                        onSelected: (String selection) {
                           _speciesController.text = selection;
                           widget.onSpeciesChanged(selection);
                           _speciesFocusNode.unfocus();
                           setState(() {}); // Force local UI update immediately!
                        },
                        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                          return TextFormField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: const InputDecoration(labelText: "Species"),
                            onFieldSubmitted: (String value) {
                              onFieldSubmitted(); // Pass event through to RawAutocomplete
                              
                              // Delay saving the submit text! If the user hit 'Enter' to 
                              // select a highlighted dropdown option, RawAutocomplete's onSelected 
                              // will fire right NOW and overwrite _speciesController.text.
                              // By waiting a split second, we save the completed selection 
                              // rather than the partial typed string!
                              Future.delayed(const Duration(milliseconds: 50), () {
                                if (mounted) {
                                  widget.onSpeciesChanged(_speciesController.text);
                                  setState(() {});
                                }
                              });
                            },
                            onChanged: (String value) {
                              widget.obs.speciesName = value;
                            },
                          );
                        },
                        optionsViewBuilder: (context, onSelected, options) {
                          return Align(
                            alignment: Alignment.topLeft,
                            child: Material(
                              elevation: 4.0,
                              child: Container(
                                constraints: const BoxConstraints(maxHeight: 250),
                                width: 300,
                                child: Builder(
                                  builder: (BuildContext context) {
                                    final int highlightedIndex = AutocompleteHighlightedOption.of(context);
                                    return ListView.builder(
                                      padding: EdgeInsets.zero,
                                      shrinkWrap: true,
                                      itemCount: options.length,
                                      itemBuilder: (BuildContext context, int index) {
                                        final String option = options.elementAt(index);
                                        final bool isHighlighted = index == highlightedIndex;
                                        return Container(
                                          color: isHighlighted ? Theme.of(context).focusColor : null,
                                          child: Listener(
                                            behavior: HitTestBehavior.opaque,
                                            onPointerDown: (_) {
                                              onSelected(option);
                                            },
                                            child: InkWell(
                                              onTap: () {}, // Required for InkWell to track hover/focus UI states natively
                                              child: Padding(
                                                padding: const EdgeInsets.all(16.0),
                                                child: Text(option),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  }
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2.0, bottom: 4.0),
                        child: Text(
                          scientificName ?? ' ',
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
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
