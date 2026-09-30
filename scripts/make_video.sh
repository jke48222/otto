#!/usr/bin/env bash
#
# make_video.sh — cut Otto's promo film, its poster and the README loop from the raw stage footage.
#
#   scripts/make_video.sh                         # raw footage from build/media-raw
#   scripts/make_video.sh --raw-dir /path/to/raw  # e.g. wherever make_media.sh --raw-dir wrote it
#   scripts/make_video.sh --crf 21                # the film's x264 CRF (default 20)
#   scripts/make_video.sh --web-crf 26            # the site's renditions' CRF (default 24, 26 if over budget)
#   scripts/make_video.sh --gif-fps 20            # the README loop's frame rate (default 22)
#   scripts/make_video.sh --web-only              # only re-derive the site's renditions from the film
#   scripts/make_video.sh --end-card launch       # the end card points at the site's trial and price
#
# Inputs (recorded by scripts/make_media.sh):
#   <raw>/{story,act,shelf-voice,settings}.mov + .json   the film's 3072×1728 60 fps masters and
#                                                         their timelines
#   <raw>/hero.mov + .json                    the README loop's master
#   <raw>/poster-stage.png                    the poster's plate (make_media.sh stills)
#   docs/media/icon.png                       app icon for the title/end cards and the poster
#
# Outputs:
#   The three .mp4 files stay out of git (.gitignore); scripts/upload_film.sh <version> puts them in the
#   downloads Blob store, and the README and site link to film/<version>/ there.
#   docs/media/otto-promo.mp4         1920×1080, ~52 s (the cut follows the takes' marks), 30 fps CFR,
#                                     H.264 High yuv420p BT.709, AAC 48 kHz stereo at -16 LUFS,
#                                     +faststart, ≤ 25 MB
#   docs/media/otto-promo-poster.jpg  1920×1080 poster frame
#   docs/media/otto-promo-web.mp4     the website's copy: 1920×1080 H.264, --web-crf, no audio track, ≤ 8 MB
#   docs/media/otto-promo-web-720.mp4 the website's copy for narrow screens: 1280×720, no audio, ≤ 3.5 MB
#   docs/media/otto-hero.gif          1280×1000, 22 fps, ~15.8 s seamless loop, UI at 1:1 with the
#                                     2× master (body text ≈ 28 px), ≤ 8 MB
#
# The picture is composed by scripts/make_video.swift (Core Image + CoreText, piped to
# ffmpeg/libx264); the edit decision list — clips, camera keys, captions and cards — lives in that
# file under "The edit".
#
# Sound: the soundtrack is ORIGINAL and SYNTHESIZED. scripts/make_audio.py generates every sample
# with numpy (additive pad voices, a sine sub, bell-like arpeggio notes, filtered-noise UI ticks and
# a synthetic noise reverb): no samples, loops, stock or third-party music. It follows the edit's
# sound cues (clicks, the notch opening and closing, the drops, the sends, the listening pill, the
# Settings window) and fits its tempo to the cut, so it resolves exactly as the end card starts,
# fading in over the title card's first 0.5 s and out over the end card's last 1.5 s. It is
# then loudness-normalized (two-pass loudnorm, -16 LUFS) and muxed.
#
# The website plays the film muted, so it gets its own silent, lighter renditions (the film itself,
# with its soundtrack, is what the README links to). They are encoded from the silent picture, or with
# --web-only from the film's picture track; site/index.html picks the 720p one below 800 px.
#
# The GIF is a 1:1 crop of the hero take, rendered by make_video.swift (with the film's collapse, the
# reply preview's real 4 s, and the unread dot's ear retracting into the notch at the end so the last
# frame is the first frame: a loop reset, not product behavior),
# then a temporal denoise (so codec noise in the still wallpaper doesn't bloat every frame), ordered
# dithering and a light gifsicle pass. Requires ffmpeg and gifsicle (brew install ffmpeg gifsicle)
# and python3 with numpy.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="$ROOT/build/media-raw"
MEDIA="$ROOT/docs/media"
FPS=30
CRF=20
WEB_CRF=24
GIF_FPS=22
WEB_ONLY=0
END_CARD=source
FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-dir) RAW="$2"; shift ;;
    --fps) FPS="$2"; shift ;;
    --crf) CRF="$2"; shift ;;
    --web-crf) WEB_CRF="$2"; shift ;;
    --gif-fps) GIF_FPS="$2"; shift ;;
    --web-only) WEB_ONLY=1 ;;
    --end-card) END_CARD="$2"; shift ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;p;}' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -x "$FFMPEG" ]] || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

check() { # file max_bytes
  local size; size=$(stat -f %z "$1" 2>/dev/null || stat -c %s "$1")
  printf '  %-26s %6.1f MB' "$(basename "$1")" "$(python3 -c "print($size/1e6)")"
  if (( size > $2 )); then echo "  OVER BUDGET ($(python3 -c "print($2/1e6)") MB)"; exit 1; else echo; fi
}

# The site's renditions: video only (-an), +faststart, H.264 High so every browser plays them. Each
# is encoded at --web-crf; one that comes out over its budget is encoded again at the fallback CRF
# (26 by default), which the budget check then holds it to.
WEB_FALLBACK_CRF=26
encode_rendition() { # source output max_bytes [scale filter]
  local crf="$WEB_CRF" vf=()
  [[ -n "${4:-}" ]] && vf=(-vf "$4")
  while true; do
    "$FFMPEG" -v error -y -i "$1" -map 0:v:0 "${vf[@]}" -an -c:v libx264 -preset slow -crf "$crf" \
      -profile:v high -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
      -movflags +faststart "$2"
    local size; size=$(stat -f %z "$2" 2>/dev/null || stat -c %s "$2")
    if (( size <= $3 )) || (( crf >= WEB_FALLBACK_CRF )); then break; fi
    echo "  $(basename "$2") is over budget at CRF $crf; encoding it again at CRF $WEB_FALLBACK_CRF"
    crf=$WEB_FALLBACK_CRF
  done
  echo "  $(basename "$2"): CRF $crf"
}
encode_web() { # source
  encode_rendition "$1" "$MEDIA/otto-promo-web.mp4" 8000000
  encode_rendition "$1" "$MEDIA/otto-promo-web-720.mp4" 3500000 "scale=1280:720:flags=lanczos"
}
check_web() {
  check "$MEDIA/otto-promo-web.mp4" 8000000
  check "$MEDIA/otto-promo-web-720.mp4" 3500000
}

if [[ $WEB_ONLY == 1 ]]; then
  [[ -f "$MEDIA/otto-promo.mp4" ]] || { echo "error: missing $MEDIA/otto-promo.mp4; run without --web-only first" >&2; exit 1; }
  echo "==> Encoding the site's renditions from the film"
  encode_web "$MEDIA/otto-promo.mp4"
  echo "==> Checking budgets"
  check_web
  echo "==> Done"
  exit 0
fi

for clip in story act shelf-voice settings hero; do
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
  --fps "$FPS" --crf "$CRF" --gif-fps "$GIF_FPS" \
  --out "$WORK/picture.mp4" --poster "$MEDIA/otto-promo-poster.jpg" --cues "$WORK/cues.json" \
  --gif "$WORK/hero.mkv" --end-card "$END_CARD"

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

echo "==> Encoding the site's renditions"
encode_web "$WORK/picture.mp4"

echo "==> Quantizing the README loop"
# hero.mkv is lossless (ffv1) from make_video.swift. The temporal denoise only touches pixels that
# barely change (codec noise in the still wallpaper); one palette for the whole loop, ordered
# dithering (position-dependent, so identical frames quantize identically: the seam stays exact).
# The denoise is temporal, so the held seam frames at the end are replaced by the loop's (denoised)
# first frame again after it.
FRAMES=$("${FFMPEG%ffmpeg}ffprobe" -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames -of csv=p=0 "$WORK/hero.mkv")
# The held seam: 0.2 s of frames, as make_video.swift writes them.
HOLD=$(python3 -c "print(int($GIF_FPS * 0.2 + 0.5))")
"$FFMPEG" -v error -y -i "$WORK/hero.mkv" -filter_complex "
  [0:v]format=rgb24,hqdn3d=0:0:4:4,split[d1][d2];
  [d1]trim=end_frame=$((FRAMES - HOLD)),setpts=PTS-STARTPTS[body];
  [d2]trim=end_frame=1,loop=loop=$((HOLD - 1)):size=1:start=0,setpts=N/$GIF_FPS/TB[tail];
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
check "$MEDIA/otto-promo.mp4" 25000000
check_web
check "$MEDIA/otto-hero.gif" 8000000
check "$MEDIA/otto-promo-poster.jpg" 2000000
echo "==> Done"
