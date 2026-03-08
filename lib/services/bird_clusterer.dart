import 'dart:math';
import 'package:ebird_generator/services/bird_detector.dart';

/// Groups detected bird crops from a single photo into clusters of likely
/// same-species birds, using bounding-box size and aspect ratio similarity.
///
/// The key insight is that birds of the same species within a photo tend to
/// have very similar bounding-box dimensions. A Mute Swan crop will be ~4×
/// the area of a Mallard crop, so they naturally fall into separate clusters
/// even when mixed in the same scene.
class BirdClusterer {
  /// Maximum relative area difference (0–1) for two birds to be considered
  /// the same species cluster. 0.6 means the smaller box can be at most 40%
  /// smaller than the larger one.
  final double areaSimilarityThreshold;

  /// Maximum absolute aspect-ratio difference (width/height) for two birds
  /// to be in the same cluster. 0.5 handles minor pose variation.
  final double aspectRatioThreshold;

  const BirdClusterer({
    this.areaSimilarityThreshold = 0.6,
    this.aspectRatioThreshold = 0.5,
  });

  /// Returns a list of clusters, each cluster being a list of [BirdCrop]s
  /// that are likely the same species.
  List<List<BirdCrop>> cluster(List<BirdCrop> crops) {
    if (crops.isEmpty) return [];
    if (crops.length == 1) return [crops];

    // Precompute features
    final areas = crops
        .map((c) => (c.box.width * c.box.height).toDouble())
        .toList();
    final aspects = crops
        .map((c) => c.box.width / max(c.box.height, 1))
        .toList();

    // Process crops from largest to smallest: big distinctive birds (swans,
    // geese) anchor their own clusters before small similar ones are grouped.
    final order = List.generate(crops.length, (i) => i)
      ..sort((a, b) => areas[b].compareTo(areas[a]));

    final List<_Cluster> clusters = [];

    for (final i in order) {
      bool placed = false;
      for (final c in clusters) {
        final areaDiff =
            (areas[i] - c.meanArea).abs() / max(areas[i], c.meanArea);
        final aspectDiff = (aspects[i] - c.meanAspect).abs();

        if (areaDiff <= areaSimilarityThreshold &&
            aspectDiff <= aspectRatioThreshold) {
          c.add(i, areas[i], aspects[i]);
          placed = true;
          break;
        }
      }
      if (!placed) {
        clusters.add(_Cluster()..add(i, areas[i], aspects[i]));
      }
    }

    return clusters
        .map((c) => c.indices.map((i) => crops[i]).toList())
        .toList();
  }
}

class _Cluster {
  final List<int> indices = [];
  double _sumArea = 0;
  double _sumAspect = 0;

  double get meanArea => _sumArea / indices.length;
  double get meanAspect => _sumAspect / indices.length;

  void add(int index, double area, double aspect) {
    indices.add(index);
    _sumArea += area;
    _sumAspect += aspect;
  }
}
