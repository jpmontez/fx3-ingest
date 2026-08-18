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
   name**, whether that file is already in the archive or is another clip in
   the same run. See [Name collisions](#name-collisions).
7. Flags clips with no gyro/IMU track, so you learn a clip can't be
   stabilized while the card is still in the reader. See
   [Gyroflow](#gyroflow).
8. Discards the staged copy and reports failure if a checksum mismatch or a
   write error occurs.
9. Checks the destination has enough free space before starting, counting
   only the files that actually need copying.
10. Shows a live, byte-weighted progress bar while it works — and drops the
    colours and the bar automatically when output is piped to a file.

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
COPY       C0002.MP4      → 2026-07-20/  318.4MB  (no gyro)
SKIP       C0003.MP4      → 2026-07-20/  (already ingested)
```

### Verifying an archive later

`--verify` re-hashes against the `.sha256` sidecars and reports corruption,
missing files, and files that never got a sidecar. It exits non-zero if
anything is wrong, so it's cron-friendly:

```bash
./fx3_ingest.sh --verify /Volumes/MyDrive/Projects/Shoot_Name/Footage
```

It also takes a single date folder, or one file, when you want a spot check
rather than a full re-hash of the archive:

```bash
./fx3_ingest.sh --verify ~/Footage/2026-07-20              # one day
./fx3_ingest.sh --verify ~/Footage/2026-07-20/C0001.MP4    # one clip
```

To check a file with `shasum` directly instead, note that `shasum -c`
resolves the filename in the sidecar relative to the **current directory**,
not to the sidecar's location — so you have to be in the file's folder:

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

## Name collisions

FX3 cards restart numbering at `C0001.MP4` after a format, so two cards from
the same shoot day will contain different clips with identical names. The
script guards both directions of this.

**Against the archive.** Whether a file is already ingested is decided by
comparing the **source** against the **destination** (size + mtime). If a
file of that name already exists but is a *different* file, that's reported
as a collision, the existing file is left untouched, the new one is not
copied, and the script exits non-zero with `Do not format the card`.

**Against the rest of the same run.** Two different clips in one source tree
can also target the same destination path — two card dumps under one parent,
or clips spread across subfolders. Those are grouped and reported together,
and *neither* is copied:

```
COLLISION  C0001.MP4      → 2026-07-20/
           two or more source files map to this path:
             /cards/cardA/C0001.MP4  (512099328B)
             /cards/cardB/C0001.MP4  (498012160B)
           Ingest each card into its own destination folder.
```

Either way: ingest the second card into a different destination folder, or
rename the clips, then re-run.

If two source files are byte-identical (same name, size, and mtime — a card
and a backup of it under one parent), that isn't a collision. The first is
copied and the rest are reported as `DUPLICATE` and skipped, since nothing is
lost.

Size + mtime is a deliberate fast path: ingest preserves mtime via `touch -r`,
so a genuine re-run skips without reading a byte. The trade-off is that
routine ingest won't detect bit rot in files already in the archive — that's
what `--verify` is for.

## Gyroflow

The FX3 records gyro/IMU data into an `rtmd` timed-metadata track **inside
the MP4**. Gyroflow reads that track out of the original file, so:

- **Ingest preserves it.** The copy is byte-exact and checksum-verified, so
  the gyro data survives untouched. Point Gyroflow at the ingested `.MP4`.
- **The `.XML` sidecar is not a substitute.** That's Sony's `nrtm`
  (*Non*-Real Time Metadata) — a summary of the clip, with no gyro in it.
- **Re-encoding or trimming outside Gyroflow destroys it.** Stabilize from
  the ingested original, not from a transcode or a Resolve render.

Sony doesn't write the IMU track in every recording mode, and proxy clips
never carry usable gyro. So ingest checks each clip and flags the ones that
have no `rtmd` track:

```
! NO GYRO:   2026-07-20/C0003.MP4  (no rtmd track — not stabilizable in Gyroflow)
```

The point is to tell you *while the card is still in the reader*. This is
informational — a clip shot in a mode without IMU data is not an ingest
failure, so it never changes the exit code.

The check is free: it reads `MetaFormat` from the file's `moov` header in the
same batched `exiftool` call that resolves dates. Confirming the samples
themselves are populated would need `exiftool -ee`, which walks the whole
`mdat` — a second full read of every clip, which is exactly what the
single-read copy exists to avoid.

## Dependencies

- [`exiftool`](https://exiftool.org/) — `brew install exiftool`
- `shasum` — built into macOS

## After ingest

Import into DaVinci Resolve and use **Media Pool → right-click → Auto-Bin by
Metadata** (or drag the date folders in directly) to mirror the folder
structure into bins.

## Scope

- macOS only — uses BSD `stat` and `df` syntax.
- Handles `.MP4` clips and their Sony XML metadata sidecars. RAW and other
  Sony formats aren't currently supported.
- Sony proxy clips (`SUB/C0001S01.MP4`) are detected and skipped, not
  ingested — they carry no usable gyro. The count is reported.
- macOS AppleDouble stubs (`._C0001.MP4`), which appear on exFAT cards, are
  ignored.
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
