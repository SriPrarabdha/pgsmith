"""Voice-over with Ming-3.0-tts-0.5b (MIT, local GPU).

    .venv-ming/bin/python gen_ming.py samples                 # one line in several voices -> ../public/vo-samples/ming-*.wav
    .venv-ming/bin/python gen_ming.py full --voice design     # the whole script -> ../public/vo/*.wav + ../src/data/vo.json

Voices: ip:US_Emma, ip:UK_George, ip:UK_Charlotte, freeform, design. For freeform/design the first line is
generated from the description and then used as the reference clip for every other line, so the voice stays
the same across the video.
"""
import json
import pathlib
import sys

import numpy as np
import soundfile as sf
import torch

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "ming-tts"))
from ming_tts import MingTTS  # noqa: E402

LINES = json.loads((HERE.parent / "script/vo.json").read_text())
FREEFORM = ("Speak like a confident, energetic narrator of a developer-tool launch video: crisp and upbeat, "
            "clear articulation, a brisk but unhurried pace, a hint of excitement on the reveals.")
DESIGN = ("A confident American male narrator in his thirties for a tech product launch video. Warm, energetic, "
          "crisp diction, upbeat and modern, like a polished developer keynote.")


def load():
    return MingTTS(str(HERE / "models/Ming-3.0-tts-0.5b"), device="cuda:0", text_normalization=False)


def synth_one(m, voice, text, ref=None):
    # one sentence per call, sent whole: Ming truncates very long inputs, and splitting a sentence
    # into fragments breaks its intonation
    kw = dict(text=text, language_id="English", max_length=400)
    if ref is not None:
        return m.synthesize(task="TTS", prompt_wav_path=ref[0], prompt_text=ref[1], use_spk_emb=True, **kw)
    if voice.startswith("ip:"):
        return m.synthesize(task="IP", controls={"ip": voice[3:]}, use_zero_spk_emb=True, **kw)
    if voice == "freeform":
        return m.synthesize(task="FREEFORM", instruction=FREEFORM, use_zero_spk_emb=True, **kw)
    if voice == "design":
        return m.synthesize(task="VOICE_DESIGN", controls={"style": DESIGN}, use_zero_spk_emb=True, **kw)
    raise SystemExit(f"unknown voice {voice}")


def sentences(text):
    import re
    parts = re.split(r"(?<=[.?!])\s+(?=[A-Z])", text.strip())
    return [p for p in parts if p]


TAKES = 4
LOG = []


def best_take(m, voice, spoken, shown, ref, sr):
    """generate TAKES takes of one sentence; keep the one Whisper hears most accurately, then the cleanest"""
    import judge
    best = None
    for k in range(TAKES):
        torch.manual_seed(1000 + k)
        w = trim(to_np(synth_one(m, voice, spoken, ref)), sr)
        s = judge.score(w, sr, shown)
        key = (round(s["wer"], 3), -s["ovrl"])
        if best is None or key < best[0]:
            best = (key, w, s)
        if s["wer"] == 0 and s["ovrl"] > 3.4:
            break
    LOG.append({"sentence": shown, "wer": best[2]["wer"], "ovrl": round(best[2]["ovrl"], 2), "heard": best[2]["hyp"]})
    return best[1]


SAY = {"Flagsmith": "Flag-smith"}  # spoken spelling (Whisper-checked); captions keep the real one


def synth(m, voice, text, ref=None, sr=24000):
    """a whole line: each sentence synthesised on its own, joined with natural pauses"""
    out = []
    for i, shown in enumerate(sentences(text)):
        spoken = shown
        for a, b in SAY.items():
            spoken = spoken.replace(a, b)
        w = best_take(m, voice, spoken, shown, ref, sr)
        out.append(w)
        if i < len(sentences(text)) - 1:
            gap = 0.34 if shown.endswith((".", "!")) else 0.42
            out.append(np.zeros(int(gap * sr), dtype=w.dtype))
    return np.concatenate(out)


def to_np(w):
    if isinstance(w, torch.Tensor):
        w = w.detach().float().cpu().numpy()
    return np.asarray(w).reshape(-1)


def trim(w, sr):
    thr = 10 ** (-50 / 20)
    idx = np.where(np.abs(w) > thr)[0]
    return w[max(0, idx[0] - int(0.06 * sr)): idx[-1] + int(0.06 * sr)] if len(idx) else w


def main():
    mode = sys.argv[1]
    voice = sys.argv[sys.argv.index("--voice") + 1] if "--voice" in sys.argv else "design"
    m = load()
    sr = m.sample_rate
    if mode == "samples":
        out = HERE.parent / "public/vo-samples"
        out.mkdir(parents=True, exist_ok=True)
        text = next(l["text"] for l in LINES if l["id"] == "solution")
        for v in ["ip:US_Emma", "ip:UK_George", "freeform", "design"]:
            torch.manual_seed(7)
            w = trim(synth(m, v, text, sr=sr), sr)
            f = out / f"ming-{v.replace(':', '-')}.wav"
            sf.write(f, w, sr)
            print(f, f"{len(w) / sr:.2f}s")
        return
    # full script
    tag = sys.argv[sys.argv.index("--tag") + 1] if "--tag" in sys.argv else ""
    out = HERE.parent / ("public/vo" + (f"-{tag}" if tag else ""))
    out.mkdir(parents=True, exist_ok=True)
    meta_path = HERE.parent / ("src/data/vo" + (f"-{tag}" if tag else "") + ".json")
    meta = {}
    ref = None
    only = set(sys.argv[sys.argv.index("--only") + 1].split(",")) if "--only" in sys.argv else None
    for i, ln in enumerate(LINES):
        torch.manual_seed(7)
        if voice in ("freeform", "design") and ref is None:
            # make the reference from a neutral first line, then clone it for every line
            w0 = trim(synth(m, voice, LINES[3]["text"], sr=sr), sr)
            sf.write(out / "_reference.wav", w0, sr)
            ref = (str(out / "_reference.wav"), LINES[3]["text"])
        if only and ln["id"] not in only:
            continue
        w = trim(synth(m, voice, ln["text"], ref, sr=sr), sr)
        f = out / f"{ln['id']}.wav"
        sf.write(f, w, sr)
        meta[ln["id"]] = {"file": f"{out.name}/{ln['id']}.wav", "seconds": round(len(w) / sr, 3), "text": ln["text"]}
        print(f"{ln['id']:>9} {len(w) / sr:6.2f}s")
    if only and meta_path.exists():
        old = json.loads(meta_path.read_text())
        old.update(meta)
        meta = old
    meta_path.write_text(json.dumps(meta, indent=1))
    (out / "_takes.json").write_text(json.dumps(LOG, indent=1))
    print("total", round(sum(v["seconds"] for v in meta.values()), 1), "s")


if __name__ == "__main__":
    main()
