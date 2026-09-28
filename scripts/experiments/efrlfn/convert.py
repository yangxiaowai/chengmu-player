#!/usr/bin/env python3
"""Offline, provenance-checked EfRLFN x2 -> Core ML experiment; never downloads.
Upstream model: MIT, MSU Graphics & Media Lab. See EfRLFN-LICENSE.txt.
"""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import sys
import types


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_official_model(upstream, weights):
    manifest = json.loads(Path(__file__).with_name('upstream-manifest.json').read_text())
    for name, expected in manifest['files_sha256'].items():
        path = upstream / name
        if sha256(path) != expected:
            raise ValueError(f'Upstream source hash mismatch: {path}')
    if sha256(weights) != manifest['checkpoint']['sha256']:
        raise ValueError('Expected the documented official x2 checkpoint; SHA256 mismatch')
    import torch
    # The upstream package is named "code", which conflicts with Python's stdlib.
    # Only the hash-verified model definitions are executed under isolated names.
    utils = types.ModuleType('efrlfn_utils')
    exec(compile((upstream / 'code/utils.py').read_text(), 'efrlfn_utils', 'exec'), utils.__dict__)
    sys.modules['efrlfn_utils'] = utils
    blocks = types.ModuleType('efrlfn_blocks')
    exec(compile((upstream / 'code/blocks.py').read_text().replace('from code.utils import', 'from efrlfn_utils import'), 'efrlfn_blocks', 'exec'), blocks.__dict__)
    sys.modules['efrlfn_blocks'] = blocks
    arch = types.ModuleType('efrlfn_arch')
    exec(compile((upstream / 'code/model.py').read_text().replace('import code.blocks as block', 'import efrlfn_blocks as block'), 'efrlfn_arch', 'exec'), arch.__dict__)
    model = arch.EfRLFN(upscale=2).eval()
    state = torch.load(weights, map_location='cpu', weights_only=True)
    model.load_state_dict(state, strict=True)
    return model, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', required=True, type=Path)
    parser.add_argument('--weights', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--width', type=int, help='Fixed input width; supply together with height')
    parser.add_argument('--height', type=int, help='Fixed input height; otherwise use documented dynamic bounds')
    args = parser.parse_args()
    if bool(args.width) != bool(args.height):
        parser.error('Supply both --width and --height, or neither')
    if args.width and not (64 <= args.width <= 1920 and 64 <= args.height <= 1080):
        parser.error('This experiment is bounded to width 64..1920 and height 64..1080')
    if args.output.exists():
        parser.error('Output already exists; choose a new .mlpackage path')
    import torch
    import coremltools as ct
    model, manifest = load_official_model(args.upstream, args.weights)

    class ImageOutput(torch.nn.Module):
        def __init__(self, network):
            super().__init__()
            self.network = network

        def forward(self, x):
            return self.network(x).clamp(0, 1) * 255.0

    traced = torch.jit.trace(ImageOutput(model).eval(), torch.rand(1, 3, 64, 64))
    shape = (1, 3, args.height, args.width) if args.width else (1, 3, ct.RangeDim(64, 1080, default=64), ct.RangeDim(64, 1920, default=64))
    converted = ct.convert(
        traced,
        inputs=[ct.ImageType(name='image', shape=shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name='restored', color_layout=ct.colorlayout.RGB)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        skip_model_load=True,
    )
    converted.short_description = 'Experimental EfRLFN x2; official MSU checkpoint; RGB SDR'
    converted.author = 'MSU EfRLFN authors; Core ML conversion for YingChuan evaluation'
    converted.license = 'MIT - see EfRLFN-LICENSE.txt'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(args.output)
    manifest.update({
        'python': platform.python_version(), 'torch': torch.__version__, 'coremltools': ct.__version__,
        'input': {'name': 'image', 'format': 'RGB8', 'scale': 1 / 255.0, 'size': [args.width, args.height] if args.width else 'width64..1920/height64..1080/default64'},
        'output': {'name': 'restored', 'format': 'RGB8', 'scale': 2},
        'precision': 'FP16', 'minimum_macos': 15,
        'converted_files_sha256': {str(p.relative_to(args.output)): sha256(p) for p in sorted(args.output.rglob('*')) if p.is_file()},
    })
    args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()
