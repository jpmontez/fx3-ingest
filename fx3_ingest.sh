#!/usr/bin/env bash
# =============================================================================
# fx3_ingest.sh — Sony FX3 media ingest script
#
# Usage:
#   ./fx3_ingest.sh [--dry-run] <source_dir> <destination_dir>
#   ./fx3_ingest.sh --verify <archive_dir>
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

usage() {
  echo -e "${CYAN}Usage:${NC}"
  echo "  $0 [--dry-run] <source_dir> <destination_dir>"
  echo "  $0 --verify <archive_dir>"
  echo ""
  echo "  source_dir       SD card clip folder (e.g. /Volumes/SDCARD/PRIVATE/M4ROOT/CLIP)"
  echo "  destination_dir  Project footage root (e.g. /Volumes/MyDrive/Projects/Shoot/Footage)"
  echo ""
  echo "  -n, --dry-run    Show what would be copied, where, and why. Writes nothing."
  echo "      --verify     Re-hash an existing archive against its .sha256 sidecars"
  echo "                   and report corruption, missing files, and missing sidecars."
  echo "  -h, --help       Show this help."
}

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=0
MODE="ingest"
positional=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    --verify)     MODE="verify"; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; while [ "$#" -gt 0 ]; do positional+=("$1"); shift; done ;;
    -*)           echo -e "${RED}Error:${NC} Unknown option: $1"; echo ""; usage; exit 1 ;;
    *)            positional+=("$1"); shift ;;
  esac
done

# ── Shared helpers ───────────────────────────────────────────────────────────
human_size() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1fGB", b/1073741824;
    else if (b >= 1048576) printf "%.1fMB", b/1048576;
    else printf "%dB", b;
  }'
}

files_done=0
bytes_done=0
total_files=0
total_bytes=0

draw_progress() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  # Nothing to copy (e.g. a run that only turned up collisions) — a 0/0 bar
  # would just be noise between the error lines.
  [ "$total_files" -eq 0 ] && return 0
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

# stat wrappers — BSD/macOS syntax
file_size()  { stat -f%z "$1"; }
file_mtime() { stat -f%m "$1"; }

# =============================================================================
# VERIFY MODE
# =============================================================================
# Walks an ingested archive and re-hashes every file against its .sha256
# sidecar. Also reports sidecars whose file is gone, and files that never got
# a sidecar. This is the integrity check that routine ingest deliberately
# skips (see the fast-skip note in plan_actions).
if [ "$MODE" = "verify" ]; then
  if [ "${#positional[@]}" -ne 1 ]; then
    echo -e "${RED}Error:${NC} --verify takes exactly one argument (the archive directory)"
    echo ""
    usage
    exit 1
  fi
  ARCHIVE="${positional[0]%/}"
  if [ ! -d "$ARCHIVE" ]; then
    echo -e "${RED}Error:${NC} Directory not found: $ARCHIVE"
    exit 1
  fi

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  FX3 Archive Verify${NC}"
  echo -e "${CYAN}  Archive:${NC} $ARCHIVE"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  v_ok=0; v_bad=0; v_missing=0; v_nosidecar=0

  # Pre-scan for progress totals: bytes of every file that has a sidecar.
  while IFS= read -r -d '' sidecar; do
    orig="${sidecar%.sha256}"
    if [ -f "$orig" ]; then
      total_files=$((total_files + 1))
      total_bytes=$((total_bytes + $(file_size "$orig")))
    fi
  done < <(find "$ARCHIVE" -name "*.sha256" -type f -print0 | sort -z)

  draw_progress

  while IFS= read -r -d '' sidecar; do
    orig="${sidecar%.sha256}"
    rel="${orig#"$ARCHIVE"/}"
    if [ ! -f "$orig" ]; then
      log "${RED}✗${NC} MISSING FILE:   $rel  (sidecar exists, file does not)"
      v_missing=$((v_missing + 1))
      draw_progress
      continue
    fi
    stored_hash=$(awk 'NR==1 {print $1}' "$sidecar")
    actual_hash=$(shasum -a 256 "$orig" | awk '{print $1}')
    if [ "$stored_hash" = "$actual_hash" ]; then
      v_ok=$((v_ok + 1))
    else
      log "${RED}✗${NC} CORRUPT:        $rel  (hash does not match sidecar)"
      v_bad=$((v_bad + 1))
    fi
    files_done=$((files_done + 1))
    bytes_done=$((bytes_done + $(file_size "$orig")))
    draw_progress
  done < <(find "$ARCHIVE" -name "*.sha256" -type f -print0 | sort -z)

  # Files in the archive that never got a sidecar written. macOS scatters
  # .DS_Store files through any browsed folder; they aren't media and would
  # be pure noise here.
  while IFS= read -r -d '' f; do
    case "$f" in
      *.sha256|*.part|*/.DS_Store) continue ;;
    esac
    if [ ! -f "${f}.sha256" ]; then
      log "${YELLOW}!${NC} NO SIDECAR:     ${f#"$ARCHIVE"/}"
      v_nosidecar=$((v_nosidecar + 1))
    fi
  done < <(find "$ARCHIVE" -type f -print0 | sort -z)

  printf "\r\033[K"
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${GREEN}Verified OK:${NC}        $v_ok"
  [ "$v_bad" -gt 0 ]       && echo -e "  ${RED}Corrupt:${NC}            $v_bad"
  [ "$v_missing" -gt 0 ]   && echo -e "  ${RED}Missing files:${NC}      $v_missing"
  [ "$v_nosidecar" -gt 0 ] && echo -e "  ${YELLOW}Without sidecar:${NC}    $v_nosidecar"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [ "$v_bad" -gt 0 ] || [ "$v_missing" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

# =============================================================================
# INGEST MODE
# =============================================================================
if [ "${#positional[@]}" -ne 2 ]; then
  usage
  exit 1
fi

SRC_DIR="${positional[0]%/}"   # strip trailing slash if present
DST_ROOT="${positional[1]%/}"

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
count_collision=0

# Scratch dir for the plan file and exiftool argfile. Also holds the path of
# the in-flight staging file so an interrupt can clean it up.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fx3_ingest.XXXXXX")
current_tmp=""
cleanup() {
  [ -n "$current_tmp" ] && rm -f "$current_tmp"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PLAN="$WORK_DIR/plan.tsv"
ARGFILE="$WORK_DIR/args.txt"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo -e "${CYAN}  FX3 Ingest${NC} ${YELLOW}(dry run — nothing will be written)${NC}"
else
  echo -e "${CYAN}  FX3 Ingest${NC}"
fi
echo -e "${CYAN}  Source:${NC}      $SRC_DIR"
echo -e "${CYAN}  Destination:${NC} $DST_ROOT"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Collect source clips ─────────────────────────────────────────────────────
# One walk of the card, reused for the date lookup, the plan, and the copy —
# so the card is never scanned twice and can't change between passes.
src_files=()
while IFS= read -r -d '' f; do
  # The plan file is tab-separated and the exiftool argfile is newline-
  # separated, so a path containing either would corrupt both.
  case "$f" in
    *$'\t'*|*$'\n'*)
      echo -e "${RED}Error:${NC} Path contains a tab or newline, which is not supported:"
      echo "  $f"
      exit 1
      ;;
  esac
  src_files+=("$f")
done < <(find "$SRC_DIR" -iname "*.mp4" -type f -print0 | sort -z)

if [ "${#src_files[@]}" -eq 0 ]; then
  echo -e "${YELLOW}No .MP4 files found in $SRC_DIR${NC}"
  exit 0
fi

# ── Resolve each clip's shooting date ────────────────────────────────────────
# IMPORTANT: the plain QuickTime CreateDate tag is stored in UTC, so using it
# directly files anything shot after ~19:00 local into the *next* day's folder.
# Preference order:
#   1. CreationDateValue — Sony's NRT tag, carries the camera's own UTC offset,
#      so it is the true local wall-clock time the operator saw.
#   2. CreateDate with -api QuickTimeUTC=1 — tells exiftool to treat the tag as
#      UTC and convert it to this Mac's local time. Correct as long as the Mac
#      and the camera are in the same timezone.
#   3. Filesystem mtime.
#   4. "Unknown-Date".
# One batched exiftool call for the whole card: exiftool costs ~0.5s of perl
# startup per invocation, which dominated ingest time on a large card.
printf '%s\n' "${src_files[@]}" > "$ARGFILE"

exif_out="$WORK_DIR/dates.tsv"
exiftool -q -q -m -f -T -api QuickTimeUTC=1 -d '%Y-%m-%d' \
  -CreationDateValue -CreateDate -@ "$ARGFILE" > "$exif_out" 2>/dev/null || true

# Read the results back in argfile order (exiftool -T preserves it).
dates=()
while IFS=$'\t' read -r nrt_date qt_date; do
  if [ -n "$nrt_date" ] && [ "$nrt_date" != "-" ]; then
    dates+=("$nrt_date")
  elif [ -n "$qt_date" ] && [ "$qt_date" != "-" ]; then
    dates+=("$qt_date")
  else
    dates+=("")
  fi
done < "$exif_out"

# If exiftool bailed entirely, fall back to per-file resolution below.
while [ "${#dates[@]}" -lt "${#src_files[@]}" ]; do
  dates+=("")
done

# ── Build the plan ───────────────────────────────────────────────────────────
# Each line: <action>\t<src>\t<dst_dir>\t<size>\t<reason>
# Deciding everything up front means the free-space check and the progress bar
# both reflect the work that will actually happen, not a worst case.

# Decide what to do with one source file relative to its destination.
#   COPY      — not present, or present but incomplete (no sidecar)
#   SKIP      — same file already ingested (size + mtime match)
#   COLLISION — a *different* file already occupies that name
#
# The skip test compares the source against the destination. The previous
# version compared the destination against its own sidecar, which always
# matched — so a second card whose clips are also named C0001.MP4 was silently
# reported as "already verified" and never copied.
#
# Size + mtime is the fast path: ingest copies preserve mtime via `touch -r`,
# so a genuine re-run matches without reading a byte. Bit rot in an already
# ingested file is therefore not caught during ingest — that is what
# `--verify` is for.
plan_actions() {
  local src="$1" dst_dir="$2"
  local name dst sha size mtime dst_size dst_mtime action reason
  name=$(basename "$src")
  dst="$dst_dir/$name"
  sha="${dst}.sha256"
  size=$(file_size "$src")
  mtime=$(file_mtime "$src")
  action="COPY"; reason=""

  if [ -f "$dst" ]; then
    dst_size=$(file_size "$dst")
    dst_mtime=$(file_mtime "$dst")
    if [ ! -f "$sha" ]; then
      action="COPY"; reason="incomplete previous ingest (no sidecar)"
    elif [ "$size" = "$dst_size" ] && [ "$mtime" = "$dst_mtime" ]; then
      action="SKIP"; reason="already ingested"
    else
      action="COLLISION"
      reason="different file already at this path (src ${size}B/$(date -r "$mtime" '+%Y-%m-%d %H:%M:%S') vs dst ${dst_size}B/$(date -r "$dst_mtime" '+%Y-%m-%d %H:%M:%S'))"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$src" "$dst_dir" "$size" "$reason"
}

: > "$PLAN"
i=0
for src_file in "${src_files[@]}"; do
  create_date="${dates[$i]}"
  i=$((i + 1))

  create_date="${create_date//[[:space:]]/}"

  if [ -z "$create_date" ]; then
    create_date=$(stat -f %Sm -t %Y-%m-%d "$src_file" 2>/dev/null || true)
    [ -n "$create_date" ] && \
      echo -e "${YELLOW}!${NC} No CreateDate metadata — using file mtime: $(basename "$src_file")"
  fi
  [ -z "$create_date" ] && create_date="Unknown-Date"

  dst_dir="$DST_ROOT/$create_date"
  plan_actions "$src_file" "$dst_dir" >> "$PLAN"

  # Sony NRT metadata sidecars (e.g. C0001M01.XML for C0001.MP4) ride along
  # into the clip's date folder.
  filename=$(basename "$src_file")
  base="${filename%.*}"
  while IFS= read -r -d '' xml_file; do
    plan_actions "$xml_file" "$dst_dir" >> "$PLAN"
  done < <(find "$(dirname "$src_file")" -maxdepth 1 -iname "${base}M[0-9][0-9].XML" -type f -print0 | sort -z)
done

# ── Plan totals ──────────────────────────────────────────────────────────────
plan_copy=0; plan_skip=0; plan_collide=0; copy_bytes=0
while IFS=$'\t' read -r action src dst_dir size reason; do
  case "$action" in
    COPY)      plan_copy=$((plan_copy + 1));       copy_bytes=$((copy_bytes + size)) ;;
    SKIP)      plan_skip=$((plan_skip + 1)) ;;
    COLLISION) plan_collide=$((plan_collide + 1)) ;;
  esac
done < "$PLAN"

total_files="$plan_copy"
total_bytes="$copy_bytes"

# ── Dry run: print the plan and stop ─────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  while IFS=$'\t' read -r action src dst_dir size reason; do
    name=$(basename "$src")
    rel="${dst_dir#"$DST_ROOT"/}"
    case "$action" in
      COPY)
        printf "${GREEN}%-10s${NC} %-14s → %s/  %s\n" "COPY" "$name" "$rel" "$(human_size "$size")"
        ;;
      SKIP)
        printf "${YELLOW}%-10s${NC} %-14s → %s/  (%s)\n" "SKIP" "$name" "$rel" "$reason"
        ;;
      COLLISION)
        printf "${RED}%-10s${NC} %-14s → %s/\n" "COLLISION" "$name" "$rel"
        printf "           %s\n" "$reason"
        ;;
    esac
  done < "$PLAN"

  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${GREEN}Would copy:${NC}         $plan_copy  ($(human_size "$copy_bytes"))"
  echo -e "  ${YELLOW}Would skip:${NC}         $plan_skip"
  [ "$plan_collide" -gt 0 ] && echo -e "  ${RED}Collisions:${NC}         $plan_collide"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  [ "$plan_collide" -gt 0 ] && exit 1
  exit 0
fi

# ── Free-space check ─────────────────────────────────────────────────────────
# Based on the plan, so it counts only the files that actually need copying.
mkdir -p "$DST_ROOT"
avail_bytes=$(( $(df -Pk "$DST_ROOT" | awk 'NR==2 {print $4}') * 1024 ))
if [ "$avail_bytes" -lt "$copy_bytes" ]; then
  echo -e "${RED}Error:${NC} Not enough free space on destination."
  echo -e "  Needed:    $(human_size "$copy_bytes")"
  echo -e "  Available: $(human_size "$avail_bytes")"
  exit 1
fi

if [ "$plan_copy" -eq 0 ] && [ "$plan_collide" -eq 0 ]; then
  echo -e "${GREEN}Nothing to do — all $plan_skip files already ingested.${NC}"
  exit 0
fi

# ── Copy + verify one file ───────────────────────────────────────────────────
# The source is read only once: tee copies it to a .part staging file while
# shasum hashes the same stream. The staged copy is re-read to verify, and
# only renamed into place once its hash matches — the destination never
# holds an unverified file.
ingest_file() {
  local src="$1" dst_dir="$2" rel="$3"
  local name dst sha tmp src_hash dst_hash

  name=$(basename "$src")
  dst="$dst_dir/$name"
  sha="${dst}.sha256"

  log "${CYAN}↓${NC} Copying: $name → $rel/"
  draw_progress

  if ! mkdir -p "$dst_dir"; then
    log "${RED}✗ Could not create directory: $dst_dir${NC}"
    count_failed=$((count_failed + 1))
    return 0
  fi

  tmp="${dst}.part"
  current_tmp="$tmp"

  # A write failure here (full disk, drive disconnected) makes tee exit
  # non-zero, which pipefail surfaces. Catch it rather than letting `set -e`
  # kill the script with no message and no summary.
  if ! src_hash=$(tee "$tmp" < "$src" | shasum -a 256 | awk '{print $1}'); then
    rm -f "$tmp"
    current_tmp=""
    log "${RED}✗ WRITE FAILED — destination may be full or disconnected: $name${NC}"
    count_failed=$((count_failed + 1))
    return 0
  fi

  dst_hash=$(shasum -a 256 "$tmp" | awk '{print $1}')

  if [ "$src_hash" = "$dst_hash" ]; then
    # Preserve original file timestamps, then move into place. The mtime is
    # also what makes the next run's fast skip test work.
    touch -r "$src" "$tmp"
    mv "$tmp" "$dst"
    current_tmp=""
    # Write sidecar: "<hash>  <filename>" (standard shasum format, relative to
    # the file's own directory — see the verify note in README).
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

# ── Execute the plan ─────────────────────────────────────────────────────────
draw_progress

while IFS=$'\t' read -r action src dst_dir size reason; do
  rel="${dst_dir#"$DST_ROOT"/}"
  name=$(basename "$src")
  case "$action" in
    SKIP)
      log "${YELLOW}—${NC} Skipping (already ingested):  $rel/$name"
      count_skipped=$((count_skipped + 1))
      ;;
    COLLISION)
      log "${RED}✗ NAME COLLISION — not copied: $name${NC}"
      log "    $reason"
      log "    Source: $src"
      log "    Both clips are named $name but are not the same file. Ingest the"
      log "    second card into a different destination folder, or rename one."
      count_collision=$((count_collision + 1))
      ;;
    COPY)
      ingest_file "$src" "$dst_dir" "$rel"
      files_done=$((files_done + 1))
      bytes_done=$((bytes_done + size))
      ;;
  esac
  draw_progress
done < "$PLAN"

printf "\n"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}Copied & verified:${NC}  $count_copied"
echo -e "  ${YELLOW}Skipped (existing):${NC} $count_skipped"
if [ "$count_collision" -gt 0 ]; then
  echo -e "  ${RED}Name collisions:${NC}    $count_collision  ${RED}(NOT copied)${NC}"
fi
if [ "$count_failed" -gt 0 ]; then
  echo -e "  ${RED}Failed:${NC}             $count_failed"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "$count_failed" -gt 0 ] || [ "$count_collision" -gt 0 ]; then
  echo -e "${RED}Do not format the card — some files were not ingested.${NC}"
  exit 1
fi
