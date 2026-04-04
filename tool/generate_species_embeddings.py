#!/usr/bin/env python3
"""Generate pre-computed species text embeddings for BioCLIP zero-shot classification.

Reads species names from lib/services/bird_names.dart, encodes each with the
BioCLIP text encoder using the enriched template, and writes:
  - assets/species_embeddings.bin   (float32 matrix [N × 512])
  - assets/species_labels.json      (ordered list of common names)

Usage:
    pip install open_clip_torch torch
    python tool/generate_species_embeddings.py

Takes ~5-10 minutes for ~10,700 species on CPU.
"""

import json
import os
import re
import struct
import sys

import numpy as np
import torch
import open_clip

MODEL_ID = 'hf-hub:imageomics/bioclip'
BIRD_NAMES_PATH = os.path.join(os.path.dirname(__file__), '..', 'lib', 'services', 'bird_names.dart')
EMBEDDINGS_PATH = os.path.join(os.path.dirname(__file__), '..', 'assets', 'species_embeddings.bin')
LABELS_PATH = os.path.join(os.path.dirname(__file__), '..', 'assets', 'species_labels.json')
TEMPLATE = 'a photo of a {}, a type of bird'
BATCH_SIZE = 64


def extract_common_names(dart_path: str) -> list[str]:
    """Parse common names from the Dart scientificToCommon map."""
    with open(dart_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Match values but correctly ignore escaped quotes, e.g., 'David\'s Fulvetta'
    # Captures the scientific name in group 1, and the common name in group 2
    pattern = re.compile(r"'((?:[^'\\]|\\.)*)'\s*:\s*'((?:[^'\\]|\\.)*)'")
    names = []
    seen = set()
    for m in pattern.finditer(content):
        name = m.group(2).replace("\\'", "'").replace('\\\\', '\\')
        if name not in seen:
            seen.add(name)
            names.append(name)
    return names


def main():
    print(f'Extracting species names from {BIRD_NAMES_PATH}...')
    names = extract_common_names(BIRD_NAMES_PATH)
    print(f'  Found {len(names)} unique common names')

    print(f'Loading BioCLIP model ({MODEL_ID})...')
    model, _, _ = open_clip.create_model_and_transforms(MODEL_ID)
    tokenizer = open_clip.get_tokenizer(MODEL_ID)
    model.eval()

    print(f'Encoding species embeddings (batch_size={BATCH_SIZE})...')
    all_embeddings = []

    for i in range(0, len(names), BATCH_SIZE):
        batch_names = names[i:i + BATCH_SIZE]
        texts = [TEMPLATE.format(name) for name in batch_names]
        tokens = tokenizer(texts)

        with torch.no_grad():
            text_features = model.encode_text(tokens)
            # L2-normalize
            text_features = text_features / text_features.norm(dim=-1, keepdim=True)

        all_embeddings.append(text_features.cpu().numpy())

        done = min(i + BATCH_SIZE, len(names))
        print(f'  {done}/{len(names)} species encoded')

    embeddings = np.concatenate(all_embeddings, axis=0).astype(np.float32)
    print(f'  Final embedding matrix shape: {embeddings.shape}')

    # Write binary embeddings
    os.makedirs(os.path.dirname(EMBEDDINGS_PATH), exist_ok=True)
    with open(EMBEDDINGS_PATH, 'wb') as f:
        # Header: num_species (int32), embedding_dim (int32)
        f.write(struct.pack('<ii', embeddings.shape[0], embeddings.shape[1]))
        f.write(embeddings.tobytes())

    emb_size_mb = os.path.getsize(EMBEDDINGS_PATH) / (1024 * 1024)
    print(f'  Wrote {EMBEDDINGS_PATH} ({emb_size_mb:.1f} MB)')

    # Write labels JSON
    with open(LABELS_PATH, 'w', encoding='utf-8') as f:
        json.dump(names, f, indent=2, ensure_ascii=False)

    print(f'  Wrote {LABELS_PATH} ({len(names)} labels)')
    print('Done!')


if __name__ == '__main__':
    main()
