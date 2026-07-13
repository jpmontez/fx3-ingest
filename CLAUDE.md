# FX3 Media Ingest Script

## Context

The user shoots on a Sony FX3 and needed a way to offload MP4 clips from an SD
card onto a MacBook Pro in an organized fashion, so that bins in the video
editor (DaVinci Resolve) aren't a mess on import.

### Background / tools evaluated

- **Offshoot by Hedge** — previously used, but the owned license is
  incompatible with the current macOS version.
- **DaVinci Resolve's Clone tool** (Media page) — does verified/checksummed
  copying, but is a flat copy with no metadata-derived folder templating.
  Resolve *can* auto-bin on import by mirroring folder structure, so this
  remains the intended import step after ingest.
- **phockup** (open source, exiftool-based) — sorts by date only, no
  camera-model/reel folder templating, and not very actively maintained
  (~3 years stale at time of evaluation).
- **Elodie** (open source, exiftool-based) — more actively maintained, but
  aggressively renames files, which conflicts with keeping native FX3
  filenames (`C0001.MP4` etc.) intact.
- **Conclusion**: no single open-source tool fully met requirements, so the
  solution is a custom shell script wrapping `exiftool` directly.

## Current solution: `fx3_ingest.sh`

A bash script that:

1. Recursively finds `.MP4` files in a source directory (the SD card's clip
   folder).
2. Reads `CreateDate` from each clip via `exiftool` to derive a destination
   folder path: `<destination>/<YYYY-MM-DD>/<filename>`
   (e.g. `Footage/2026-07-12/C0001.MP4`).
3. Falls back to the file's modification time (`stat -f %Sm`) if metadata
   is missing, then to an `Unknown-Date` folder as a last resort.
4. Copies each clip's Sony NRT metadata XML sidecar (e.g. `C0001M01.XML`
   for `C0001.MP4`) into the same date folder. Note: DaVinci Resolve does
   not use these (it reads metadata embedded in the MP4); they're kept for
   archival completeness and Sony's own tools (Catalyst Browse/Prepare).
5. Copies each file, preserving original filenames and timestamps
   (`touch -r`). The source is read only once — `tee` streams it into a
   `.part` staging file while `shasum` hashes the same stream — roughly
   halving ingest time vs. hash-then-copy, since the SD card is the
   bottleneck. The staged copy is renamed into place only after its hash
   is verified, so the destination never holds an unverified file (safe to
   point Resolve at mid-ingest). A trap cleans up the `.part` file if the
   script is interrupted.
6. Writes a `.sha256` sidecar file next to each copied file in standard
   `shasum -c` format, so the archive can be re-verified later without the
   original SD card.
7. Is idempotent — on re-run, skips any file whose destination + sidecar
   hash already match, without re-hashing the source.
8. Discards the staged copy and reports failure if a checksum mismatch is
   detected post-copy (protects against corrupt copies).
9. Checks the destination volume has enough free space (`df -Pk`) before
   starting. The check is conservative: it assumes every file needs
   copying, so a re-run over a mostly-ingested card can over-estimate.
10. Shows a live, in-place progress bar (`[####----] 42% (5/20 files,
   4.2GB/9.8GB)`) pinned beneath the per-clip log lines. Progress is weighted
   by bytes rather than file count, since FX3 clip sizes vary wildly (a few
   hundred MB up to several GB), and byte-weighting reflects actual time
   remaining more accurately than a flat per-file count would.

### Usage

```bash
chmod +x fx3_ingest.sh
./fx3_ingest.sh <source_dir> <destination_dir>

# Example:
./fx3_ingest.sh /Volumes/SDCARD/PRIVATE/M4ROOT/CLIP /Volumes/MyDrive/Projects/Shoot_Name/Footage
```

Re-verifying an archived clip later, without re-running the script:

```bash
shasum -a 256 -c /path/to/clip.MP4.sha256
```

### Dependencies

- `exiftool` (installed via Homebrew: `brew install exiftool`)
- `shasum` (built into macOS, no install needed)

### Development conventions

- The repo is local-only: no CI, no test suite (the user explicitly
  declined GitHub Actions and a smoke-test harness). Lint locally with
  `shellcheck fx3_ingest.sh` (already installed via Homebrew) before
  committing, and keep README.md / CLAUDE.md in sync with script changes.

## Next steps / open threads

- Script handles `.MP4` clips plus their matching Sony XML sidecars
  (case-insensitive). If The user starts shooting RAW or proxy files, the
  `find ... -iname "*.mp4"` filter and folder templating will need
  extending.
- No multi-destination (simultaneous backup) cloning — The user confirmed he
  doesn't need this, so it hasn't been built.
- Resolve's Media Pool auto-bin step (right-click → Auto-Bin by Metadata, or
  drag folders in directly) is the intended next step after ingest, but is a
  manual step in Resolve itself, not part of this script.
