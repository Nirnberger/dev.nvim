#!/usr/bin/env bash
# Install CI tools via `gh release download` (the github.com/.../releases/download URLs are flaky).
# Usage: scripts/ci-tools.sh [nvim-tag]   (needs GH_TOKEN; nvim-tag e.g. v0.11.4, stable, nightly)
# Installs tree-sitter, tectonic and ImageMagick 7 (+ghostscript) into ~/.local/bin, neovim into ~/nvim; adds them to $GITHUB_PATH.
set -euo pipefail

NVIM_TAG="${1:-}"
BIN="$HOME/.local/bin"
TMP="$(mktemp -d)"
mkdir -p "$BIN"

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

verify() { # <sha256> <file>
  if command -v sha256sum >/dev/null; then echo "$1  $2" | sha256sum -c -
  else echo "$1  $2" | shasum -a 256 -c -; fi
}

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
  brew install imagemagick ghostscript
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
fi

[ -z "${GITHUB_PATH:-}" ] || echo "$BIN" >> "$GITHUB_PATH"
rm -rf "$TMP"
