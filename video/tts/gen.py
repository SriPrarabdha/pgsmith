"""Generate the voice-over with Kokoro (local, open-weight TTS).

    .venv/bin/python gen.py [--voice am_michael] [--speed 1.0] [--only id,id] [--out ../public/vo]
Writes one WAV per script line and ../src/data/vo.json with each line's duration.
"""
import argparse, json, pathlib
import numpy as np, soundfile as sf
from kokoro import KPipeline

HERE = pathlib.Path(__file__).resolve().parent
ap = argparse.ArgumentParser()
ap.add_argument("--voice", default="am_michael")
ap.add_argument("--speed", type=float, default=1.0)
ap.add_argument("--only", default="")
ap.add_argument("--out", default=str(HERE.parent / "public/vo"))
ap.add_argument("--meta", default=str(HERE.parent / "src/data/vo.json"))
a = ap.parse_args()
lines = json.loads((HERE.parent / "script/vo.json").read_text())
only = set(filter(None, a.only.split(",")))
out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
lang = "b" if a.voice.startswith("b") else "a"
pipe = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M")
meta_path = pathlib.Path(a.meta)
meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
for ln in lines:
    if only and ln["id"] not in only:
        continue
    chunks = [audio.numpy() if hasattr(audio, "numpy") else audio
              for _, _, audio in pipe(ln["text"], voice=a.voice, speed=a.speed, split_pattern=None)]
    wav = np.concatenate(chunks)
    # trim leading/trailing silence below -50 dB, keep 60 ms
    thr = 10 ** (-50 / 20); idx = np.where(np.abs(wav) > thr)[0]
    if len(idx):
        wav = wav[max(0, idx[0] - 1440): idx[-1] + 1440]
    f = out / f"{ln['id']}.wav"
    sf.write(f, wav, 24000)
    meta[ln["id"]] = {"file": f"vo/{ln['id']}.wav", "seconds": round(len(wav) / 24000, 3), "text": ln["text"]}
    print(f"{ln['id']:>9}  {len(wav) / 24000:6.2f}s  {ln['text'][:70]}")
meta_path.parent.mkdir(parents=True, exist_ok=True)
meta_path.write_text(json.dumps(meta, indent=1))
print("total", round(sum(m["seconds"] for m in meta.values()), 1), "s")
