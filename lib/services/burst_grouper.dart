import 'package:rackery/services/exif_service.dart';

/// Groups a sorted list of file-exif pairs into "bursts" — sequences of photos
/// taken within [burstGapSeconds] of each other.
///
/// Photos without timestamps are placed in their own single-file burst.
class BurstGrouper {
  /// Maximum gap in seconds between consecutive photos for them to be
  /// considered part of the same burst.
  final int burstGapSeconds;

  const BurstGrouper({this.burstGapSeconds = 15});

  int _hammingDistance(String h1, String h2) {
    if (h1.length != h2.length) return 64; // Fallback
    int dist = 0;
    for (int i = 0; i < h1.length; i++) {
      int v1 = int.parse(h1[i], radix: 16);
      int v2 = int.parse(h2[i], radix: 16);
      int xor = v1 ^ v2;
      dist +=
          (xor & 1) + ((xor >> 1) & 1) + ((xor >> 2) & 1) + ((xor >> 3) & 1);
    }
    return dist;
  }

  /// [fileData] is a list of `{'path': String, 'exif': ExifData, 'visualHash': String?}` maps,
  /// pre-sorted chronologically by the caller.
  ///
  /// Returns a list of bursts, each burst being the file paths it contains.
  List<List<String>> group(List<Map<String, dynamic>> fileData) {
    final List<List<String>> bursts = [];
    List<String> currentBurst = [];
    DateTime? lastTime;
    String? lastHash;

    for (final data in fileData) {
      final path = data['path'] as String;
      final date = (data['exif'] as ExifData).dateTime;
      final currentHash = data['visualHash'] as String?;

      if (currentBurst.isEmpty) {
        currentBurst.add(path);
        lastTime = date ?? lastTime; // Usually null initially anyway
        lastHash = currentHash ?? lastHash;
        continue;
      }

      bool isSameBurst = false;

      // 1. Temporal Check (Fast logical grouping)
      if (date != null && lastTime != null) {
        final diffSeconds = date.difference(lastTime).inSeconds.abs();
        if (diffSeconds <= burstGapSeconds) {
          isSameBurst = true;
        }
      }

      // 2. Strict Environmental Overrule
      if (currentHash != null && lastHash != null) {
        final dist = _hammingDistance(currentHash, lastHash);

        if (dist > 20) {
          // If the visual background shifts significantly, BREAK the burst immediately!
          // This prevents rapid-fire turning from getting lumped into one burst.
          isSameBurst = false;
        } else if (dist <= 15) {
          // If the visual background is very similar, FORCE the burst to group!
          // This bridges photos taken minutes apart if the user stood completely still.
          if (date == null ||
              lastTime == null ||
              date.difference(lastTime).inSeconds.abs() <= 300) {
            isSameBurst = true;
          }
        }
      }

      if (isSameBurst) {
        currentBurst.add(path);
      } else {
        bursts.add(List.from(currentBurst));
        currentBurst = [path];
      }

      // Update tracking markers based on latest photo
      lastTime = date ?? lastTime;
      lastHash = currentHash ?? lastHash;
    }

    if (currentBurst.isNotEmpty) bursts.add(currentBurst);
    return bursts;
  }
}
