#!/usr/bin/env bash
# Fish Audio Drama 3 (41.5 GB): waits for Breeze, then fetches 4 shards at a time, 6 connections each. Resumable.
set -u
cd "$(dirname "$0")/../models"
set -a; . /home/prarabdha/work/hack/.env; set +a
export HF_TOKEN=${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACE_TOKEN:-}}}
until grep -q "BREEZE DONE" fetch.log 2>/dev/null; do sleep 10; done
D=drama-3; mkdir -p $D
for f in $(cat "$1"); do mkdir -p "$D/$(dirname "$f")"; until curl -sfL -H "Authorization: Bearer $HF_TOKEN" -o "$D/$f" "https://huggingface.co/fishaudio/drama-3/resolve/main/$f"; do sleep 5; done; done
cat "$2" | xargs -P 4 -I{} bash -c 'mkdir -p "'$D'/$(dirname {})"; until python3 ../tools/pget.py "https://huggingface.co/fishaudio/drama-3/resolve/main/{}" "'$D'/{}" 6; do sleep 10; done; echo "$(date +%H:%M) drama-3 {}" >> fetch.log'
echo "$(date +%H:%M) DRAMA3 DONE" >> fetch.log
