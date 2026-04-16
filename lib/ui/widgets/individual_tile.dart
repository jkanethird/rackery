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

import 'package:flutter/material.dart';
import '../../models/observation.dart';
import '../drag_data.dart';

/// A draggable list tile representing a single individual within an
/// [Observation]. Supports multi-selection feedback and per-source-photo
/// navigation.
class IndividualTile extends StatelessWidget {
  final int index;
  final int obsIndex;
  final String individualName;
  final bool isSelected;
  final bool isMultiSelected;
  final int multiSelectedCount;
  final List<SourceImage> sourceImages;
  final void Function(int) onTap;
  final void Function(int) onDragStarted;
  final void Function() onDragEnded;
  final void Function(List<int>)? onDeleteIndividuals;
  final void Function(String) onTapPhoto;
  final List<int> selectedIndividualIndices;

  const IndividualTile({
    super.key,
    required this.index,
    required this.obsIndex,
    required this.individualName,
    required this.isSelected,
    required this.isMultiSelected,
    required this.multiSelectedCount,
    required this.sourceImages,
    required this.onTap,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onTapPhoto,
    required this.selectedIndividualIndices,
    this.onDeleteIndividuals,
  });

  @override
  Widget build(BuildContext context) {
    final label = isMultiSelected
        ? '$multiSelectedCount Individuals'
        : individualName;

    return Draggable<DragData>(
      data: DragData(
        obsIndex: obsIndex,
        indIndices: (isSelected && selectedIndividualIndices.contains(index))
            ? selectedIndividualIndices.toList()
            : [index],
      ),
      onDragStarted: () => onDragStarted(obsIndex),
      onDragEnd: (_) => onDragEnded(),
      onDraggableCanceled: (_, _) => onDragEnded(),
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
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
            selected: isSelected && selectedIndividualIndices.contains(index),
            selectedColor: Theme.of(context).colorScheme.primary,
            selectedTileColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            onTap: () => onTap(index),
            trailing: isSelected && selectedIndividualIndices.contains(index)
                ? IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    color: Theme.of(context).colorScheme.error,
                    tooltip: 'Delete individual',
                    onPressed: onDeleteIndividuals == null
                        ? null
                        : () => onDeleteIndividuals!(selectedIndividualIndices.toList()),
                  )
                : null,
          ),
          if (isSelected &&
              selectedIndividualIndices.contains(index) &&
              sourceImages.length > 1)
            Padding(
              padding: const EdgeInsets.only(left: 82, right: 16, bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: sourceImages.map((src) {
                  final filename = src.imagePath.split('/').last.split('\\').last;
                  return InkWell(
                    onTap: () => onTapPhoto(src.imagePath),
                    borderRadius: BorderRadius.circular(6),
                    hoverColor: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.05),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8,
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
