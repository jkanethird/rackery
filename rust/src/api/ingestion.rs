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

use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::sync::OnceLock;

use crate::frb_generated::StreamSink;
use rayon::prelude::*;

// ── FFI Types ──────────────────────────────────────────────────────────────

/// Per-file ingestion result streamed back to Dart.
pub struct IngestionFileResult {
    pub path: String,
    pub processed_path: String,
    pub exif_date_ms: Option<i64>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub visual_hash: Option<String>,
    pub file_size: u64,
}

// ── Public API ─────────────────────────────────────────────────────────────

/// Process a batch of image files: extract EXIF, compute perceptual hash,
/// and convert HEIC/HEIF to JPEG. Results stream to Dart as each file
/// completes. Files are sorted by size (ascending) so the smallest finish
/// first.
pub fn ingest_files(
    paths: Vec<String>,
    heic_cache_dir: String,
    stream: StreamSink<IngestionFileResult>,
) -> Result<(), String> {
    // Sort by file size (ascending) so small files finish first.
    let mut sorted_paths = paths;
    sorted_paths.sort_by_key(|p| std::fs::metadata(p).map(|m| m.len()).unwrap_or(u64::MAX));

    // Process all files in parallel; send each result as it completes.
    sorted_paths.par_iter().for_each(|path| {
        let result = process_single_file(path, &heic_cache_dir);
        stream.add(result).ok();
    });

    Ok(())
}

// ── Per-File Processing ────────────────────────────────────────────────────

fn process_single_file(path: &str, heic_cache_dir: &str) -> IngestionFileResult {
    let file_size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    // 1. HEIC conversion (if needed)
    let processed_path = if ext == "heic" || ext == "heif" {
        convert_heic_to_jpeg(path, heic_cache_dir).unwrap_or_else(|_| path.to_string())
    } else {
        path.to_string()
    };

    // 2. EXIF extraction
    let (exif_date_ms, latitude, longitude) = extract_exif(path);

    // 3. Perceptual hash
    let visual_hash = compute_ahash(&processed_path);

    IngestionFileResult {
        path: path.to_string(),
        processed_path,
        exif_date_ms,
        latitude,
        longitude,
        visual_hash,
        file_size,
    }
}

// ── EXIF Extraction ────────────────────────────────────────────────────────

fn extract_exif(path: &str) -> (Option<i64>, Option<f64>, Option<f64>) {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return (None, None, None),
    };
    let mut reader = BufReader::new(&file);

    let exif = match exif::Reader::new().read_from_container(&mut reader) {
        Ok(e) => e,
        Err(_) => return (None, None, None),
    };

    // Date
    let date_ms = exif
        .get_field(exif::Tag::DateTimeOriginal, exif::In::PRIMARY)
        .or_else(|| exif.get_field(exif::Tag::DateTime, exif::In::PRIMARY))
        .and_then(|f| parse_exif_date(&f.display_value().to_string()));

    // GPS
    let lat = parse_gps_coord(
        exif.get_field(exif::Tag::GPSLatitude, exif::In::PRIMARY),
        exif.get_field(exif::Tag::GPSLatitudeRef, exif::In::PRIMARY),
    );
    let lon = parse_gps_coord(
        exif.get_field(exif::Tag::GPSLongitude, exif::In::PRIMARY),
        exif.get_field(exif::Tag::GPSLongitudeRef, exif::In::PRIMARY),
    );

    (date_ms, lat, lon)
}

fn parse_exif_date(display: &str) -> Option<i64> {
    // EXIF dates: "2024-03-15 10:30:00" or "2024:03:15 10:30:00"
    let cleaned = display
        .trim_matches('"')
        .replacen(':', "-", 2);

    // Try parsing with chrono-like manual parsing
    // Format: "YYYY-MM-DD HH:MM:SS"
    let parts: Vec<&str> = cleaned.split_whitespace().collect();
    if parts.len() < 2 {
        return None;
    }

    let date_parts: Vec<&str> = parts[0].split('-').collect();
    let time_parts: Vec<&str> = parts[1].split(':').collect();
    if date_parts.len() < 3 || time_parts.len() < 3 {
        return None;
    }

    let year: i32 = date_parts[0].parse().ok()?;
    let month: u32 = date_parts[1].parse().ok()?;
    let day: u32 = date_parts[2].parse().ok()?;
    let hour: u32 = time_parts[0].parse().ok()?;
    let minute: u32 = time_parts[1].parse().ok()?;
    let second: u32 = time_parts[2].parse().ok()?;

    // Calculate milliseconds since epoch (simplified, assumes UTC)
    // Use the same logic as Dart DateTime.parse
    if year < 1970 || month < 1 || month > 12 || day < 1 || day > 31 {
        return None;
    }

    // Days from epoch to start of year
    let mut days: i64 = 0;
    for y in 1970..year {
        days += if is_leap_year(y) { 366 } else { 365 };
    }

    let month_days = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for m in 1..month {
        days += month_days[m as usize] as i64;
        if m == 2 && is_leap_year(year) {
            days += 1;
        }
    }
    days += (day - 1) as i64;

    let ms = days * 86_400_000
        + hour as i64 * 3_600_000
        + minute as i64 * 60_000
        + second as i64 * 1_000;

    Some(ms)
}

fn is_leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn parse_gps_coord(
    coord_field: Option<&exif::Field>,
    ref_field: Option<&exif::Field>,
) -> Option<f64> {
    let coord = coord_field?;
    let reference = ref_field?;

    let rationals = match &coord.value {
        exif::Value::Rational(v) if v.len() == 3 => v,
        _ => return None,
    };

    let degrees = rationals[0].to_f64();
    let minutes = rationals[1].to_f64();
    let seconds = rationals[2].to_f64();

    let mut value = degrees + minutes / 60.0 + seconds / 3600.0;

    let ref_str = reference.display_value().to_string();
    let ref_str = ref_str.trim_matches('"');
    if ref_str == "S" || ref_str == "W" {
        value = -value;
    }

    Some(value)
}

// ── Perceptual Hash ────────────────────────────────────────────────────────

fn compute_ahash(path: &str) -> Option<String> {
    let img = image::open(path).ok()?;

    // 1. Resize to 8×8
    let small = img.resize_exact(8, 8, image::imageops::FilterType::Triangle);
    let rgb = small.to_rgb8();

    // 2. Grayscale luminances
    let mut luminances = Vec::with_capacity(64);
    let mut total: u64 = 0;

    for pixel in rgb.pixels() {
        let lum = (0.299 * pixel[0] as f64 + 0.587 * pixel[1] as f64 + 0.114 * pixel[2] as f64)
            .round() as u64;
        luminances.push(lum);
        total += lum;
    }

    // 3. Average
    let avg = total / luminances.len() as u64;

    // 4. 64-bit hash
    let mut hash: u64 = 0;
    for (i, &lum) in luminances.iter().enumerate() {
        if lum >= avg {
            hash |= 1u64 << (63 - i);
        }
    }

    Some(format!("{:016x}", hash))
}

// ── HEIC Conversion ────────────────────────────────────────────────────────
//
// We dynamically load libheif at runtime (same library the Dart FFI uses).
// This avoids build-time linking dependencies on all platforms.

// C function signatures from libheif
type HeifContextAlloc = unsafe extern "C" fn() -> *mut std::ffi::c_void;
type HeifContextFree = unsafe extern "C" fn(*mut std::ffi::c_void);
type HeifContextReadFromFile = unsafe extern "C" fn(
    *mut std::ffi::c_void,
    *const std::ffi::c_char,
    *const std::ffi::c_void,
) -> HeifErrorRaw;
type HeifCtxGetPrimaryHandle = unsafe extern "C" fn(
    *mut std::ffi::c_void,
    *mut *mut std::ffi::c_void,
) -> HeifErrorRaw;
type HeifHandleRelease = unsafe extern "C" fn(*mut std::ffi::c_void);
type HeifHandleGetWidth = unsafe extern "C" fn(*mut std::ffi::c_void) -> i32;
type HeifHandleGetHeight = unsafe extern "C" fn(*mut std::ffi::c_void) -> i32;
type HeifDecodeImage = unsafe extern "C" fn(
    *mut std::ffi::c_void,       // handle
    *mut *mut std::ffi::c_void,  // out image
    i32,                         // colorspace
    i32,                         // chroma
    *const std::ffi::c_void,     // options
) -> HeifErrorRaw;
type HeifImageRelease = unsafe extern "C" fn(*mut std::ffi::c_void);
type HeifImageGetPlaneReadonly = unsafe extern "C" fn(
    *mut std::ffi::c_void,  // image
    i32,                    // channel
    *mut i32,               // stride out
) -> *const u8;

#[repr(C)]
#[derive(Clone, Copy)]
struct HeifErrorRaw {
    code: u32,
    subcode: u32,
    message: *const std::ffi::c_char,
}

const HEIF_COLORSPACE_RGB: i32 = 1;
const HEIF_CHROMA_INTERLEAVED_RGB: i32 = 10;
const HEIF_CHANNEL_INTERLEAVED: i32 = 10;

struct HeifLib {
    _lib: libloading::Library,
    alloc: HeifContextAlloc,
    free: HeifContextFree,
    read_from_file: HeifContextReadFromFile,
    get_primary_handle: HeifCtxGetPrimaryHandle,
    release_handle: HeifHandleRelease,
    get_width: HeifHandleGetWidth,
    get_height: HeifHandleGetHeight,
    decode_image: HeifDecodeImage,
    release_image: HeifImageRelease,
    get_plane_readonly: HeifImageGetPlaneReadonly,
}

unsafe impl Send for HeifLib {}
unsafe impl Sync for HeifLib {}

static HEIF_LIB: OnceLock<Result<HeifLib, String>> = OnceLock::new();

fn load_heif_lib() -> &'static Result<HeifLib, String> {
    HEIF_LIB.get_or_init(|| {
        let lib_names: &[&str] = if cfg!(target_os = "windows") {
            &["heif.dll", "libheif.dll"]
        } else if cfg!(target_os = "macos") {
            &["libheif.1.dylib", "libheif.dylib"]
        } else {
            &["libheif.so.1", "libheif.so"]
        };

        let mut last_err = String::new();
        for name in lib_names {
            match unsafe { libloading::Library::new(name) } {
                Ok(lib) => {
                    let result = unsafe {
                        let alloc: HeifContextAlloc = *lib.get(b"heif_context_alloc\0")
                            .map_err(|e| format!("heif_context_alloc: {e}"))?;
                        let free: HeifContextFree = *lib.get(b"heif_context_free\0")
                            .map_err(|e| format!("heif_context_free: {e}"))?;
                        let read_from_file: HeifContextReadFromFile = *lib.get(b"heif_context_read_from_file\0")
                            .map_err(|e| format!("heif_context_read_from_file: {e}"))?;
                        let get_primary_handle: HeifCtxGetPrimaryHandle = *lib.get(b"heif_context_get_primary_image_handle\0")
                            .map_err(|e| format!("heif_context_get_primary_image_handle: {e}"))?;
                        let release_handle: HeifHandleRelease = *lib.get(b"heif_image_handle_release\0")
                            .map_err(|e| format!("heif_image_handle_release: {e}"))?;
                        let get_width: HeifHandleGetWidth = *lib.get(b"heif_image_handle_get_width\0")
                            .map_err(|e| format!("heif_image_handle_get_width: {e}"))?;
                        let get_height: HeifHandleGetHeight = *lib.get(b"heif_image_handle_get_height\0")
                            .map_err(|e| format!("heif_image_handle_get_height: {e}"))?;
                        let decode_image: HeifDecodeImage = *lib.get(b"heif_decode_image\0")
                            .map_err(|e| format!("heif_decode_image: {e}"))?;
                        let release_image: HeifImageRelease = *lib.get(b"heif_image_release\0")
                            .map_err(|e| format!("heif_image_release: {e}"))?;
                        let get_plane_readonly: HeifImageGetPlaneReadonly = *lib.get(b"heif_image_get_plane_readonly\0")
                            .map_err(|e| format!("heif_image_get_plane_readonly: {e}"))?;

                        Ok(HeifLib {
                            _lib: lib,
                            alloc,
                            free,
                            read_from_file,
                            get_primary_handle,
                            release_handle,
                            get_width,
                            get_height,
                            decode_image,
                            release_image,
                            get_plane_readonly,
                        })
                    };
                    return result;
                }
                Err(e) => {
                    last_err = format!("{name}: {e}");
                }
            }
        }
        Err(format!("Failed to load libheif: {last_err}"))
    })
}

fn convert_heic_to_jpeg(path: &str, cache_dir: &str) -> Result<String, String> {
    let heif = load_heif_lib().as_ref().map_err(|e| e.clone())?;

    // Build cached JPEG path
    let stem = Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown");
    let cached_path = format!("{}/{}.jpg", cache_dir, stem);

    // Return cached version if it exists
    if Path::new(&cached_path).exists() {
        return Ok(cached_path);
    }

    // Ensure cache directory exists
    std::fs::create_dir_all(cache_dir).map_err(|e| format!("mkdir: {e}"))?;

    let c_path = std::ffi::CString::new(path).map_err(|e| format!("CString: {e}"))?;

    unsafe {
        let ctx = (heif.alloc)();
        if ctx.is_null() {
            return Err("heif_context_alloc returned null".to_string());
        }

        // Read file
        let err = (heif.read_from_file)(ctx, c_path.as_ptr(), std::ptr::null());
        if err.code != 0 {
            (heif.free)(ctx);
            return Err(format!("heif read error code {}", err.code));
        }

        // Get primary handle
        let mut handle: *mut std::ffi::c_void = std::ptr::null_mut();
        let err = (heif.get_primary_handle)(ctx, &mut handle);
        if err.code != 0 {
            (heif.free)(ctx);
            return Err(format!("heif handle error code {}", err.code));
        }

        let width = (heif.get_width)(handle) as u32;
        let height = (heif.get_height)(handle) as u32;

        // Decode to RGB
        let mut img_ptr: *mut std::ffi::c_void = std::ptr::null_mut();
        let err = (heif.decode_image)(
            handle,
            &mut img_ptr,
            HEIF_COLORSPACE_RGB,
            HEIF_CHROMA_INTERLEAVED_RGB,
            std::ptr::null(),
        );
        if err.code != 0 {
            (heif.release_handle)(handle);
            (heif.free)(ctx);
            return Err(format!("heif decode error code {}", err.code));
        }

        // Get pixel plane
        let mut stride: i32 = 0;
        let plane = (heif.get_plane_readonly)(img_ptr, HEIF_CHANNEL_INTERLEAVED, &mut stride);
        if plane.is_null() {
            (heif.release_image)(img_ptr);
            (heif.release_handle)(handle);
            (heif.free)(ctx);
            return Err("heif plane is null".to_string());
        }

        let total_bytes = (stride as usize) * (height as usize);
        let pixel_slice = std::slice::from_raw_parts(plane, total_bytes);

        // Build contiguous RGB buffer (stride may include padding)
        let row_bytes = (width * 3) as usize;
        let mut rgb_data = Vec::with_capacity(row_bytes * height as usize);
        for y in 0..height as usize {
            let row_start = y * stride as usize;
            rgb_data.extend_from_slice(&pixel_slice[row_start..row_start + row_bytes]);
        }

        // Release libheif resources
        (heif.release_image)(img_ptr);
        (heif.release_handle)(handle);
        (heif.free)(ctx);

        // Encode to JPEG using jpeg-encoder
        let encoder = jpeg_encoder::Encoder::new_file(&cached_path, 90)
            .map_err(|e| format!("jpeg encoder create: {e}"))?;
        encoder
            .encode(&rgb_data, width as u16, height as u16, jpeg_encoder::ColorType::Rgb)
            .map_err(|e| format!("jpeg encode: {e}"))?;

        Ok(cached_path)
    }
}
