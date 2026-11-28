"""Voice-over with Fish Audio Drama 3 (research licence), served by vLLM-Omni on this GPU.

    # server (separate terminal / background):
    .venv-vomni/bin/vllm serve models/drama-3 --omni --port 8091
    # client:
    .venv-breeze/bin/python gen_drama3.py full [--ref male] [--tag drama3] [--only a,b] [--takes 4]

Drama 3 takes its voice from a reference clip: here the narrator voice designed with Breeze
(public/vo-ref/<ref>.wav, made by gen_breeze.py design), so no real person's voice is cloned.
Each sentence: TAKES takes with different seeds; the one Whisper hears most accurately, then the cleanest
by DNSMOS, is kept (judge.py). Output: public/vo[-tag]/*.wav and src/data/vo[-tag].json.
"""
from __future__ import annotations

import base64
import io
import json
import pathlib
import re
import sys
import urllib.request

import numpy as np
import soundfile as sf

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import judge  # noqa: E402

URL = "http://127.0.0.1:8091/v1/audio/speech"
LINES = json.loads((HERE.parent / "script/vo.json").read_text())
DESIGN_TEXT = ("I spent the last few weeks building something I'm really excited about. It lets your database "
               "read feature flags directly, and honestly, it changed how I ship.")
SAY = {"Flagsmith": "Flag-smith", "Supabase": "Soopa-base"}


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


TAKES = int(arg("--takes", 4))


REF_TEXT = DESIGN_TEXT


def speak(text, ref_b64, seed):
    body = {"model": arg("--model", "models/drama-3"), "input": text, "voice": "default",
            "ref_audio": f"data:audio/wav;base64,{ref_b64}", "ref_text": REF_TEXT,
            "response_format": "wav", "seed": seed}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        w, sr = sf.read(io.BytesIO(r.read()), dtype="float32")
    if w.ndim > 1:
        w = w.mean(axis=1)
    return trim(w, sr), sr


def trim(w, sr):
    idx = np.where(np.abs(w) > 10 ** (-50 / 20))[0]
    return w[max(0, idx[0] - int(0.05 * sr)): idx[-1] + int(0.08 * sr)] if len(idx) else w


def sentences(text):
    return [p for p in re.split(r"(?<=[.?!])\s+(?=[A-Z])", text.strip()) if p]


def spoken(t):
    for a, b in SAY.items():
        t = t.replace(a, b)
    return t


def main():
    global REF_TEXT
    ref = HERE.parent / "public/vo-ref" / f"{arg('--ref', 'male')}.wav"
    if arg("--ref-line"):  # use a narration line (e.g. Breeze's upbeat take) as the reference: its pace carries over
        src = json.loads((HERE.parent / "src/data" / f"{arg('--ref-meta', 'vo')}.json").read_text())[arg("--ref-line")]
        ref, REF_TEXT = HERE.parent / "public" / src["file"], src["text"]
    ref_b64 = base64.b64encode(ref.read_bytes()).decode()
    tag = arg("--tag", "drama3")
    out = HERE.parent / ("public/vo" + (f"-{tag}" if tag else ""))
    out.mkdir(parents=True, exist_ok=True)
    meta_path = HERE.parent / ("src/data/vo" + (f"-{tag}" if tag else "") + ".json")
    only = set(arg("--only").split(",")) if arg("--only") else None
    meta = json.loads(meta_path.read_text()) if (only and meta_path.exists()) else {}
    log = []
    sr = 44100
    for ln in LINES:
        if only and ln["id"] not in only:
            continue
        parts = []
        sents = sentences(ln["text"])
        for j, sent in enumerate(sents):
            top = None
            for k in range(TAKES):
                w, sr = speak(spoken(sent), ref_b64, seed=1000 + k)
                s = judge.score(w, sr, sent)
                key = (round(s["wer"], 3), -s["ovrl"])
                if top is None or key < top[0]:
                    top = (key, w, s)
                if s["wer"] == 0 and s["ovrl"] > 3.4:
                    break
            log.append({"line": ln["id"], "sentence": sent, "wer": top[2]["wer"], "ovrl": round(top[2]["ovrl"], 2), "heard": top[2]["hyp"]})
            parts.append(top[1])
            if j < len(sents) - 1:
                parts.append(np.zeros(int((0.18 if sent.endswith((".", "!")) else 0.26) * sr), dtype=np.float32))
        wav = np.concatenate(parts)
        sf.write(out / f"{ln['id']}.wav", wav, sr)
        meta[ln["id"]] = {"file": f"{out.name}/{ln['id']}.wav", "seconds": round(len(wav) / sr, 3), "text": ln["text"]}
        print(f"{ln['id']:>9} {len(wav) / sr:6.2f}s", flush=True)
    meta_path.write_text(json.dumps(meta, indent=1))
    (out / "_takes.json").write_text(json.dumps(log, indent=1))
    print("total", round(sum(v["seconds"] for v in meta.values()), 1), "s;",
          sum(1 for x in log if x["wer"] > 0), "of", len(log), "sentences not word-perfect")


if __name__ == "__main__":
    main()
