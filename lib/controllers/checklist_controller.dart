import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
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

  // ─── Photo selection & processing ────────────────────────────────────────

  Future<void> selectAndProcessPhotos(BuildContext context) async {
    final result = await IngestionPipeline.gatherFiles(
      currentSelectedFiles: selectedFiles,
      currentExifData: imageExifData,
      currentVisualHashes: imageVisualHashes,
      burstGrouper: _burstGrouper,
      onStartProcessing: () {
        isProcessing = true;
        progress = 0.0;
        progressMessage = 'Preparing files...';
        batchStartTime = DateTime.now();
        batchElapsedTime = null;
        notifyListeners();
      },
    );

    if (result == null) return;

    selectedFiles = result.allFiles;
    processingFiles.addAll(result.newPaths);
    fileBursts = result.bursts;
    imageExifData.addAll(result.exifData);
    imageVisualHashes.addAll(result.visualHashes);

    if (currentlyDisplayedImage == null && processingFiles.isNotEmpty) {
      currentlyDisplayedImage = processingFiles.first;
      notifyListeners();
    }

    final int sessionTime = DateTime.now().millisecondsSinceEpoch;
    final List<String> burstIds = List.generate(
      fileBursts.length,
      (i) => 'burst_${sessionTime}_$i',
    );

    for (int i = 0; i < fileBursts.length; i++) {
      final burstSet = fileBursts[i];
      final bId = burstIds[i];
      for (final obs in observations) {
        if (burstSet.contains(obs.imagePath)) {
          obs.burstId = bId;
        }
      }
    }

    notifyListeners();

    final processor = PhotoProcessor(
      classifier: _classifier,
      detector: _detector,
      clusterer: _clusterer,
    );

    await processor.run(
      newPaths: result.newPaths,
      bursts: result.bursts,
      burstIds: burstIds,
      onProgress: (value) {
        progress = value;
        notifyListeners();
      },
      onProgressMessage: (msg) {
        progressMessage = msg;
        notifyListeners();
      },
      onObservationAdded: (newObs) {
        observations.addAll(newObs);
        observationVersion++;
        notifyListeners();
      },
      onObservationsChanged: () {
        observationVersion++;
        notifyListeners();
      },
      onFileStarted: (filePath) {
        activeFiles.add(filePath);
        fileStartTimes.putIfAbsent(filePath, () => DateTime.now());
        notifyListeners();
      },
      onFileCompleted: (filePath) {
        processingFiles.remove(filePath);
        activeFiles.remove(filePath);
        final startTime = fileStartTimes.remove(filePath);
        if (startTime != null) {
          fileElapsedTimes[filePath] = DateTime.now().difference(startTime);
        }
        notifyListeners();
      },
      onError: (filePath, error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error processing $filePath: $error')),
          );
        }
      },
    );

    isProcessing = false;
    activeFiles.clear();
    if (batchStartTime != null) {
      batchElapsedTime = DateTime.now().difference(batchStartTime!);
      batchStartTime = null;
    }
    if (selectedObservation == null && observations.isNotEmpty) {
      selectedObservation = observations.first;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
      currentlyDisplayedImage = selectedObservation!.imagePath;
    }
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

  // ─── Export ──────────────────────────────────────────────────────────────

  Future<void> exportCsv(BuildContext context) async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'ebird_checklist.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (outputFile == null) return;

    if (!outputFile.endsWith('.csv')) outputFile += '.csv';
    await CsvService.generateEbirdCsv(observations, outputFile);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV exported to $outputFile')));
    }
  }

  // ─── Selection Helpers ───────────────────────────────────────────────────

  void selectFile(String file) {
    currentlyDisplayedImage = file;
    selectedObservation = observations
        .where((o) => o.imagePath == file)
        .firstOrNull;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentCenterPage = 0;
    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
    notifyListeners();
  }

  void selectObservation(Observation obs) {
    selectedObservation = obs;
    currentlyDisplayedImage = obs.imagePath;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentCenterPage = 0;
    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
    notifyListeners();
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
    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
    notifyListeners();
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

  // ─── Merge / extract operations ──────────────────────────────────────────

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

  void updateObservationSpecies(Observation obs, String species) {
    obs.speciesName = species;
    notifyListeners();
  }

  void updateObservationCount(Observation obs, int count) {
    obs.count = count;
    while (obs.individualNames.length < count) {
      obs.individualNames.add(generatePronounceableName());
    }
    if (obs.individualNames.length > count) {
      obs.individualNames.removeRange(count, obs.individualNames.length);
    }
    notifyListeners();
  }

  void _syncSelectionAfterMutation(Observation from) {
    if (from.count <= 0) {
      if (selectedObservation == from) {
        selectedObservation = observations.isNotEmpty
            ? observations.first
            : null;
        selectedIndividualIndices.clear();
        lastSelectedIndividualIndex = null;
        currentCenterPage = 0;
        if (pageController.hasClients) pageController.jumpToPage(0);
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
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
    }
    notifyListeners();
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
    notifyListeners();
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
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
    } else if (wasSelected) {
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    notifyListeners();
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
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
      currentlyDisplayedImage = processingFiles.isNotEmpty
          ? processingFiles.first
          : null;
    } else if (wasSelected) {
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    notifyListeners();
    notifyListeners();
  }

  void addManualIndividual(String imagePath, Rectangle<int> box) {
    if (selectedObservation != null) {
      ObservationOperations.addIndividual(selectedObservation!, imagePath, box);
      observationVersion++;
      notifyListeners();
    } else {
      final newObs = Observation(
        imagePath: imagePath,
        speciesName: 'Identifying...',
        exifData: imageExifData[imagePath] ?? ExifData(),
        count: 1,
        boundingBoxes: [box],
        boxesByImagePath: {
          imagePath: [box],
        },
        fullImageDisplayPath: processingFiles.contains(imagePath)
            ? null
            : imagePath,
      );
      observations.add(newObs);
      selectedObservation = newObs;

      observationVersion++;
      notifyListeners();

      _classifyManualIndividual(newObs, box);
    }
  }

  Future<void> _classifyManualIndividual(
    Observation obs,
    Rectangle<int> box,
  ) async {
    final suggestions = await _classifier.classifyFile(
      obs.imagePath,
      box: box,
      latitude: obs.exifData.latitude,
      longitude: obs.exifData.longitude,
      photoDate: obs.exifData.dateTime,
    );

    // Only update if the observation wasn't deleted by the user while classifying
    if (observations.contains(obs)) {
      if (suggestions.isNotEmpty) {
        obs.speciesName = suggestions.first;
        obs.possibleSpecies = suggestions;
      } else {
        obs.speciesName = 'Unknown Bird';
      }
      observationVersion++;
      notifyListeners();
    }
  }
}
