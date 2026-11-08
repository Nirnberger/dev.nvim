#!/usr/bin/env bash
# Install CI tools via `gh release download` (the github.com/.../releases/download URLs are flaky).
# Usage: scripts/ci-tools.sh [nvim-tag]   (needs GH_TOKEN; nvim-tag e.g. v0.12.0, stable, nightly)
# Installs tree-sitter, tectonic and ImageMagick 7 (+ghostscript) into ~/.local/bin, neovim into ~/nvim; adds them to $GITHUB_PATH.
# Linux also: kitty into ~/.local/kitty.app (+ xvfb/xauth/xkb libs via apt), sets INKMATH_REQUIRE_KITTY=1 in $GITHUB_ENV.
#        scripts/ci-tools.sh lint         installs only StyLua (Linux x86_64)
set -euo pipefail

NVIM_TAG="${1:-}"
BIN="$HOME/.local/bin"
TMP="$(mktemp -d)"
mkdir -p "$BIN"

verify() { # <sha256> <file>
  if command -v sha256sum >/dev/null; then echo "$1  $2" | sha256sum -c -
  else echo "$1  $2" | shasum -a 256 -c -; fi
}

if [ "$NVIM_TAG" = lint ]; then
  [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || { echo "lint: only Linux x86_64" >&2; exit 1; }
  SL_ZIP=stylua-linux-x86_64.zip
  gh release download v2.6.0 -R JohnnyMorganz/StyLua -p "$SL_ZIP" -D "$TMP"
  verify a485f72bbfa22e4642e77a84b5edc2611a5cab7477b34e2e709dd8f78e919895 "$TMP/$SL_ZIP"
  unzip -o -q "$TMP/$SL_ZIP" stylua -d "$BIN"
  chmod +x "$BIN/stylua"
  [ -z "${GITHUB_PATH:-}" ] || echo "$BIN" >> "$GITHUB_PATH"
  rm -rf "$TMP"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    NVIM_ASSET=nvim-linux-x86_64
    TS_ASSET=tree-sitter-linux-x64.gz
    TS_SHA=7ed56d152c52437397b9fcaa43cf341f49933cecc1ca291843f0d347c6e2cb3a
    TT_ASSET=tectonic-0.17.0-x86_64-unknown-linux-musl.tar.gz
    TT_SHA=8533d07f9ccbd7a65824b9e0459041bca34af1eb33daba48f59215593753a3b7
    ;;
  Darwin-arm64)
    NVIM_ASSET=nvim-macos-arm64
    TS_ASSET=tree-sitter-macos-arm64.gz
    TS_SHA=5a08b66e5713b0c69691611250b2191d07139647a3c6e39ba85954284b634d2d
    TT_ASSET=tectonic-0.17.0-aarch64-apple-darwin.tar.gz
    TT_SHA=a3f1cac7c5678f01661a92212f58480ae3b0634115d880dbc59e2953ded45667
    ;;
  *) echo "unsupported platform: $(uname -sm)" >&2; exit 1 ;;
esac

# tree-sitter
gh release download v0.27.2 -R tree-sitter/tree-sitter -p "$TS_ASSET" -D "$TMP"
verify "$TS_SHA" "$TMP/$TS_ASSET"
gunzip -c "$TMP/$TS_ASSET" > "$BIN/tree-sitter"
chmod +x "$BIN/tree-sitter"

# tectonic
gh release download tectonic@0.17.0 -R tectonic-typesetting/tectonic -p "$TT_ASSET" -D "$TMP"
verify "$TT_SHA" "$TMP/$TT_ASSET"
tar -xzf "$TMP/$TT_ASSET" -C "$BIN" tectonic

# neovim
if [ -n "$NVIM_TAG" ]; then
  gh release download "$NVIM_TAG" -R neovim/neovim -p "$NVIM_ASSET.tar.gz" -D "$TMP"
  rm -rf "$HOME/nvim"
  tar -xzf "$TMP/$NVIM_ASSET.tar.gz" -C "$TMP"
  mv "$TMP/$NVIM_ASSET" "$HOME/nvim"
  [ -z "${GITHUB_PATH:-}" ] || echo "$HOME/nvim/bin" >> "$GITHUB_PATH"
fi

# ImageMagick 7 (`magick`, needed by the tectonic backend) + ghostscript (PDF input)
if [ "$(uname -s)" = Darwin ]; then
  brew install imagemagick ghostscript tmux
else
  command -v gs >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y ghostscript; }
  IM=ImageMagick-7.1.2-35-gcc-x86_64.AppImage
  gh release download 7.1.2-35 -R ImageMagick/ImageMagick -p "$IM" -D "$TMP"
  verify f111044ed06b68cfb478df724c5a32d35145afa21073242f888d234a2f8cc002 "$TMP/$IM"
  rm -rf "$HOME/.local/opt/imagemagick"
  mkdir -p "$HOME/.local/opt/imagemagick"
  chmod +x "$TMP/$IM"
  # no FUSE on runners: extract instead of mounting
  (cd "$HOME/.local/opt/imagemagick" && "$TMP/$IM" --appimage-extract >/dev/null)
  printf '#!/bin/sh\nexec "$HOME/.local/opt/imagemagick/squashfs-root/AppRun" "$@"\n' > "$BIN/magick"
  chmod +x "$BIN/magick"

  # kitty under Xvfb for tests/test_kitty_real.lua (macOS: nothing installed, the test skips)
  pkgs=()
  command -v xvfb-run >/dev/null || pkgs+=(xvfb)
  command -v xauth >/dev/null || pkgs+=(xauth)
  command -v tmux >/dev/null || pkgs+=(tmux) # scripts/screenshots.sh kitty-tmux variant
  for p in libxcb-xkb1 libxkbcommon-x11-0 fonts-dejavu-core; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done
  if [ "${#pkgs[@]}" -gt 0 ]; then sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}"; fi
  KITTY=kitty-0.50.0-x86_64.txz
  gh release download v0.50.0 -R kovidgoyal/kitty -p "$KITTY" -D "$TMP"
  verify f04b11775574d6aabfb529b7e734cc0a7d7d12c7df9fb8ec1843e45420e514ee "$TMP/$KITTY"
  rm -rf "$HOME/.local/kitty.app"
  mkdir -p "$HOME/.local/kitty.app"
  tar -xJf "$TMP/$KITTY" -C "$HOME/.local/kitty.app"
  ln -sf "$HOME/.local/kitty.app/bin/kitty" "$HOME/.local/kitty.app/bin/kitten" "$BIN/"
  # the kitty test must run on Linux CI, never skip
  [ -z "${GITHUB_ENV:-}" ] || echo "INKMATH_REQUIRE_KITTY=1" >> "$GITHUB_ENV"
fi

[ -z "${GITHUB_PATH:-}" ] || echo "$BIN" >> "$GITHUB_PATH"
rm -rf "$TMP"
