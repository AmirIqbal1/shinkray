#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_DIR="$(mktemp -d)"
INPUT_FILE="${TEMP_DIR}/synthetic-input.mkv"
OUTPUT_FILE="${TEMP_DIR}/synthetic-output.mkv"

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

command -v ffmpeg >/dev/null 2>&1 || {
  printf 'smoke test: ffmpeg is required\n' >&2
  exit 1
}
command -v ffprobe >/dev/null 2>&1 || {
  printf 'smoke test: ffprobe is required\n' >&2
  exit 1
}

printf 'Generating a short synthetic input video...\n'
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=320x240:rate=24:duration=3" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=3" \
  -map 0:v:0 -map 1:a:0 \
  -c:v mpeg4 -q:v 2 -c:a pcm_s16le \
  "$INPUT_FILE"

printf 'Running shrinkray...\n'
bash "${ROOT_DIR}/shrinkray" "$INPUT_FILE" \
  --size 1 --quality fast --output "$OUTPUT_FILE" -y

[ -s "$OUTPUT_FILE" ] || {
  printf 'smoke test: shrinkray did not create a non-empty output\n' >&2
  exit 1
}
[ ! -e "${OUTPUT_FILE}.part" ] || {
  printf 'smoke test: temporary .part output was not cleaned up\n' >&2
  exit 1
}

STREAM_TYPE="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_type -of csv=p=0 "$OUTPUT_FILE")"
[ "$STREAM_TYPE" = "video" ] || {
  printf 'smoke test: ffprobe did not find a valid video stream\n' >&2
  exit 1
}

printf 'Smoke test passed.\n'
