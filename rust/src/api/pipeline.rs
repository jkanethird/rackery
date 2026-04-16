// Rackery - Automatic bird identification and eBird checklist generation.
// Copyright (C) 2026 Joseph J. Kane III
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

use image::{imageops::FilterType, GenericImageView};
use std::cmp::min;
use std::collections::HashSet;
use ort::{session::builder::GraphOptimizationLevel, session::Session, value::Value, init};
use rayon::prelude::*;
use crate::frb_generated::StreamSink;

use super::nms::{RawDetection, apply_nms, parse_tile_detections};
use super::pool::{SessionPool, CLASSIFIER_POOL, DETECTOR_POOL, SPECIES_DATA};

// ── Constants ──────────────────────────────────────────────────────────────

/// CLIP image-normalisation constants (mean / std per channel).
const CLIP_MEAN: [f32; 3] = [0.48145466, 0.4578275, 0.40821073];
const CLIP_STD:  [f32; 3] = [0.26862954, 0.26130258, 0.27577711];

/// Confidence threshold below which an auto-detected crop is rejected.
const MIN_CONFIDENCE: f32 = 0.18;

/// Fallback threshold (entire-image classification, no detected bird).
const FALLBACK_CONFIDENCE: f32 = 0.25;

/// Bonus added to cosine similarity for species on the eBird local checklist.
const LOCAL_BONUS: f32 = 0.08;

/// Number of top-K species returned per detected bird.
const TOP_K: usize = 5;

/// Detector input resolution (square).
const DET_SIZE: u32 = 512;

// ── FFI Types (exposed to Dart via flutter_rust_bridge) ───────────────────

pub struct NativeBirdResult {
    pub species: String,
    pub possible_species: Vec<String>,
    pub confidence: f64,
    pub box_x: u32,
    pub box_y: u32,
    pub box_w: u32,
    pub box_h: u32,
    pub center_color: Vec<f64>,
    pub crop_jpg_bytes: Vec<u8>,
}

pub struct PipelineResult {
    pub birds: Vec<NativeBirdResult>,
    pub detection_ms: u64,
    pub classification_ms: u64,
}

pub enum PipelineEvent {
    Progress(String),
    Complete(PipelineResult),
}

pub struct ClassificationResult {
    pub species: Vec<String>,
}

// ── Initialization ─────────────────────────────────────────────────────────

pub fn init_pipeline(
    detector_model_bytes: Vec<u8>,
    classifier_model_bytes: Vec<u8>,
    embeddings_bytes: Vec<u8>,
    labels_json: String,
) -> Result<(), String> {
    let _ = init().with_name("rackery").commit();

    // Build execution provider list: try most-performant hardware first.
    // TensorRT is intentionally omitted — it validates ONNX node names more
    // strictly than the TF-exported EfficientDet model satisfies, causing a
    // hard failure rather than a graceful fallback to the next provider.
    let eps = [
        ort::ep::CUDA::default().build(),
        ort::ep::DirectML::default().build(),
        ort::ep::CoreML::default().build(),
        ort::ep::CPU::default().build(),
    ];

    let pool_size = std::thread::available_parallelism()
        .map(|n| n.get() / 2)
        .unwrap_or(2)
        .clamp(1, 4);

    let mut det_sessions = Vec::new();
    let mut cls_sessions = Vec::new();

    for _ in 0..pool_size {
        let det = Session::builder()
            .map_err(|e| format!("{:?}", e))?
            .with_execution_providers(eps.clone())
            .map_err(|e| format!("{:?}", e))?
            // Level1 avoids the aggressive graph-fusion pass that causes the
            // Windows ORT binary to reject tf2onnx-exported models with
            // semicolon-joined node names (a benign export artefact).
            .with_optimization_level(GraphOptimizationLevel::Level1)
            .map_err(|e| format!("{:?}", e))?
            .commit_from_memory(&detector_model_bytes)
            .map_err(|e| format!("{:?}", e))?;
        det_sessions.push(det);

        let cls = Session::builder()
            .map_err(|e| format!("{:?}", e))?
            .with_execution_providers(eps.clone())
            .map_err(|e| format!("{:?}", e))?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(|e| format!("{:?}", e))?
            .commit_from_memory(&classifier_model_bytes)
            .map_err(|e| format!("{:?}", e))?;
        cls_sessions.push(cls);
    }

    let _ = DETECTOR_POOL.set(SessionPool::new(det_sessions));
    let _ = CLASSIFIER_POOL.set(SessionPool::new(cls_sessions));

    // Species embeddings — binary format:
    // [i32 num_species][i32 dim][f32 × num_species × dim]
    if embeddings_bytes.len() < 8 {
        return Err("Embeddings file too small".to_string());
    }
    let num_species = i32::from_le_bytes([
        embeddings_bytes[0], embeddings_bytes[1],
        embeddings_bytes[2], embeddings_bytes[3],
    ]) as usize;
    let dim = i32::from_le_bytes([
        embeddings_bytes[4], embeddings_bytes[5],
        embeddings_bytes[6], embeddings_bytes[7],
    ]) as usize;

    let float_bytes = &embeddings_bytes[8..];
    let expected_len = num_species * dim * 4;
    if float_bytes.len() < expected_len {
        return Err(format!(
            "Embeddings data too small: expected {} bytes, got {}",
            expected_len, float_bytes.len()
        ));
    }

    let mut embeddings = Vec::with_capacity(num_species * dim);
    for i in 0..(num_species * dim) {
        let offset = i * 4;
        embeddings.push(f32::from_le_bytes([
            float_bytes[offset], float_bytes[offset + 1],
            float_bytes[offset + 2], float_bytes[offset + 3],
        ]));
    }

    let labels: Vec<String> = serde_json::from_str(&labels_json)
        .map_err(|e| format!("Failed to parse labels JSON: {:?}", e))?;
    if labels.len() != num_species {
        return Err(format!(
            "Label count ({}) != embedding count ({})",
            labels.len(), num_species
        ));
    }

    let _ = SPECIES_DATA.set((embeddings, labels, dim));
    Ok(())
}

// ── Full Pipeline ──────────────────────────────────────────────────────────

pub fn process_pipeline(
    file_bytes: Vec<u8>,
    allowed_species: Option<Vec<String>>,
    stream: StreamSink<PipelineEvent>,
) -> Result<(), String> {
    let allowed_set: Option<HashSet<String>> = allowed_species
        .map(|v| v.into_iter().collect());

    stream.add(PipelineEvent::Progress("Starting detection pipeline...".to_string())).ok();
    let t0 = std::time::Instant::now();

    // 1. Decode image
    let img = image::load_from_memory(&file_bytes).map_err(|e| e.to_string())?;
    let (orig_w, orig_h) = img.dimensions();

    // 2. Build tiles (25% overlap)
    stream.add(PipelineEvent::Progress("Preparing image tiles...".to_string())).ok();
    let tiles = build_tiles(orig_w, orig_h);

    // 3. Parallel tensor preparation
    stream.add(PipelineEvent::Progress(
        format!("Preparing {} tile tensors...", tiles.len())
    )).ok();
    let tile_tensors: Vec<Vec<u8>> = tiles.par_iter()
        .map(|tile| prepare_tile_tensor(&img, *tile))
        .collect();

    // 4. Concurrent detection with early-exit optimisation
    stream.add(PipelineEvent::Progress("Running object detection...".to_string())).ok();
    let all_detections = run_detection_concurrent(&tile_tensors, &tiles, orig_w, orig_h, &stream)?;

    // 5. Non-Maximum Suppression
    stream.add(PipelineEvent::Progress("Filtering detections...".to_string())).ok();
    let kept = apply_nms(all_detections);

    let detection_ms = t0.elapsed().as_millis() as u64;

    if kept.is_empty() {
        stream.add(PipelineEvent::Complete(PipelineResult {
            birds: vec![],
            detection_ms,
            classification_ms: 0,
        })).ok();
        return Ok(());
    }

    // 6. Classification
    stream.add(PipelineEvent::Progress(
        format!("Classifying {} detections...", kept.len())
    )).ok();
    let t1 = std::time::Instant::now();

    let mut birds: Vec<NativeBirdResult> = Vec::new();

    for (i, det) in kept.iter().enumerate() {
        stream.add(PipelineEvent::Progress(
            format!("Classifying bird {}/{}...", i + 1, kept.len())
        )).ok();

        // Extract unpadded crop for centre-colour sampling
        let unpadded = img.crop_imm(det.global_x, det.global_y, det.local_w, det.local_h);
        let center_color = compute_center_color(&unpadded);

        // Extract padded crop for classification + thumbnail
        let pad_x = (det.local_w as f32 * 0.5) as u32;
        let pad_y = (det.local_h as f32 * 0.5) as u32;
        let crop_x1 = det.global_x.saturating_sub(pad_x);
        let crop_y1 = det.global_y.saturating_sub(pad_y);
        let crop_x2 = min(det.global_x + det.local_w + pad_x, orig_w);
        let crop_y2 = min(det.global_y + det.local_h + pad_y, orig_h);
        let padded = img.crop_imm(crop_x1, crop_y1, crop_x2 - crop_x1, crop_y2 - crop_y1);

        let species_list = classify_image(&padded, &allowed_set, false)?;
        if species_list.is_empty() {
            continue; // BioCLIP rejected this crop as non-bird
        }

        // Encode thumbnail JPEG (upscale tiny crops for display)
        let mut thumb = padded.clone();
        if thumb.width() < 150 || thumb.height() < 150 {
            let scale = 150.0 / std::cmp::max(thumb.width(), thumb.height()) as f32;
            let new_w = (thumb.width() as f32 * scale).round() as u32;
            let new_h = (thumb.height() as f32 * scale).round() as u32;
            thumb = thumb.resize_exact(new_w, new_h, FilterType::Triangle);
        }
        let mut buf = std::io::Cursor::new(Vec::new());
        let _ = thumb.write_to(&mut buf, image::ImageFormat::Jpeg);

        birds.push(NativeBirdResult {
            species: species_list[0].clone(),
            possible_species: species_list,
            confidence: det.score as f64,
            box_x: det.global_x,
            box_y: det.global_y,
            box_w: det.local_w,
            box_h: det.local_h,
            center_color,
            crop_jpg_bytes: buf.into_inner(),
        });
    }

    let classification_ms = t1.elapsed().as_millis() as u64;

    stream.add(PipelineEvent::Complete(PipelineResult {
        birds,
        detection_ms,
        classification_ms,
    })).ok();
    Ok(())
}

// ── Standalone Classifier ──────────────────────────────────────────────────

/// Classify a single pre-cropped image (used for manual bounding boxes and
/// re-classification requests from Dart).
pub fn classify_crop(
    crop_bytes: Vec<u8>,
    allowed_species: Option<Vec<String>>,
    is_fallback: bool,
) -> Result<ClassificationResult, String> {
    let allowed_set: Option<HashSet<String>> = allowed_species
        .map(|v| v.into_iter().collect());

    let img = image::load_from_memory(&crop_bytes).map_err(|e| e.to_string())?;
    let species = classify_image(&img, &allowed_set, is_fallback)?;
    Ok(ClassificationResult { species })
}

// ── Detection Helpers ──────────────────────────────────────────────────────

/// Partition the image into overlapping 1536×1536 tiles (25% overlap).
///
/// The first tile is always the full image at its native resolution; this
/// is the tile checked for the early-exit optimisation.
fn build_tiles(orig_w: u32, orig_h: u32) -> Vec<[u32; 4]> {
    let tile_size: u32 = 1536;
    let stride = tile_size * 3 / 4;
    let mut tiles = vec![[0, 0, orig_w, orig_h]]; // full-image tile first

    if orig_w > tile_size || orig_h > tile_size {
        let mut y: u32 = 0;
        while y < orig_h {
            let mut x: u32 = 0;
            while x < orig_w {
                let mut crop_x = x;
                let mut crop_y = y;
                if crop_x + tile_size > orig_w { crop_x = orig_w.saturating_sub(tile_size); }
                if crop_y + tile_size > orig_h { crop_y = orig_h.saturating_sub(tile_size); }
                let crop_w = min(tile_size, orig_w - crop_x);
                let crop_h = min(tile_size, orig_h - crop_y);
                tiles.push([crop_x, crop_y, crop_w, crop_h]);
                x += stride;
            }
            y += stride;
        }
    }
    tiles.dedup();
    tiles
}

/// Crop and resize a single tile to the detector's fixed input size,
/// returning a flat RGB byte buffer (HWC layout, uint8).
fn prepare_tile_tensor(img: &image::DynamicImage, tile: [u32; 4]) -> Vec<u8> {
    let [left, top, width, height] = tile;
    let cropped = img.crop_imm(left, top, width, height);
    let resized = cropped.resize_exact(DET_SIZE, DET_SIZE, FilterType::Triangle);
    let rgb = resized.to_rgb8();

    let mut input_vec: Vec<u8> = Vec::with_capacity((DET_SIZE * DET_SIZE * 3) as usize);
    for (_x, _y, pixel) in rgb.enumerate_pixels() {
        input_vec.push(pixel[0]);
        input_vec.push(pixel[1]);
        input_vec.push(pixel[2]);
    }
    input_vec
}

/// Run a single tile through the detector using a pool session.
fn infer_single_tile(
    pool: &SessionPool,
    tensor: &[u8],
    tile: [u32; 4],
    orig_w: u32,
    orig_h: u32,
) -> Result<Vec<RawDetection>, String> {
    let input_tensor = Value::from_array(
        (vec![1_i64, DET_SIZE as i64, DET_SIZE as i64, 3_i64], tensor.to_vec())
    ).map_err(|e| format!("{:?}", e))?;

    let inputs = ort::inputs!["serving_default_images:0" => input_tensor];

    let mut session = pool.acquire();
    let dets = {
        let outputs = session.run(inputs).map_err(|e| format!("{:?}", e))?;

        let (_, out_boxes)   = outputs["StatefulPartitionedCall:3"].try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_classes) = outputs["StatefulPartitionedCall:2"].try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_scores)  = outputs["StatefulPartitionedCall:1"].try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_count)   = outputs["StatefulPartitionedCall:0"].try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;

        let count   = out_count[0] as usize;
        let max_det = out_scores.len();

        parse_tile_detections(out_boxes, out_scores, out_classes, 0, max_det, count, tile, orig_w, orig_h)
    };
    pool.release(session);
    Ok(dets)
}

/// Run detection across all tiles concurrently, with an early-exit
/// optimisation: if the full-image tile (tile[0]) contains a large,
/// high-confidence bird (score > 0.65, area > 25% of image), skip the
/// remaining sub-tiles entirely.
fn run_detection_concurrent(
    tile_tensors: &[Vec<u8>],
    tiles: &[[u32; 4]],
    orig_w: u32,
    orig_h: u32,
    stream: &StreamSink<PipelineEvent>,
) -> Result<Vec<RawDetection>, String> {
    let pool = DETECTOR_POOL.get().ok_or("Detector pool not initialized")?;

    if tile_tensors.is_empty() {
        return Ok(Vec::new());
    }

    // --- Early-exit check on full-image tile ---
    stream.add(PipelineEvent::Progress(
        format!("Detection tile 1/{} (Early Exit Check)", tiles.len())
    )).ok();

    let first_dets = infer_single_tile(pool, &tile_tensors[0], tiles[0], orig_w, orig_h)?;
    let total_area = (orig_w as f32) * (orig_h as f32);

    let early_exit = first_dets.iter().any(|d| {
        d.score > 0.65 && (d.local_w as f32 * d.local_h as f32) / total_area > 0.25
    });

    if early_exit {
        return Ok(first_dets);
    }

    // --- Fall back to concurrent sub-tile processing ---
    let remaining_tensors = &tile_tensors[1..];
    let remaining_tiles = &tiles[1..];

    let parallel_dets: Result<Vec<Vec<RawDetection>>, String> = remaining_tensors
        .par_iter()
        .enumerate()
        .map(|(i, tensor)| {
            stream.add(PipelineEvent::Progress(
                format!("Detection tile {}/{}", i + 2, tiles.len())
            )).ok();
            infer_single_tile(pool, tensor, remaining_tiles[i], orig_w, orig_h)
        })
        .collect();

    let mut final_dets = first_dets;
    final_dets.extend(parallel_dets?.into_iter().flatten());
    Ok(final_dets)
}

// ── Classification Internals ───────────────────────────────────────────────

fn classify_image(
    img: &image::DynamicImage,
    allowed_set: &Option<HashSet<String>>,
    is_fallback: bool,
) -> Result<Vec<String>, String> {
    let (embeddings, labels, dim) = SPECIES_DATA.get()
        .ok_or("Species data not initialized")?;

    // 1. Preprocess: resize to 224×224, CLIP-normalize, CHW float32
    let resized = img.resize_exact(224, 224, FilterType::Triangle);
    let rgb = resized.to_rgb8();

    let mut tensor = Vec::with_capacity(3 * 224 * 224);
    for c in 0..3_usize {
        for (_x, _y, pixel) in rgb.enumerate_pixels() {
            let raw = pixel[c] as f32 / 255.0;
            tensor.push((raw - CLIP_MEAN[c]) / CLIP_STD[c]);
        }
    }

    // 2. Run BioCLIP inference
    let input_tensor = Value::from_array(
        (vec![1_i64, 3, 224, 224], tensor)
    ).map_err(|e| format!("{:?}", e))?;

    let inputs = ort::inputs!["pixel_values" => input_tensor];

    let pool = CLASSIFIER_POOL.get().ok_or("Classifier pool not initialized")?;
    let mut session = pool.acquire();

    let raw_embedding_vec = {
        let outputs = session.run(inputs).map_err(|e| format!("{:?}", e))?;
        let (_, raw_embedding) = outputs["embedding"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        raw_embedding.to_vec()
    };
    pool.release(session);

    // 3. L2-normalise the embedding
    let mut embedding: Vec<f32> = raw_embedding_vec;
    l2_normalize(&mut embedding);

    // 4. Cosine similarities with optional eBird local-list bonus
    let num_species = labels.len();
    let mut similarities = vec![0.0_f32; num_species];
    for i in 0..num_species {
        let offset = i * dim;
        let dot: f32 = (0..*dim).map(|j| embedding[j] * embeddings[offset + j]).sum();
        let bonus = if allowed_set.as_ref().map_or(false, |s| s.contains(&labels[i])) {
            LOCAL_BONUS
        } else {
            0.0
        };
        similarities[i] = dot + bonus;
    }

    // 5. Filter hybrids, rank top-K
    let mut indices: Vec<usize> = (0..num_species)
        .filter(|&i| {
            let label = &labels[i];
            !label.contains('/') && !label.contains(" x ") && !label.contains("(hybrid)")
        })
        .collect();
    indices.sort_by(|&a, &b| similarities[b].partial_cmp(&similarities[a])
        .unwrap_or(std::cmp::Ordering::Equal));

    if indices.is_empty() {
        return Ok(vec!["Unknown Bird".to_string()]);
    }

    let top_label = &labels[indices[0]];
    let has_bonus = allowed_set.as_ref().map_or(false, |s| s.contains(top_label));
    let raw_score = similarities[indices[0]] - if has_bonus { LOCAL_BONUS } else { 0.0 };
    let threshold = if is_fallback { FALLBACK_CONFIDENCE } else { MIN_CONFIDENCE };

    if raw_score < threshold {
        return Ok(vec![]); // Rejected as non-bird
    }

    Ok(indices.iter().take(TOP_K).map(|&i| labels[i].clone()).collect())
}

// ── Utility ────────────────────────────────────────────────────────────────

fn l2_normalize(v: &mut [f32]) {
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() { *x /= norm; }
    }
}

fn compute_center_color(img: &image::DynamicImage) -> Vec<f64> {
    let w = img.width();
    let h = img.height();
    let start_x = (w as f32 * 0.4) as u32;
    let start_y = (h as f32 * 0.4) as u32;
    let end_x   = (w as f32 * 0.6) as u32;
    let end_y   = (h as f32 * 0.6) as u32;

    if start_x < end_x && start_y < end_y {
        let mut sum_r = 0.0_f64;
        let mut sum_g = 0.0_f64;
        let mut sum_b = 0.0_f64;
        let mut count = 0.0_f64;
        for y in start_y..end_y {
            for x in start_x..end_x {
                let p = img.get_pixel(x, y);
                sum_r += p[0] as f64;
                sum_g += p[1] as f64;
                sum_b += p[2] as f64;
                count += 1.0;
            }
        }
        if count > 0.0 {
            return vec![sum_r / count, sum_g / count, sum_b / count];
        }
    }
    if w > 0 && h > 0 {
        let p = img.get_pixel(w / 2, h / 2);
        return vec![p[0] as f64, p[1] as f64, p[2] as f64];
    }
    vec![0.0, 0.0, 0.0]
}
