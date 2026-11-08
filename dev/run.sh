#!/usr/bin/env bash
# Usage: dev/run.sh [file] [--tmux]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
file=""
tmux_mode=0
for a in "$@"; do
  if [ "$a" = "--tmux" ]; then tmux_mode=1; else file="$a"; fi
done
file="${file:-dev/samples/document.tex}"
cmd="cd '$root' && NVIM_APPNAME=inkmath-dev nvim -u dev/init.lua '$file'"
if [ "$tmux_mode" = 1 ]; then
  tmux -L inkmath -f /dev/null new-session -d
  tmux -L inkmath set -g allow-passthrough on
  tmux -L inkmath set -as terminal-features ',*:RGB'
  tmux -L inkmath send-keys "$cmd" Enter
  tmux -L inkmath attach
else
  cd "$root"
  NVIM_APPNAME=inkmath-dev nvim -u dev/init.lua "$file"
fi
