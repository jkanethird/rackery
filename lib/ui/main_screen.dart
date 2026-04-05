import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rackery/controllers/checklist_controller.dart';
import 'package:rackery/ui/sine_wave_progress.dart';
import 'package:rackery/ui/widgets/file_list_panel.dart';
import 'package:rackery/ui/widgets/center_pane.dart';
import 'package:rackery/ui/widgets/observation_list_panel.dart';
import 'package:rackery/services/ebird_api_service.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final ChecklistController _controller = ChecklistController();
  Timer? _batchTicker;

  // ── Memoized panel widgets ────────────────────────────────────────────────
  // When the ListenableBuilder fires we recompute a hash of each panel's
  // inputs.  If the hash hasn't changed we return the *same* widget instance,
  // causing Flutter to skip the entire subtree rebuild.

  Widget? _cachedFilePanel;
  int _filePanelHash = 0;

  Widget? _cachedCenterPane;
  int _centerPaneHash = 0;

  Widget? _cachedObsPanel;
  int _obsPanelHash = 0;

  Widget _memoizedFilePanel() {
    final hash = Object.hash(
      _controller.fileBursts.length,
      _controller.selectedFiles.length,
      _controller.processingFiles.length,
      _controller.activeFiles.length,
      _controller.currentlyDisplayedImage,
      _controller.observations.length,
      _controller.fileStartTimes.length,
      _controller.fileElapsedTimes.length,
    );
    if (hash != _filePanelHash || _cachedFilePanel == null) {
      _filePanelHash = hash;
      _cachedFilePanel = FileListPanel(
        fileBursts: _controller.fileBursts,
        selectedFiles: _controller.selectedFiles,
        processingFiles: _controller.processingFiles,
        activeFiles: _controller.activeFiles,
        imageExifData: _controller.imageExifData,
        observations: _controller.observations,
        currentlyDisplayedImage: _controller.currentlyDisplayedImage,
        fileStartTimes: _controller.fileStartTimes,
        fileElapsedTimes: _controller.fileElapsedTimes,
        onFileTapped: _controller.selectFile,
      );
    }
    return _cachedFilePanel!;
  }

  Widget _memoizedCenterPane() {
    final hash = Object.hash(
      identityHashCode(_controller.selectedObservation),
      Object.hashAll(_controller.selectedIndividualIndices),
      _controller.currentlyDisplayedImage,
      _controller.boxVisibility,
      _controller.observationVersion,
      Object.hashAll(_controller.processingFiles),
    );
    if (hash != _centerPaneHash || _cachedCenterPane == null) {
      _centerPaneHash = hash;
      _cachedCenterPane = CenterPane(
        selectedObservation: _controller.selectedObservation,
        selectedIndividualIndices: _controller.selectedIndividualIndices,
        currentlyDisplayedImage: _controller.currentlyDisplayedImage,
        imageExifData: _controller.imageExifData,
        boxVisibility: _controller.boxVisibility,
        allObservations: _controller.observations,
        onSetBoxVisibility: _controller.setBoundingBoxVisibility,
        processingFiles: _controller.processingFiles,
        getDisplayPath: _controller.getDisplayPath,
        getImageSize: _controller.getImageSize,
        onIndividualSelected: _controller.selectIndividual,
        onDrawBoundingBox: _controller.addManualIndividual,
      );
    }
    return _cachedCenterPane!;
  }

  Widget _memoizedObsPanel() {
    final hash = Object.hash(
      _controller.observations.length,
      _controller.observationVersion,
      identityHashCode(_controller.selectedObservation),
      identityHashCode(_controller.expandedObservation),
      Object.hashAll(_controller.selectedIndividualIndices),
      _controller.lastSelectedIndividualIndex,
      _controller.draggingIndex,
      _controller.isDropdownOpen,
    );
    if (hash != _obsPanelHash || _cachedObsPanel == null) {
      _obsPanelHash = hash;
      _cachedObsPanel = ObservationListPanel(
        observations: _controller.observations,
        selectedObservation: _controller.selectedObservation,
        selectedIndividualIndices: _controller.selectedIndividualIndices,
        lastSelectedIndividualIndex: _controller.lastSelectedIndividualIndex,
        expandedObservation: _controller.expandedObservation,
        draggingIndex: _controller.draggingIndex,
        isDropdownOpen: _controller.isDropdownOpen,
        scrollController: _controller.observationScrollController,
        onTapCard: _controller.selectObservation,
        onTapIndividual: (obs, i) =>
            _controller.selectIndividual(obs, i, scroll: false),
        onToggleExpanded: _controller.toggleExpanded,
        onSpeciesChanged: _controller.updateObservationSpecies,
        onSpeciesSelected: _controller.updateObservationSpecies,
        onCountChanged: _controller.updateObservationCount,
        onMergeObservations: _controller.mergeObservations,
        onMergeIndividuals: _controller.mergeIndividuals,
        onDragStarted: _controller.setDraggingIndex,
        onDragEnded: () => _controller.setDraggingIndex(null),
        onExtractIndividuals: _controller.extractIndividuals,
        onDropdownToggled: _controller.setDropdownOpen,
        onDeleteIndividuals: _controller.deleteIndividuals,
        onTapPhoto: _controller.selectPhotoImage,
      );
    }
    return _cachedObsPanel!;
  }

  @override
  void dispose() {
    _batchTicker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Starts / stops a 1-second ticker so the batch timer updates live.
  void _syncBatchTicker() {
    if (_controller.batchStartTime != null) {
      _batchTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _batchTicker?.cancel();
      _batchTicker = null;
    }
  }

  static String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    if (totalSeconds < 60) return '${totalSeconds}s';
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes}m ${seconds}s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        _syncBatchTicker();
        if (!_controller.isInit) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Rackery'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'Settings (eBird API Key)',
                onPressed: () async {
                  final currentKey = await EbirdApiService.getApiKey() ?? '';
                  final controller = TextEditingController(text: currentKey);
                  if (!context.mounted) return;

                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Settings'),
                      content: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          labelText: 'eBird API Key',
                          hintText: 'Paste your eBird API Token here',
                          helperText:
                              'Required for geographic & seasonal filtering.',
                        ),
                        obscureText: true,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () {
                            EbirdApiService.setApiKey(controller.text.trim());
                            Navigator.pop(context);
                          },
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'About & Licenses',
                onPressed: () {
                  showAboutDialog(
                    context: context,
                    applicationName: 'Rackery',
                    applicationVersion: '1.0.0',
                    applicationIcon: const Icon(Icons.flutter_dash, size: 48),
                    applicationLegalese:
                        'Powered by BioCLIP (ONNX Runtime) and TensorFlow Lite.',
                  );
                },
              ),
              if (_controller.selectedFiles.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _controller.isProcessing
                      ? null
                      : _controller.clearAll,
                  tooltip: 'Clear all photos and results',
                ),
              IconButton(
                icon: const Icon(Icons.download),
                onPressed:
                    _controller.observations.isEmpty || _controller.isProcessing
                    ? null
                    : () => _controller.exportCsv(context),
                tooltip: 'Export eBird checklist CSV',
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
                        child: _memoizedFilePanel(),
                      ),
                    ),
                    const VerticalDivider(width: 1),

                    // Centre: photo viewer
                    _memoizedCenterPane(),

                    const VerticalDivider(width: 1),

                    // Right: observations list
                    Expanded(flex: 1, child: _memoizedObsPanel()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          ElevatedButton.icon(
            onPressed: _controller.isProcessing
                ? null
                : () => _controller.selectAndProcessPhotos(context),
            icon: const Icon(Icons.photo_library),
            label: const Text('Select Photos'),
          ),
          const SizedBox(width: 16),
          if (_controller.isProcessing)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _controller.progressMessage.isNotEmpty
                              ? _controller.progressMessage
                              : 'Processing images...',
                        ),
                      ),
                      if (_controller.batchStartTime != null)
                        Text(
                          _formatDuration(
                            DateTime.now().difference(
                              _controller.batchStartTime!,
                            ),
                          ),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SineWaveProgressIndicator(value: _controller.progress),
                ],
              ),
            )
          else
            Expanded(
              child: Row(
                children: [
                  Text(
                    _controller.observations.isEmpty
                        ? 'No photos selected'
                        : '${_controller.observations.length} observations generated',
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                  if (_controller.batchElapsedTime != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      'in ${_formatDuration(_controller.batchElapsedTime!)}',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
