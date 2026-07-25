#!/usr/bin/env bash

set -euo pipefail

ZIP="$(find incoming -maxdepth 1 -type f -name 'Voxtr-changed-files*.zip' -printf '%T@ %p\n' \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-)"

TEMP_DIR="/tmp/voxtr-update"

if [[ -z "$ZIP" ]]; then
  echo "Fant ingen Voxtr-changed-files ZIP i incoming/"
  exit 1
fi

if [[ ! -f "$ZIP" ]]; then
  echo "ZIP-filen finnes ikke: $ZIP"
  exit 1
fi

echo "Bruker ZIP:"
echo "  $ZIP"
echo

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

echo "Pakker ut..."
unzip "$ZIP" -d "$TEMP_DIR"

echo
echo "Filer i leveransen:"
find "$TEMP_DIR" -maxdepth 6 -type f | sort

echo
read -r -p "Kopiere disse filene inn i prosjektet? [y/N] " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Avbrutt. Ingen filer ble kopiert."
  exit 0
fi

echo
echo "Kopierer filer..."
rsync -av "$TEMP_DIR/" ./

echo
echo "Git status:"
git status

echo
echo "Diff-statistikk:"
git diff --stat

echo
echo "Whitespace-sjekk:"
git diff --check

echo
echo "Import fullført."
