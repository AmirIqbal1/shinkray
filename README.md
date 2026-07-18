# shrinkray 📼➡️📦

Point it at a video file. Get a much smaller one back. That's it.

No codec knowledge required — `shrinkray` figures out the best video
encoder your machine supports and uses it sensibly, so you don't have
to know what HEVC, AV1, CRF, or bitrate even mean.

## Install (Ubuntu / Linux Mint)

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/shrinkray/main/install.sh | bash
```

This installs `ffmpeg` if you don't already have it, and puts
`shrinkray` on your PATH.

Or, clone it and install manually:

```bash
git clone https://github.com/YOUR_USERNAME/shrinkray.git
cd shrinkray
./install.sh
```

## Use it

```bash
shrinkray movie.mkv
```

That's the whole thing. It'll produce `movie.shrunk.mkv` at roughly
500MB by default.

Want it a different size, or better quality (slower)?

```bash
shrinkray movie.mkv --size 700 --quality best
```

Got a folder full of films on your media server?

```bash
shrinkray --batch ~/Movies --size 500
```

## Options

| Flag | What it does | Default |
|---|---|---|
| `--size <MB>` | Target output size | `500` |
| `--quality <fast\|good\|best>` | Slower = better compression for the same size | `good` |
| `--codec <auto\|hevc\|av1>` | Which encoder to use | `auto` (picks the best one available) |
| `--container <mkv\|mp4>` | Output file format | `mkv` |
| `--keep-all-audio` | Keep every audio track instead of just the first | off |
| `--output <path>` | Custom output filename | `<name>.shrunk.<container>` |
| `--batch <dir>` | Process every video in a folder | — |
| `--dry-run` | Show what it would do, without doing it | off |
| `-y` | Don't ask before overwriting | off |

## What it actually does (for the curious)

- Re-encodes the video using **AV1** if your system supports it
  (better compression), falling back to **HEVC** automatically if not
  — including if AV1 encoding fails partway through.
- Calculates the bitrate needed to hit your target size based on the
  film's length, and uses two-pass encoding (for HEVC) to hit it
  accurately.
- Drops extra audio tracks by default (commentary, alternate language
  dubs) since those often account for hundreds of MB you're not using
  — subtitles are kept, since they're tiny.

## File formats: mkv vs mp4

- **Input**: shrinkray reads whatever ffmpeg can decode - mp4, mkv, avi,
  mov, ts, whatever your file already is. No conversion needed first.
- **Output**: defaults to **mkv**, because it's the most capable
  container for this job - it can hold any subtitle format and modern
  audio codecs without a fuss.
- Pass `--container mp4` if you need maximum compatibility with older
  smart TVs, phones, or media boxes that are picky about mkv.
  **Trade-off**: Blu-ray rips almost always carry image-based (PGS)
  subtitles, and mp4 simply can't contain those - so mp4 output drops
  subtitles entirely. If you need to keep subtitles, stick with mkv
  (which nearly everything modern - Plex, Jellyfin, Kodi, VLC - plays
  natively anyway).

## A note on quality

Below a certain size, video quality genuinely has to give a little —
that's true of any tool, not a shrinkray limitation. `--quality best`
gets more out of the same file size by spending more time thinking
about each frame, but for very aggressive size targets (e.g. squeezing
a 2-hour film into 500MB) you may notice softness in busy scenes. If
that matters to you, try a bigger `--size` first.

## Uninstall

```bash
rm ~/.local/bin/shrinkray
```
