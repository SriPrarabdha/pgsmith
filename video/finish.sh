#!/usr/bin/env bash
# Final render. Video and audio are rendered separately; the audio stays lossless until one final AAC encode,
# after a two-pass *linear* loudness normalisation to -14 LUFS (one fixed gain, no pumping).
set -euo pipefail
cd "$(dirname "$0")"
node scenes-json.mjs
tts/.venv/bin/python music/score.py music/scenes.json public/music/bed.wav
npx remotion render src/index.ts Launch out/video.noaudio.mp4 --codec h264 --crf 16 --muted --concurrency 16 --log error
npx remotion render src/index.ts Launch out/mix.wav --codec wav --log error
M=$(ffmpeg -hide_banner -i out/mix.wav -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
get() { echo "$M" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
AF="loudnorm=I=-14:TP=-1.5:LRA=11:linear=true:measured_I=$(get input_i):measured_TP=$(get input_tp):measured_LRA=$(get input_lra):measured_thresh=$(get input_thresh):offset=$(get target_offset)"
ffmpeg -y -loglevel error -i out/video.noaudio.mp4 -i out/mix.wav -map 0:v -map 1:a -c:v copy -af "$AF" -ar 48000 -c:a aac -b:a 256k -movflags +faststart -shortest out/pgsmith-launch.mp4
npx remotion still src/index.ts Thumbnail out/thumbnail.png --log error
ffprobe -v error -show_entries format=duration,size -of default=nw=1 out/pgsmith-launch.mp4
ffmpeg -hide_banner -i out/pgsmith-launch.mp4 -vn -af ebur128=peak=true -f null - 2>&1 | grep -E "^\s+(I|LRA|Peak):" | head -3
