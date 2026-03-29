import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:file_picker/file_picker.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/services/bird_clusterer.dart';
import 'package:ebird_generator/services/burst_grouper.dart';
import 'package:ebird_generator/services/csv_service.dart';
import 'package:ebird_generator/services/image_converter.dart';
import 'package:ebird_generator/services/bird_detector.dart';
import 'package:ebird_generator/services/photo_processor.dart';
import 'package:ebird_generator/services/ingestion_pipeline.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/utils/name_generator.dart';
import 'package:ebird_generator/utils/observation_operations.dart';

part 'selection_actions.dart';
part 'observation_actions.dart';
part 'manual_detection_actions.dart';
part 'photo_processing_actions.dart';
part 'export_actions.dart';

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

  // Individual selection
  final Set<int> selectedIndividualIndices = {};
  int? lastSelectedIndividualIndex;
  int? draggingIndex;

  // Dropdown UI state
  bool isDropdownOpen = false;

  // Center pane pager
  int currentCenterPage = 0;
  final PageController pageController = PageController();

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
    pageController.dispose();
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

  void setCenterPage(int page, String imagePath) {
    currentCenterPage = page;
    currentlyDisplayedImage = imagePath;
    notifyListeners();
  }

  // ─── Clear ───────────────────────────────────────────────────────────────

  void clearAll() {
    observations.clear();
    selectedObservation = null;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentCenterPage = 0;
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
    if (pageController.hasClients) pageController.jumpToPage(0);
    notifyListeners();
  }
}
