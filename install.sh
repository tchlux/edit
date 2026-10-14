#!/bin/sh
# Build and replace the current user's macOS app; leave no source checkout.
set -eu

if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install
  printf 'Finish installing Command Line Tools, then run this command again.\n'
  exit 1
fi

src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
git clone --depth 1 https://github.com/tchlux/edit.git "$src"
cd "$src"
sh build.sh
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Edit.app"
ditto Edit.app "$HOME/Applications/Edit.app"
open "$HOME/Applications/Edit.app"
