# shrinkray 📼➡️📦

Point shrinkray at a movie. It creates a smaller copy and leaves the original
alone.

```bash
shrinkray movie.mkv
```

The default output is `movie.shrunk.mkv`, with a target size of about 500 MB.

## Install

Shrinkray supports Ubuntu Server and Linux Mint. The installer adds `ffmpeg`
with `apt-get` when it is missing, then installs the `shrinkray` command for
your user.

```bash
curl -fsSL https://raw.githubusercontent.com/AmirIqbal1/shinkray/main/install.sh | bash
```

Open a new terminal after installation, then check that everything is ready:

```bash
shrinkray doctor
```

To install from a clone instead:

```bash
git clone https://github.com/AmirIqbal1/shinkray.git
cd shinkray
./install.sh
```

For a system-wide installation in `/usr/local/bin`:

```bash
curl -fsSL https://raw.githubusercontent.com/AmirIqbal1/shinkray/main/install.sh | bash -s -- --system
```

The default user installation goes to `~/.local/bin` and does not need `sudo`
unless `ffmpeg` must be installed.

## Quick start

On Ubuntu Server or Linux Mint, the basic workflow is the same:

```bash
shrinkray ~/Movies/movie.mkv
```

Choose another target size or spend more time improving compression:

```bash
shrinkray ~/Movies/movie.mkv --size 700 --quality best
```

Process one directory:

```bash
shrinkray --batch ~/Movies --size 500
```

Include its subdirectories:

```bash
shrinkray --batch ~/Movies --recursive --size 500
```

Software video encoding is CPU-intensive and may be slow, especially with
`--quality best` or the explicitly requested AV1 codec. Start with the default
HEVC mode unless you specifically need AV1.

## Options

| Flag | What it does | Default |
|---|---|---|
| `--size <MB>` | Target output size in whole megabytes | `500` |
| `--quality <fast\|good\|best>` | Trade encoding time for compression quality | `good` |
| `--codec <auto\|hevc\|av1>` | Select the video encoder | `auto` (HEVC) |
| `--container <mkv\|mp4>` | Select the output container | `mkv` |
| `--keep-all-audio` | Keep all audio tracks instead of the first one | off |
| `--output <path>` | Set a custom output for one input file | automatic |
| `--batch <dir>` | Process videos in a directory | — |
| `--recursive` | Include subdirectories with `--batch` | off |
| `--dry-run` | Show planned work without encoding | off |
| `-y` | Replace an existing output without asking | off |

Run `shrinkray --help` for usage examples.

## Safety

Shrinkray never deletes or replaces the source movie. It encodes to a temporary
file ending in `.part`, validates that file with `ffprobe`, and only then moves
it to the requested output name. Failed and interrupted encodes are cleaned up.

MKV output keeps global metadata, chapters, and available subtitles. MP4 output
drops subtitles because common movie subtitle formats are not always compatible
with MP4. Audio is optional, so silent videos work too.

The target size is approximate. Shrinkray warns when the requested target is not
smaller than the source.

## Diagnostics

```bash
shrinkray doctor
```

This shows the shrinkray version and installation path, the installed `ffmpeg`
and `ffprobe` versions, and whether HEVC and AV1 software encoders are available.

## Uninstall

For a user installation:

```bash
rm ~/.local/bin/shrinkray
```

For a system installation:

```bash
sudo rm /usr/local/bin/shrinkray
```

## Licence

Shrinkray is free software licensed under the GNU General Public License,
version 3.0 (GPL-3.0).
