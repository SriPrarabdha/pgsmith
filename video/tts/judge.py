"""Local judges for picking narration takes: Whisper base.en (did it say the words?) and DNSMOS (is it clean?)."""
import json, pathlib
import numpy as np, librosa, torch, jiwer
from speechmos import dnsmos
from transformers import WhisperForConditionalGeneration, WhisperProcessor
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

WD = pathlib.Path(__file__).resolve().parent / "models/eval/whisper-base.en"
_proc = WhisperProcessor.from_pretrained(WD)
_asr = WhisperForConditionalGeneration.from_pretrained(WD).to("cuda").eval()
_norm = EnglishTextNormalizer(json.loads((WD / "normalizer.json").read_text()) if (WD / "normalizer.json").exists() else {})
FIX = [("flag smith", "flagsmith"), ("flag-smith", "flagsmith"), ("pg smith", "pgsmith"), ("pgsmith", "pgsmith"),
       ("p g smith", "pgsmith"), ("flag shift", "flagshift"), ("replan", "re plan"), ("sinks", "syncs")]


def norm(t):
    t = _norm(t)
    for a, b in FIX:
        t = t.replace(a, b)
    return t


def transcribe(w, sr):
    w16 = librosa.resample(np.asarray(w, dtype=np.float32), orig_sr=sr, target_sr=16000)
    out = []
    for i in range(0, len(w16), 16000 * 28):
        f = _proc(w16[i:i + 16000 * 28], sampling_rate=16000, return_tensors="pt").input_features.to("cuda")
        with torch.no_grad():
            out.append(_proc.batch_decode(_asr.generate(f, max_new_tokens=220), skip_special_tokens=True)[0])
    return " ".join(out), w16


def score(w, sr, text):
    hyp, w16 = transcribe(w, sr)
    wer = jiwer.wer(norm(text.replace("P G smith", "pgsmith")), norm(hyp)) if text.strip() else 0.0
    d = dnsmos.run(w16, 16000, return_df=False)
    return {"wer": wer, "ovrl": d["ovrl_mos"], "p808": d["p808_mos"], "hyp": hyp}
