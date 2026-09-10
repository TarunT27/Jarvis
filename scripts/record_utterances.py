"""Guided recorder for the Stage 1 recognition set.

Prompts you with each utterance that still needs a recording, captures it from the
default microphone at 16 kHz mono, and saves tests/speech/recordings/<id>.wav where
speech_accuracy.py picks it up automatically.

  ./.runtime/venv/bin/python scripts/record_utterances.py            # everything still missing
  ./.runtime/venv/bin/python scripts/record_utterances.py te         # only Telugu
  ./.runtime/venv/bin/python scripts/record_utterances.py auto en    # mixed and English
  ./.runtime/venv/bin/python scripts/record_utterances.py --redo te-04

Enter starts and stops each recording. 'r' re-records, 's' skips, 'q' quits.
Recordings stay on this Mac; nothing is uploaded.
"""
import json, pathlib, sys
import numpy as np, sounddevice as sd, soundfile as sf

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEECH = ROOT / "tests/speech"
RECORDINGS = SPEECH / "recordings"
RECORDINGS.mkdir(parents=True, exist_ok=True)
RATE = 16000

args = [a for a in sys.argv[1:]]
redo = "--redo" in args
if redo: args.remove("--redo")
manifest = json.loads((SPEECH / "manifest.json").read_text())["utterances"]

if redo:
    todo = [u for u in manifest if u["id"] in args]
else:
    todo = [u for u in manifest
            if not (RECORDINGS / f"{u['id']}.wav").exists()
            and (not args or u["language"] in args)]

if not todo:
    print("Nothing to record."); sys.exit(0)

print(f"{len(todo)} utterance(s) to record. Speak naturally, as you would to the assistant.")
print("Enter = start, Enter again = stop, then 'r' re-record, 's' skip, 'q' quit.\n")

def capture():
    frames = []
    with sd.InputStream(samplerate=RATE, channels=1, dtype="float32",
                        callback=lambda indata, *_: frames.append(indata.copy())):
        input("   recording... press Enter to stop")
    return np.concatenate(frames, axis=0) if frames else np.zeros((0, 1), dtype="float32")

done = 0
for n, u in enumerate(todo, 1):
    print(f"[{n}/{len(todo)}] {u['id']}  ({u['language']})")
    print(f"   say:  {u['text']}")
    while True:
        choice = input("   Enter to record, s skip, q quit: ").strip().lower()
        if choice == "q":
            print(f"\nStopped. {done} recorded this session."); sys.exit(0)
        if choice == "s":
            print("   skipped\n"); break
        audio = capture()
        seconds = len(audio) / RATE
        peak = float(np.abs(audio).max()) if len(audio) else 0.0
        if seconds < 0.4 or peak < 0.02:
            print(f"   too quiet or too short ({seconds:.1f}s, peak {peak:.3f}) - try again\n")
            continue
        path = RECORDINGS / f"{u['id']}.wav"
        sf.write(path, audio, RATE, subtype="PCM_16")
        print(f"   saved {path.name}  ({seconds:.1f}s, peak {peak:.2f})")
        again = input("   Enter to keep, r to re-record: ").strip().lower()
        if again != "r":
            done += 1; print(); break

print(f"Done. {done} recorded. Now run:  python3 scripts/speech_accuracy.py")
