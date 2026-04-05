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
import 'package:rackery/models/observation.dart';
import 'package:rackery/ui/drag_data.dart';
import 'package:rackery/ui/widgets/observation_card.dart' hide DragData;
import 'package:rackery/ui/widgets/superellipse_border.dart';

/// Right-side panel: a scrollable list of [ObservationCard]s with drag-and-drop
/// support for merging observations and extracting individuals.
class ObservationListPanel extends StatelessWidget {
  final List<Observation> observations;
  final Observation? selectedObservation;
  final Observation? expandedObservation;
  final Set<int> selectedIndividualIndices;
  final int? lastSelectedIndividualIndex;
  final int? draggingIndex;
  final bool isDropdownOpen;
  final ScrollController scrollController;

  // Card interaction callbacks
  final void Function(Observation obs) onTapCard;
  final void Function(Observation obs, int i) onTapIndividual;
  final void Function(Observation obs) onToggleExpanded;
  final void Function(Observation obs, String val) onSpeciesChanged;
  final void Function(Observation obs, String choice) onSpeciesSelected;
  final void Function(Observation obs, int count) onCountChanged;
  final void Function(int fromIdx, int intoIdx) onMergeObservations;
  final void Function(int fromObsIdx, List<int> indIndices, int intoIdx)
  onMergeIndividuals;
  final void Function(int dragIndex) onDragStarted;
  final void Function() onDragEnded;
  final void Function(int fromObsIdx, List<int> indIndices, int insertAtIdx)
  onExtractIndividuals;
  final void Function(String imagePath) onTapPhoto;
  final void Function(bool isOpen)? onDropdownToggled;
  final void Function(int obsIdx, List<int> indIndices)? onDeleteIndividuals;

  const ObservationListPanel({
    super.key,
    required this.observations,
    required this.selectedObservation,
    required this.expandedObservation,
    required this.selectedIndividualIndices,
    required this.lastSelectedIndividualIndex,
    required this.draggingIndex,
    required this.isDropdownOpen,
    required this.scrollController,
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
    required this.onExtractIndividuals,
    required this.onTapPhoto,
    this.onDropdownToggled,
    this.onDeleteIndividuals,
  });

  @override
  Widget build(BuildContext context) {
    final listView = ListView.builder(
      controller: scrollController,
      physics: isDropdownOpen ? const NeverScrollableScrollPhysics() : null,
      itemCount: observations.length,
      findChildIndexCallback: (Key key) {
        if (key is ObjectKey && key.value is Observation) {
          final obs = key.value as Observation;
          final idx = observations.indexOf(obs);
          if (idx >= 0) return idx;
        }
        return null;
      },
      itemBuilder: (context, index) {
        final obs = observations[index];
        final isSelected = selectedObservation == obs;
        final isExpanded = expandedObservation == obs;
        final isDragging = draggingIndex == index;

        final observationItem = ObservationCard(
          key: ObjectKey(obs),
          obs: obs,
          index: index,
          isSelected: isSelected,
          isExpanded: isExpanded,
          isDragging: isDragging,
          selectedIndividualIndices: selectedIndividualIndices.toList(),
          lastSelectedIndividualIndex: lastSelectedIndividualIndex,
          onTapCard: () => onTapCard(obs),
          onTapIndividual: (int i) => onTapIndividual(obs, i),
          onToggleExpanded: () => onToggleExpanded(obs),
          onSpeciesChanged: (val) => onSpeciesChanged(obs, val),
          onSpeciesSelected: (choice) => onSpeciesSelected(obs, choice),
          onCountChanged: (count) => onCountChanged(obs, count),
          onMergeObservations: onMergeObservations,
          onMergeIndividuals: onMergeIndividuals,
          onDragStarted: onDragStarted,
          onDragEnded: onDragEnded,
          onTapPhoto: onTapPhoto,
          onDropdownToggled: onDropdownToggled,
          onDeleteIndividuals: (indIndices) =>
              onDeleteIndividuals?.call(index, indIndices),
        );

        // Show a burst separator between this item and the next if bursts differ.
        final isLastInBurst =
            index < observations.length - 1 &&
            observations[index].burstId != observations[index + 1].burstId;

        Widget dropZone(int targetIndex, {Widget? child}) {
          return DragTarget<DragData>(
            onWillAcceptWithDetails: (details) {
              if (details.data.indIndices == null) {
                debugPrint('Drag reject: indIndices is null');
                return false;
              }
              // We allow dropping here to create a new observation set.
              // To be safe, we allow any valid individual drag.
              // The ChecklistController will handle the array insertion safely.
              return true;
            },
            onAcceptWithDetails: (details) {
              onExtractIndividuals(
                details.data.obsIndex,
                details.data.indIndices!,
                targetIndex,
              );
            },
            builder: (context, candidateData, rejectedData) {
              return Container(
                width: double.infinity,
                margin: child == null
                    ? const EdgeInsets.symmetric(horizontal: 24)
                    : EdgeInsets.zero,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: candidateData.isNotEmpty
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
                child: child ?? const SizedBox(height: 12),
              );
            },
          );
        }

        return Column(
          key: GlobalObjectKey(obs),
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drop zone above the first item
            if (index == 0) dropZone(0),

            observationItem,

            // Between items: burst divider or plain drop zone (but not for last item)
            if (index < observations.length - 1) ...[
              if (isLastInBurst)
                dropZone(
                  index + 1,
                  child: const Divider(
                    height: 32,
                    thickness: 1,
                    indent: 32,
                    endIndent: 32,
                    color: Colors.white24,
                  ),
                )
              else
                dropZone(index + 1),
            ],

            // Drop zone below the last item
            if (index == observations.length - 1) dropZone(observations.length),
          ],
        );
      },
    );

    return Stack(
      children: [
        listView,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ListenableBuilder(
            listenable: scrollController,
            builder: (context, _) {
              final show =
                  scrollController.hasClients &&
                  scrollController.position.hasContentDimensions &&
                  scrollController.position.maxScrollExtent > 0 &&
                  scrollController.position.pixels > 0;
              if (!show) return const SizedBox.shrink();
              return _buildScrollButton(
                context: context,
                tooltip: 'Go to top',
                pointingUp: true,
                onPressed: () {
                  scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                },
              );
            },
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: ListenableBuilder(
            listenable: scrollController,
            builder: (context, _) {
              final show =
                  scrollController.hasClients &&
                  scrollController.position.hasContentDimensions &&
                  scrollController.position.maxScrollExtent > 0 &&
                  scrollController.position.pixels <
                      scrollController.position.maxScrollExtent;
              if (!show) return const SizedBox.shrink();
              return _buildScrollButton(
                context: context,
                tooltip: 'Go to bottom',
                pointingUp: false,
                onPressed: () {
                  void scrollToBottom([bool isInitial = true]) {
                    if (!scrollController.hasClients) return;
                    scrollController
                        .animateTo(
                          scrollController.position.maxScrollExtent,
                          duration: Duration(
                            milliseconds: isInitial ? 300 : 100,
                          ),
                          curve: isInitial ? Curves.easeOut : Curves.linear,
                        )
                        .then((_) {
                          if (scrollController.hasClients &&
                              scrollController.position.pixels <
                                  scrollController.position.maxScrollExtent) {
                            scrollToBottom(false);
                          }
                        });
                  }

                  scrollToBottom();
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildScrollButton({
    required BuildContext context,
    required String tooltip,
    required bool pointingUp,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16.0,
        right: 16.0,
        top: pointingUp ? 8.0 : 0.0,
        bottom: pointingUp ? 0.0 : 8.0,
      ),
      child: Center(
        child: ClipRect(
          child: Align(
            alignment: pointingUp
                ? Alignment.topCenter
                : Alignment.bottomCenter,
            heightFactor: 0.5,
            child: SizedBox(
              width: double.infinity,
              height: 32, // Shorter height, 16px when clipped
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.8),
                shape: const SuperellipseBorder(m: 200, n: 20),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onPressed,
                  mouseCursor: SystemMouseCursors.click,
                  child: Tooltip(
                    message: tooltip,
                    child: Align(
                      alignment: pointingUp
                          ? const Alignment(0, -0.6)
                          : const Alignment(0, 0.6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: SizedBox(
                          width: double.infinity,
                          height: 8,
                          child: CustomPaint(
                            painter: _WideChevronPainter(
                              pointingUp: pointingUp,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer
                                  .withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WideChevronPainter extends CustomPainter {
  final bool pointingUp;
  final Color color;

  _WideChevronPainter({required this.pointingUp, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path();
    if (pointingUp) {
      path.moveTo(0, size.height);
      path.lineTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width / 2, size.height);
      path.lineTo(size.width, 0);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WideChevronPainter oldDelegate) {
    return pointingUp != oldDelegate.pointingUp || color != oldDelegate.color;
  }
}
