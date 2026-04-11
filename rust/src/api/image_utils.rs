use rayon::prelude::*;
use flutter_rust_bridge::frb;
use image::{imageops::FilterType, GenericImageView, DynamicImage};
use std::cmp::{max, min};

pub struct PrepareTilesResult {
    pub tile_pixels: Vec<Vec<u8>>,
    pub tile_rects: Vec<Vec<u32>>,
    pub orig_w: u32,
    pub orig_h: u32,
}

pub fn prepare_tiles(
    file_bytes: Vec<u8>,
    target_w: u32,
    target_h: u32,
    custom_tiles: Option<Vec<Vec<u32>>>,
) -> Option<PrepareTilesResult> {
    let img = image::load_from_memory(&file_bytes).ok()?;
    let (orig_w, orig_h) = img.dimensions();

    let tiles = if let Some(ct) = custom_tiles {
        ct
    } else {
        // Build default tiles
        let mut t = Vec::new();
        t.push(vec![0, 0, orig_w, orig_h]);

        let tile_size = 1536;
        let stride = tile_size / 2;

        if orig_w > tile_size || orig_h > tile_size {
            let mut y = 0;
            while y < orig_h {
                let mut x = 0;
                while x < orig_w {
                    let mut crop_x = x;
                    let mut crop_y = y;

                    if crop_x + tile_size > orig_w {
                        crop_x = orig_w.saturating_sub(tile_size);
                    }
                    if crop_y + tile_size > orig_h {
                        crop_y = orig_h.saturating_sub(tile_size);
                    }

                    let crop_w = min(tile_size, orig_w - crop_x);
                    let crop_h = min(tile_size, orig_h - crop_y);

                    t.push(vec![crop_x, crop_y, crop_w, crop_h]);

                    x += stride;
                }
                y += stride;
            }
        }
        
        // Remove duplicates
        let mut unique = Vec::new();
        for tile in t {
            if !unique.contains(&tile) {
                unique.push(tile);
            }
        }
        unique
    };

    let processed_tiles: Vec<(Vec<u8>, Vec<u32>)> = tiles
        .into_par_iter()
        .map(|tile| {
            let left = tile[0];
            let top = tile[1];
            let width = tile[2];
            let height = tile[3];
            
            let left_safe = left.min(orig_w.saturating_sub(1));
            let top_safe = top.min(orig_h.saturating_sub(1));
            let width_safe = width.min(orig_w - left_safe);
            let height_safe = height.min(orig_h - top_safe);

            let cropped = img.crop_imm(left_safe, top_safe, width_safe, height_safe);
            let resized = cropped.resize_exact(target_w, target_h, FilterType::Triangle);
            
            let rgb = resized.to_rgb8();
            (rgb.into_raw(), tile)
        })
        .collect();

    let mut tile_pixels = Vec::with_capacity(processed_tiles.len());
    let mut tile_rects = Vec::with_capacity(processed_tiles.len());
    
    for (pixels, rect) in processed_tiles {
        tile_pixels.push(pixels);
        tile_rects.push(rect);
    }

    Some(PrepareTilesResult {
        tile_pixels,
        tile_rects,
        orig_w,
        orig_h,
    })
}
