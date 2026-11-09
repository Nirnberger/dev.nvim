#!/usr/bin/env bash
# Screenshots of inkmath in real terminals, for PR previews (CI job `screenshots`).
# Usage: scripts/screenshots.sh <outdir>
# Writes <outdir>/<sample>--<variant>.png for every dev/samples/* file and variant:
#   kitty       Neovim + inkmath directly in kitty
#   kitty-tmux  the same inside tmux (allow-passthrough on); skipped locally without tmux >= 3.3,
#               a failure when INKMATH_REQUIRE_TMUX=1 (CI)
# and the overlay backends in other real terminals (scripts/realterm.sh), only for the samples in
# INKMATH_SHOT_OVERLAY_SAMPLES (default: display.md inline.md, the PR comment stays narrow):
#   xterm-sixel      xterm -ti vt340, Sixel          foot-sixel       foot under sway headless, Sixel
#   wezterm-overlay  WezTerm, kitty graphics overlay  wezterm-iterm2   WezTerm, term.backend = "iterm2"
#   konsole-overlay  Konsole, kitty graphics overlay
#   A missing terminal skips its variants; INKMATH_REQUIRE_<TERM>=1 (CI) makes that a failure.
#   Ready file as for kitty, then every recorded paint must have drawn pixels
#   (scripts/realterm-check.lua) and two screen reads in a row must be identical.
# Linux only: kitty under Xvfb (xvfb-run), pixels read from Xvfb's framebuffer (-fbdir, XWD),
# cropped to the kitty window with ImageMagick (`magick`). Fixed kitty config (no user config),
# window size, font, colors; the cursor stays at line 1, column 1 and does not blink.
# No sleeps for rendering: the child Neovim writes a ready file once inkmath has settled
# (scripts/screenshots-init.lua); then the script waits until every image whose placeholders are
# on the kitty screen (`kitty @ get-text --ansi --add-wrap-markers`) has drawn pixels in its cells
# (scripts/screenshots-check.lua) and for two identical framebuffer reads in a row.
# A failed shot is retried once (::warning:: in GitHub Actions), a second failure exits 1.
# Env: INKMATH_SHOT_TIMEOUT (seconds per wait, default 60), INKMATH_SHOT_SAMPLES (space-separated
# file names in dev/samples, default all), INKMATH_SHOT_VARIANTS (space-separated, default all).
set -euo pipefail

out="${1:?usage: scripts/screenshots.sh <outdir>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
timeout_s="${INKMATH_SHOT_TIMEOUT:-60}"
draw_timeout_s=15
BG=1c1c1c # kitty background = habamax Normal bg (scripts/screenshots-init.lua)
cols=90
rows=44

die() { echo "screenshots: $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "Linux only (Xvfb)"
for exe in nvim node kitty xvfb-run magick jq; do
  command -v "$exe" >/dev/null || die "missing: $exe"
done
variants=(kitty)
tmux_ok=0
if command -v tmux >/dev/null; then
  v="$(tmux -V | sed -E 's/^tmux (next-)?([0-9]+)\.([0-9]+).*/\2 \3/')"
  read -r tmaj tmin <<<"$v"
  if [ "$tmaj" -gt 3 ] || { [ "$tmaj" -eq 3 ] && [ "$tmin" -ge 3 ]; }; then tmux_ok=1; fi
fi
if [ "$tmux_ok" = 1 ]; then
  variants+=(kitty-tmux)
elif [ "${INKMATH_REQUIRE_TMUX:-}" = 1 ]; then
  die "INKMATH_REQUIRE_TMUX=1 but no tmux >= 3.3 ($(tmux -V 2>/dev/null || echo missing))"
else
  echo "screenshots: no tmux >= 3.3, skipping variant kitty-tmux" >&2
fi
overlay_term() { # <variant>: terminal of an overlay variant (scripts/realterm.sh), empty for kitty ones
  case "$1" in
    xterm-sixel) echo xterm ;;
    foot-sixel) echo foot ;;
    wezterm-overlay | wezterm-iterm2) echo wezterm ;;
    konsole-overlay) echo konsole ;;
  esac
}
for v in xterm-sixel foot-sixel wezterm-overlay wezterm-iterm2 konsole-overlay; do
  t="$(overlay_term "$v")"
  if why="$(bash "$root/scripts/realterm.sh" need "$t")"; then
    variants+=("$v")
  else
    req="INKMATH_REQUIRE_${t^^}"
    [ "${!req:-}" != 1 ] || die "$req=1 but $t: $why"
    echo "screenshots: $t: $why, skipping variant $v" >&2
  fi
done
if [ -n "${INKMATH_SHOT_VARIANTS:-}" ]; then
  keep=()
  for v in "${variants[@]}"; do
    case " $INKMATH_SHOT_VARIANTS " in *" $v "*) keep+=("$v") ;; esac
  done
  variants=("${keep[@]}")
fi
overlay_samples="${INKMATH_SHOT_OVERLAY_SAMPLES:-display.md inline.md}"

# treesitter parsers (make deps) and worker modules
(cd "$root" && make -s deps >/dev/null)
[ -d "$root/worker/node_modules" ] || (cd "$root/worker" && npm ci --silent)

mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# tectonic (fallback for formulas MathJax rejects) keeps its bundle cache on the real path
export TECTONIC_CACHE_DIR="${TECTONIC_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/tectonic}"

cat >"$work/kitty.conf" <<EOF
font_family DejaVu Sans Mono
bold_font auto
italic_font auto
font_size 11
disable_ligatures always
linux_display_server x11
allow_remote_control socket-only
initial_window_width ${cols}c
initial_window_height ${rows}c
remember_window_size no
window_padding_width 0
placement_strategy top-left
hide_window_decorations yes
cursor_shape block
cursor_blink_interval 0
cursor_trail 0
shell_integration disabled
confirm_os_window_close 0
enable_audio_bell no
visual_bell_duration 0
update_check_interval 0
background #$BG
foreground #bcbcbc
EOF

cat >"$work/tmux.conf" <<'EOF'
set -g allow-passthrough on
set -g status off
set -g escape-time 0
set -g default-terminal tmux-256color
set -as terminal-features ',xterm-kitty:RGB'
EOF


# wait_for <what> <command...>: retry every 0.2 s until the command succeeds or the timeout hits
wait_for() {
  local what="$1" deadline=$((SECONDS + timeout_s))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "screenshots: timeout after ${timeout_s}s: $what" >&2; return 1; }
    sleep 0.2
  done
}

shoot() { # <sample file> <variant>
  local file="$1" variant="$2"
  local name d sock ready fb pid
  name="$(basename "${file%.*}")"
  d="$work/$name--$variant"
  mkdir -p "$d/fb" "$d/cache"
  sock="$d/kitty.sock"
  ready="$d/ready.json"
  fb="$d/fb/Xvfb_screen0"
  local -a cmd=(nvim --noplugin -u "$root/scripts/screenshots-init.lua" "dev/samples/$file")
  if [ "$variant" = kitty-tmux ]; then
    cmd=(tmux -u -S "$d/tmux.sock" -f "$work/tmux.conf" new-session "${cmd[*]}")
  fi

  (cd "$root" && exec env -u TMUX -u TMUX_PANE -u SSH_CONNECTION -u SSH_TTY \
    NVIM_APPNAME=inkmath-dev XDG_CACHE_HOME="$d/cache" INKMATH_ROOT="$root" INKMATH_SHOT_READY="$ready" \
    xvfb-run -a -s "-screen 0 1280x1024x24 -dpi 96 -br -nocursor -fbdir $d/fb" \
    kitty --config "$work/kitty.conf" --listen-on "unix:$sock" "${cmd[@]}") >"$d/kitty.log" 2>&1 &
  pid=$!

  rc() { kitty @ --to "unix:$sock" "$@" 2>/dev/null; }
  drawn() { # every image with placeholders on screen has pixels in its cells
    rc get-text --ansi --add-wrap-markers >"$d/screen" || return 1
    nvim --clean -l "$root/scripts/screenshots-check.lua" "$root" "$d/screen" "$fb" "$cw" "$ch" "$BG" >"$d/check" 2>&1
  }
  stable_fb() {
    [ -s "$fb" ] || return 1
    cp "$fb" "$d/fb.prev" 2>/dev/null || return 1
    sleep 0.3
    cmp -s "$fb" "$d/fb.prev"
  }
  fail() {
    echo "screenshots: $name ($variant): $1" >&2
    echo "--- kitty screen:" >&2
    rc get-text >&2 || echo "(kitty not reachable)" >&2
    echo "--- kitty log:" >&2
    tail -n 20 "$d/kitty.log" >&2
    stop
    return 1
  }
  stop() {
    [ "$variant" != kitty-tmux ] || tmux -S "$d/tmux.sock" kill-server 2>/dev/null || true
    rc close-window >/dev/null || true
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }

  wait_for "inkmath ready signal ($ready)" test -s "$ready" || {
    fail "inkmath did not finish rendering (every formula must fit in the ${cols}x${rows} window)"
    return 1
  }
  local info placed formulas cw ch
  info="$(cat "$ready")"
  placed="$(jq -r .placed <<<"$info")"
  formulas="$(jq -r .formulas <<<"$info")"
  cw="$(jq -r '.cell.w // empty' <<<"$info")"
  ch="$(jq -r '.cell.h // empty' <<<"$info")"
  [ -n "$cw" ] && [ -n "$ch" ] || { fail "inkmath found no cell size: $info"; return 1; }
  [ "$placed" -gt 0 ] || { fail "inkmath placed no image ($formulas formulas): $info"; return 1; }
  timeout_s=$draw_timeout_s wait_for "kitty draws the images" drawn || { fail "$(cat "$d/check")"; return 1; }
  wait_for "framebuffer settles" stable_fb || { fail "framebuffer kept changing"; return 1; }

  local png="$out/$name--$variant.png"
  magick "xwd:$fb" -crop "$((cols * cw))x$((rows * ch))+0+0" +repage -strip \
    -define png:compression-level=9 "$png" || { fail "magick could not convert the framebuffer"; return 1; }
  stop
  printf '%s: %d/%d formulas placed, %s\n' "$(basename "$png")" "$placed" "$formulas" "$(du -h "$png" | cut -f1)"
}

shoot_overlay() { # <sample file> <variant>: the variant's terminal via scripts/realterm.sh
  local file="$1" variant="$2"
  local name d ready scr pid t force=auto
  t="$(overlay_term "$variant")"
  [ "$variant" != wezterm-iterm2 ] || force=iterm2
  name="$(basename "${file%.*}")"
  d="$work/$name--$variant"
  rm -rf "$d"
  mkdir -p "$d/cache"
  ready="$d/ready.json"
  scr="$d/screen.ppm"

  (cd "$root" && exec env NVIM_APPNAME=inkmath-dev XDG_CACHE_HOME="$d/cache" INKMATH_ROOT="$root" \
    INKMATH_SHOT_READY="$ready" INKMATH_SHOT_BACKEND="$force" \
    setsid bash "$root/scripts/realterm.sh" run "$t" "$d" "$cols" "$rows" \
    "$(command -v nvim)" --noplugin -u "$root/scripts/screenshots-init.lua" "dev/samples/$file") >"$d/term.log" 2>&1 &
  pid=$!

  shot() { bash "$root/scripts/realterm.sh" shot "$t" "$d" "$1" 2>/dev/null; }
  drawn() {
    shot "$scr" || return 1
    nvim --clean -l "$root/scripts/realterm-check.lua" "$root" "$ready" "$scr" >"$d/check" 2>&1
  }
  stable() {
    shot "$scr" || return 1
    sleep 0.3
    shot "$d/screen2.ppm" || return 1
    cmp -s "$scr" "$d/screen2.ppm"
  }
  stop() {
    kill -TERM -- "-$pid" 2>/dev/null || true
    for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }
  fail() {
    echo "screenshots: $name ($variant): $1" >&2
    echo "--- child status: $(cat "$ready.status" 2>/dev/null || echo none)" >&2
    echo "--- inner command: $(cat "$d/inner.log" 2>/dev/null || echo running)" >&2
    echo "--- terminal log:" >&2
    tail -n 30 "$d/term.log" >&2
    stop
    return 1
  }

  wait_for "inkmath ready signal ($ready)" test -s "$ready" || {
    fail "inkmath did not finish rendering and painting"
    return 1
  }
  local info placed formulas cw ch backend
  info="$(cat "$ready")"
  placed="$(jq -r .placed <<<"$info")"
  formulas="$(jq -r .formulas <<<"$info")"
  backend="$(jq -r '.backend + " " + .mode' <<<"$info")"
  cw="$(jq -r '.cell.w // empty' <<<"$info")"
  ch="$(jq -r '.cell.h // empty' <<<"$info")"
  [ -n "$cw" ] && [ -n "$ch" ] || { fail "inkmath found no cell size: $info"; return 1; }
  [ "$placed" -gt 0 ] || { fail "inkmath placed no image ($formulas formulas): $info"; return 1; }
  timeout_s=$draw_timeout_s wait_for "$t draws the images" drawn || { fail "$(cat "$d/check")"; return 1; }
  wait_for "screen settles" stable || { fail "screen kept changing"; return 1; }

  local png="$out/$name--$variant.png"
  magick "$scr" -crop "$((cols * cw))x$((rows * ch))+0+0" +repage -strip \
    -define png:compression-level=9 "$png" || { fail "magick could not convert the screen"; return 1; }
  stop
  printf '%s: %d/%d formulas placed, backend %s, %s\n' "$(basename "$png")" "$placed" "$formulas" "$backend" \
    "$(du -h "$png" | cut -f1)"
}

samples="${INKMATH_SHOT_SAMPLES:-$(cd "$root/dev/samples" && ls)}"
for f in $samples; do
  [ -f "$root/dev/samples/$f" ] || die "no such sample: $f"
  for v in "${variants[@]}"; do
    if [ -n "$(overlay_term "$v")" ]; then
      case " $overlay_samples " in *" $f "*) ;; *) continue ;; esac
      shoot_overlay "$f" "$v" || {
        echo "${GITHUB_ACTIONS:+::warning::}screenshots: $f ($v) failed, retrying once" >&2
        shoot_overlay "$f" "$v" || {
          # konsole: known failure (window chrome, see KNOWN in tests/test_terminals_real.lua): no shot, no failure
          [ "$v" = konsole-overlay ] && { echo "${GITHUB_ACTIONS:+::warning::}screenshots: $f ($v) skipped (known failure)" >&2; continue; }
          die "$f ($v) failed twice"
        }
      }
      continue
    fi
    # one retry: a lost image (placeholders drawn blank) has been seen once and never reproduced
    shoot "$f" "$v" || {
      echo "${GITHUB_ACTIONS:+::warning::}screenshots: $f ($v) failed, retrying once" >&2
      shoot "$f" "$v" || die "$f ($v) failed twice"
    }
  done
done
