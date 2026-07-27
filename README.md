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
2. Derives each clip's shooting date and files it as
   `<destination>/<YYYY-MM-DD>/<filename>`. See
   [Date handling](#date-handling) — this is the part most likely to go
   wrong, and it's worth understanding.
3. Copies each clip's Sony XML metadata sidecar (e.g. `C0001M01.XML`) into
   the same date folder, so the camera metadata survives card formatting.
4. Copies each file, preserving original filenames and timestamps. The
   source is read only once: it's hashed while being copied to a `.part`
   staging file, which is renamed into place only after verification — the
   destination never holds an unverified file.
5. Verifies every copy with a SHA-256 checksum (source vs. destination) and
   writes a `.sha256` sidecar next to each copied file, so the archive can
   be re-verified later without the original SD card.
6. Is idempotent — re-running skips files already ingested, and **refuses to
   silently overwrite or skip a different file that happens to share a
   name**. See [Name collisions](#name-collisions).
7. Discards the staged copy and reports failure if a checksum mismatch or a
   write error occurs.
8. Checks the destination has enough free space before starting, counting
   only the files that actually need copying.
9. Shows a live, byte-weighted progress bar while it works.

## Usage

```bash
chmod +x fx3_ingest.sh
./fx3_ingest.sh <source_dir> <destination_dir>

# Example:
./fx3_ingest.sh /Volumes/SDCARD/PRIVATE/M4ROOT/CLIP /Volumes/MyDrive/Projects/Shoot_Name/Footage
```

### Preview before committing

`--dry-run` prints exactly what would be copied, where, and why, and writes
nothing. Worth running before an ingest you're going to format the card
after:

```bash
./fx3_ingest.sh --dry-run /Volumes/SDCARD/PRIVATE/M4ROOT/CLIP ~/Footage
```

```
COPY       C0001.MP4      → 2026-07-20/  512.1MB
COPY       C0001M01.XML   → 2026-07-20/  2144B
SKIP       C0002.MP4      → 2026-07-20/  (already ingested)
```

### Verifying an archive later

`--verify` re-hashes an entire archive against its `.sha256` sidecars and
reports corruption, missing files, and files that never got a sidecar. It
exits non-zero if anything is wrong, so it's cron-friendly:

```bash
./fx3_ingest.sh --verify /Volumes/MyDrive/Projects/Shoot_Name/Footage
```

To check a single file by hand, note that `shasum -c` resolves the filename
in the sidecar relative to the **current directory**, not to the sidecar's
location — so you have to be in the file's folder:

```bash
cd /path/to/2026-07-20 && shasum -a 256 -c C0001.MP4.sha256
```

## Date handling

An MP4's QuickTime `CreateDate` tag is stored in **UTC**. Using it directly
files anything shot after roughly 19:00 local into the *next* day's folder,
which splits a single evening shoot across two folders. The script resolves
the true local date in this order:

1. **`CreationDateValue`** — Sony's NRT tag, which carries the camera's own
   UTC offset (e.g. `2026-07-20T19:01:58-05:00`). This is the wall-clock
   time the operator actually saw, and is the preferred source.
2. **`CreateDate` with `-api QuickTimeUTC=1`** — tells exiftool to treat the
   tag as UTC and convert to this Mac's local time. Correct as long as the
   Mac and the camera share a timezone.
3. **Filesystem mtime.**
4. **`Unknown-Date`** as a last resort.

All clips on the card are read in a single batched `exiftool` call, since
exiftool costs roughly half a second of interpreter startup per invocation.

> **Archives created before this fix are misfiled** — clips shot late in the
> evening sit in the following day's folder. Re-file them by hand, moving each
> clip together with its `.XML` and `.sha256` sidecars.

## Name collisions

FX3 cards restart numbering at `C0001.MP4` after a format, so two cards from
the same shoot day will contain different clips with identical names.

The script decides whether a file is already ingested by comparing the
**source** against the **destination** (size + mtime). If a file of that name
already exists but is a *different* file, that's reported as a collision, the
existing file is left untouched, the new one is not copied, and the script
exits non-zero with `Do not format the card`.

Ingest the second card into a different destination folder, or rename the
clips, then re-run.

Size + mtime is a deliberate fast path: ingest preserves mtime via `touch -r`,
so a genuine re-run skips without reading a byte. The trade-off is that
routine ingest won't detect bit rot in files already in the archive — that's
what `--verify` is for.

## Dependencies

- [`exiftool`](https://exiftool.org/) — `brew install exiftool`
- `shasum` — built into macOS

## After ingest

Import into DaVinci Resolve and use **Media Pool → right-click → Auto-Bin by
Metadata** (or drag the date folders in directly) to mirror the folder
structure into bins.

## Scope

- macOS only — uses BSD `stat` and `df` syntax.
- Handles `.MP4` clips and their Sony XML metadata sidecars. RAW or other
  Sony formats (proxy files, etc.) aren't currently supported.
- No multi-destination (simultaneous backup) cloning — single destination
  only, by design.
- No reel/card-ID folder level; the FX3 writes no usable card identifier
  (`serialNo` is `4294967295`, and `umidRef` is per-clip). Collisions are
  caught rather than structurally prevented.
- Paths containing tabs or newlines are rejected rather than mishandled.

## Development

The script is linted with [shellcheck](https://www.shellcheck.net/)
(`brew install shellcheck`):

```bash
shellcheck fx3_ingest.sh
```
