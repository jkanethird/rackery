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
