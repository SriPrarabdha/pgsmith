"""Score narration variants without listening: DNSMOS (P.835 SIG/BAK/OVRL + P.808) for audio quality, and
Whisper base.en word error rate against the script for intelligibility (dropped, garbled or added words).

    .venv-ming/bin/python eval_voices.py vo-us-emma vo-uk-george vo vo-kokoro
"""
import json, pathlib, sys
import numpy as np, librosa, torch, jiwer
from speechmos import dnsmos
from transformers import WhisperForConditionalGeneration, WhisperProcessor
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

HERE = pathlib.Path(__file__).resolve().parent
PUB, DATA = HERE.parent / "public", HERE.parent / "src/data"
wdir = HERE / "models/eval/whisper-base.en"
proc = WhisperProcessor.from_pretrained(wdir)
asr = WhisperForConditionalGeneration.from_pretrained(wdir).to("cuda").eval()
norm = EnglishTextNormalizer(json.loads((wdir / "normalizer.json").read_text()) if (wdir / "normalizer.json").exists() else {})


def transcribe(w16):
    out = []
    for i in range(0, len(w16), 16000 * 28):  # whisper windows are 30 s
        feats = proc(w16[i:i + 16000 * 28], sampling_rate=16000, return_tensors="pt").input_features.to("cuda")
        with torch.no_grad():
            ids = asr.generate(feats, max_new_tokens=220)
        out.append(proc.batch_decode(ids, skip_special_tokens=True)[0])
    return " ".join(out)


rows = {}
for tag in sys.argv[1:]:
    meta_file = DATA / ("vo.json" if tag == "vo" else f"{tag}.json")
    meta = json.loads(meta_file.read_text())
    sig = bak = ovr = p808 = 0.0; errs = words = 0; secs = chars = 0; worst = []
    for lid, m in meta.items():
        f = PUB / tag / pathlib.Path(m["file"]).name   # the variant's own folder
        w, sr = librosa.load(f, sr=16000, mono=True)
        d = dnsmos.run(w, 16000, return_df=False)
        sig += d["sig_mos"]; bak += d["bak_mos"]; ovr += d["ovrl_mos"]; p808 += d["p808_mos"]
        hyp = transcribe(w)
        ref_n, hyp_n = norm(m["text"].replace("P G smith", "pgsmith")), norm(hyp.replace("PG Smith", "pgsmith").replace("PGSmith", "pgsmith").replace("PG smith", "pgsmith"))
        wer = jiwer.wer(ref_n, hyp_n)
        n = len(ref_n.split()); errs += wer * n; words += n
        secs += m["seconds"]; chars += len(m["text"])
        worst.append((wer, lid, hyp))
    k = len(meta)
    worst.sort(reverse=True)
    rows[tag] = dict(SIG=sig / k, BAK=bak / k, OVRL=ovr / k, P808=p808 / k, WER=errs / words, cps=chars / secs, total=secs, worst=worst[:3])
for tag, r in rows.items():
    print(f"{tag:14} OVRL {r['OVRL']:.2f}  SIG {r['SIG']:.2f}  BAK {r['BAK']:.2f}  P808 {r['P808']:.2f}  WER {r['WER'] * 100:5.1f}%  {r['cps']:.1f} chars/s  {r['total']:.0f}s")
    for wer, lid, hyp in r["worst"]:
        print(f"     {wer * 100:5.1f}% {lid}: {hyp[:150]}")
