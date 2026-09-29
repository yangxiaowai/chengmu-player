#!/usr/bin/env python3
"""One CPU FP32 reference for a full 720p input; compares completed RGB8 output."""
import argparse,json,sys,hashlib
from pathlib import Path
import numpy as np
from PIL import Image
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--artifacts',type=Path,required=True);p.add_argument('--results',type=Path,required=True)
p.add_argument('--prepare',action='store_true');p.add_argument('--upstream',type=Path);p.add_argument('--weights',type=Path);p.add_argument('--fixture',type=Path)
a=p.parse_args()
if a.prepare:
    import torch
    torch.set_num_threads(4)
    sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
    from convert import load_official_model
    # Upscaling a 480p fixture here makes a full-sized conversion test input.
    # It is not a restoration-quality test or an input downscale optimization.
    image=Image.open(a.fixture).convert('RGB').resize((1280,720),Image.Resampling.BICUBIC)
    image.save(a.artifacts/'parity-720.png')
    model,_=load_official_model(a.upstream,a.weights)
    x=torch.from_numpy(np.asarray(image,dtype=np.float32)/255.).permute(2,0,1).unsqueeze(0)
    with torch.inference_mode(): y=model(x).clamp(0,1).squeeze(0).permute(1,2,0).numpy()*255.
    np.save(a.artifacts/'reference-720.npy',y)
    print('CPU reference done',y.shape)
else:
    ref=np.load(a.artifacts/'reference-720.npy');entries=[]
    for path in sorted(a.artifacts.glob('parity-*/*-coreml.png')):
        actual=np.asarray(Image.open(path).convert('RGB'),dtype=np.float32)
        if actual.shape!=ref.shape: raise ValueError('Shape mismatch')
        error=np.abs(actual-ref)
        entries.append({'variant':path.parent.name.removeprefix('parity-'),'shape':list(actual.shape),'MAE_RGB8_codes':float(error.mean()),'max_RGB8_codes':float(error.max()),'p99_RGB8_codes':float(np.quantile(error,.99)),'png_sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    if not entries: raise ValueError('No CoreML outputs')
    report={'scope':'one full1280x720 RGB8 input rendered x2; selected still image checks color/FP16 conversion only, not perceptual quality or temporal consistency','fixture_sha256':hashlib.sha256((a.artifacts/'parity-720.png').read_bytes()).hexdigest(),'results':entries}
    a.results.mkdir(parents=True,exist_ok=True);(a.results/'coreml-parity.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
