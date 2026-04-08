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

/// Selection-related actions for [ChecklistController].
extension SelectionActions on ChecklistController {
  void selectFile(String file) {
    currentlyDisplayedImage = file;
    selectedObservation = observations
        .where((o) => o.imagePath == file)
        .firstOrNull;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    ensureBoundingBoxesVisible();
    notify();
  }

  void selectObservation(Observation obs) {
    selectedObservation = obs;
    currentlyDisplayedImage = obs.imagePath;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    ensureBoundingBoxesVisible();
    notify();
  }

  void selectPhotoImage(String imagePath) {
    currentlyDisplayedImage = imagePath;
    ensureBoundingBoxesVisible();
    notify();
  }

  void selectIndividual(Observation obs, int i, {bool scroll = true}) {
    if (selectedObservation != obs) {
      selectedObservation = obs;
      currentlyDisplayedImage = obs.imagePath;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    selectedIndividualIndices.clear();
    selectedIndividualIndices.add(i);
    lastSelectedIndividualIndex = i;
    expandedObservation = obs;
    ensureBoundingBoxesVisible();
    if (scroll) scrollToObservation(obs);
    notify();
  }

  void toggleExpanded(Observation obs) {
    if (expandedObservation == obs) {
      expandedObservation = null;
    } else {
      expandedObservation = obs;
    }
    notify();
  }

  void scrollToObservation(Observation obs) async {
    // Wait for the ObservationCard's AnimatedSize expansion (300ms) to complete
    // so that the scroll controller's maxScrollExtent grows appropriately.
    await Future.delayed(const Duration(milliseconds: 310));

    if (!observationScrollController.hasClients) return;
    final index = observations.indexOf(obs);
    if (index < 0) return;

    // Phase 1: Jump roughly so the lazy ListView builds the target item.
    const estimatedItemHeight = 120.0;
    final roughTarget = (index * estimatedItemHeight).clamp(
      0.0,
      observationScrollController.position.maxScrollExtent,
    );
    observationScrollController.jumpTo(roughTarget);

    // Let the frame rebuild so the widget is in the tree.
    await Future.delayed(const Duration(milliseconds: 50));

    // Phase 2: Use the actual widget position for pixel-perfect scrolling.
    final key = GlobalObjectKey(obs);
    final ctx = key.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
  }

  void scrollToObservationForImage(String imagePath) {
    final obs = observations.where((o) => o.imagePath == imagePath).firstOrNull;
    if (obs != null) scrollToObservation(obs);
  }
}
