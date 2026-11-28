# pgsmith launch video

Every shot comes from the running demo stack: the Flagsmith UI takes are real screen recordings, and the terminals
replay what the commands actually printed. Remotion assembles the cut from code.

| Path | What |
|---|---|
| `script/vo.json` | the narration, one line per scene (captions use this text) |
| `capture/term.py` | runs a command against the stack and saves its real output → `src/data/term/*.json` |
| `capture/shoot-ui.mjs` | drives the local Flagsmith UI in headless Chrome and records takes → `public/ui/*.mp4` |
| `capture/watch.py` | polls Postgres during the flag-flip take (the 0.76 s measurement) |
| `tts/gen_drama3.py` | **narration used in the video**: Fish Audio Drama 3 (research licence) served by vLLM-Omni 0.33 on the local GPU; voice cloned from the Breeze-designed narrator clip; best of 4 takes per sentence → `public/vo/*.wav`, `src/data/vo.json` |
| `tts/gen_breeze.py` | Breeze TTS 2 (research / non-commercial licence): designs the narrator voice from a description (`design`) and can voice the whole script (`full`) |
| `tts/gen_ming.py` | earlier narration with Ming-3.0-tts-0.5b (MIT) |
| `tts/judge.py`, `tts/eval_voices.py` | take selection and scoring: Whisper base.en word error rate + DNSMOS quality |
| `music/score.py` | an original music bed, synthesised and timed to the edit → `public/music/bed.wav` |
| `src/` | the Remotion composition (`Launch`, 1920×1080, 30 fps) and the `Thumbnail` still |
| `probe.mjs` | renders every 3rd frame and reports any text that overlaps other text or a UI recording |
| `finish.sh` | final render: video and lossless audio separately, two-pass linear loudness to −14 LUFS, one AAC encode |

```bash
npx remotion studio src/index.ts        # preview and scrub
node probe.mjs 3                        # overlap check → out/overlaps.txt
./finish.sh                             # out/pgsmith-launch.mp4 + out/thumbnail.png
```

Regenerating the Drama 3 voice:

```bash
cd tts
uv venv .venv-vomni -p 3.12 && uv pip install --python .venv-vomni/bin/python --torch-backend=cu130 vllm==0.33.0 vllm-omni==0.33.0rc1
hf download fishaudio/drama-3 --local-dir models/drama-3          # 41.5 GB; needs ~80 GB of GPU memory at the default split
.venv-vomni/bin/vllm serve models/drama-3 --omni --port 8091      # vLLM 0.34 dropped the runner Drama 3's codec stage needs
.venv-breeze/bin/python gen_drama3.py full --tag drama3 --ref-line solution --ref-meta vo-breeze-male-upbeat
```

The judges need Whisper base.en in `tts/models/eval/whisper-base.en` (and `speechmos`, `jiwer`, `librosa`). The scene timings follow the narration, so a new voice re-times the
video. The experiment traffic is simulated, and the video says so on screen.
