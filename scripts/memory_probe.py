"""Stage 1 gate: everyday-mode memory footprint under a realistic mixed workload.

Samples resident memory of every Jarvis-owned process (model server, model runner,
speech worker, whisper) while driving chat turns, transcription and synthesis, then
reports the peak assistant footprint against the 12-16 GB everyday budget.
Only processes under this project's .runtime are counted, so a separately
installed Ollama on the default port is never attributed to Jarvis.
"""
import json, pathlib, subprocess, sys, threading, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENDPOINT = "http://127.0.0.1:11439/api/chat"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen3.5:9b"
DEEP = "qwen3.8:27b"
# Two different budgets: everyday mode targets 12-16 GB, Deep mode under 30 GB.
BUDGET_GB = 30.0 if MODEL == DEEP else 16.0
MODE = "deep" if MODEL == DEEP else "everyday"
SLUG = MODEL.replace(":", "-").replace(".", "-")

# Match both the absolute path and the project-relative form, since a server
# launched as ./.runtime/... shows a relative command in ps.
OWNED = (str(ROOT / ".runtime"), f"{ROOT.parent.name}/{ROOT.name}/.runtime", "./.runtime")


def sample():
    """Resident MB per Jarvis-owned process, keyed by a short label."""
    out = subprocess.run(["ps", "-Ao", "rss=,command="], capture_output=True, text=True).stdout
    total, detail = 0.0, {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        rss, _, cmd = line.partition(" ")
        if not any(o in cmd for o in OWNED):
            continue
        try:
            mb = int(rss) / 1024
        except ValueError:
            continue
        label = pathlib.Path(cmd.split()[0]).name
        detail[label] = round(detail.get(label, 0.0) + mb, 1)
        total += mb
    return round(total, 1), detail


peaks = {"total_mb": 0.0, "detail": {}}
stop = threading.Event()


def monitor():
    while not stop.is_set():
        total, detail = sample()
        if total > peaks["total_mb"]:
            peaks["total_mb"], peaks["detail"] = total, detail
        time.sleep(0.5)


def chat(text):
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": text}],
                       "stream": False, "think": False,
                       "options": {"num_ctx": 8192, "num_predict": 512, "temperature": 0.2}}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)


baseline_total, baseline_detail = sample()
threading.Thread(target=monitor, daemon=True).start()

# Speech worker stays resident, as it does in the app.
worker = subprocess.Popen([str(ROOT / ".runtime/venv/bin/python"), str(ROOT / "speech/worker.py")],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True)


def speech(req):
    worker.stdin.write(json.dumps(req) + "\n"); worker.stdin.flush()
    return json.loads(worker.stdout.readline())


timeline = []
try:
    for i, prompt in enumerate([
        "Summarise in three sentences why local-first software protects privacy.",
        "List five things to check before a long flight.",
        "Explain the difference between a reminder and a calendar event.",
    ]):
        t = time.monotonic(); chat(prompt)
        spoken = speech({"op": "synthesize", "text": "Here is the summary you asked for."})
        heard = speech({"op": "transcribe", "audio": spoken["audio"], "language": "en"})
        total, detail = sample()
        timeline.append({"turn": i, "seconds": round(time.monotonic() - t, 2),
                         "resident_mb": total, "transcript_ok": bool(heard.get("text"))})
        print(json.dumps(timeline[-1]), flush=True)
finally:
    stop.set(); time.sleep(0.8); worker.terminate()

report = {
    "model": MODEL,
    "baseline_mb": baseline_total, "baseline_detail": baseline_detail,
    "peak_mb": peaks["total_mb"], "peak_gb": round(peaks["total_mb"] / 1024, 2),
    "peak_detail_mb": peaks["detail"],
    "mode": MODE, "budget_gb": BUDGET_GB,
    "within_budget": peaks["total_mb"] / 1024 <= BUDGET_GB,
    "timeline": timeline,
    "limits": "Short mixed workload on one machine. Sustained 30-minute thermal and swap validation is separate.",
}
print("\n" + json.dumps({k: v for k, v in report.items() if k != "timeline"}, indent=2))
(ROOT / f"reports/memory-probe-{SLUG}.json").write_text(json.dumps(report, indent=2))
