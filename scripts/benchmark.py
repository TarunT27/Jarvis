#!/usr/bin/env python3
"""Non-destructive inference test; no desktop or account tools execute."""
import json, pathlib, statistics, time, urllib.request, subprocess, os
ROOT = pathlib.Path(__file__).resolve().parents[1]
def call(path, data):
    req=urllib.request.Request('http://127.0.0.1:11439/api/'+path,data=json.dumps(data).encode(),headers={'Content-Type':'application/json'})
    return urllib.request.urlopen(req,timeout=240)
rows=[]
for i,prompt in enumerate(['Say hello in one short sentence.', 'Explain what a calendar reminder does in one short sentence.', 'What is 17 plus 28? Answer briefly.', 'Summarize this in one sentence: I have a meeting at noon and should prepare my notes before it.', 'Reply in English: రేపు నా సమావేశం ఎప్పుడు?']):
    t=time.monotonic(); first=None; text=''; final={}
    with call('chat',{'model':'qwen3.5:9b','messages':[{'role':'user','content':prompt}],'think':False,'stream':True,'keep_alive':300,'options':{'num_ctx':8192,'num_predict':100}}) as f:
        for line in f:
            j=json.loads(line); token=j.get('message',{}).get('content','')
            if token and first is None: first=time.monotonic()-t
            text+=token; final=j
    rows.append({'case':i,'first_token_seconds':first,'total_seconds':time.monotonic()-t,'answer':text,'eval_count':final.get('eval_count'),'eval_duration_ns':final.get('eval_duration')})
    print(json.dumps(rows[-1]),flush=True)
with urllib.request.urlopen('http://127.0.0.1:11439/api/ps') as f: loaded=json.load(f)
with urllib.request.urlopen('http://127.0.0.1:11439/api/tags') as f: models=json.load(f)
report={'generated':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'model_trials':rows,'loaded_models':loaded,'installed_models':models,'limits':'Synthetic prompts only. Human Telugu recognition and 30-minute thermal validation pending.'}
(ROOT/'reports/model-benchmark.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
