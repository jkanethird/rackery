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

  void selectIndividual(Observation obs, int i) {
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
    scrollToObservation(obs);
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

    const estimatedItemHeight = 120.0;
    final target = (index * estimatedItemHeight).clamp(
      0.0,
      observationScrollController.position.maxScrollExtent,
    );
    observationScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void scrollToObservationForImage(String imagePath) {
    final obs = observations.where((o) => o.imagePath == imagePath).firstOrNull;
    if (obs != null) scrollToObservation(obs);
  }
}
