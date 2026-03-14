/// Carries the payload for drag-and-drop operations on observation cards.
class DragData {
  final int obsIndex;

  /// When non-null, the drag represents individual birds within the observation
  /// rather than the whole observation.
  final List<int>? indIndices;

  DragData({required this.obsIndex, this.indIndices});
}
