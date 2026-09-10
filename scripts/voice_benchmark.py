import subprocess,json,time,pathlib,base64
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=subprocess.Popen([str(ROOT/'.runtime/venv/bin/python'),str(ROOT/'speech/worker.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
rows=[]
try:
    for i in range(3):
        t=time.monotonic();p.stdin.write(json.dumps({'op':'synthesize','text':'Please remind me to review my notes tomorrow morning.'})+'\n');p.stdin.flush()
        result=json.loads(p.stdout.readline())
        if 'error' in result: raise RuntimeError(result['error'])
        tts=time.monotonic()-t
        t=time.monotonic();p.stdin.write(json.dumps({'op':'transcribe','audio':result['audio'],'language':'en'})+'\n');p.stdin.flush()
        transcription=json.loads(p.stdout.readline())
        rows.append({'trial':i,'tts_seconds':tts,'stt_seconds':time.monotonic()-t,'transcript':transcription.get('text'),'error':transcription.get('error')})
        print(json.dumps(rows[-1]),flush=True)
finally:p.terminate()
(ROOT/'reports/voice-benchmark.json').write_text(json.dumps({'synthetic_roundtrip':rows,'human_english_telugu_mixed_test':'pending'},indent=2))
