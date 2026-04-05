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

import 'dart:io';

import 'package:flutter/material.dart';
import '../../models/observation.dart';
import '../../services/bird_names.dart';
import '../../ui/drag_data.dart';
import '../../ui/widgets/superellipse_border.dart';

export '../../ui/drag_data.dart' show DragData;

class ObservationCard extends StatefulWidget {
  final Observation obs;
  final int index;
  final bool isSelected;
  final bool isExpanded;
  final bool isDragging;
  final List<int> selectedIndividualIndices;
  final int? lastSelectedIndividualIndex;

  final Function() onTapCard;
  final Function(int) onTapIndividual;
  final Function() onToggleExpanded;
  final Function(String) onSpeciesChanged;
  final Function(String) onSpeciesSelected;
  final void Function(int count) onCountChanged;
  final void Function(int fromObsIdx, int intoIdx) onMergeObservations;
  final void Function(int fromObsIdx, List<int> indIndices, int intoIdx)
  onMergeIndividuals;
  final void Function(int dragIndex) onDragStarted;
  final void Function() onDragEnded;
  final void Function(bool isOpen)? onDropdownToggled;
  final void Function(List<int> indIndices)? onDeleteIndividuals;
  final void Function(String imagePath) onTapPhoto;

  const ObservationCard({
    super.key,
    required this.obs,
    required this.index,
    required this.isSelected,
    required this.isExpanded,
    required this.isDragging,
    required this.selectedIndividualIndices,
    required this.lastSelectedIndividualIndex,
    required this.onTapCard,
    required this.onTapIndividual,
    required this.onToggleExpanded,
    required this.onSpeciesChanged,
    required this.onSpeciesSelected,
    required this.onCountChanged,
    required this.onMergeObservations,
    required this.onMergeIndividuals,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onTapPhoto,
    this.onDropdownToggled,
    this.onDeleteIndividuals,
  });

  @override
  State<ObservationCard> createState() => _ObservationCardState();
}

class _ObservationCardState extends State<ObservationCard>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _speciesController;
  late final FocusNode _speciesFocusNode;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;
  final LayerLink _layerLink = LayerLink();

  @override
  void initState() {
    super.initState();
    _speciesController = TextEditingController(
      text: widget.obs.speciesName == 'Unknown Bird'
          ? ''
          : widget.obs.speciesName,
    );
    _speciesFocusNode = FocusNode();
    _speciesFocusNode.addListener(_onFocusChanged);
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    _fadeController.forward();
  }

  void _onFocusChanged() {
    if (_speciesFocusNode.hasFocus && mounted) {
      _showOverlay();
    } else if (!_speciesFocusNode.hasFocus && mounted) {
      _hideOverlay();
      widget.onSpeciesChanged(_speciesController.text);
    }
  }

  OverlayEntry? _overlayEntry;

  void _hideOverlay() {
    if (_overlayEntry != null) {
      _overlayEntry?.remove();
      _overlayEntry = null;
      widget.onDropdownToggled?.call(false);
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;
    widget.onDropdownToggled?.call(true);

    bool flipUp = false;
    try {
      final RenderBox? cardBox = context.findRenderObject() as RenderBox?;
      if (cardBox != null && cardBox.hasSize) {
        final position = cardBox.localToGlobal(Offset.zero);
        final screenHeight = MediaQuery.of(context).size.height;
        final spaceBelow = screenHeight - position.dy - cardBox.size.height;
        if (spaceBelow < 250 && position.dy > spaceBelow) {
          flipUp = true;
        }
      }
    } catch (_) {}

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return ValueListenableBuilder<TextEditingValue>(
          valueListenable: _speciesController,
          builder: (context, value, child) {
            final query = value.text.toLowerCase();
            final modelCommons = widget.obs.possibleSpecies
                .where(
                  (s) => s.toLowerCase().contains(query) && s != 'Unknown Bird',
                )
                .toList();
            final taxonomyCommons = query.isNotEmpty
                ? scientificToCommon.values
                      .where(
                        (s) =>
                            s.toLowerCase().contains(query) &&
                            !modelCommons.contains(s),
                      )
                      .take(15)
                : <String>[];
            final options = [...modelCommons, ...taxonomyCommons];

            if (options.isEmpty) return const SizedBox.shrink();

            final list = TextFieldTapRegion(
              child: Material(
                elevation: 4.0,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 250),
                  width: 300,
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options[index];
                      return InkWell(
                        onTap: () {
                          widget.onSpeciesChanged(option);
                          _speciesController.text = option;
                          _hideOverlay();
                          _speciesFocusNode.unfocus();
                          if (mounted) setState(() {});
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(option),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );

            return Stack(
              children: [
                CompositedTransformFollower(
                  link: _layerLink,
                  showWhenUnlinked: false,
                  targetAnchor: flipUp
                      ? Alignment.topLeft
                      : Alignment.bottomLeft,
                  followerAnchor: flipUp
                      ? Alignment.bottomLeft
                      : Alignment.topLeft,
                  offset: flipUp ? const Offset(0, -4) : const Offset(0, 4),
                  child: list,
                ),
              ],
            );
          },
        );
      },
    );

    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
  }

  @override
  void didUpdateWidget(ObservationCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!widget.isSelected && oldWidget.isSelected) {
      if (_speciesFocusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _speciesFocusNode.hasFocus) {
            _speciesFocusNode.unfocus();
          }
        });
      }
    }
    if (widget.obs.speciesName != oldWidget.obs.speciesName &&
        _speciesController.text != widget.obs.speciesName) {
      _speciesController.text = widget.obs.speciesName == 'Unknown Bird'
          ? ''
          : widget.obs.speciesName;
    }
  }

  @override
  void dispose() {
    _hideOverlay();
    _fadeController.dispose();
    _speciesFocusNode.removeListener(_onFocusChanged);
    _speciesController.dispose();
    _speciesFocusNode.dispose();
    super.dispose();
  }

  // ─────────────── Helpers ──────────────────────────────────────────────────

  Widget _buildSplitButtonHalf({required bool isTop}) {
    return InkWell(
      onTap: widget.onToggleExpanded,
      child: Container(
        width: double.infinity,
        height: 20,
        margin: EdgeInsets.only(top: isTop ? 0 : 4, bottom: isTop ? 4 : 0),
        color: Colors.transparent,
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [_buildDot(), _buildDot(), _buildDot()],
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
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        shape: BoxShape.circle,
      ),
    );
  }

  // ─────────────── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Resolve scientific name for display beneath the species field
    String? scientificName;
    if (widget.obs.speciesName != "Unknown Bird") {
      final match = scientificToCommon.entries.where(
        (e) => e.value == widget.obs.speciesName,
      );
      if (match.isNotEmpty) scientificName = match.first.key;
    }

    final cardChild = _buildCardChild(scientificName);

    Widget observationItem = DragTarget<DragData>(
      onWillAcceptWithDetails: (details) =>
          details.data.obsIndex != widget.index,
      onAcceptWithDetails: (details) {
        if (details.data.indIndices == null) {
          widget.onMergeObservations(details.data.obsIndex, widget.index);
        } else {
          widget.onMergeIndividuals(
            details.data.obsIndex,
            details.data.indIndices!,
            widget.index,
          );
        }
      },
      builder: (context, candidateData, rejectedData) {
        return Draggable<DragData>(
          data: DragData(obsIndex: widget.index),
          onDragStarted: () => widget.onDragStarted(widget.index),
          onDragEnd: (_) => widget.onDragEnded(),
          onDraggableCanceled: (_, _) => widget.onDragEnded(),
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
                            cacheWidth: 80,
                            cacheHeight: 80,
                            gaplessPlayback: true,
                          )
                        : const Icon(Icons.image),
                    title: Text(
                      widget.obs.speciesName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'Date: ${widget.obs.exifData.dateTime?.toLocal().toString().split(".")[0] ?? "?"}',
                    ),
                    trailing: Text(
                      'x${widget.obs.count}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
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

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Opacity(
        opacity: widget.isDragging ? 0.4 : 1.0,
        child: observationItem,
      ),
    );
  }

  Widget _buildCardChild(String? scientificName) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: const SuperellipseBorder(m: 200.0, n: 20.0),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: widget.isSelected ? Colors.blue.withValues(alpha: 0.1) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(scientificName),
          _buildSplitButtonHalf(isTop: true),
          _buildIndividualsList(),
          if (widget.isExpanded) _buildSplitButtonHalf(isTop: false),
        ],
      ),
    );
  }

  Widget _buildHeader(String? scientificName) {
    return ListTile(
      shape: const SuperellipseBorder(m: 200.0, n: 20.0),
      onTap: widget.onTapCard,
      leading: widget.obs.displayPath != null
          ? Image.file(
              File(widget.obs.displayPath!),
              width: 50,
              height: 50,
              fit: BoxFit.cover,
              cacheWidth: 100,
              cacheHeight: 100,
              gaplessPlayback: true,
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
                _buildSpeciesField(),
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
        'Date: ${widget.obs.exifData.dateTime?.toLocal().toString().split(".")[0] ?? "?"}\n'
        'Lat: ${widget.obs.exifData.latitude?.toStringAsFixed(4) ?? "?"}, '
        'Lon: ${widget.obs.exifData.longitude?.toStringAsFixed(4) ?? "?"}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.remove, size: 20),
            onPressed: widget.obs.count > 1
                ? () => widget.onCountChanged(widget.obs.count - 1)
                : null,
          ),
          SizedBox(
            width: 40,
            child: TextFormField(
              key: ValueKey('count_${widget.obs.hashCode}_${widget.obs.count}'),
              initialValue: widget.obs.count.toString(),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              keyboardType: TextInputType.number,
              onChanged: (val) {
                final intVal = int.tryParse(val);
                if (intVal != null && intVal > 0) {
                  widget.onCountChanged(intVal);
                }
              },
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.add, size: 20),
            onPressed: () => widget.onCountChanged(widget.obs.count + 1),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeciesField() {
    final bool hasSelection =
        widget.obs.speciesName.isNotEmpty &&
        widget.obs.speciesName != 'Unknown Bird';

    if (hasSelection) {
      final button = OutlinedButton.icon(
        onPressed: () {
          widget.onSpeciesChanged('Unknown Bird');
          if (mounted) {
            setState(() {
              _speciesController.text = '';
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _speciesFocusNode.requestFocus();
              }
            });
          }
        },
        icon: const Icon(Icons.clear, size: 16),
        label: Text(
          widget.obs.speciesName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: const SuperellipseBorder(m: 200.0, n: 20.0),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );

      return Padding(
        padding: const EdgeInsets.only(bottom: 4.0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: !widget.isSelected
              ? GestureDetector(
                  onTap: widget.onTapCard,
                  child: AbsorbPointer(child: button),
                )
              : button,
        ),
      );
    }

    return _buildSpeciesAutocomplete();
  }

  Widget _buildSpeciesAutocomplete() {
    Widget field;
    if (!widget.isSelected) {
      field = GestureDetector(
        onTap: widget.onTapCard,
        child: AbsorbPointer(
          child: TextFormField(
            controller: _speciesController,
            focusNode: _speciesFocusNode,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8.0),
            ),
            style: const TextStyle(fontSize: 16),
            readOnly: true,
          ),
        ),
      );
    } else {
      field = TextFormField(
        controller: _speciesController,
        focusNode: _speciesFocusNode,
        decoration: const InputDecoration(labelText: 'Species'),
        onFieldSubmitted: (String value) {
          widget.onSpeciesChanged(value);
          _hideOverlay();
          Future.microtask(() {
            if (mounted) setState(() {});
          });
        },
        onChanged: (String value) {
          widget.obs.speciesName = value;
        },
      );
    }

    return CompositedTransformTarget(link: _layerLink, child: field);
  }

  Widget _buildIndividualsList() {
    final sortedIndices = List.generate(widget.obs.count, (i) => i);
    sortedIndices.sort((a, b) {
      final nameA = a < widget.obs.individualNames.length
          ? widget.obs.individualNames[a]
          : 'Individual ${a + 1}';
      final nameB = b < widget.obs.individualNames.length
          ? widget.obs.individualNames[b]
          : 'Individual ${b + 1}';
      return nameA.compareTo(nameB);
    });

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: Container(
        constraints: widget.isExpanded
            ? const BoxConstraints()
            : const BoxConstraints(maxHeight: 0),
        child: Column(
          children: [for (int i in sortedIndices) _buildIndividualTile(i)],
        ),
      ),
    );
  }

  Widget _buildIndividualTile(int i) {
    final individualName = i < widget.obs.individualNames.length
        ? widget.obs.individualNames[i]
        : 'Individual ${i + 1}';

    final isMultiSelected =
        widget.isSelected &&
        widget.selectedIndividualIndices.contains(i) &&
        widget.selectedIndividualIndices.length > 1;
    final label = isMultiSelected
        ? '${widget.selectedIndividualIndices.length} Individuals'
        : individualName;

    return Draggable<DragData>(
      data: DragData(
        obsIndex: widget.index,
        indIndices:
            (widget.isSelected && widget.selectedIndividualIndices.contains(i))
            ? widget.selectedIndividualIndices.toList()
            : [i],
      ),
      onDragStarted: () => widget.onDragStarted(widget.index),
      onDragEnd: (_) => widget.onDragEnded(),
      onDraggableCanceled: (_, _) => widget.onDragEnded(),
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
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.5,
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 82, right: 16),
          title: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: const EdgeInsets.only(left: 82, right: 16),
            title: Text(individualName, style: const TextStyle(fontSize: 13)),
            selected:
                widget.isSelected &&
                widget.selectedIndividualIndices.contains(i),
            selectedColor: Theme.of(context).colorScheme.primary,
            selectedTileColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.1),
            onTap: () => widget.onTapIndividual(i),
            trailing:
                widget.isSelected &&
                    widget.selectedIndividualIndices.contains(i)
                ? IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    color: Theme.of(context).colorScheme.error,
                    tooltip: 'Delete individual',
                    onPressed: () {
                      if (widget.onDeleteIndividuals != null) {
                        widget.onDeleteIndividuals!(
                          widget.selectedIndividualIndices.toList(),
                        );
                      }
                    },
                  )
                : null,
          ),
          if (widget.isSelected &&
              widget.selectedIndividualIndices.contains(i) &&
              widget.obs.sourceImages.length > 1)
            Padding(
              padding: const EdgeInsets.only(left: 82, right: 16, bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.obs.sourceImages.map((src) {
                  final filename = src.imagePath
                      .split('/')
                      .last
                      .split('\\')
                      .last;
                  return InkWell(
                    onTap: () => widget.onTapPhoto(src.imagePath),
                    borderRadius: BorderRadius.circular(6),
                    hoverColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.05),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.photo_outlined,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              filename,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
