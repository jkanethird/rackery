import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/services/bird_clusterer.dart';
import 'package:ebird_generator/services/burst_grouper.dart';
import 'package:ebird_generator/services/csv_service.dart';
import 'package:ebird_generator/services/image_converter.dart';
import 'package:ebird_generator/services/bird_detector.dart';
import 'package:ebird_generator/services/photo_processor.dart';
import 'package:ebird_generator/ui/sine_wave_progress.dart';
import 'package:ebird_generator/ui/widgets/file_list_panel.dart';
import 'package:ebird_generator/ui/widgets/center_pane.dart';
import 'package:ebird_generator/ui/widgets/observation_list_panel.dart';

const _kLastPickerDirKey = 'last_picker_directory';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // ─── Services ────────────────────────────────────────────────────────────
  final BirdClassifier _classifier = BirdClassifier();
  final BirdDetector _detector = BirdDetector();
  final BirdClusterer _clusterer = const BirdClusterer();
  final BurstGrouper _burstGrouper = const BurstGrouper();

  // ─── App State ───────────────────────────────────────────────────────────
  bool _isInit = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  String _progressMessage = '';

  final List<Observation> _observations = [];
  Observation? _selectedObservation;
  String? _currentlyDisplayedImage;

  // Left panel state
  List<String> _selectedFiles = [];
  final Set<String> _processingFiles = {};
  final Map<String, ExifData> _imageExifData = {};
  List<List<String>> _fileBursts = [];

  // Cache on-demand HEIC→JPEG conversions for files without observations
  final Map<String, String> _convertedHeicPaths = {};

  // Right panel scroll controller
  final ScrollController _observationScrollController = ScrollController();

  // Individual selection
  final Set<int> _selectedIndividualIndices = {};
  int? _lastSelectedIndividualIndex;
  int? _draggingIndex;

  // Center pane pager
  int _currentCenterPage = 0;
  final PageController _pageController = PageController();

  // ─── Lifecycle ───────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initClassifier();
  }

  Future<void> _initClassifier() async {
    try {
      await _classifier.init();
      await _detector.init();
      setState(() => _isInit = true);
    } catch (e) {
      debugPrint('Error initializing classifier: $e');
    }
  }

  @override
  void dispose() {
    _classifier.dispose();
    _detector.dispose();
    _observationScrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  // ─── Display path resolution ─────────────────────────────────────────────

  /// Returns the best displayable (non-HEIC) path for [imagePath].
  Future<String?> _getDisplayPath(String imagePath) async {
    if (_selectedObservation?.imagePath == imagePath) {
      final path = _selectedObservation!.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    }
    try {
      final obs = _observations.firstWhere((o) => o.imagePath == imagePath);
      final path = obs.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    } catch (_) {}

    if (!imagePath.toLowerCase().endsWith('.heic') &&
        !imagePath.toLowerCase().endsWith('.heif')) {
      return imagePath;
    }

    if (_convertedHeicPaths.containsKey(imagePath)) {
      return _convertedHeicPaths[imagePath];
    }
    final converted = await ImageConverter.convertToJpegIfNeeded(imagePath);
    if (converted != null && converted != imagePath) {
      _convertedHeicPaths[imagePath] = converted;
      return converted;
    }
    return imagePath;
  }

  Future<Size> _getImageSize(String path) async {
    final bytes = await File(path).readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    return Size(decoded.width.toDouble(), decoded.height.toDouble());
  }

  // ─── Photo selection & processing ────────────────────────────────────────

  Future<void> _selectAndProcessPhotos() async {
    final prefs = await SharedPreferences.getInstance();
    final lastDir = prefs.getString(_kLastPickerDirKey);

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      initialDirectory: lastDir,
      allowedExtensions: [
        'jpg', 'jpeg', 'png', 'heic', 'heif',
        'JPG', 'JPEG', 'PNG', 'HEIC', 'HEIF',
      ],
    );

    if (result == null) return;

    // Save last-used directory
    final firstPath = result.files.first.path;
    if (firstPath != null) {
      await prefs.setString(
          _kLastPickerDirKey, File(firstPath).parent.path);
    }

    // Only process genuinely new files
    final pickedPaths = result.files.map((f) => f.path!).toSet();
    final newPaths = pickedPaths.difference(_selectedFiles.toSet()).toList();
    if (newPaths.isEmpty) return;

    // Sort smallest-first so quick results appear early
    newPaths.sort((a, b) =>
        File(a).lengthSync().compareTo(File(b).lengthSync()));

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _progressMessage = 'Preparing files...';
      _selectedFiles.addAll(newPaths);
      _processingFiles.addAll(newPaths);
    });

    // Pre-extract EXIF for new files
    for (final path in newPaths) {
      try {
        _imageExifData[path] = await ExifService.extractExif(path);
      } catch (_) {
        _imageExifData[path] = ExifData();
      }
    }

    // Re-group ALL files (old + new) into chronological bursts
    final allFileData = _selectedFiles.map((path) {
      return {'path': path, 'exif': _imageExifData[path] ?? ExifData()};
    }).toList();

    allFileData.sort((a, b) {
      final dateA = (a['exif'] as ExifData).dateTime;
      final dateB = (b['exif'] as ExifData).dateTime;
      if (dateA == null && dateB == null) return 0;
      if (dateA == null) return 1;
      if (dateB == null) return -1;
      return dateA.compareTo(dateB);
    });

    final bursts = _burstGrouper.group(allFileData);

    setState(() {
      _fileBursts = bursts;
      _selectedFiles = bursts.expand((b) => b).toList();
    });

    // Run the two-phase pipeline
    final processor = PhotoProcessor(
      classifier: _classifier,
      detector: _detector,
      clusterer: _clusterer,
    );

    await processor.run(
      newPaths: newPaths,
      bursts: bursts,
      onProgress: (value) {
        if (mounted) setState(() => _progress = value);
      },
      onProgressMessage: (msg) {
        if (mounted) setState(() => _progressMessage = msg);
      },
      onObservationAdded: (newObs) {
        if (mounted) setState(() => _observations.addAll(newObs));
      },
      onFileCompleted: (filePath) {
        if (mounted) setState(() => _processingFiles.remove(filePath));
      },
      onError: (filePath, error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error processing $filePath: $error')),
          );
        }
      },
    );

    setState(() {
      _isProcessing = false;
      if (_selectedObservation == null && _observations.isNotEmpty) {
        _selectedObservation = _observations.first;
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
        _currentCenterPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
        _currentlyDisplayedImage = _selectedObservation!.imagePath;
      }
    });
  }

  // ─── Clear ───────────────────────────────────────────────────────────────

  void _clearAll() {
    setState(() {
      _observations.clear();
      _selectedObservation = null;
      _selectedIndividualIndices.clear();
      _lastSelectedIndividualIndex = null;
      _currentCenterPage = 0;
      _currentlyDisplayedImage = null;
      _fileBursts = [];
      _selectedFiles.clear();
      _processingFiles.clear();
      _imageExifData.clear();
      _progress = 0.0;
      _progressMessage = '';
      _isProcessing = false;
    });
    if (_pageController.hasClients) _pageController.jumpToPage(0);
  }

  // ─── Export ──────────────────────────────────────────────────────────────

  Future<void> _exportCsv() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'ebird_checklist.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (outputFile == null) return;

    if (!outputFile.endsWith('.csv')) outputFile += '.csv';
    await CsvService.generateEbirdCsv(_observations, outputFile);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV exported to $outputFile')),
      );
    }
  }

  // ─── Scroll helper ───────────────────────────────────────────────────────

  void _scrollToObservationForImage(String imagePath) {
    if (!_observationScrollController.hasClients) return;
    final idx = _observations.indexWhere((o) => o.imagePath == imagePath);
    if (idx < 0) return;
    const estimatedItemHeight = 96.0;
    final target = (idx * estimatedItemHeight).clamp(
      0.0,
      _observationScrollController.position.maxScrollExtent,
    );
    _observationScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // ─── Merge / extract operations ──────────────────────────────────────────

  void _mergeObservations(int fromIdx, int intoIdx) {
    if (fromIdx == intoIdx) return;
    setState(() {
      final from = _observations[fromIdx];
      final into = _observations[intoIdx];
      into.count += from.count;
      into.boundingBoxes.addAll(from.boundingBoxes);
      for (final s in from.possibleSpecies) {
        if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
      }
      final existingPaths = into.sourceImages.map((s) => s.imagePath).toSet();
      for (final src in from.sourceImages) {
        if (existingPaths.add(src.imagePath)) into.sourceImages.add(src);
      }
      for (final entry in from.boxesByImagePath.entries) {
        into.boxesByImagePath.putIfAbsent(entry.key, () => []).addAll(entry.value);
      }
      _observations.removeAt(fromIdx);
      if (_selectedObservation == from) {
        _selectedObservation = into;
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
        _currentCenterPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
      }
    });
  }

  void _mergeIndividuals(int fromObsIdx, List<int> indIndices, int intoIdx) {
    if (fromObsIdx == intoIdx || indIndices.isEmpty) return;
    setState(() {
      final from = _observations[fromObsIdx];
      final into = _observations[intoIdx];
      into.count += indIndices.length;
      from.count -= indIndices.length;

      final sortedIndices = List<int>.from(indIndices)
        ..sort((a, b) => b.compareTo(a));

      for (final src in List.from(from.sourceImages)) {
        final path = src.imagePath;
        final fromBoxes = from.boxesByImagePath[path];
        if (fromBoxes != null && fromBoxes.isNotEmpty) {
          final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
            ..sort((a, b) => a.left.compareTo(b.left));
          for (final idx in sortedIndices) {
            if (idx < sortedBoxes.length) {
              final box = sortedBoxes[idx];
              fromBoxes.remove(box);
              into.boxesByImagePath.putIfAbsent(path, () => []).add(box);
              from.boundingBoxes.remove(box);
              into.boundingBoxes.add(box);
            }
          }
        }
        if (!into.sourceImages.any((s) => s.imagePath == src.imagePath)) {
          into.sourceImages.add(src);
        }
      }
      for (final s in from.possibleSpecies) {
        if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
      }
      if (from.count <= 0) {
        _observations.removeAt(fromObsIdx);
      } else if (_selectedObservation == from) {
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
      }
      if (_selectedObservation == from && from.count <= 0) {
        _selectedObservation =
            _observations.isNotEmpty ? _observations.first : null;
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
        _currentCenterPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
      }
    });
  }

  void _extractIndividuals(
    int fromObsIdx,
    List<int> indIndices,
    int insertAtIdx,
  ) {
    if (indIndices.isEmpty) return;
    setState(() {
      final from = _observations[fromObsIdx];

      final newObs = Observation(
        imagePath: from.imagePath,
        displayPath: from.displayPath,
        fullImageDisplayPath: from.fullImageDisplayPath,
        speciesName: from.speciesName,
        possibleSpecies: List.from(from.possibleSpecies),
        exifData: from.exifData,
        count: indIndices.length,
        boundingBoxes: [],
        sourceImages: [],
        boxesByImagePath: {},
        burstId: from.burstId,
      );
      from.count -= indIndices.length;

      final sortedIndices = List<int>.from(indIndices)
        ..sort((a, b) => b.compareTo(a));

      for (final src in List.from(from.sourceImages)) {
        final path = src.imagePath;
        final fromBoxes = from.boxesByImagePath[path];
        if (fromBoxes != null && fromBoxes.isNotEmpty) {
          final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
            ..sort((a, b) => a.left.compareTo(b.left));
          for (final idx in sortedIndices) {
            if (idx < sortedBoxes.length) {
              final box = sortedBoxes[idx];
              fromBoxes.remove(box);
              newObs.boxesByImagePath.putIfAbsent(path, () => []).add(box);
              from.boundingBoxes.remove(box);
              newObs.boundingBoxes.add(box);
            }
          }
        }
        if (newObs.boxesByImagePath.containsKey(path) &&
            newObs.boxesByImagePath[path]!.isNotEmpty) {
          newObs.sourceImages.add(src);
        }
      }

      int actualInsertIdx = insertAtIdx;
      if (from.count <= 0) {
        _observations.removeAt(fromObsIdx);
        if (insertAtIdx > fromObsIdx) actualInsertIdx--;
      } else if (_selectedObservation == from) {
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
      }
      _observations.insert(actualInsertIdx, newObs);
      if (_selectedObservation == from && from.count <= 0) {
        _selectedObservation = newObs;
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
        _currentCenterPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
      }
    });
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_isInit) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('eBird Checklist Generator'),
        actions: [
          if (_selectedFiles.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _isProcessing ? null : _clearAll,
              tooltip: 'Clear all photos and results',
            ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _observations.isEmpty || _isProcessing ? null : _exportCsv,
            tooltip: 'Export CSV',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: file list
                Expanded(
                  flex: 1,
                  child: Container(
                    color: Theme.of(context).cardColor,
                    child: FileListPanel(
                      fileBursts: _fileBursts,
                      selectedFiles: _selectedFiles,
                      processingFiles: _processingFiles,
                      imageExifData: _imageExifData,
                      observations: _observations,
                      currentlyDisplayedImage: _currentlyDisplayedImage,
                      onFileTapped: (file) {
                        setState(() {
                          _currentlyDisplayedImage = file;
                          _selectedObservation = _observations
                              .where((o) => o.imagePath == file)
                              .firstOrNull;
                          _selectedIndividualIndices.clear();
                          _lastSelectedIndividualIndex = null;
                          _currentCenterPage = 0;
                          if (_pageController.hasClients) {
                            _pageController.jumpToPage(0);
                          }
                        });
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _scrollToObservationForImage(file),
                        );
                      },
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),

                // Centre: photo viewer
                CenterPane(
                  selectedObservation: _selectedObservation,
                  selectedIndividualIndices: _selectedIndividualIndices,
                  currentlyDisplayedImage: _currentlyDisplayedImage,
                  imageExifData: _imageExifData,
                  currentPage: _currentCenterPage,
                  pageController: _pageController,
                  getDisplayPath: _getDisplayPath,
                  getImageSize: _getImageSize,
                  onPageChanged: (page, imagePath) {
                    setState(() {
                      _currentCenterPage = page;
                      _currentlyDisplayedImage = imagePath;
                    });
                  },
                ),

                const VerticalDivider(width: 1),

                // Right: observations list
                Expanded(
                  flex: 1,
                  child: ObservationListPanel(
                    observations: _observations,
                    selectedObservation: _selectedObservation,
                    selectedIndividualIndices: _selectedIndividualIndices,
                    lastSelectedIndividualIndex: _lastSelectedIndividualIndex,
                    draggingIndex: _draggingIndex,
                    scrollController: _observationScrollController,
                    onTapCard: (obs) {
                      setState(() {
                        _selectedObservation = obs;
                        _currentlyDisplayedImage = obs.imagePath;
                        _selectedIndividualIndices.clear();
                        _lastSelectedIndividualIndex = null;
                        _currentCenterPage = 0;
                        if (_pageController.hasClients) {
                          _pageController.jumpToPage(0);
                        }
                      });
                    },
                    onTapIndividual: (obs, i) {
                      setState(() {
                        if (_selectedObservation != obs) {
                          _selectedObservation = obs;
                          _currentlyDisplayedImage = obs.imagePath;
                          _selectedIndividualIndices.clear();
                          _lastSelectedIndividualIndex = null;
                        }
                        _selectedIndividualIndices.clear();
                        _selectedIndividualIndices.add(i);
                        _lastSelectedIndividualIndex = i;
                        _currentCenterPage = 0;
                        if (_pageController.hasClients) {
                          _pageController.jumpToPage(0);
                        }
                      });
                    },
                    onSpeciesChanged: (obs, val) {
                      obs.speciesName = val;
                    },
                    onSpeciesSelected: (obs, choice) {
                      setState(() => obs.speciesName = choice);
                    },
                    onCountChanged: (obs, count) {
                      obs.count = count;
                    },
                    onMergeObservations: _mergeObservations,
                    onMergeIndividuals: _mergeIndividuals,
                    onDragStarted: (idx) {
                      setState(() => _draggingIndex = idx);
                    },
                    onDragEnded: () {
                      setState(() => _draggingIndex = null);
                    },
                    onExtractIndividuals: _extractIndividuals,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _selectAndProcessPhotos,
            icon: const Icon(Icons.photo_library),
            label: const Text('Select Photos'),
          ),
          const SizedBox(width: 16),
          if (_isProcessing)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _progressMessage.isNotEmpty
                        ? _progressMessage
                        : 'Processing images...',
                  ),
                  const SizedBox(height: 8),
                  SineWaveProgressIndicator(value: _progress),
                ],
              ),
            )
          else
            Expanded(
              child: Text(
                _observations.isEmpty
                    ? 'No photos selected'
                    : '${_observations.length} observations generated',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }
}
