import 'package:flutter/material.dart';
import 'package:ebird_generator/controllers/checklist_controller.dart';
import 'package:ebird_generator/ui/sine_wave_progress.dart';
import 'package:ebird_generator/ui/widgets/file_list_panel.dart';
import 'package:ebird_generator/ui/widgets/center_pane.dart';
import 'package:ebird_generator/ui/widgets/observation_list_panel.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final ChecklistController _controller = ChecklistController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        if (!_controller.isInit) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('eBird Checklist Generator'),
            actions: [
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'About & Licenses',
                onPressed: () {
                  showAboutDialog(
                    context: context,
                    applicationName: 'eBird Checklist Generator',
                    applicationVersion: '1.0.0',
                    applicationIcon: const Icon(Icons.flutter_dash, size: 48),
                    applicationLegalese: 'Built with Llama 3.2 Vision.\nPowered by TensorFlow Lite.',
                  );
                },
              ),
              if (_controller.selectedFiles.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _controller.isProcessing ? null : _controller.clearAll,
                  tooltip: 'Clear all photos and results',
                ),
              IconButton(
                icon: const Icon(Icons.download),
                onPressed: _controller.observations.isEmpty || _controller.isProcessing
                    ? null
                    : () => _controller.exportCsv(context),
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
                          fileBursts: _controller.fileBursts,
                          selectedFiles: _controller.selectedFiles,
                          processingFiles: _controller.processingFiles,
                          activeFiles: _controller.activeFiles,
                          imageExifData: _controller.imageExifData,
                          observations: _controller.observations,
                          currentlyDisplayedImage: _controller.currentlyDisplayedImage,
                          onFileTapped: _controller.selectFile,
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),

                    // Centre: photo viewer
                    CenterPane(
                      selectedObservation: _controller.selectedObservation,
                      selectedIndividualIndices: _controller.selectedIndividualIndices,
                      currentlyDisplayedImage: _controller.currentlyDisplayedImage,
                      imageExifData: _controller.imageExifData,
                      currentPage: _controller.currentCenterPage,
                      pageController: _controller.pageController,
                      getDisplayPath: _controller.getDisplayPath,
                      getImageSize: _controller.getImageSize,
                      onPageChanged: _controller.setCenterPage,
                    ),

                    const VerticalDivider(width: 1),

                    // Right: observations list
                    Expanded(
                      flex: 1,
                      child: ObservationListPanel(
                        observations: _controller.observations,
                        selectedObservation: _controller.selectedObservation,
                        selectedIndividualIndices: _controller.selectedIndividualIndices,
                        lastSelectedIndividualIndex: _controller.lastSelectedIndividualIndex,
                        draggingIndex: _controller.draggingIndex,
                        scrollController: _controller.observationScrollController,
                        onTapCard: _controller.selectObservation,
                        onTapIndividual: _controller.selectIndividual,
                        onSpeciesChanged: _controller.updateObservationSpecies,
                        onSpeciesSelected: _controller.updateObservationSpecies,
                        onCountChanged: _controller.updateObservationCount,
                        onMergeObservations: _controller.mergeObservations,
                        onMergeIndividuals: _controller.mergeIndividuals,
                        onDragStarted: _controller.setDraggingIndex,
                        onDragEnded: () => _controller.setDraggingIndex(null),
                        onExtractIndividuals: _controller.extractIndividuals,
                      ),
                    ),
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
            onPressed: _controller.isProcessing ? null : () => _controller.selectAndProcessPhotos(context),
            icon: const Icon(Icons.photo_library),
            label: const Text('Select Photos'),
          ),
          const SizedBox(width: 16),
          if (_controller.isProcessing)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _controller.progressMessage.isNotEmpty
                        ? _controller.progressMessage
                        : 'Processing images...',
                  ),
                  const SizedBox(height: 8),
                  SineWaveProgressIndicator(value: _controller.progress),
                ],
              ),
            )
          else
            Expanded(
              child: Text(
                _controller.observations.isEmpty
                    ? 'No photos selected'
                    : '${_controller.observations.length} observations generated',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }
}
