#!/usr/bin/env bash
# Real terminals for the overlay backends, shared by tests/test_terminals_real.lua and scripts/screenshots.sh.
# Linux only. Every terminal gets a fixed config (no user config), DejaVu Sans Mono 11, background
# #1c1c1c, no padding/border/scrollbar, window at the screen's top left corner.
#   realterm.sh need <term>                       exit 1 and print what is missing
#   realterm.sh run <term> <dir> <cols> <rows> <cmd>...
#        runs <cmd> in the terminal on a private display (Xvfb, or sway headless for foot), in the
#        foreground until the terminal exits. <dir>: fresh, private working dir. Start it in its
#        own process group (setsid) and stop it by killing the group.
#   realterm.sh shot <term> <dir> <out.ppm>       the whole screen as binary PPM (P6)
#   realterm.sh text <term> <dir>                 the screen text (WezTerm only; else exit 2)
# <term>: xterm (Sixel, -ti vt340), foot (Sixel, Wayland), wezterm (kitty graphics + OSC 1337),
#         konsole (kitty graphics).
set -euo pipefail

die() { echo "realterm: $*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || die "Linux only"
sub="${1:?usage: realterm.sh need|run|shot|text <term> ...}"
term="${2:?missing terminal}"
BG=1c1c1c
FG=bcbcbc

# WezTerm: the official AppImage, extracted by scripts/ci-tools.sh (no FUSE on runners)
wezterm_bin() {
  if command -v wezterm >/dev/null; then command -v wezterm
  elif [ -x "$HOME/.local/opt/wezterm/squashfs-root/usr/bin/wezterm" ]; then echo "$HOME/.local/opt/wezterm/squashfs-root/usr/bin/wezterm"
  else return 1; fi
}

tools() { # <term>: executables it needs
  case "$1" in
    xterm) echo "xterm xvfb-run magick" ;;
    foot) echo "foot sway grim" ;;
    wezterm) echo "xvfb-run magick jq" ;;
    konsole) echo "konsole xvfb-run magick" ;;
    *) die "unknown terminal: $1" ;;
  esac
}

need() {
  local missing=()
  for exe in $(tools "$term"); do command -v "$exe" >/dev/null || missing+=("$exe"); done
  if [ "$term" = wezterm ]; then
    wezterm_bin >/dev/null || missing+=(wezterm)
    # the AppImage dlopens libEGL even with front_end = "Software"
    { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null || true; } | grep -q 'libEGL\.so\.1' || missing+=(libEGL.so.1)
  fi
  [ "${#missing[@]}" -eq 0 ] || { echo "missing: ${missing[*]}"; exit 1; }
}

xvfb() { # <dir> <cmd>...: on a private Xvfb whose framebuffer is <dir>/fb/Xvfb_screen0
  local d="$1"
  shift
  mkdir -p "$d/fb"
  exec xvfb-run -a -s "-screen 0 1280x1024x24 -dpi 96 -br -nocursor -fbdir $d/fb" "$@"
}

run() {
  local d="$1" cols="$2" rows="$3"
  shift 3
  mkdir -p "$d/home/.config" "$d/home/.local/share" "$d/run"
  chmod 700 "$d/run"
  # the command inside gets the caller's XDG dirs back (Neovim finds its parsers there)
  local -a keep=(env) sets=()
  for v in XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR; do
    # env takes options (-u) only before the first NAME=VALUE: unsets first
    if [ -n "${!v+x}" ]; then sets+=("$v=${!v}"); else keep+=(-u "$v"); fi
  done
  # the inner command's exit status lands in <dir>/inner.log (diagnostics: a terminal that ends at once)
  # (127: not found, then also the PATH it saw)
  set -- sh -c '"$@"; rc=$?; echo "inner command exited with $rc" >>"$0"
    [ "$rc" != 127 ] || echo "PATH inside the terminal: $PATH" >>"$0"' "$d/inner.log" "${keep[@]}" "${sets[@]}" "$@"
  # the terminal gets nothing from the outer session: no user config, no inherited terminal identity
  export XDG_CONFIG_HOME="$d/home/.config" XDG_DATA_HOME="$d/home/.local/share" XDG_RUNTIME_DIR="$d/run"
  unset TERM_PROGRAM TERM_PROGRAM_VERSION LC_TERMINAL KONSOLE_VERSION WEZTERM_PANE WEZTERM_UNIX_SOCKET \
    KITTY_WINDOW_ID TMUX TMUX_PANE SSH_CONNECTION SSH_TTY WAYLAND_DISPLAY DISPLAY WT_SESSION
  case "$term" in
    xterm)
      xvfb "$d" xterm -ti vt340 -xrm 'XTerm*numColorRegisters: 1024' -xrm 'XTerm*maxGraphicSize: 2048x2048' \
        -xrm 'XTerm*cursorBlink: false' -xrm 'XTerm*internalBorder: 0' -fa 'DejaVu Sans Mono' -fs 11 \
        -geometry "${cols}x${rows}+0+0" -bw 0 +sb -bg "#$BG" -fg "#$FG" -e "$@"
      ;;
    wezterm)
      cat >"$d/wezterm.lua" <<EOF
local wezterm = require("wezterm")
return {
  front_end = "Software",
  enable_kitty_graphics = true,
  font = wezterm.font("DejaVu Sans Mono"),
  font_size = 11,
  dpi = 96,
  initial_cols = $cols,
  initial_rows = $rows,
  window_padding = { left = 0, right = 0, top = 0, bottom = 0 },
  enable_tab_bar = false,
  window_decorations = "NONE",
  check_for_updates = false,
  audible_bell = "Disabled",
  default_cursor_style = "SteadyBlock",
  warn_about_missing_glyphs = false,
  colors = { background = "#$BG", foreground = "#$FG" },
}
EOF
      xvfb "$d" "$(wezterm_bin)" --config-file "$d/wezterm.lua" start --always-new-process --cwd "$PWD" -- "$@"
      ;;
    konsole)
      local k="$XDG_DATA_HOME/konsole"
      mkdir -p "$k"
      cat >"$k/inkmath.colorscheme" <<EOF
[Background]
Color=28,28,28
[BackgroundIntense]
Color=28,28,28
[Foreground]
Color=188,188,188
[ForegroundIntense]
Color=188,188,188
[General]
Description=inkmath
Opacity=1
EOF
      cat >"$k/inkmath.profile" <<EOF
[Appearance]
ColorScheme=inkmath
Font=DejaVu Sans Mono,11,-1,5,50,0,0,0,0,0
[Cursor Options]
CursorShape=0
[General]
Name=inkmath
Parent=FALLBACK/
TerminalColumns=$cols
TerminalRows=$rows
TerminalMargin=0
TerminalCenter=false
[Scrolling]
ScrollBarPosition=2
[Terminal Features]
BlinkingCursorEnabled=false
EOF
      printf '[Desktop Entry]\nDefaultProfile=inkmath.profile\n[KonsoleWindow]\nRememberWindowSize=false\n[MainWindow]\nMenuBar=Disabled\nToolBarsMovable=Disabled\n[TabBar]\nTabBarVisibility=AlwaysHideTabBar\n' \
        >"$XDG_CONFIG_HOME/konsolerc"
      export QT_QPA_PLATFORM=xcb QT_QUICK_BACKEND=software LIBGL_ALWAYS_SOFTWARE=1
      local -a k_cmd=(konsole --nofork --hide-menubar --hide-tabbar --profile inkmath.profile -e "$@")
      if command -v dbus-run-session >/dev/null; then k_cmd=(dbus-run-session -- "${k_cmd[@]}"); fi
      xvfb "$d" "${k_cmd[@]}"
      ;;
    foot)
      cat >"$d/sway.conf" <<EOF
output HEADLESS-1 resolution 1280x1024 position 0 0 bg #$BG solid_color
default_border none
default_floating_border none
focus_follows_mouse no
for_window [app_id="inkmath"] floating enable, move position 0 0
EOF
      cat >"$d/foot.ini" <<EOF
font=DejaVu Sans Mono:size=11
dpi-aware=no
pad=0x0
[cursor]
style=block
blink=no
[colors]
background=$BG
foreground=$FG
EOF
      WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
        sway -c "$d/sway.conf" >"$d/sway.log" 2>&1 &
      local sway=$!
      local sock=""
      for _ in $(seq 100); do
        sock="$(cd "$XDG_RUNTIME_DIR" && ls wayland-[0-9] 2>/dev/null | head -n 1 || true)"
        [ -z "$sock" ] || break
        kill -0 "$sway" 2>/dev/null || { cat "$d/sway.log" >&2; die "sway exited"; }
        sleep 0.1
      done
      [ -n "$sock" ] || { cat "$d/sway.log" >&2; die "sway made no Wayland socket"; }
      echo "$sock" >"$d/wayland-display"
      local rc=0
      WAYLAND_DISPLAY="$sock" foot -c "$d/foot.ini" --app-id=inkmath --window-size-chars="${cols}x${rows}" "$@" || rc=$?
      kill "$sway" 2>/dev/null || true
      exit "$rc"
      ;;
    *) die "unknown terminal: $term" ;;
  esac
}

shot() {
  local d="$1" out="$2"
  case "$term" in
    foot)
      [ -s "$d/wayland-display" ] || return 1
      XDG_RUNTIME_DIR="$d/run" WAYLAND_DISPLAY="$(cat "$d/wayland-display")" grim -t ppm "$out.tmp"
      ;;
    *)
      [ -s "$d/fb/Xvfb_screen0" ] || return 1
      magick "xwd:$d/fb/Xvfb_screen0" -depth 8 "ppm:$out.tmp" 2>/dev/null
      ;;
  esac
  mv "$out.tmp" "$out"
}

text() {
  local d="$1" sock
  [ "$term" = wezterm ] || exit 2
  sock="$(ls "$d"/run/wezterm/gui-sock-* 2>/dev/null | head -n 1)"
  [ -n "$sock" ] || return 1
  # without $WEZTERM_PANE get-text needs the pane id
  local -a cli=(env XDG_RUNTIME_DIR="$d/run" WEZTERM_UNIX_SOCKET="$sock" "$(wezterm_bin)" cli --no-auto-start)
  local pane
  pane="$("${cli[@]}" list --format json | jq -r '.[0].pane_id // empty')"
  [ -n "$pane" ] || { echo "realterm: wezterm cli list shows no pane" >&2; return 1; }
  "${cli[@]}" get-text --pane-id "$pane"
}

case "$sub" in
  need) need ;;
  run) run "${@:3}" ;;
  shot) shot "${@:3}" ;;
  text) text "${@:3}" ;;
  *) die "unknown subcommand: $sub" ;;
esac
