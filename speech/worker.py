"""Local-only speech worker. JSON lines over inherited pipes; no HTTP listener.
Audio is transported as in-memory base64 WAV and never saved by the worker.
"""
import base64, contextlib, io, json, os, re, subprocess, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
os.environ['HF_HOME'] = str(ROOT / '.runtime/huggingface')
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'

WHISPER = [str(ROOT/'.runtime/whisper-cli'), '-m', str(ROOT/'.runtime/models/ggml-large-v3-turbo-q5_0.bin'),
           '-f', '-', '-nt', '-t', '4']
# Biases decoding toward Telugu script. Measured: it clearly helps pure Telugu, but hurts
# English badly and hurts code-switched speech, so it is applied only to an explicit
# Telugu selection - never to 'auto', where an utterance may be mixed or English.
TELUGU_PROMPT = 'ఇది తెలుగు సంభాషణ. అన్ని పదాలు తెలుగు లిపిలో రాయాలి.'
LAST = {}


def detect(audio):
    """Choose between the two languages this assistant supports.

    Whisper's own auto-detect ranges over 100 languages and confidently mislabels
    Telugu as Tamil, which yields a transcript in the wrong script. Collapsing the
    decision to English-or-Telugu avoids that whole failure mode.
    """
    p = subprocess.run(WHISPER + ['-dl'], input=audio, capture_output=True, timeout=60)
    found = re.search(r'auto-detected language: ([a-z]{2})', p.stderr.decode('utf-8', 'replace'))
    return 'en' if found and found.group(1) == 'en' else 'te'


def transcribe(audio, lang):
    if lang == 'auto':
        lang = detect(audio)
        args = ['-l', lang]                      # no script prompt: the speech may be mixed
    elif lang == 'te':
        args = ['-l', 'te', '--prompt', TELUGU_PROMPT]
    else:
        args = ['-l', 'en']
    LAST['language'] = lang
    p = subprocess.run(WHISPER + ['-otxt', '-of', '-'] + args,
                       input=audio, capture_output=True, timeout=90)
    if p.returncode: raise RuntimeError('Local transcription failed.')
    return p.stdout.decode('utf-8', 'replace').strip()


model = None
for line in sys.stdin:
    try:
        req = json.loads(line)
        start = time.monotonic()
        if req['op'] == 'transcribe':
            audio = base64.b64decode(req['audio'], validate=True)
            if len(audio) > 8_000_000: raise ValueError('Recording is too long.')
            lang = req.get('language', 'auto')
            if lang not in ('auto','en','te'): raise ValueError('Unsupported language.')
            out = {'text': transcribe(audio, lang), 'language': LAST.get('language', lang)}
        elif req['op'] == 'synthesize':
            with contextlib.redirect_stdout(sys.stderr):
                from mlx_audio.tts.utils import load
                import numpy as np
                import soundfile as sf
                if model is None: model = load('mlx-community/Kokoro-82M-bf16')
                results = list(model.generate(req['text'][:2500], voice='af_heart', lang_code='a'))
                audio = np.concatenate([np.asarray(r.audio) for r in results])
                buf = io.BytesIO(); sf.write(buf,audio,results[0].sample_rate,format='WAV',subtype='PCM_16')
                out = {'audio':base64.b64encode(buf.getvalue()).decode()}
        else: raise ValueError('Unknown speech operation.')
        out['seconds'] = time.monotonic()-start
        print(json.dumps(out), flush=True)
    except Exception as e:
        print(json.dumps({'error': str(e)[:300]}), flush=True)
