import 'package:flutter/material.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/ui/drag_data.dart';
import 'package:ebird_generator/ui/widgets/observation_card.dart' hide DragData;

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
    return ListView.builder(
      controller: scrollController,
      physics: isDropdownOpen ? const NeverScrollableScrollPhysics() : null,
      itemCount: observations.length,
      findChildIndexCallback: (Key key) {
        if (key is ObjectKey && key.value is Observation) {
          final obs = key.value as Observation;
          final idx = observations.indexOf(obs);
          if (idx >= 0) return observations.length - 1 - idx;
        }
        return null;
      },
      itemBuilder: (context, i) {
        final index = observations.length - 1 - i;
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

        // In reversed display order, index+1 is the item visually *above*.
        // Show a separator when this item's burst differs from the one below.
        final isFirstInBurst =
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
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
                child: child ?? const SizedBox(height: 12),
              );
            },
          );
        }

        return Column(
          key: ObjectKey(obs),
          mainAxisSize: MainAxisSize.min,
          children: [
            // Ensure the very top drop zone is rendered above the highest indexed item
            if (index == observations.length - 1)
              dropZone(index + 1),
              
            if (isFirstInBurst)
              dropZone(index + 1, child: const Divider(
                height: 32,
                thickness: 1,
                indent: 32,
                endIndent: 32,
                color: Colors.white24,
              ))
            else if (index < observations.length - 1)
              // Only need the 12px drop zone if we didn't just render a full divider
              dropZone(index + 1),
              
            observationItem,
            
            if (index == 0) dropZone(0),
          ],
        );
      },
    );
  }
}
