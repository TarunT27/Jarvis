"""Stage 1 gate: English / Telugu / mixed recognition accuracy.

Every utterance in tests/speech/manifest.json is transcribed through the same
local whisper path the app uses. Audio comes from one of two sources:

  recorded   tests/speech/recordings/<id>.wav in your own voice - the real measurement
  synthetic  generated locally by Kokoro when no recording exists (English only)

Synthetic rows measure the transcription plumbing, not human speech, and are
reported separately so the two are never averaged together. Telugu and mixed
utterances have no local voice, so they stay 'awaiting recording' until you
record them.

Reports word error rate and character error rate; CER is the meaningful figure
for Telugu, where word segmentation differs from English.
"""
import json, pathlib, re, subprocess, sys, unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEECH = ROOT / "tests/speech"
RECORDINGS = SPEECH / "recordings"
WHISPER = ROOT / ".runtime/whisper-cli"
WMODEL = ROOT / ".runtime/models/ggml-large-v3-turbo-q5_0.bin"

manifest = json.loads((SPEECH / "manifest.json").read_text())


UNITS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    "fifteen sixteen seventeen eighteen nineteen".split())}
TENS = {w: (i + 2) * 10 for i, w in enumerate("twenty thirty forty fifty sixty seventy eighty ninety".split())}
ORDINALS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
            "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
            "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
            "nineteenth": 19, "twentieth": 20, "thirtieth": 30}


def normalise(text):
    """Compare what was heard, not how it was spelled.

    Whisper writes "4:30" and "23rd" where a reference spells the numbers out, and
    prefers US spelling. Folding both sides to a common form keeps the error rate a
    measure of recognition rather than orthography. Telugu text is unaffected.
    """
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"(\d+)(st|nd|rd|th)\b", r"\1", text)              # 23rd -> 23
    text = re.sub(r"[^\w\sఀ-౿]", " ", text)                          # 4:30 -> 4 30
    text = re.sub(r"\b(\w+?)is(e|ed|es|ing)\b", r"\1iz\2", text)     # summarise -> summarize

    tokens, out = re.sub(r"\s+", " ", text).strip().split(), []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t in TENS and i + 1 < len(tokens):
            nxt = tokens[i + 1]
            value = UNITS.get(nxt, ORDINALS.get(nxt, 0))
            if 1 <= value <= 9:                                       # twenty three -> 23
                out.append(str(TENS[t] + value)); i += 2; continue
        if t in UNITS:      out.append(str(UNITS[t]))
        elif t in TENS:     out.append(str(TENS[t]))
        elif t in ORDINALS: out.append(str(ORDINALS[t]))
        else:               out.append(t)
        i += 1
    return " ".join(out)


def edit_distance(a, b):
    if not a: return len(b)
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def rate(ref, hyp, by_word):
    r = ref.split() if by_word else list(ref.replace(" ", ""))
    h = hyp.split() if by_word else list(hyp.replace(" ", ""))
    return round(edit_distance(r, h) / max(len(r), 1), 3)


def synthesise_system(text, voice="Geeta"):
    """Telugu and mixed audio from the macOS te_IN voice, converted to 16 kHz mono WAV.

    A synthetic Indic voice is a weaker proxy for human speech than the English case:
    it will not reproduce your accent, pace, or code-switching. Treat these rows as a
    regression baseline for the Telugu decode path, not as the recognition gate.
    """
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        aiff, wav = pathlib.Path(d) / "a.aiff", pathlib.Path(d) / "a.wav"
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True, timeout=120)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                        str(aiff), str(wav)], check=True, timeout=120,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return wav.read_bytes()


worker = None
def speech(request):
    """Drive the same worker process the app uses, so this measures the shipped path."""
    global worker
    if worker is None:
        worker = subprocess.Popen([str(ROOT / ".runtime/venv/bin/python"), str(ROOT / "speech/worker.py")],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True)
    worker.stdin.write(json.dumps(request) + "\n"); worker.stdin.flush()
    result = json.loads(worker.stdout.readline())
    if "error" in result:
        raise RuntimeError(result["error"])
    return result


def transcribe(wav_bytes, language):
    import base64
    result = speech({"op": "transcribe", "audio": base64.b64encode(wav_bytes).decode(),
                     "language": language})
    return result.get("text", ""), result.get("language", language)


def synthesise(text):
    """English-only local voice, used when no recording is present."""
    import base64
    return base64.b64decode(speech({"op": "synthesize", "text": text})["audio"])


rows = []
for u in manifest["utterances"]:
    wav_path = RECORDINGS / f"{u['id']}.wav"
    source = "recorded" if wav_path.exists() else "synthetic"
    row = {"id": u["id"], "language": u["language"], "source": source, "reference": u["text"]}
    try:
        if source == "recorded":
            audio = wav_path.read_bytes()
        elif u["language"] == "en":
            audio = synthesise(u["text"])
        else:
            audio = synthesise_system(u["text"])
        hypothesis, routed = transcribe(audio, u["language"])
        ref, hyp = normalise(u["text"]), normalise(hypothesis)
        row.update({"status": "measured", "hypothesis": hypothesis, "routed_language": routed,
                    "wer": rate(ref, hyp, True), "cer": rate(ref, hyp, False)})
    except Exception as e:
        row.update({"status": "error", "error": str(e)[:200]})
    rows.append(row)
    print(f"{row['id']:6} {row['source']:9} {row.get('status'):18} "
          f"wer={row.get('wer','-')} cer={row.get('cer','-')}", flush=True)

if worker: worker.terminate()


def group(pred):
    got = [r for r in rows if r.get("status") == "measured" and pred(r)]
    if not got: return None
    return {"utterances": len(got),
            "mean_wer": round(sum(r["wer"] for r in got) / len(got), 3),
            "mean_cer": round(sum(r["cer"] for r in got) / len(got), 3),
            "exact_match": round(sum(normalise(r["reference"]) == normalise(r["hypothesis"])
                                     for r in got) / len(got), 3)}


summary = {
    "synthetic_english": group(lambda r: r["source"] == "synthetic" and r["language"] == "en"),
    "synthetic_telugu": group(lambda r: r["source"] == "synthetic" and r["language"] == "te"),
    "synthetic_mixed": group(lambda r: r["source"] == "synthetic" and r["language"] == "auto"),
    "recorded_english": group(lambda r: r["source"] == "recorded" and r["language"] == "en"),
    "recorded_telugu": group(lambda r: r["source"] == "recorded" and r["language"] == "te"),
    "recorded_mixed": group(lambda r: r["source"] == "recorded" and r["language"] == "auto"),
    "awaiting_recording": sorted(r["id"] for r in rows if r.get("status") == "awaiting recording"),
    "errors": [r["id"] for r in rows if r.get("status") == "error"],
}
summary["gate_note"] = ("Synthetic rows exercise the transcription path with machine voices. They are a "
                        "regression baseline, not the gate: the Stage 1 recognition gate is met only "
                        "when recorded English, Telugu and mixed sets are measured in your own voice. "
                        "Record them with scripts/record_utterances.py.")
summary["gate_met"] = all(summary[k] and summary[k]["mean_cer"] <= 0.15
                          for k in ("recorded_english", "recorded_telugu", "recorded_mixed"))
print("\n" + json.dumps(summary, indent=2, ensure_ascii=False))
(ROOT / "reports/speech-accuracy.json").write_text(
    json.dumps({"summary": summary, "utterances": rows}, indent=2, ensure_ascii=False))
