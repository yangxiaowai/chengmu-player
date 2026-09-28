#!/usr/bin/env python3
"""CPU FP32 reference and optional RGB8 Core ML parity measurement; no downloads."""
from pathlib import Path
import argparse
import json
import numpy as np
from PIL import Image
from convert import load_official_model


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--upstream', required=True, type=Path)
    p.add_argument('--weights', required=True, type=Path)
    p.add_argument('--input', required=True, type=Path)
    p.add_argument('--output-prefix', required=True, type=Path)
    p.add_argument('--coreml-output', type=Path)
    args = p.parse_args()
    import torch
    model, _ = load_official_model(args.upstream, args.weights)
    rgb = np.asarray(Image.open(args.input).convert('RGB'), dtype=np.float32) / 255.0
    with torch.inference_mode():
        tensor = torch.from_numpy(rgb.transpose(2, 0, 1)).unsqueeze(0)
        reference = model(tensor).clamp(0, 1).squeeze(0).permute(1, 2, 0).numpy() * 255.0
    args.output_prefix.parent.mkdir(parents=True, exist_ok=True)
    np.save(str(args.output_prefix) + '.npy', reference)
    Image.fromarray(np.rint(reference).astype(np.uint8)).save(str(args.output_prefix) + '.png')
    if args.coreml_output:
        actual = np.asarray(Image.open(args.coreml_output).convert('RGB'), dtype=np.float32)
        if actual.shape != reference.shape:
            raise ValueError(f'Shape mismatch: {actual.shape} vs {reference.shape}')
        difference = np.abs(actual - reference)
        report = {'shape': list(actual.shape), 'mae_codes': float(difference.mean()),
                  'max_abs_codes': float(difference.max()), 'p99_abs_codes': float(np.quantile(difference, .99)),
                  'rmse_codes': float(np.sqrt((difference ** 2).mean())),
                  'scope': 'RGB 0..255 codes; one image; this verifies conversion, not restoration quality'}
        Path(str(args.output_prefix) + '-parity.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
