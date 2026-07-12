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
3. Falls back to an `Unknown-Date` folder if metadata is missing.
4. Copies each file, preserving original filenames and timestamps
   (`touch -r`).
5. Verifies every copy with a SHA-256 checksum (`shasum -a 256`): hash the
   source before copy, hash the destination after, compare.
6. Writes a `.sha256` sidecar file next to each copied clip in standard
   `shasum -c` format, so the archive can be re-verified later without the
   original SD card.
7. Is idempotent — on re-run, skips any file whose destination + sidecar
   hash already match, without re-hashing the source.
8. Deletes the destination file and reports failure if a checksum mismatch
   is detected post-copy (protects against corrupt copies).
9. Shows a live, in-place progress bar (`[####----] 42% (5/20 files,
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

## Next steps / open threads

- Script currently handles `.MP4` only (case-insensitive). If The user starts
  shooting RAW or other Sony formats (e.g. `.XML` sidecars, proxy files),
  the `find ... -iname "*.mp4"` filter and folder templating will need
  extending.
- No multi-destination (simultaneous backup) cloning — The user confirmed he
  doesn't need this, so it hasn't been built.
- Resolve's Media Pool auto-bin step (right-click → Auto-Bin by Metadata, or
  drag folders in directly) is the intended next step after ingest, but is a
  manual step in Resolve itself, not part of this script.
