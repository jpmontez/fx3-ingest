# fx3-ingest

A checksum-verified ingest script for offloading Sony FX3 MP4 clips from an
SD card into a date-organized folder structure, ready for import into
DaVinci Resolve.

## Why

[Offshoot](https://www.hedge.video/offshoot) no longer runs on current
macOS. DaVinci Resolve's Clone tool does verified copying but no
metadata-based folder templating. Existing open-source options
([phockup](https://github.com/ivandokov/phockup),
[Elodie](https://github.com/jmathai/elodie)) either lack folder templating
or rename files in ways that conflict with keeping native FX3 filenames
(`C0001.MP4`, etc.) intact. `fx3_ingest.sh` is a small bash script wrapping
`exiftool` and `shasum` that does exactly what's needed and nothing more.

## What it does

1. Recursively finds `.MP4` files in a source directory (the SD card's clip
   folder).
2. Reads `CreateDate` from each clip via `exiftool` to derive a destination
   path: `<destination>/<YYYY-MM-DD>/<filename>` (falls back to
   `Unknown-Date` if metadata is missing).
3. Copies each file, preserving original filenames and timestamps.
4. Verifies every copy with a SHA-256 checksum (source vs. destination) and
   writes a `.sha256` sidecar next to each copied clip, so the archive can
   be re-verified later without the original SD card.
5. Is idempotent — re-running the script skips any file whose destination +
   sidecar hash already match.
6. Deletes the destination file and reports failure if a checksum mismatch
   is detected.
7. Shows a live, byte-weighted progress bar while it works.

## Usage

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

## Dependencies

- [`exiftool`](https://exiftool.org/) — `brew install exiftool`
- `shasum` — built into macOS

## After ingest

Import into DaVinci Resolve and use **Media Pool → right-click → Auto-Bin by
Metadata** (or drag the date folders in directly) to mirror the folder
structure into bins.

## Scope

- Handles `.MP4` only. RAW or other Sony formats (XML sidecars, proxy
  files) aren't currently supported.
- No multi-destination (simultaneous backup) cloning — single destination
  only, by design.
