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
use std::sync::{OnceLock, Mutex};
use rayon::prelude::*;
use crate::frb_generated::StreamSink;

// ── Constants ──────────────────────────────────────────────────────────────

/// CLIP image-normalisation constants (mean / std per channel).
const CLIP_MEAN: [f32; 3] = [0.48145466, 0.4578275, 0.40821073];
const CLIP_STD: [f32; 3] = [0.26862954, 0.26130258, 0.27577711];

/// Confidence threshold below which an auto-detected crop is rejected.
const MIN_CONFIDENCE: f32 = 0.18;

/// Fallback threshold (entire-image classification, no detected bird).
const FALLBACK_CONFIDENCE: f32 = 0.25;

/// Bonus added to cosine similarity for species on eBird local checklist.
const LOCAL_BONUS: f32 = 0.08;

/// Number of top-K species to return.
const TOP_K: usize = 5;

/// Maximum number of tiles to batch in a single detector inference call.
/// Kept moderate to avoid OOM on smaller GPUs.
const MAX_BATCH: usize = 16;

/// Detector input resolution.
const DET_SIZE: u32 = 512;

// ── Static State ───────────────────────────────────────────────────────────

static DETECTOR_SESSION: OnceLock<Mutex<Session>> = OnceLock::new();
static CLASSIFIER_SESSION: OnceLock<Mutex<Session>> = OnceLock::new();

/// (flat f32 embeddings row-major, species labels, embedding_dim)
static SPECIES_DATA: OnceLock<(Vec<f32>, Vec<String>, usize)> = OnceLock::new();

/// Whether the ONNX model accepts dynamic batch sizes (tested once).
static BATCH_SUPPORTED: OnceLock<bool> = OnceLock::new();

// ── FFI Structs ────────────────────────────────────────────────────────────

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

// ── Internal Types ─────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
struct RawDetection {
    global_x: u32,
    global_y: u32,
    local_w: u32,
    local_h: u32,
    score: f32,
}

// ── Initialization ─────────────────────────────────────────────────────────

pub fn init_pipeline(
    detector_model_bytes: Vec<u8>,
    classifier_model_bytes: Vec<u8>,
    embeddings_bytes: Vec<u8>,
    labels_json: String,
) -> Result<(), String> {
    let _ = init().with_name("rackery").commit();

    // Build execution provider list: try CUDA first, always include CPU fallback.
    let eps = [
        ort::ep::CUDA::default().build(),
        ort::ep::CPU::default().build(),
    ];

    // 1. Detector session
    let det_session = Session::builder()
        .map_err(|e| format!("{:?}", e))?
        .with_execution_providers(eps.clone())
        .map_err(|e| format!("{:?}", e))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| format!("{:?}", e))?
        .commit_from_memory(&detector_model_bytes)
        .map_err(|e| format!("{:?}", e))?;
    let _ = DETECTOR_SESSION.set(Mutex::new(det_session));

    // 2. Classifier session
    let cls_session = Session::builder()
        .map_err(|e| format!("{:?}", e))?
        .with_execution_providers(eps)
        .map_err(|e| format!("{:?}", e))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| format!("{:?}", e))?
        .commit_from_memory(&classifier_model_bytes)
        .map_err(|e| format!("{:?}", e))?;
    let _ = CLASSIFIER_SESSION.set(Mutex::new(cls_session));

    // 3. Species embeddings
    // Binary format: [i32 num_species, i32 dim, f32 × num_species × dim]
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
        let val = f32::from_le_bytes([
            float_bytes[offset], float_bytes[offset + 1],
            float_bytes[offset + 2], float_bytes[offset + 3],
        ]);
        embeddings.push(val);
    }

    // 4. Species labels
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

    // ── 1. Decode image ────────────────────────────────────────────────────
    let img = image::load_from_memory(&file_bytes).map_err(|e| e.to_string())?;
    let (orig_w, orig_h) = img.dimensions();

    // ── 2. Build tiles (25% overlap instead of 50%) ────────────────────────
    stream.add(PipelineEvent::Progress("Preparing image tiles...".to_string())).ok();
    let tiles = build_tiles(orig_w, orig_h);

    // ── 3. Parallel tensor preparation ─────────────────────────────────────
    stream.add(PipelineEvent::Progress(
        format!("Preparing {} tile tensors...", tiles.len())
    )).ok();
    let tile_tensors: Vec<Vec<u8>> = tiles.par_iter()
        .map(|tile| prepare_tile_tensor(&img, *tile))
        .collect();

    // ── 4. Detection inference (batched or sequential) ─────────────────────
    stream.add(PipelineEvent::Progress("Running object detection...".to_string())).ok();
    let det_mutex = DETECTOR_SESSION.get()
        .ok_or("Detector not initialized")?;
    let mut det_session = det_mutex.lock().map_err(|_| "Detector lock error")?;

    let all_detections = run_detection_batched_or_sequential(
        &mut det_session, &tile_tensors, &tiles, orig_w, orig_h, &stream,
    )?;
    drop(det_session); // Release lock early

    // ── 5. NMS ─────────────────────────────────────────────────────────────
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

    // ── 6. Classification ──────────────────────────────────────────────────
    stream.add(PipelineEvent::Progress(
        format!("Classifying {} detections...", kept.len())
    )).ok();
    let t1 = std::time::Instant::now();

    let cls_mutex = CLASSIFIER_SESSION.get()
        .ok_or("Classifier not initialized")?;
    let mut cls_session = cls_mutex.lock().map_err(|_| "Classifier lock error")?;

    let mut birds: Vec<NativeBirdResult> = Vec::new();

    for (i, det) in kept.iter().enumerate() {
        stream.add(PipelineEvent::Progress(
            format!("Classifying bird {}/{}...", i + 1, kept.len())
        )).ok();

        // 6a. Extract unpadded crop for center color
        let unpadded = img.crop_imm(det.global_x, det.global_y, det.local_w, det.local_h);
        let center_color = compute_center_color(&unpadded);

        // 6b. Extract padded crop for classification + thumbnail
        let pad_x = (det.local_w as f32 * 0.5) as u32;
        let pad_y = (det.local_h as f32 * 0.5) as u32;
        let crop_x1 = det.global_x.saturating_sub(pad_x);
        let crop_y1 = det.global_y.saturating_sub(pad_y);
        let crop_x2 = min(det.global_x + det.local_w + pad_x, orig_w);
        let crop_y2 = min(det.global_y + det.local_h + pad_y, orig_h);
        let padded = img.crop_imm(crop_x1, crop_y1, crop_x2 - crop_x1, crop_y2 - crop_y1);

        // 6c. Classify padded crop
        let species_list = classify_image(
            &mut cls_session,
            &padded,
            &allowed_set,
            false, // not fallback
        )?;

        // If classifier rejects as non-bird, skip
        if species_list.is_empty() {
            continue;
        }

        // 6d. Encode thumbnail JPEG
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
    drop(cls_session);

    let classification_ms = t1.elapsed().as_millis() as u64;

    stream.add(PipelineEvent::Complete(PipelineResult {
        birds,
        detection_ms,
        classification_ms,
    })).ok();
    Ok(())
}

// ── Standalone Classifier (for manual bounding box) ────────────────────────

pub fn classify_crop(
    crop_bytes: Vec<u8>,
    allowed_species: Option<Vec<String>>,
    is_fallback: bool,
) -> Result<ClassificationResult, String> {
    let allowed_set: Option<HashSet<String>> = allowed_species
        .map(|v| v.into_iter().collect());

    let img = image::load_from_memory(&crop_bytes).map_err(|e| e.to_string())?;

    let cls_mutex = CLASSIFIER_SESSION.get()
        .ok_or("Classifier not initialized")?;
    let mut cls_session = cls_mutex.lock().map_err(|_| "Classifier lock error")?;

    let species = classify_image(&mut cls_session, &img, &allowed_set, is_fallback)?;
    Ok(ClassificationResult { species })
}

// ── Detection Internals ────────────────────────────────────────────────────

fn build_tiles(orig_w: u32, orig_h: u32) -> Vec<[u32; 4]> {
    let tile_size: u32 = 1536;
    let stride = tile_size * 3 / 4; // 25% overlap (was 50%)
    let mut tiles = Vec::new();
    tiles.push([0, 0, orig_w, orig_h]);

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

/// Prepare a single tile's input tensor (crop → resize → RGB bytes).
/// This is the CPU-intensive pre-processing step that benefits from parallelism.
fn prepare_tile_tensor(
    img: &image::DynamicImage,
    tile: [u32; 4],
) -> Vec<u8> {
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

/// Run detection using batched inference if the model supports it,
/// falling back to sequential tile-by-tile inference otherwise.
fn run_detection_batched_or_sequential(
    session: &mut Session,
    tile_tensors: &[Vec<u8>],
    tiles: &[[u32; 4]],
    orig_w: u32,
    orig_h: u32,
    stream: &StreamSink<PipelineEvent>,
) -> Result<Vec<RawDetection>, String> {
    // Check if we already know the model doesn't support batching
    if BATCH_SUPPORTED.get() == Some(&false) {
        return run_detection_sequential(session, tile_tensors, tiles, orig_w, orig_h, stream);
    }

    // Try batched inference
    match run_detection_batched(session, tile_tensors, tiles, orig_w, orig_h, stream) {
        Ok(dets) => {
            let _ = BATCH_SUPPORTED.set(true);
            Ok(dets)
        }
        Err(e) => {
            eprintln!("Batched detection failed ({}), falling back to sequential", e);
            let _ = BATCH_SUPPORTED.set(false);
            run_detection_sequential(session, tile_tensors, tiles, orig_w, orig_h, stream)
        }
    }
}

/// Run detection in chunks of MAX_BATCH tiles per ORT call.
fn run_detection_batched(
    session: &mut Session,
    tile_tensors: &[Vec<u8>],
    tiles: &[[u32; 4]],
    orig_w: u32,
    orig_h: u32,
    stream: &StreamSink<PipelineEvent>,
) -> Result<Vec<RawDetection>, String> {
    let pixel_count = (DET_SIZE * DET_SIZE * 3) as usize;
    let mut all_detections: Vec<RawDetection> = Vec::new();

    for chunk_start in (0..tiles.len()).step_by(MAX_BATCH) {
        let chunk_end = (chunk_start + MAX_BATCH).min(tiles.len());
        let batch_size = chunk_end - chunk_start;

        stream.add(PipelineEvent::Progress(
            format!("Detection batch {}-{}/{}", chunk_start + 1, chunk_end, tiles.len())
        )).ok();

        // Concatenate pre-prepared tensors into a single batch
        let mut batch_input: Vec<u8> = Vec::with_capacity(batch_size * pixel_count);
        for tensor in &tile_tensors[chunk_start..chunk_end] {
            batch_input.extend_from_slice(tensor);
        }

        let input_tensor = Value::from_array(
            (vec![batch_size as i64, DET_SIZE as i64, DET_SIZE as i64, 3_i64], batch_input)
        ).map_err(|e| format!("{:?}", e))?;

        let inputs = ort::inputs!["serving_default_images:0" => input_tensor];
        let outputs = session.run(inputs).map_err(|e| format!("{:?}", e))?;

        let (box_shape, out_boxes) = outputs["StatefulPartitionedCall:3"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_classes) = outputs["StatefulPartitionedCall:2"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_scores) = outputs["StatefulPartitionedCall:1"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_count) = outputs["StatefulPartitionedCall:0"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;

        // Determine max_det from the boxes shape: [B, max_det, 4]
        let max_det = if box_shape.len() >= 3 {
            box_shape[1] as usize
        } else if box_shape.len() == 2 {
            // Unbatched shape [max_det, 4] — model doesn't support batching
            return Err("Model output shape suggests no batch support".to_string());
        } else {
            return Err(format!("Unexpected box shape: {:?}", box_shape));
        };

        // Parse detections for each tile in the batch
        for b in 0..batch_size {
            let count = out_count[b] as usize;
            let tile = tiles[chunk_start + b];

            let dets = parse_tile_detections(
                out_boxes, out_scores, out_classes,
                b, max_det, count, tile, orig_w, orig_h,
            );
            all_detections.extend(dets);
        }
    }

    Ok(all_detections)
}

/// Fallback: run detection one tile at a time using pre-prepared tensors.
fn run_detection_sequential(
    session: &mut Session,
    tile_tensors: &[Vec<u8>],
    tiles: &[[u32; 4]],
    orig_w: u32,
    orig_h: u32,
    stream: &StreamSink<PipelineEvent>,
) -> Result<Vec<RawDetection>, String> {
    let mut all_detections: Vec<RawDetection> = Vec::new();

    for (i, tensor) in tile_tensors.iter().enumerate() {
        stream.add(PipelineEvent::Progress(
            format!("Detection tile {}/{}", i + 1, tiles.len())
        )).ok();

        let input_tensor = Value::from_array(
            (vec![1_i64, DET_SIZE as i64, DET_SIZE as i64, 3_i64], tensor.clone())
        ).map_err(|e| format!("{:?}", e))?;

        let inputs = ort::inputs!["serving_default_images:0" => input_tensor];
        let outputs = session.run(inputs).map_err(|e| format!("{:?}", e))?;

        let (_, out_boxes) = outputs["StatefulPartitionedCall:3"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_classes) = outputs["StatefulPartitionedCall:2"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_scores) = outputs["StatefulPartitionedCall:1"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;
        let (_, out_count) = outputs["StatefulPartitionedCall:0"]
            .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;

        let count = out_count[0] as usize;
        let max_det = out_scores.len(); // For batch=1, this is the full score array
        let tile = tiles[i];

        let dets = parse_tile_detections(
            out_boxes, out_scores, out_classes,
            0, max_det, count, tile, orig_w, orig_h,
        );
        all_detections.extend(dets);
    }

    Ok(all_detections)
}

/// Parse raw detection outputs for a single tile within a (possibly batched) result.
///
/// `batch_idx` — which element in the batch this tile corresponds to
/// `max_det`   — maximum detections per batch element (from output shape)
/// `count`     — actual number of valid detections for this tile
fn parse_tile_detections(
    out_boxes: &[f32],
    out_scores: &[f32],
    out_classes: &[f32],
    batch_idx: usize,
    max_det: usize,
    count: usize,
    tile: [u32; 4],
    orig_w: u32,
    orig_h: u32,
) -> Vec<RawDetection> {
    let [left, top, width, height] = tile;
    let mut detections = Vec::new();

    for j in 0..count {
        let flat_idx = batch_idx * max_det + j;
        let score = out_scores[flat_idx];
        let detected_class = out_classes[flat_idx] as i32;

        // COCO class 15=bird, 16=cat (EfficientDet mapping)
        if score <= 0.45 || (detected_class != 16 && detected_class != 15) {
            continue;
        }

        let box_flat = batch_idx * max_det * 4 + j * 4;
        let ymin = out_boxes[box_flat].clamp(0.0, 1.0);
        let xmin = out_boxes[box_flat + 1].clamp(0.0, 1.0);
        let ymax = out_boxes[box_flat + 2].clamp(0.0, 1.0);
        let xmax = out_boxes[box_flat + 3].clamp(0.0, 1.0);

        // Skip edge detections on non-full-image tiles
        if (xmin <= 0.02 && left > 0) ||
           (ymin <= 0.02 && top > 0) ||
           (xmax >= 0.98 && (left + width) < orig_w) ||
           (ymax >= 0.98 && (top + height) < orig_h) {
            continue;
        }

        let local_w = ((xmax - xmin) * width as f32) as i32;
        let local_h = ((ymax - ymin) * height as f32) as i32;
        let global_x = ((xmin * width as f32) + left as f32) as i32;
        let global_y = ((ymin * height as f32) + top as f32) as i32;

        let global_x = global_x.clamp(0, (orig_w - 1) as i32);
        let global_y = global_y.clamp(0, (orig_h - 1) as i32);
        let w_safe = local_w.clamp(1, orig_w as i32 - global_x);
        let h_safe = local_h.clamp(1, orig_h as i32 - global_y);

        let aspect = w_safe as f32 / h_safe as f32;
        if w_safe < 10 || h_safe < 10 || aspect > 5.0 || aspect < 0.20 {
            continue;
        }

        detections.push(RawDetection {
            global_x: global_x as u32,
            global_y: global_y as u32,
            local_w: w_safe as u32,
            local_h: h_safe as u32,
            score,
        });
    }
    detections
}

fn apply_nms(mut detections: Vec<RawDetection>) -> Vec<RawDetection> {
    detections.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    let mut kept: Vec<RawDetection> = Vec::new();

    for current in detections {
        let c_cx = current.global_x as f32 + current.local_w as f32 / 2.0;
        let c_cy = current.global_y as f32 + current.local_h as f32 / 2.0;
        let mut is_duplicate = false;

        for k in &kept {
            let k_cx = k.global_x as f32 + k.local_w as f32 / 2.0;
            let k_cy = k.global_y as f32 + k.local_h as f32 / 2.0;

            let ix_min = current.global_x.max(k.global_x);
            let ix_max = (current.global_x + current.local_w).min(k.global_x + k.local_w);
            let iy_min = current.global_y.max(k.global_y);
            let iy_max = (current.global_y + current.local_h).min(k.global_y + k.local_h);

            if ix_min < ix_max && iy_min < iy_max {
                let intersect = ((ix_max - ix_min) * (iy_max - iy_min)) as f32;
                let area1 = (current.local_w * current.local_h) as f32;
                let area2 = (k.local_w * k.local_h) as f32;
                let iou = intersect / (area1 + area2 - intersect);
                let io_min = intersect / area1.min(area2);

                let dist = ((c_cx - k_cx).powi(2) + (c_cy - k_cy).powi(2)).sqrt();
                let dist_thresh = (current.local_w + k.local_w + current.local_h + k.local_h) as f32 / 8.0;

                if iou > 0.30 || io_min > 0.50 || (iou > 0.10 && dist < dist_thresh) {
                    is_duplicate = true;
                    break;
                }
            }
        }
        if !is_duplicate {
            kept.push(current);
        }
    }
    kept
}

// ── Classification Internals ───────────────────────────────────────────────

fn classify_image(
    session: &mut Session,
    img: &image::DynamicImage,
    allowed_set: &Option<HashSet<String>>,
    is_fallback: bool,
) -> Result<Vec<String>, String> {
    let (embeddings, labels, dim) = SPECIES_DATA.get()
        .ok_or("Species data not initialized")?;

    // 1. Preprocess: resize 224×224, CLIP-normalize, CHW float32
    let resized = img.resize_exact(224, 224, FilterType::Triangle);
    let rgb = resized.to_rgb8();

    let mut tensor = Vec::with_capacity(3 * 224 * 224);
    // CHW layout: channel-first
    for c in 0..3_usize {
        for (_x, _y, pixel) in rgb.enumerate_pixels() {
            let raw = pixel[c] as f32 / 255.0;
            tensor.push((raw - CLIP_MEAN[c]) / CLIP_STD[c]);
        }
    }

    // 2. Run inference
    let input_tensor = Value::from_array(
        (vec![1_i64, 3, 224, 224], tensor)
    ).map_err(|e| format!("{:?}", e))?;

    let inputs = ort::inputs!["pixel_values" => input_tensor];
    let outputs = session.run(inputs).map_err(|e| format!("{:?}", e))?;

    let (_, raw_embedding) = outputs["embedding"]
        .try_extract_tensor::<f32>().map_err(|e| format!("{:?}", e))?;

    // 3. L2-normalize
    let mut embedding: Vec<f32> = raw_embedding.to_vec();
    l2_normalize(&mut embedding);

    // 4. Cosine similarities + local bonus
    let num_species = labels.len();
    let mut similarities = vec![0.0_f32; num_species];
    for i in 0..num_species {
        let offset = i * dim;
        let mut dot: f32 = 0.0;
        for j in 0..*dim {
            dot += embedding[j] * embeddings[offset + j];
        }
        if let Some(ref allowed) = allowed_set {
            if allowed.contains(&labels[i]) {
                dot += LOCAL_BONUS;
            }
        }
        similarities[i] = dot;
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

    let top_score = similarities[indices[0]];
    let top_label = &labels[indices[0]];

    // Check confidence (subtract bonus if present to get raw score)
    let has_bonus = allowed_set.as_ref()
        .map_or(false, |s| s.contains(top_label));
    let raw_score = top_score - if has_bonus { LOCAL_BONUS } else { 0.0 };
    let threshold = if is_fallback { FALLBACK_CONFIDENCE } else { MIN_CONFIDENCE };

    if raw_score < threshold {
        return Ok(vec![]); // Rejected as non-bird
    }

    Ok(indices.iter().take(TOP_K).map(|&i| labels[i].clone()).collect())
}

fn l2_normalize(v: &mut [f32]) {
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
}

fn compute_center_color(img: &image::DynamicImage) -> Vec<f64> {
    let w = img.width();
    let h = img.height();
    let start_x = (w as f32 * 0.4) as u32;
    let start_y = (h as f32 * 0.4) as u32;
    let end_x = (w as f32 * 0.6) as u32;
    let end_y = (h as f32 * 0.6) as u32;

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
