#!/usr/bin/env bash
#
# make_media.sh — regenerate Otto's marketing media from the real app, end to end.
#
#   scripts/make_media.sh                  # stills + raw footage
#   scripts/make_media.sh --stills-only
#   scripts/make_media.sh --footage-only [--scenes "story act shelf-voice settings hero"]
#   scripts/make_media.sh --raw-dir /path/to/raw
#
# Stills (rendered off screen, no permissions needed) go straight into docs/media:
#   docs/media/screens/{ask,context,answer,actions,glance,settings,shelf,voice,recents}.png
#                                                                2080×1300 RGB, quantized (≤ 700 KB)
#   docs/media/social-preview.png                                1280×640 RGB (< 1 MB)
#   docs/media/icon.png                                          512×512
#   <raw>/poster-stage.png                                       3072×1728, the poster's plate (make_video.sh)
#
# The screens are squeezed with pngquant + oxipng when installed (brew install pngquant oxipng), and
# the run fails if a screen ends up over 700 KB or the social preview over 1 MB.
#
# Raw footage goes to --raw-dir (default: build/media-raw), one clip per scene. The film needs
# story, act, shelf-voice and settings. The README loop needs hero. The default records all five.
# Closed, hover-open, context, screenshot, draft and glance are extra takes. Footage is recorded
# from a Release build, which keeps every frame on time:
#   <scene>.mov        master, 3072×1728 (the 1536×864 pt stage at 2×), 60 fps CFR, H.264
#   <scene>.json       timeline sidecar: scene start + key moments in movie time
#   <scene>-1080p.mp4  1920×1080 60 fps H.264 (yuv420p, BT.709, +faststart) proxy for editing
#   manifest.json      every clip, its duration and its key timestamps
#
# Footage is recorded with ScreenCaptureKit from a stage window that sits *behind the desktop*,
# so the screen is never taken over. The shell running this needs Screen Recording permission
# (System Settings → Privacy & Security → Screen & System Audio Recording). Requires ffmpeg for
# the 1080p proxies (brew install ffmpeg).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto"
RELEASE_BINARY="$ROOT/build/Build/Products/Release/Otto.app/Contents/MacOS/Otto"
RECORDER="$ROOT/build/record_promo"
MEDIA="$ROOT/docs/media"
RAW="$ROOT/build/media-raw"
SCENES="story act shelf-voice settings hero"
DO_STILLS=1
DO_FOOTAGE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stills-only) DO_FOOTAGE=0 ;;
    --footage-only) DO_STILLS=0 ;;
    --raw-dir) RAW="$2"; shift ;;
    --scenes) SCENES="$2"; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

"$ROOT/scripts/build.sh"

if [[ "$DO_STILLS" == "1" ]]; then
  echo "==> Rendering stills"
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  "$BINARY" --promo-stills "$STAGING" >/dev/null
  mkdir -p "$MEDIA/screens"
  if command -v pngquant >/dev/null 2>&1; then
    for png in "$STAGING"/screens/*.png; do
      pngquant --force --skip-if-larger --quality 80-96 --speed 1 --output "$png" -- "$png" || true
    done
  fi
  if command -v oxipng >/dev/null 2>&1; then
    oxipng --quiet -o 4 --strip safe "$STAGING"/screens/*.png "$STAGING/social-preview.png"
  fi
  over=0
  for png in "$STAGING"/screens/*.png; do
    bytes=$(stat -f %z "$png")
    if (( bytes > 700 * 1024 )); then
      echo "error: $(basename "$png") is $((bytes / 1024)) KB, over the 700 KB budget" >&2
      over=1
    fi
  done
  bytes=$(stat -f %z "$STAGING/social-preview.png")
  if (( bytes >= 1024 * 1024 )); then
    echo "error: social-preview.png is $((bytes / 1024)) KB, over the 1 MB budget" >&2
    over=1
  fi
  [[ "$over" == "0" ]] || exit 1
  cp "$STAGING"/screens/*.png "$MEDIA/screens/"
  cp "$STAGING/social-preview.png" "$STAGING/icon.png" "$MEDIA/"
  mkdir -p "$RAW"
  cp "$STAGING/poster-stage.png" "$RAW/"
  echo "==> Stills written to $MEDIA"
fi

if [[ "$DO_FOOTAGE" == "1" ]]; then
  echo "==> Building Otto (Release + OTTO_TOOLS) for recording"
  # Shipping Release builds leave out the promo stage (Otto/Debug is DEBUG-only); OTTO_TOOLS puts
  # it back for this optimized recording build.
  xcodebuild -project "$ROOT/Otto.xcodeproj" -scheme Otto -configuration Release \
    -derivedDataPath "$ROOT/build" -destination 'platform=macOS,arch=arm64' -quiet build \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=OTTO_TOOLS
  echo "==> Building the recorder"
  swiftc -O -suppress-warnings -o "$RECORDER" "$ROOT/scripts/record_promo.swift"
  mkdir -p "$RAW"
  for scene in $SCENES; do
    echo "==> Recording $scene"
    "$RECORDER" --app "$RELEASE_BINARY" --scene "$scene" --out "$RAW/$scene.mov"
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -v error -y -i "$RAW/$scene.mov" \
        -vf "scale=1920:1080:flags=lanczos" -r 60 \
        -c:v libx264 -preset slow -crf 14 -pix_fmt yuv420p \
        -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
        -movflags +faststart "$RAW/$scene-1080p.mp4"
    fi
  done

  echo "==> Writing $RAW/manifest.json"
  python3 - "$RAW" $SCENES <<'PY'
import json, os, sys
raw, scenes = sys.argv[1], sys.argv[2:]
clips = []
for scene in scenes:
    path = os.path.join(raw, scene + ".json")
    if not os.path.exists(path):
        continue
    with open(path) as handle:
        clip = json.load(handle)
    clip["master"] = scene + ".mov"
    clip.pop("file", None)
    proxy = scene + "-1080p.mp4"
    if os.path.exists(os.path.join(raw, proxy)):
        clip["proxy1080p"] = proxy
    clips.append(clip)
manifest = {
    "description": "Raw footage of Otto's promo stage: the real notch UI (NotchRootView + NotchViewModel + ChatSession, scripted replies) on a stylized MacBook display. Times are seconds in each clip. 'sceneStart' is when the choreography begins (earlier frames are a still pre-roll handle); 'marks' are key moments.",
    "stage": {"points": [1536, 864], "masterPixels": [3072, 1728], "proxyPixels": [1920, 1080], "fps": 60},
    "notchInMaster": {"topCenterPx": [1536, 90], "closedSizePx": [380, 64], "openPanelWidthPx": 1080},
    "clips": clips,
}
with open(os.path.join(raw, "manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2, ensure_ascii=False)
PY
  echo "==> Footage written to $RAW"
fi
