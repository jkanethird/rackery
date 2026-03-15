import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';

/// Left-side panel that displays all selected files grouped into bursts,
/// with timestamps, processing indicators, and individual-count badges.
class FileListPanel extends StatelessWidget {
  final List<List<String>> fileBursts;
  final List<String> selectedFiles;
  final Set<String> processingFiles;
  final Set<String> activeFiles;
  final Map<String, ExifData> imageExifData;
  final List<Observation> observations;
  final String? currentlyDisplayedImage;

  /// Called when the user taps a file tile. Provides the file path.
  final void Function(String filePath) onFileTapped;

  const FileListPanel({
    super.key,
    required this.fileBursts,
    required this.selectedFiles,
    required this.processingFiles,
    required this.activeFiles,
    required this.imageExifData,
    required this.observations,
    required this.currentlyDisplayedImage,
    required this.onFileTapped,
  });

  @override
  Widget build(BuildContext context) {
    // Fall back to a flat list if bursts haven't been computed yet
    final bursts = fileBursts.isNotEmpty
        ? fileBursts
        : selectedFiles.map((f) => [f]).toList();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: bursts.length,
      itemBuilder: (context, burstIndex) {
        final burstFiles = bursts[burstIndex];
        final isBurst = burstFiles.length > 1;

        final firstFile = burstFiles.first;
        final firstExif = imageExifData[firstFile];
        final timestamp = firstExif?.dateTime;
        final timeLabel = timestamp != null
            ? '${timestamp.hour.toString().padLeft(2, '0')}:'
                  '${timestamp.minute.toString().padLeft(2, '0')}:'
                  '${timestamp.second.toString().padLeft(2, '0')}'
            : 'Unknown time';
        final dateLabel = timestamp != null
            ? '${timestamp.year}-'
                  '${timestamp.month.toString().padLeft(2, '0')}-'
                  '${timestamp.day.toString().padLeft(2, '0')}'
            : '';

        Widget fileTile(String file) {
          final isProcessing = processingFiles.contains(file);
          final isActive = activeFiles.contains(file);
          final filename = file.split(Platform.pathSeparator).last;
          final isSelected = currentlyDisplayedImage == file;

          final individualCount = observations
              .where((o) => o.sourceImages.any((s) => s.imagePath == file))
              .fold<int>(
                0,
                (sum, o) => sum + (o.boxesByImagePath[file]?.length ?? 0),
              );

          Widget statusIndicator;
          if (isActive) {
            // Actively being detected/classified right now — full spinner
            statusIndicator = const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            );
          } else if (isProcessing) {
            // In the queue, waiting for its turn — dim spinner
            statusIndicator = Opacity(
              opacity: 0.30,
              child: const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            );
          } else {
            // Done — green check
            statusIndicator = const Icon(
              Icons.check_circle,
              color: Colors.green,
              size: 12,
            );
          }

          return InkWell(
            onTap: () => onFileTapped(file),
            child: Container(
              color: isSelected
                  ? Colors.blue.withValues(alpha: 0.12)
                  : Colors.transparent,
              padding: EdgeInsets.only(
                left: isBurst ? 24 : 12,
                right: 8,
                top: 6,
                bottom: 6,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      filename,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (!isProcessing && individualCount > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$individualCount',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  statusIndicator,
                ],
              ),
            ),
          );
        }

        if (!isBurst) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (burstIndex == 0 || dateLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 11,
                        color: Theme.of(context).hintColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$dateLabel  $timeLabel',
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              fileTile(firstFile),
              const Divider(height: 1, indent: 12, endIndent: 8),
            ],
          );
        }

        // Multi-photo burst header
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.burst_mode,
                    size: 13,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '$dateLabel  $timeLabel',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  Text(
                    '${burstFiles.length} photos',
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
            ...burstFiles.map(fileTile),
            const Divider(height: 1, indent: 12, endIndent: 8),
          ],
        );
      },
    );
  }
}
