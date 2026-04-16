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

// ── RawDetection ──────────────────────────────────────────────────────────

/// A single raw bounding-box detection from the EfficientDet model,
/// expressed in global image coordinates before NMS filtering.
#[derive(Clone, Copy)]
pub struct RawDetection {
    pub global_x: u32,
    pub global_y: u32,
    pub local_w: u32,
    pub local_h: u32,
    pub score: f32,
}

// ── Box parsing ───────────────────────────────────────────────────────────

/// Parse raw detection outputs for a single tile within a (possibly batched)
/// result.
///
/// * `batch_idx` — which element in the batch this tile corresponds to
/// * `max_det`   — maximum detections per batch element (from output shape)
/// * `count`     — actual number of valid detections for this tile
pub fn parse_tile_detections(
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

        // COCO class 15=bird, 16=cat (EfficientDet mapping).
        // Cats are intentionally included because round-faced birds (e.g. owls)
        // are often misclassified as cats by the generic detector.
        if score <= 0.45 || (detected_class != 16 && detected_class != 15) {
            continue;
        }

        let box_flat = batch_idx * max_det * 4 + j * 4;
        let ymin = out_boxes[box_flat].clamp(0.0, 1.0);
        let xmin = out_boxes[box_flat + 1].clamp(0.0, 1.0);
        let ymax = out_boxes[box_flat + 2].clamp(0.0, 1.0);
        let xmax = out_boxes[box_flat + 3].clamp(0.0, 1.0);

        // Skip detections that bleed off the edge of a non-full-image tile —
        // they are likely partial crops of a bird centred in an adjacent tile.
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

// ── Non-Maximum Suppression ───────────────────────────────────────────────

/// Filter duplicate detections using IoU + centre-distance NMS.
///
/// Sorted by descending score so that the highest-confidence box for each
/// subject is always preferred. The coverage check is intentionally omitted
/// so that a small foreground bird enclosed by a larger background bird is
/// not incorrectly suppressed.
pub fn apply_nms(mut detections: Vec<RawDetection>) -> Vec<RawDetection> {
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

                let dist = ((c_cx - k_cx).powi(2) + (c_cy - k_cy).powi(2)).sqrt();
                let dist_thresh = (current.local_w + k.local_w + current.local_h + k.local_h) as f32 / 8.0;

                if iou > 0.30 || (iou > 0.10 && dist < dist_thresh) {
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
