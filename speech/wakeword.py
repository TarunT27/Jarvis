"""Local "Hey Jarvis" detector. Raw 16 kHz mono int16 PCM on stdin, JSON lines on stdout.

It only scores each 80 ms frame against the wake phrase: nothing is transcribed,
kept, or written anywhere, and there is no network listener. The app stops feeding
it while a conversation holds the microphone.
"""
import json, os, sys, time
from pathlib import Path
import numpy as np
from openwakeword.model import Model

MODELS = Path(os.environ.get('JARVIS_WAKEWORD_MODELS', Path(__file__).resolve().parents[1] / '.runtime/models/wakeword'))
THRESHOLD = float(os.environ.get('JARVIS_WAKEWORD_THRESHOLD', '0.5'))
FRAME = 1280                 # 80 ms at 16 kHz, the model's native step
REFRACTORY = 2.0             # one utterance of the phrase fires once


def main():
    model = Model(wakeword_models=[str(MODELS / 'hey_jarvis_v0.1.onnx')], inference_framework='onnx',
                  melspec_model_path=str(MODELS / 'melspectrogram.onnx'),
                  embedding_model_path=str(MODELS / 'embedding_model.onnx'))
    print(json.dumps({'ready': True}), flush=True)
    last = 0.0
    stream = sys.stdin.buffer
    while True:
        chunk = stream.read(FRAME * 2)
        if not chunk or len(chunk) < FRAME * 2:
            return
        score = max(model.predict(np.frombuffer(chunk, dtype=np.int16)).values())
        now = time.monotonic()
        if score >= THRESHOLD and now - last > REFRACTORY:
            last = now
            model.reset()
            print(json.dumps({'wake': round(float(score), 3)}), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(json.dumps({'error': str(e)[:300]}), flush=True)
