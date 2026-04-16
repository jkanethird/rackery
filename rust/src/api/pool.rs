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
use std::sync::{Condvar, Mutex, OnceLock};

// ── Session Pool ───────────────────────────────────────────────────────────

/// Thread-safe pool of ONNX Runtime sessions.
///
/// Callers `acquire` a session (blocking until one is idle) and `release` it
/// when inference is complete. This lets multiple rayon threads share a fixed
/// set of GPU/CPU sessions without creating per-thread sessions.
pub struct SessionPool {
    sessions: Mutex<Vec<Session>>,
    cvar: Condvar,
}

impl SessionPool {
    pub fn new(sessions: Vec<Session>) -> Self {
        Self {
            sessions: Mutex::new(sessions),
            cvar: Condvar::new(),
        }
    }

    /// Blocks until a session is available, then pops and returns it.
    pub fn acquire(&self) -> Session {
        let mut lock = self.sessions.lock().unwrap();
        while lock.is_empty() {
            lock = self.cvar.wait(lock).unwrap();
        }
        lock.pop().unwrap()
    }

    /// Returns a session to the pool and wakes one waiting thread.
    pub fn release(&self, session: Session) {
        self.sessions.lock().unwrap().push(session);
        self.cvar.notify_one();
    }
}

// ── Static Pools ───────────────────────────────────────────────────────────

pub static DETECTOR_POOL: OnceLock<SessionPool> = OnceLock::new();
pub static CLASSIFIER_POOL: OnceLock<SessionPool> = OnceLock::new();

/// (flat f32 embeddings row-major, species labels, embedding_dim)
pub static SPECIES_DATA: OnceLock<(Vec<f32>, Vec<String>, usize)> = OnceLock::new();
