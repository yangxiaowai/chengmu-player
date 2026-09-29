#!/usr/bin/env python3
"""Serial accelerator window: one cold + three warm, fixed full-size frames.
Do not run concurrently with another GPU benchmark. No downloads/installations.
"""
import argparse, json, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--artifacts',type=Path,required=True)
p.add_argument('--baseline',type=Path,required=True)
p.add_argument('--results',type=Path,required=True)
p.add_argument('--baseline1080',type=Path)
p.add_argument('--parity-fixture',type=Path)
a=p.parse_args();a.results.mkdir(parents=True,exist_ok=True)
models={'baseline':a.baseline, 'eca2d':a.artifacts/'eca2d-1280x720.mlpackage', 'toeplitz':a.artifacts/'toeplitz-1280x720.mlpackage', 'padded64':a.artifacts/'padded64-1280x720.mlpackage'}
for variant,model in models.items():
    directory=a.results/variant; directory.mkdir(exist_ok=True)
    units=['all','gpu','ne'] if variant=='baseline' else ['all','ne']
    for unit in units:
        commands=[['plan',str(model),str(directory/f'plan-{unit}.json'),unit],['probe',str(model),str(directory),unit,'1280x720']]
        for tool,*args in commands:
            print(f'{variant} {unit} {tool}',flush=True)
            result=subprocess.run([str(a.artifacts/tool),*args],capture_output=True,text=True,timeout=120)
            (directory/f'{tool}-{unit}.log').write_text(result.stdout+result.stderr)
            print(result.stdout,flush=True)
            if result.returncode: raise RuntimeError(result.stderr)
if a.baseline1080:
    directory=a.results/'baseline1080';directory.mkdir(exist_ok=True)
    result=subprocess.run([str(a.artifacts/'probe'),str(a.baseline1080),str(directory),'ne','1920x1080'],capture_output=True,text=True,timeout=120)
    (directory/'probe-ne.log').write_text(result.stdout+result.stderr);print(result.stdout,flush=True)
    if result.returncode:raise RuntimeError(result.stderr)
if a.parity_fixture:
    for variant, model in models.items():
        if variant=='baseline':continue
        result=subprocess.run([str(a.artifacts/'render'),str(model),str(a.artifacts/f'parity-{variant}'),str(a.parity_fixture)],capture_output=True,text=True,timeout=120)
        (a.results/f'render-{variant}.log').write_text(result.stdout+result.stderr);print(result.stdout,flush=True)
        if result.returncode:raise RuntimeError(result.stderr)
print('All serial probes completed.')
