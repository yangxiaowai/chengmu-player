#!/usr/bin/env python3
"""Summarize observed timing and static placement; no inferred utilization."""
import collections, json, sys
from pathlib import Path
def device_label(description):
    for marker,label in [('MLNeuralEngineComputeDevice','ANE'),('MLGPUComputeDevice','GPU'),('MLCPUComputeDevice','CPU')]:
        if marker in description:return label
    return description
root=Path(sys.argv[1]); reports=[]
for p in sorted(root.glob('*/report-*.json')):
    d=json.loads(p.read_text());r=d['results'][0]
    reports.append({'variant':p.parent.name,'units':d['units'],'first_ms':r['total_ms'][0],'warm_ms':r['total_ms'][1:],'warm_mean_ms':r['warm_mean_ms'],'model_ms':r['model_ms'],'repeat_identical':r['repeat_identical']})
plans=[]
for p in sorted(root.glob('*/plan-*.json')):
    d=json.loads(p.read_text());ops=d['operations']; counts=collections.Counter(); costs=collections.Counter(); byop={}
    for o in ops:
        if o['operator']=='const':continue
        dev=device_label(o.get('preferred','unknown'));counts[dev]+=1;costs[dev]+=o.get('estimated_cost_weight',0)
        key=(o['operator'],dev)
        if key not in byop:byop[key]={'operator':o['operator'],'preferred':dev,'count':0,'estimated_cost_weight_sum':0}
        byop[key]['count']+=1;byop[key]['estimated_cost_weight_sum']+=o.get('estimated_cost_weight',0)
    plans.append({'variant':p.parent.name,'units':d['units'],'preferred_operation_counts':dict(counts),'relative_predicted_cost_by_preferred_device':dict(costs),'operators':sorted(byop.values(),key=lambda x:-x['estimated_cost_weight_sum'])})
summary={'timing':reports,'plans':plans,'caution':'MLComputePlan cost is a static relative estimate; it does not measure GPU/ANE occupancy or power. Times include completed input/output CI rendering, exclude decode/audio, from four repeated synthetic frames.'}
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
