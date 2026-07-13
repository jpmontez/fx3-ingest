#!/usr/bin/env bash
# =============================================================================
# fx3_ingest.sh — Sony FX3 media ingest script
#
# Usage:
#   ./fx3_ingest.sh <source_dir> <destination_dir>
#
# Example:
#   ./fx3_ingest.sh /Volumes/SDCARD/PRIVATE/M4ROOT/CLIP /Volumes/MyDrive/Projects/Shoot_Name/Footage
#
# Folder structure produced:
#   <destination>/2026-07-12/C0001.MP4
#                            C0001.MP4.sha256
#                            C0001M01.XML
#                            C0001M01.XML.sha256
#
# Requires: exiftool (brew install exiftool), shasum (built into macOS)
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

# ── Arguments ─────────────────────────────────────────────────────────────────
if [ "$#" -ne 2 ]; then
  echo -e "${CYAN}Usage:${NC} $0 <source_dir> <destination_dir>"
  echo -e "  source_dir       SD card clip folder (e.g. /Volumes/SDCARD/PRIVATE/M4ROOT/CLIP)"
  echo -e "  destination_dir  Project footage root (e.g. /Volumes/MyDrive/Projects/Shoot/Footage)"
  exit 1
fi

SRC_DIR="${1%/}"   # strip trailing slash if present
DST_ROOT="${2%/}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if [ ! -d "$SRC_DIR" ]; then
  echo -e "${RED}Error:${NC} Source directory not found: $SRC_DIR"
  exit 1
fi

if ! command -v exiftool &>/dev/null; then
  echo -e "${RED}Error:${NC} exiftool not found. Install with: brew install exiftool"
  exit 1
fi

# ── Counters ──────────────────────────────────────────────────────────────────
count_copied=0
count_skipped=0
count_failed=0

# Remove a half-written staging file if the script is interrupted mid-copy
current_tmp=""
trap 'if [ -n "$current_tmp" ]; then rm -f "$current_tmp"; fi' EXIT

# ── Progress bar helpers ─────────────────────────────────────────────────────
# Percentage is tracked by bytes (not file count) since clip sizes vary
# wildly — a 268MB clip and a 7GB clip shouldn't move the bar equally.
human_size() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1fGB", b/1073741824;
    else if (b >= 1048576) printf "%.1fMB", b/1048576;
    else printf "%dB", b;
  }'
}

files_done=0
bytes_done=0

draw_progress() {
  local pct=0 width=30 filled empty bar
  if [ "$total_bytes" -gt 0 ]; then
    pct=$(( bytes_done * 100 / total_bytes ))
  fi
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  bar="$(printf "%${filled}s" | tr ' ' '#')$(printf "%${empty}s" | tr ' ' '-')"
  printf "\r\033[K${CYAN}[%s] %3d%%${NC} (%d/%d files, %s/%s)" \
    "$bar" "$pct" "$files_done" "$total_files" \
    "$(human_size "$bytes_done")" "$(human_size "$total_bytes")"
}

# Clears the in-place progress bar so a normal log line can print cleanly
# above it; callers are expected to redraw the bar right after.
log() {
  printf "\r\033[K"
  echo -e "$1"
}

# ── Copy + verify one file ───────────────────────────────────────────────────
# The source is read only once: tee copies it to a .part staging file while
# shasum hashes the same stream. The staged copy is re-read to verify, and
# only renamed into place once its hash matches — the destination never
# holds an unverified file. Updates the copied/skipped/failed counters.
ingest_file() {
  local src="$1" dst_dir="$2" rel="$3"
  local name dst sha tmp stored_hash src_hash dst_hash
  name=$(basename "$src")
  dst="$dst_dir/$name"
  sha="${dst}.sha256"

  # Skip if already verified
  if [ -f "$dst" ] && [ -f "$sha" ]; then
    stored_hash=$(awk '{print $1}' "$sha")
    dst_hash=$(shasum -a 256 "$dst" | awk '{print $1}')
    if [ "$stored_hash" = "$dst_hash" ]; then
      log "${YELLOW}—${NC} Skipping (verified):  $rel/$name"
      count_skipped=$((count_skipped + 1))
      return 0
    fi
    log "${YELLOW}!${NC} Sidecar exists but checksum mismatch — re-copying: $name"
  fi

  log "${CYAN}↓${NC} Copying: $name → $rel/"
  draw_progress

  mkdir -p "$dst_dir"
  tmp="${dst}.part"
  current_tmp="$tmp"

  src_hash=$(tee "$tmp" < "$src" | shasum -a 256 | awk '{print $1}')
  dst_hash=$(shasum -a 256 "$tmp" | awk '{print $1}')

  if [ "$src_hash" = "$dst_hash" ]; then
    # Preserve original file timestamps, then move into place
    touch -r "$src" "$tmp"
    mv "$tmp" "$dst"
    current_tmp=""
    # Write sidecar: "<hash>  <filename>" (standard shasum format)
    echo "$dst_hash  $name" > "$sha"
    log "${GREEN}✓${NC} Verified:  $rel/$name"
    count_copied=$((count_copied + 1))
  else
    rm -f "$tmp"
    current_tmp=""
    log "${RED}✗ CHECKSUM MISMATCH — discarding corrupt copy: $name${NC}"
    count_failed=$((count_failed + 1))
  fi
}

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  FX3 Ingest${NC}"
echo -e "${CYAN}  Source:${NC}      $SRC_DIR"
echo -e "${CYAN}  Destination:${NC} $DST_ROOT"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Pre-scan for progress totals ─────────────────────────────────────────────
total_files=0
total_bytes=0
while IFS= read -r -d '' f; do
  total_files=$((total_files + 1))
  total_bytes=$((total_bytes + $(stat -f%z "$f")))
done < <(find "$SRC_DIR" -iname "*.mp4" -type f -print0)

if [ "$total_files" -eq 0 ]; then
  echo -e "${YELLOW}No .MP4 files found in $SRC_DIR${NC}"
  exit 0
fi

# ── Free-space check ─────────────────────────────────────────────────────────
# Conservative: assumes every file needs copying, so a re-run over a mostly
# ingested card may over-estimate what's actually needed.
mkdir -p "$DST_ROOT"
avail_bytes=$(( $(df -Pk "$DST_ROOT" | awk 'NR==2 {print $4}') * 1024 ))
if [ "$avail_bytes" -lt "$total_bytes" ]; then
  echo -e "${RED}Error:${NC} Not enough free space on destination."
  echo -e "  Needed:    $(human_size "$total_bytes")"
  echo -e "  Available: $(human_size "$avail_bytes")"
  exit 1
fi

draw_progress

# ── Main loop ─────────────────────────────────────────────────────────────────
# Find all MP4/mp4 files recursively in the source directory
while IFS= read -r -d '' src_file; do

  filename=$(basename "$src_file")
  file_size=$(stat -f%z "$src_file")

  # ── Derive folder structure from metadata ──────────────────────────────────
  # Pull CreateDate from the clip; fall back gracefully if missing
  create_date=$(exiftool -s3 -d "%Y-%m-%d" -CreateDate "$src_file" 2>/dev/null || true)

  # Strip whitespace
  create_date="${create_date//[[:space:]]/}"

  # Fall back to filesystem mtime, then "Unknown-Date", if metadata is missing
  if [ -z "$create_date" ]; then
    create_date=$(stat -f %Sm -t %Y-%m-%d "$src_file" 2>/dev/null || true)
    [ -n "$create_date" ] && log "${YELLOW}!${NC} No CreateDate metadata — using file mtime: $filename"
  fi
  [ -z "$create_date" ] && create_date="Unknown-Date"

  # Build destination path: <root>/<YYYY-MM-DD>/<filename>
  dst_dir="$DST_ROOT/$create_date"

  ingest_file "$src_file" "$dst_dir" "$create_date"

  files_done=$((files_done + 1))
  bytes_done=$((bytes_done + file_size))
  draw_progress

  # Sony NRT metadata sidecars (e.g. C0001M01.XML for C0001.MP4) ride along
  # into the clip's date folder. They're ~2KB, so they aren't counted in the
  # byte-weighted progress totals.
  base="${filename%.*}"
  while IFS= read -r -d '' xml_file; do
    ingest_file "$xml_file" "$dst_dir" "$create_date"
    draw_progress
  done < <(find "$(dirname "$src_file")" -maxdepth 1 -iname "${base}M[0-9][0-9].XML" -type f -print0)

done < <(find "$SRC_DIR" -iname "*.mp4" -type f -print0)

printf "\n"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}Copied & verified:${NC}  $count_copied"
echo -e "  ${YELLOW}Skipped (existing):${NC} $count_skipped"
if [ "$count_failed" -gt 0 ]; then
  echo -e "  ${RED}Failed (mismatch):${NC}  $count_failed"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "$count_failed" -gt 0 ]; then
  exit 1
fi
