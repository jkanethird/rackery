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
    currentCenterPage = 0;
    if (pageController.hasClients) pageController.jumpToPage(0);
    notify();
  }

  void selectObservation(Observation obs) {
    selectedObservation = obs;
    currentlyDisplayedImage = obs.imagePath;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentCenterPage = 0;
    if (pageController.hasClients) pageController.jumpToPage(0);
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
    currentCenterPage = 0;
    if (pageController.hasClients) pageController.jumpToPage(0);
    notify();
  }

  void scrollToObservationForImage(String imagePath) {
    if (!observationScrollController.hasClients) return;
    final idx = observations.indexWhere((o) => o.imagePath == imagePath);
    if (idx < 0) return;
    const estimatedItemHeight = 96.0;
    final target = (idx * estimatedItemHeight).clamp(
      0.0,
      observationScrollController.position.maxScrollExtent,
    );
    observationScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
}
