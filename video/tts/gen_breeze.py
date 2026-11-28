"""Voice-over with Breeze TTS 2 (BreezeBlue; weights under a research / non-commercial licence).

    .venv-breeze/bin/python gen_breeze.py design [--voice male|female]    # make the narrator reference clip
    .venv-breeze/bin/python gen_breeze.py full [--voice male] [--tag x]   # every line, in that voice

1. design: Breeze creates a voice from a description (no reference audio). Several candidates are generated
   and the one Whisper understands best and DNSMOS rates cleanest becomes public/vo-ref/<voice>.wav.
2. full: every sentence is spoken in the reference voice with a delivery instruction ("voice direction"),
   best of TAKES takes, chosen the same way. Output: public/vo/*.wav and src/data/vo.json (scene timings).
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

import numpy as np
import soundfile as sf
import torch

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "breeze-tts"))
from breeze_infer.runtime import load_runtime, resolve_device, set_all_seeds, update_generation_config_for_breeze  # noqa: E402
from breeze_infer.templates import get_template, prepare_inputs, select_template_name  # noqa: E402
from models.fast_streaming import FastBreezeStreamingRuntime, FastStreamingConfig  # noqa: E402

import judge  # noqa: E402

MODEL = HERE / "models/breeze-tts-2"
LINES = json.loads((HERE.parent / "script/vo.json").read_text())
VOICES = {
    "male": "A natural, warm American man in his early thirties, a software engineer presenting a project he built "
            "and is proud of. Relaxed and conversational, genuinely enthusiastic, clear diction, natural pauses and "
            "varied intonation. Real and human, not an announcer, not robotic.",
    "female": "A natural, warm American woman in her early thirties, a software engineer presenting a project she built "
              "and is proud of. Relaxed and conversational, genuinely enthusiastic, clear diction, natural pauses and "
              "varied intonation. Real and human, not an announcer, not robotic.",
}
DIRECTION = ("Speak naturally at an upbeat pace, a little quicker than normal conversation, like a real engineer "
             "demoing something exciting they built: warm and confident, with natural rhythm and emphasis. Not an announcer.")
DESIGN_TEXT = ("I spent the last few weeks building something I'm really excited about. It lets your database "
               "read feature flags directly, and honestly, it changed how I ship.")
SAY = {"Flagsmith": "Flag-smith", "Postgres": "Post-gres", "Supabase": "Soopa-base"}
SR = 24000
TAKES = int(sys.argv[sys.argv.index("--takes") + 1]) if "--takes" in sys.argv else 4

_rt = None


def runtime():
    global _rt
    if _rt is None:
        tok, model, at = load_runtime(MODEL, device=resolve_device(), attn_implementation="eager")
        update_generation_config_for_breeze(model)
        cfg = FastStreamingConfig(max_new_tokens=1500, max_seq_len=2048, repetition_penalty=1.1)
        _rt = (tok, model, at, FastBreezeStreamingRuntime(model, at, cfg, tokenizer=tok))
    return _rt


def generate(text, instruction=None, ref=None, seed=42, cfg=4.0):
    tok, model, at, rt = runtime()
    req = {"id": "r", "text": text, "speaker": "S0"}
    if instruction:
        req["instruction"] = instruction
    if ref:
        req["ref_audio_path"], req["ref_text"] = str(ref[0]), ref[1]
    set_all_seeds(seed)
    inputs = prepare_inputs(tok, at, model, [req], get_template(select_template_name(req)),
                            guidance_scale=cfg, guidance_scale_ref=None, guidance_scale_ins=None)
    chunks = [c.audio for c in rt.iter_audio_chunks(inputs, request_id="r", seed=seed)]
    return trim(np.concatenate(chunks).astype(np.float32).reshape(-1))


def trim(w):
    idx = np.where(np.abs(w) > 10 ** (-50 / 20))[0]
    return w[max(0, idx[0] - int(0.05 * SR)): idx[-1] + int(0.08 * SR)] if len(idx) else w


def best(text_shown, make, k=TAKES):
    """k takes; keep the one Whisper hears most accurately, then the cleanest by DNSMOS"""
    top = None
    for i in range(k):
        w = make(1000 + i)
        s = judge.score(w, SR, text_shown)
        key = (round(s["wer"], 3), -s["ovrl"])
        if top is None or key < top[0]:
            top = (key, w, s)
        if s["wer"] == 0 and s["ovrl"] > 3.4:
            break
    return top[1], top[2]


def spoken(t):
    for a, b in SAY.items():
        t = t.replace(a, b)
    return t


def sentences(text):
    return [p for p in re.split(r"(?<=[.?!])\s+(?=[A-Z])", text.strip()) if p]


def main():
    mode = sys.argv[1]
    voice = sys.argv[sys.argv.index("--voice") + 1] if "--voice" in sys.argv else "male"
    refdir = HERE.parent / "public/vo-ref"
    refdir.mkdir(parents=True, exist_ok=True)
    ref_wav = refdir / f"{voice}.wav"
    if mode == "design":
        w, s = best(DESIGN_TEXT, lambda seed: generate(DESIGN_TEXT, instruction=VOICES[voice], seed=seed), k=6)
        sf.write(ref_wav, w, SR)
        print(f"reference {ref_wav}: {len(w) / SR:.1f}s  WER {s['wer']:.2f}  OVRL {s['ovrl']:.2f}  heard: {s['hyp']}")
        return
    tag = sys.argv[sys.argv.index("--tag") + 1] if "--tag" in sys.argv else ""
    out = HERE.parent / ("public/vo" + (f"-{tag}" if tag else ""))
    out.mkdir(parents=True, exist_ok=True)
    meta_path = HERE.parent / ("src/data/vo" + (f"-{tag}" if tag else "") + ".json")
    only = set(sys.argv[sys.argv.index("--only") + 1].split(",")) if "--only" in sys.argv else None
    ref = (ref_wav, DESIGN_TEXT)
    meta = json.loads(meta_path.read_text()) if (only and meta_path.exists()) else {}
    log = []
    for ln in LINES:
        if only and ln["id"] not in only:
            continue
        parts = []
        for j, sent in enumerate(sentences(ln["text"])):
            w, s = best(sent, lambda seed: generate(spoken(sent), instruction=DIRECTION, ref=ref, seed=seed))
            log.append({"line": ln["id"], "sentence": sent, "wer": s["wer"], "ovrl": round(s["ovrl"], 2), "heard": s["hyp"]})
            parts.append(w)
            if j < len(sentences(ln["text"])) - 1:
                parts.append(np.zeros(int((0.24 if sent.endswith((".", "!")) else 0.32) * SR), dtype=np.float32))
        wav = np.concatenate(parts)
        sf.write(out / f"{ln['id']}.wav", wav, SR)
        meta[ln["id"]] = {"file": f"{out.name}/{ln['id']}.wav", "seconds": round(len(wav) / SR, 3), "text": ln["text"]}
        print(f"{ln['id']:>9} {len(wav) / SR:6.2f}s", flush=True)
    meta_path.write_text(json.dumps(meta, indent=1))
    (out / "_takes.json").write_text(json.dumps(log, indent=1))
    bad = [x for x in log if x["wer"] > 0]
    print("total", round(sum(v["seconds"] for v in meta.values()), 1), "s;", len(bad), "of", len(log), "sentences not word-perfect")


if __name__ == "__main__":
    main()
