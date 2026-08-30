# mark-watched

Marks YouTube videos as watched in your real YouTube account while playing
them in mpv, so YouTube's recommendations reflect what you actually watch.

## What it does

mpv plays YouTube URLs by resolving a raw stream via yt-dlp and streaming
that directly - it never touches youtube.com's own web player, so none of
YouTube's normal watch-history tracking happens on its own. This script
calls yt-dlp's own `--mark-watched` flag instead - a real POST to
YouTube's watch-history endpoint, authenticated the same way yt-dlp
already is on this machine (via `--cookies-from-browser` in yt-dlp's own
global config, `~/.config/yt-dlp/config`). `--simulate` keeps the call a
pure metadata/side-effect operation - nothing gets (re-)downloaded.

A video is marked watched once **either** `min_seconds` of actual playback
**or** `min_percent` of its duration is reached, whichever comes first
(defaults: 30s / 50%) - not the instant playback starts. A video clicked
and immediately skipped was not actually watched, and letting that count
would feed YouTube's recommender the wrong signal, undermining the whole
point of doing this. A video that finishes (reaches end-of-file) before
either threshold is hit - very short clips, mostly - is marked watched
regardless.

Non-YouTube files/URLs are ignored entirely.

## Installation

1. Copy or symlink `scripts/mark_watched.lua` into mpv's `scripts/`
   directory.
2. Optionally copy `script-opts/mark_watched.conf` to
   `~/.config/mpv/script-opts/mark_watched.conf` to override the defaults.
3. Make sure yt-dlp is on `PATH` and already authenticated (a
   `--cookies-from-browser <browser>` line in yt-dlp's own global config,
   or equivalent) - this script relies on that being set up already,
   rather than duplicating a machine-specific browser choice here.

## Options

| Option        | Default | Meaning                                    |
|---------------|---------|---------------------------------------------|
| `enabled`     | `yes`   | Master on/off switch.                      |
| `min_seconds` | `30`    | Seconds of actual (unpaused) playback.     |
| `min_percent` | `50`    | Percent of the video's duration.           |

## License

MPL-2.0, see [LICENSE](LICENSE).
