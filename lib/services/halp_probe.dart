import 'dart:math';
import 'dart:typed_data';

/// HALlucination Prediction via Pre-Generation Probing (HALP).
///
/// Estimates the risk that the model is about to hallucinate by analysing
/// the probability distribution (logits) after each decoded token.
///
/// ## Method — Shannon Entropy
/// After each `llama_decode()` call, `llama_get_logits_ith()` returns a
/// 128,000-element float32 vector of raw logit scores. We:
///   1. Numerically-stable softmax over top-K scores
///   2. Compute Shannon entropy: H = -Σ p·log(p)
///   3. Normalise by log(K) so the score is always in [0.0, 1.0]
///
/// **Score interpretation:**
/// - 0.0  → model is maximally confident (single token dominates)
/// - 0.5  → moderate uncertainty
/// - 1.0  → model is completely uncertain (uniform distribution) → hallucination likely
///
/// **Threshold guidance:**
/// - < 0.55 → PASS   (confident prediction)
/// - 0.55–0.75 → WARN (uncertain, treat output with lower confidence)
/// - > 0.75 → FAIL   (high hallucination risk, consider re-sampling)

class HalpProbe {
  static const int _topK = 20;
  static const double kPassThreshold = 0.55;
  static const double kFailThreshold = 0.90; // raised from 0.75 — FFI raw logits have higher entropy
  static const int _skipTokens  = 5;         // ignore HALP for first N tokens (output format settling)
  static const int _consecFails = 5;         // consecutive fails needed to abort (up from 3)

  /// Estimate hallucination risk from a [logits] vector of length [nVocab].
  /// Returns a normalised entropy score in [0.0, 1.0].
  static double estimateRisk(Float32List logits, int nVocab) {
    if (logits.isEmpty || nVocab <= 0) return 1.0;
    final k = min(_topK, nVocab);

    // Find top-K indices (simple partial sort)
    final topKIndices = _topKIndices(logits, nVocab, k);
    if (topKIndices.isEmpty) return 1.0;

    // Numerically-stable softmax: subtract max before exp
    double maxLogit = double.negativeInfinity;
    for (final i in topKIndices) {
      if (logits[i] > maxLogit) maxLogit = logits[i].toDouble();
    }
    final probs = Float64List(k);
    double sumExp = 0.0;
    for (int j = 0; j < k; j++) {
      probs[j] = exp(logits[topKIndices[j]] - maxLogit);
      sumExp += probs[j];
    }
    if (sumExp == 0.0) return 1.0;
    for (int j = 0; j < k; j++) {
      probs[j] /= sumExp;
    }

    // Shannon entropy
    double entropy = 0.0;
    for (final p in probs) {
      if (p > 1e-12) entropy -= p * log(p);
    }

    // Normalise by log(K)
    return (entropy / log(k)).clamp(0.0, 1.0);
  }

  /// Returns whether [score] indicates high hallucination risk.
  static bool isHighRisk(double score) => score > kFailThreshold;

  /// Returns whether [score] indicates the model is uncertain but not failed.
  static bool isWarning(double score) =>
      score >= kPassThreshold && score <= kFailThreshold;

  /// Summarise a sequence of per-token risk scores into a single verdict.
  ///
  /// If 3 or more consecutive tokens breach [kFailThreshold], this returns
  /// `true` to signal that the entire generation segment is suspect.
  static bool shouldAbortGeneration(List<double> scores) {
    if (scores.length <= _skipTokens) return false; // warm-up period
    int consecutiveFails = 0;
    for (int i = _skipTokens; i < scores.length; i++) {
      if (isHighRisk(scores[i])) {
        consecutiveFails++;
        if (consecutiveFails >= _consecFails) return true;
      } else {
        consecutiveFails = 0;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static List<int> _topKIndices(Float32List logits, int nVocab, int k) {
    // Partial selection sort — O(n·k) but n=128k and k=20 is fast enough
    final result = <int>[];
    final used = <int>{};

    for (int step = 0; step < k; step++) {
      double maxVal = double.negativeInfinity;
      int maxIdx = -1;
      for (int i = 0; i < nVocab; i++) {
        if (!used.contains(i) && logits[i] > maxVal) {
          maxVal = logits[i].toDouble();
          maxIdx = i;
        }
      }
      if (maxIdx == -1) break;
      result.add(maxIdx);
      used.add(maxIdx);
    }
    return result;
  }
}
