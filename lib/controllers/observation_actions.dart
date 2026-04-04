part of 'checklist_controller.dart';

/// Observation mutation actions for [ChecklistController].
extension ObservationActions on ChecklistController {
  void updateObservationSpecies(Observation obs, String species) {
    obs.speciesName = species;
    observationVersion++;
    notify();
  }

  void updateObservationCount(Observation obs, int count) {
    obs.count = count;
    while (obs.individualNames.length < count) {
      obs.individualNames.add(generatePronounceableName());
    }
    if (obs.individualNames.length > count) {
      obs.individualNames.removeRange(count, obs.individualNames.length);
    }
    observationVersion++;
    notify();
  }

  void _syncSelectionAfterMutation(Observation from) {
    if (from.count <= 0) {
      if (selectedObservation == from) {
        selectedObservation = observations.isNotEmpty
            ? observations.first
            : null;
        selectedIndividualIndices.clear();
        lastSelectedIndividualIndex = null;
      }
    } else if (selectedObservation == from) {
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
  }

  void mergeObservations(int fromIdx, int intoIdx) {
    final from = observations[fromIdx];
    final into = observations[intoIdx];
    ObservationOperations.mergeObservations(observations, fromIdx, intoIdx);
    if (selectedObservation == from) {
      selectedObservation = into;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    notify();
  }

  void mergeIndividuals(int fromObsIdx, List<int> indIndices, int intoIdx) {
    final from = observations[fromObsIdx];
    ObservationOperations.mergeIndividuals(
      observations,
      fromObsIdx,
      indIndices,
      intoIdx,
    );
    _syncSelectionAfterMutation(from);
    notify();
  }

  void extractIndividuals(
    int fromObsIdx,
    List<int> indIndices,
    int insertAtIdx,
  ) {
    final from = observations[fromObsIdx];
    final bool wasSelected = selectedObservation == from;
    final bool wasDeleted = from.count - indIndices.length <= 0;

    final newObs = ObservationOperations.extractIndividuals(
      observations,
      fromObsIdx,
      indIndices,
      insertAtIdx,
    );
    if (newObs == null) return;

    if (wasSelected && wasDeleted) {
      selectedObservation = newObs;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    } else if (wasSelected) {
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    notify();
  }

  void deleteIndividuals(int obsIdx, List<int> indIndices) {
    final from = observations[obsIdx];
    final bool wasSelected = selectedObservation == from;
    final bool wasDeleted = from.count - indIndices.length <= 0;

    ObservationOperations.deleteIndividuals(observations, obsIdx, indIndices);

    if (wasSelected && wasDeleted) {
      selectedObservation = null;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
      currentlyDisplayedImage = processingFiles.isNotEmpty
          ? processingFiles.first
          : null;
    } else if (wasSelected) {
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    notify();
  }
}
