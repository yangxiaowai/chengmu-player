#!/usr/bin/env python3
"""Exact offline ECA graph rewrites; use parent hash-checked official loader."""
import argparse, collections, copy, json, sys, hashlib
from pathlib import Path
import torch
import coremltools as ct
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from convert import load_official_model, sha256

class ECA2D(torch.nn.Module):
    def __init__(self, original):
        super().__init__()
        self.pool = torch.nn.AdaptiveAvgPool2d(1)
        self.conv = torch.nn.Conv2d(1, 1, (3, 1), padding=(1, 0), bias=False)
        with torch.no_grad(): self.conv.weight.copy_(original.conv.weight.unsqueeze(-1))
    def forward(self, x):
        y = self.pool(x).transpose(1, 2)
        return x * self.conv(y).transpose(1, 2).sigmoid()

class ECAToeplitz(torch.nn.Module):
    def __init__(self, original, channels=52):
        super().__init__()
        self.pool = torch.nn.AdaptiveAvgPool2d(1)
        self.conv = torch.nn.Conv2d(channels, channels, 1, bias=False)
        with torch.no_grad():
            self.conv.weight.zero_()
            for c in range(channels):
                for k in range(3):
                    j = c + k - 1
                    if 0 <= j < channels:
                        self.conv.weight[c, j, 0, 0] = original.conv.weight[0, 0, k]
    def forward(self, x):
        return x * self.conv(self.pool(x)).sigmoid()

class ImageOutput(torch.nn.Module):
    def __init__(self, network): super().__init__(); self.network=network
    def forward(self, x): return self.network(x).clamp(0, 1) * 255.

def optimize(model, variant):
    model = copy.deepcopy(model)
    if variant != 'baseline':
        cls = ECA2D if variant == 'eca2d' else ECAToeplitz
        for i in range(1, 7):
            block=getattr(model, f'block_{i}'); block.eca=cls(block.eca, channels=64) if variant=='padded64' else cls(block.eca)
    if variant=='padded64':
        # Extra feature planes are exactly zero throughout: zero kernels/bias, tanh(0)=0,
        # residual additions preserve zero, attention is multiplied by zero.
        for name, layer in list(model.named_modules()):
            if not isinstance(layer, torch.nn.Conv2d) or (layer.in_channels!=52 and layer.out_channels!=52): continue
            cin=64 if layer.in_channels==52 else layer.in_channels
            cout=64 if layer.out_channels==52 else layer.out_channels
            padded=torch.nn.Conv2d(cin,cout,layer.kernel_size,stride=layer.stride,padding=layer.padding,dilation=layer.dilation,groups=layer.groups,bias=layer.bias is not None,padding_mode=layer.padding_mode)
            with torch.no_grad():
                padded.weight.zero_();padded.weight[:layer.out_channels,:layer.in_channels].copy_(layer.weight)
                if layer.bias is not None:
                    padded.bias.zero_();padded.bias[:layer.out_channels].copy_(layer.bias)
            parent_name, _, attribute=name.rpartition('.')
            setattr(model.get_submodule(parent_name) if parent_name else model, attribute, padded)
    return model.eval()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--upstream', required=True, type=Path); p.add_argument('--weights', required=True, type=Path)
    p.add_argument('--directory', required=True, type=Path)
    p.add_argument('--variant', choices=['baseline','eca2d','toeplitz','padded64'], required=True)
    p.add_argument('--width', type=int, default=1280); p.add_argument('--height', type=int, default=720)
    p.add_argument('--fixture', type=Path)
    a=p.parse_args(); a.directory.mkdir(parents=True, exist_ok=True)
    target=a.directory/f'{a.variant}-{a.width}x{a.height}.mlpackage'
    if target.exists(): p.error('output exists: '+str(target))
    torch.set_num_threads(4); torch.manual_seed(20260929)
    original, provenance=load_official_model(a.upstream,a.weights)
    rewritten=optimize(original,a.variant)
    samples=[('random64',torch.rand(1,3,64,64))]
    if a.fixture:
        import numpy as np
        from PIL import Image
        data=np.asarray(Image.open(a.fixture).convert('RGB'),dtype=np.float32)/255.
        samples.append((a.fixture.stem,torch.from_numpy(data).permute(2,0,1).unsqueeze(0)))
    parity=[]
    with torch.inference_mode():
        for name, tensor in samples:
            reference=original(tensor); actual=rewritten(tensor); error=(actual-reference).abs()
            entry={'fixture':name,'input_shape':list(tensor.shape),'unclipped_FP32_max_abs':float(error.max()),'unclipped_FP32_mean_abs':float(error.mean())}
            if float(error.max())>1e-5: raise RuntimeError(f'Not equivalent: {entry}')
            parity.append(entry)
    wrapped=ImageOutput(rewritten).eval()
    traced=torch.jit.trace(wrapped,torch.rand(1,3,64,64))
    converted=ct.convert(traced,inputs=[ct.ImageType(name='image',shape=(1,3,a.height,a.width),scale=1/255.,color_layout=ct.colorlayout.RGB)],outputs=[ct.ImageType(name='restored',color_layout=ct.colorlayout.RGB)],minimum_deployment_target=ct.target.macOS15,compute_precision=ct.precision.FLOAT16,skip_model_load=True)
    converted.author='MSU EfRLFN authors; exact ECA rewrite experiment'; converted.license='MIT; see ../EfRLFN-LICENSE.txt'
    converted.save(target)
    histogram=collections.Counter(op.op_type for f in converted._mil_program.functions.values() for op in f.operations)
    report={'variant':a.variant,'input':[a.width,a.height],'output':[a.width*2,a.height*2],'source':provenance,'parity':parity,'MIL_operator_counts':dict(histogram),'files_sha256':{str(x.relative_to(target)):sha256(x) for x in sorted(target.rglob('*')) if x.is_file()},'torch':torch.__version__,'coremltools':ct.__version__}
    target.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'model':str(target),'parity':parity,'ops':dict(histogram)},indent=2))
if __name__=='__main__': main()
