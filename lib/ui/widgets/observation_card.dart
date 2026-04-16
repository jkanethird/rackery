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
import '../../ui/widgets/species_fuzzy_field.dart';
import '../../ui/widgets/individual_tile.dart';

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
  final void Function(int fromObsIdx, List<int> indIndices, int intoIdx) onMergeIndividuals;
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
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    String? scientificName;
    if (widget.obs.speciesName != 'Unknown Bird') {
      final match = scientificToCommon.entries
          .where((e) => e.value == widget.obs.speciesName);
      if (match.isNotEmpty) scientificName = match.first.key;
    }

    final cardChild = _buildCardChild(scientificName);

    final observationItem = DragTarget<DragData>(
      onWillAcceptWithDetails: (d) => d.data.obsIndex != widget.index,
      onAcceptWithDetails: (d) {
        if (d.data.indIndices == null) {
          widget.onMergeObservations(d.data.obsIndex, widget.index);
        } else {
          widget.onMergeIndividuals(d.data.obsIndex, d.data.indIndices!, widget.index);
        }
      },
      builder: (ctx, _, rejected) => Draggable<DragData>(
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
                          width: 40, height: 40,
                          fit: BoxFit.cover,
                          cacheWidth: 80, cacheHeight: 80,
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
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.2, child: cardChild),
        child: cardChild,
      ),
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
          _buildExpandButton(isTop: true),
          _buildIndividualsList(),
          if (widget.isExpanded) _buildExpandButton(isTop: false),
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
              width: 50, height: 50,
              fit: BoxFit.cover,
              cacheWidth: 100, cacheHeight: 100,
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
                SpeciesFuzzyField(
                  speciesName: widget.obs.speciesName,
                  possibleSpecies: widget.obs.possibleSpecies,
                  isSelected: widget.isSelected,
                  onSpeciesChanged: widget.onSpeciesChanged,
                  onTapField: widget.onTapCard,
                  onDropdownToggled: widget.onDropdownToggled,
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
                if (intVal != null && intVal > 0) widget.onCountChanged(intVal);
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

  // ── Expand / collapse toggle ───────────────────────────────────────────────

  Widget _buildExpandButton({required bool isTop}) {
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

  Widget _buildDot() => Container(
        width: 4,
        height: 4,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
      );

  // ── Individuals list ──────────────────────────────────────────────────────

  Widget _buildIndividualsList() {
    final sortedIndices = List.generate(widget.obs.count, (i) => i)
      ..sort((a, b) {
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
          children: [
            for (final i in sortedIndices)
              IndividualTile(
                index: i,
                obsIndex: widget.index,
                individualName: i < widget.obs.individualNames.length
                    ? widget.obs.individualNames[i]
                    : 'Individual ${i + 1}',
                isSelected: widget.isSelected,
                isMultiSelected: widget.isSelected &&
                    widget.selectedIndividualIndices.contains(i) &&
                    widget.selectedIndividualIndices.length > 1,
                multiSelectedCount: widget.selectedIndividualIndices.length,
                sourceImages: widget.obs.sourceImages,
                selectedIndividualIndices: widget.selectedIndividualIndices,
                onTap: widget.onTapIndividual,
                onDragStarted: widget.onDragStarted,
                onDragEnded: widget.onDragEnded,
                onDeleteIndividuals: widget.onDeleteIndividuals,
                onTapPhoto: widget.onTapPhoto,
              ),
          ],
        ),
      ),
    );
  }
}
