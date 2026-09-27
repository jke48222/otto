#!/usr/bin/env bash
#
# make_video.sh — cut Otto's promo film, its poster and the README loop from the raw stage footage.
#
#   scripts/make_video.sh                         # raw footage from build/media-raw
#   scripts/make_video.sh --raw-dir /path/to/raw  # e.g. wherever make_media.sh --raw-dir wrote it
#   scripts/make_video.sh --crf 20                # lighter film
#
# Inputs (recorded by scripts/make_media.sh):
#   <raw>/{story,settings,hero}.mov + .json   3072×1728 60 fps masters and their timelines
#   <raw>/poster-stage.png                    the poster's plate (make_media.sh stills)
#   docs/media/icon.png                       app icon for the title/end cards and the poster
#
# Outputs:
#   docs/media/otto-promo.mp4         1920×1080, ~40 s (the cut follows the takes' marks), 30 fps CFR,
#                                     H.264 High yuv420p BT.709, AAC 48 kHz stereo at -16 LUFS,
#                                     +faststart, ≤ 25 MB
#   docs/media/otto-promo-poster.jpg  1920×1080 poster frame
#   docs/media/otto-hero.gif          1280×1000, 25 fps, 13.6 s seamless loop, UI at 1:1 with the
#                                     2× master (body text ≈ 28 px), ≤ 8 MB
#
# The picture is composed by scripts/make_video.swift (Core Image + CoreText, piped to
# ffmpeg/libx264); the edit decision list — clips, camera keys, captions and cards — lives in that
# file under "The edit".
#
# Sound: the soundtrack is ORIGINAL and SYNTHESIZED. scripts/make_audio.py generates every sample
# with numpy (additive pad voices, a sine sub, bell-like arpeggio notes, filtered-noise UI ticks and
# a synthetic noise reverb): no samples, loops, stock or third-party music. It follows the edit's
# sound cues (clicks, the notch opening and closing, the Settings window) and resolves under the end
# card, fading in over the title card's first 0.5 s and out over the end card's last 1.5 s. It is
# then loudness-normalized (two-pass loudnorm, -16 LUFS) and muxed.
#
# The GIF is a 1:1 crop of the hero take, rendered by make_video.swift (with the film's collapse, and
# the unread dot's ear retracting into the notch at the end so the last frame is the first frame),
# then a temporal denoise (so codec noise in the still wallpaper doesn't bloat every frame), ordered
# dithering and a light gifsicle pass. Requires ffmpeg and gifsicle (brew install ffmpeg gifsicle)
# and python3 with numpy.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="$ROOT/build/media-raw"
MEDIA="$ROOT/docs/media"
FPS=30
CRF=18
FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-dir) RAW="$2"; shift ;;
    --fps) FPS="$2"; shift ;;
    --crf) CRF="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -x "$FFMPEG" ]] || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }
for clip in story settings hero; do
  [[ -f "$RAW/$clip.mov" && -f "$RAW/$clip.json" ]] || { echo "error: missing $RAW/$clip.mov/.json — run scripts/make_media.sh --footage-only first" >&2; exit 1; }
done
[[ -f "$RAW/poster-stage.png" ]] || { echo "error: missing $RAW/poster-stage.png — run scripts/make_media.sh --stills-only --raw-dir $RAW" >&2; exit 1; }
mkdir -p "$ROOT/build" "$MEDIA"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building the renderer"
swiftc -O -suppress-warnings -o "$ROOT/build/make_video" "$ROOT/scripts/make_video.swift"

echo "==> Rendering the picture, the poster and the sound cues"
"$ROOT/build/make_video" \
  --raw "$RAW" --icon "$MEDIA/icon.png" --ffmpeg "$FFMPEG" \
  --fps "$FPS" --crf "$CRF" \
  --out "$WORK/picture.mp4" --poster "$MEDIA/otto-promo-poster.jpg" --cues "$WORK/cues.json" \
  --gif "$WORK/hero.mkv"

echo "==> Scoring the soundtrack"
python3 "$ROOT/scripts/make_audio.py" --cues "$WORK/cues.json" --out "$WORK/score.wav"
# Two-pass loudnorm to -16 LUFS integrated (linear, so the mix itself is untouched).
MEASURED="$("$FFMPEG" -hide_banner -nostats -i "$WORK/score.wav" \
  -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')"
read -r MI MTP MLRA MTH OFF < <(python3 -c '
import json, sys
m = json.loads(sys.stdin.read())
print(m["input_i"], m["input_tp"], m["input_lra"], m["input_thresh"], m["target_offset"])' <<<"$MEASURED")

echo "==> Muxing"
"$FFMPEG" -v error -y -i "$WORK/picture.mp4" -i "$WORK/score.wav" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=$MI:measured_TP=$MTP:measured_LRA=$MLRA:measured_thresh=$MTH:offset=$OFF:linear=true,aresample=48000" \
  -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 160k -ar 48000 -ac 2 -shortest \
  -movflags +faststart "$MEDIA/otto-promo.mp4"

echo "==> Quantizing the README loop"
# hero.mkv is lossless (ffv1) from make_video.swift. The temporal denoise only touches pixels that
# barely change (codec noise in the still wallpaper); one palette for the whole loop, ordered
# dithering (position-dependent, so identical frames quantize identically: the seam stays exact).
# The denoise is temporal, so the held seam frames at the end are replaced by the loop's (denoised)
# first frame again after it.
FRAMES=$("${FFMPEG%ffmpeg}ffprobe" -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames -of csv=p=0 "$WORK/hero.mkv")
HOLD=5
"$FFMPEG" -v error -y -i "$WORK/hero.mkv" -filter_complex "
  [0:v]format=rgb24,hqdn3d=0:0:4:4,split[d1][d2];
  [d1]trim=end_frame=$((FRAMES - HOLD)),setpts=PTS-STARTPTS[body];
  [d2]trim=end_frame=1,loop=loop=$((HOLD - 1)):size=1:start=0,setpts=N/25/TB[tail];
  [body][tail]concat=n=2:v=1:a=0,split[a][b];
  [a]palettegen=max_colors=192:stats_mode=full[p];
  [b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  -loop 0 "$WORK/hero.gif"
# gifsicle's lossy LZW pass (--lossy=35) is what brings the 1:1 loop under 8 MB; the text stays clean
# (it mostly perturbs noisy wallpaper pixels). Lossy LZW encodes the last frame as a lossy
# difference, so it is then swapped for a copy of the (already lossy) first frame, with the held
# seam's delay: the loop's last frame is pixel-identical to its first. brew install gifsicle.
if command -v gifsicle >/dev/null 2>&1; then
  gifsicle -O3 --lossy=35 "$WORK/hero.gif" -o "$WORK/lossy.gif"
  N=$(gifsicle --info "$WORK/lossy.gif" | grep -c "+ image")
  HOLD_CS=$(gifsicle --info "$WORK/lossy.gif" | grep -o "delay [0-9.]*s" | tail -1 | tr -dc '0-9')
  gifsicle --unoptimize "$WORK/lossy.gif" "#0" -o "$WORK/first.gif"
  gifsicle "$WORK/lossy.gif" --delete "#$((N - 1))" -o "$WORK/body.gif"
  gifsicle --merge "$WORK/body.gif" "$WORK/first.gif" -o "$WORK/merged.gif"
  gifsicle "$WORK/merged.gif" "#0-$((N - 2))" --delay="$((10#$HOLD_CS))" "#$((N - 1))" -o "$MEDIA/otto-hero.gif"
else
  echo "warning: gifsicle not found (brew install gifsicle); the GIF may exceed 8 MB" >&2
  cp "$WORK/hero.gif" "$MEDIA/otto-hero.gif"
fi
echo "==> Checking budgets"
check() { # file max_bytes
  local size; size=$(stat -f %z "$1" 2>/dev/null || stat -c %s "$1")
  printf '  %-26s %6.1f MB' "$(basename "$1")" "$(python3 -c "print($size/1e6)")"
  if (( size > $2 )); then echo "  OVER BUDGET ($(python3 -c "print($2/1e6)") MB)"; exit 1; else echo; fi
}
check "$MEDIA/otto-promo.mp4" 25000000
check "$MEDIA/otto-hero.gif" 8000000
check "$MEDIA/otto-promo-poster.jpg" 2000000
echo "==> Done"
