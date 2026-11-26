# pgsmith launch video

Every shot comes from the running demo stack: the Flagsmith UI takes are real screen recordings, and the terminals
replay what the commands actually printed. Remotion assembles the cut from code.

| Path | What |
|---|---|
| `script/vo.json` | the narration, one line per scene (captions use this text) |
| `capture/term.py` | runs a command against the stack and saves its real output → `src/data/term/*.json` |
| `capture/shoot-ui.mjs` | drives the local Flagsmith UI in headless Chrome and records takes → `public/ui/*.mp4` |
| `capture/watch.py` | polls Postgres during the flag-flip take (the 0.76 s measurement) |
| `tts/gen_ming.py` | narration with Ming-3.0-tts-0.5b (MIT), built-in voice `US_Emma`, one sentence per generation, best of 4 takes per sentence → `public/vo/*.wav`, `src/data/vo.json` |
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

Regenerating the voice needs the Ming weights in `tts/models/Ming-3.0-tts-0.5b`, the Ming code in `tts/ming-tts`
(commit in `tts/patches/ming-tts.COMMIT`, plus `tts/patches/ming-istft-float32.patch` for torch ≥ 2.14) and Whisper
base.en in `tts/models/eval/whisper-base.en`. The scene timings follow the narration, so a new voice re-times the
video. The experiment traffic is simulated, and the video says so on screen.
