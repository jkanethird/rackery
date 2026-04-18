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

use ort::session::Session;
use std::sync::{Mutex, OnceLock};

// ── Static Sessions ────────────────────────────────────────────────────────

pub(crate) static DETECTOR_SESSION: OnceLock<Mutex<Session>> = OnceLock::new();
pub(crate) static CLASSIFIER_SESSION: OnceLock<Mutex<Session>> = OnceLock::new();

/// (flat f32 embeddings row-major, species labels, embedding_dim)
pub(crate) static SPECIES_DATA: OnceLock<(Vec<f32>, Vec<String>, usize)> = OnceLock::new();
