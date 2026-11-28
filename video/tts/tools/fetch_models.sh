#!/usr/bin/env bash
# Breeze TTS 2 first (7.7 GB), then Fish Audio Drama 3 (41.5 GB). Resumable: completed parts are remembered.
set -u
cd "$(dirname "$0")/../models"
set -a; . /home/prarabdha/work/hack/.env; set +a
export HF_TOKEN=${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACE_TOKEN:-}}}
P=../tools/pget.py
fetch_repo() {  # repo dir files...
  local repo=$1 dir=$2; shift 2
  mkdir -p "$dir"
  for f in "$@"; do
    mkdir -p "$dir/$(dirname "$f")"
    until python3 $P "https://huggingface.co/$repo/resolve/main/$f" "$dir/$f" 4; do sleep 10; done
    echo "$(date +%H:%M) $repo $f" >> fetch.log
  done
}
small() {  # repo dir files... (small files, plain curl)
  local repo=$1 dir=$2; shift 2
  for f in "$@"; do mkdir -p "$dir/$(dirname "$f")"; until curl -sfL -H "Authorization: Bearer $HF_TOKEN" -o "$dir/$f" "https://huggingface.co/$repo/resolve/main/$f"; do sleep 5; done; done
}
small BreezeBlue/breeze-tts-2 breeze-tts-2 config.json generation_config.json model.safetensors.index.json special_tokens_map.json \
  tokenizer.json tokenizer_config.json audio_tokenizer/config.json audio_tokenizer/configuration.json audio_tokenizer/preprocessor_config.json LICENSE README.md
fetch_repo BreezeBlue/breeze-tts-2 breeze-tts-2 audio_tokenizer/model.safetensors model-00002-of-00002.safetensors model-00001-of-00002.safetensors
echo "$(date +%H:%M) BREEZE DONE" >> fetch.log
