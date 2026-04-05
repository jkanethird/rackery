import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:file_picker/file_picker.dart';
import 'package:rackery/models/observation.dart';
import 'package:rackery/services/bird_classifier.dart';
import 'package:rackery/services/bird_clusterer.dart';
import 'package:rackery/services/burst_grouper.dart';
import 'package:rackery/services/csv_service.dart';
import 'package:rackery/services/image_converter.dart';
import 'package:rackery/services/bird_detector.dart';
import 'package:rackery/services/photo_processor.dart';
import 'package:rackery/services/ebird_api_service.dart';
import 'package:rackery/services/ingestion_pipeline.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/utils/name_generator.dart';
import 'package:rackery/utils/observation_operations.dart';

part 'selection_actions.dart';
part 'observation_actions.dart';
part 'manual_detection_actions.dart';
part 'photo_processing_actions.dart';
part 'export_actions.dart';

enum BoundingBoxVisibility { focused, all, hidden }

class ChecklistController extends ChangeNotifier {
  // ─── Services ────────────────────────────────────────────────────────────
  final BirdClassifier _classifier = BirdClassifier();
  final BirdDetector _detector = BirdDetector();
  final BirdClusterer _clusterer = const BirdClusterer();
  final BurstGrouper _burstGrouper = const BurstGrouper();

  // ─── App State ───────────────────────────────────────────────────────────
  bool isInit = false;
  bool isProcessing = false;
  double progress = 0.0;
  String progressMessage = '';
  DateTime? batchStartTime;
  Duration? batchElapsedTime;
  int observationVersion = 0;

  final List<Observation> observations = [];
  Observation? selectedObservation;
  String? currentlyDisplayedImage;

  // Left panel state
  List<String> selectedFiles = [];
  final Set<String> processingFiles = {};
  final Set<String> activeFiles = {};
  final Map<String, ExifData> imageExifData = {};
  final Map<String, String> imageVisualHashes = {};
  final Map<String, DateTime> fileStartTimes = {};
  final Map<String, Duration> fileElapsedTimes = {};
  List<List<String>> fileBursts = [];

  // Right panel scroll controller
  final ScrollController observationScrollController = ScrollController();
  Observation? expandedObservation;

  // Individual selection
  final Set<int> selectedIndividualIndices = {};
  int? lastSelectedIndividualIndex;
  int? draggingIndex;
  // Dropdown UI state
  bool isDropdownOpen = false;
  BoundingBoxVisibility boxVisibility = BoundingBoxVisibility.focused;

  void toggleBoundingBoxes() {
    switch (boxVisibility) {
      case BoundingBoxVisibility.focused:
        boxVisibility = BoundingBoxVisibility.all;
        break;
      case BoundingBoxVisibility.all:
        boxVisibility = BoundingBoxVisibility.hidden;
        break;
      case BoundingBoxVisibility.hidden:
        boxVisibility = BoundingBoxVisibility.focused;
        break;
    }
    notify();
  }

  void setBoundingBoxVisibility(BoundingBoxVisibility v) {
    if (boxVisibility != v) {
      boxVisibility = v;
      notify();
    }
  }

  void ensureBoundingBoxesVisible() {
    if (boxVisibility != BoundingBoxVisibility.focused) {
      boxVisibility = BoundingBoxVisibility.focused;
      notify();
    }
  }

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  ChecklistController() {
    _initClassifier();
  }

  Future<void> _initClassifier() async {
    try {
      await _classifier.init();
      await _detector.init();
      isInit = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Error initializing classifier: $e');
    }
  }

  @override
  void dispose() {
    _classifier.dispose();
    _detector.dispose();
    observationScrollController.dispose();
    super.dispose();
  }

  /// Public wrapper so part-file extensions can trigger listener updates.
  void notify() => notifyListeners();

  // ─── Display path resolution ─────────────────────────────────────────────

  Future<String?> getDisplayPath(String imagePath) async {
    if (selectedObservation?.imagePath == imagePath) {
      final path = selectedObservation!.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    }
    try {
      final obs = observations.firstWhere((o) => o.imagePath == imagePath);
      final path = obs.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    } catch (_) {}

    return ImageConverter.getDisplayPath(imagePath);
  }

  Future<Size> getImageSize(String path) async {
    final bytes = await File(path).readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    return Size(decoded.width.toDouble(), decoded.height.toDouble());
  }

  // ─── Simple setters ─────────────────────────────────────────────────────

  void setDraggingIndex(int? idx) {
    draggingIndex = idx;
    notifyListeners();
  }

  void setDropdownOpen(bool isOpen) {
    if (isDropdownOpen != isOpen) {
      isDropdownOpen = isOpen;
      notifyListeners();
    }
  }

  // ─── Clear ───────────────────────────────────────────────────────────────

  void clearAll() {
    observations.clear();
    selectedObservation = null;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentlyDisplayedImage = null;
    fileBursts.clear();
    selectedFiles.clear();
    processingFiles.clear();
    activeFiles.clear();
    imageExifData.clear();
    imageVisualHashes.clear();
    fileStartTimes.clear();
    fileElapsedTimes.clear();
    progress = 0.0;
    progressMessage = '';
    isProcessing = false;
    batchStartTime = null;
    batchElapsedTime = null;
    observationVersion = 0;
    notifyListeners();
  }
}
