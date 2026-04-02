#!/usr/bin/env python3
"""Export the BioCLIP vision encoder to ONNX format.

Usage:
    pip install open_clip_torch torch onnx onnxscript
    python tool/export_bioclip_vision.py

Produces: assets/bioclip_vision.onnx (~350MB)
"""

import os
import torch
import open_clip

MODEL_ID = 'hf-hub:imageomics/bioclip'
OUTPUT_PATH = os.path.join(os.path.dirname(__file__), '..', 'assets', 'bioclip_vision.onnx')


class VisualWrapper(torch.nn.Module):
    """Thin wrapper so torch.onnx sees a plain nn.Module with a forward()."""
    def __init__(self, visual):
        super().__init__()
        self.visual = visual

    def forward(self, pixel_values):
        return self.visual(pixel_values)


def main():
    print(f'Loading BioCLIP model from {MODEL_ID}...')
    model, _, preprocess = open_clip.create_model_and_transforms(MODEL_ID)
    model.eval()

    wrapper = VisualWrapper(model.visual)
    wrapper.eval()

    # Dummy input: batch=1, channels=3, H=224, W=224
    dummy = torch.randn(1, 3, 224, 224)

    print('Exporting vision encoder to ONNX (legacy exporter)...')
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)

    # Force the legacy (TorchScript-based) exporter by setting dynamo=False
    torch.onnx.export(
        wrapper,
        (dummy,),
        OUTPUT_PATH,
        export_params=True,
        opset_version=17,
        do_constant_folding=True,
        input_names=['pixel_values'],
        output_names=['embedding'],
        dynamo=False,
    )

    size_mb = os.path.getsize(OUTPUT_PATH) / (1024 * 1024)
    print(f'Exported to {OUTPUT_PATH} ({size_mb:.1f} MB)')


if __name__ == '__main__':
    main()
