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

Deciding *when* a video counts as watched is not the instant playback
starts - a video clicked and immediately skipped was not actually watched,
and letting that count would feed YouTube's recommender the wrong signal,
undermining the whole point of doing this. Two selectable algorithms
handle that:

- **`threshold`** (the default) - marks watched once **either**
  `min_seconds` of actual playback **or** `min_percent` of the video's
  duration is reached, whichever comes first. Several named `profile`
  presets pick common combinations for you (`immediate`, `seconds_only`,
  `percent_only`, `balanced` - the default, 30s/50% - and
  `near_completion`, ~90%) instead of hand-tuning the two numbers; set
  `profile=custom` to use your own `min_seconds`/`min_percent` directly.
- **`adaptive`** - the percent-watched target itself scales with the
  video's duration instead of a flat number: stricter (a higher percent
  required) for short videos, more lenient for long ones, linearly
  interpolated between two configurable anchor points.

A video that finishes (reaches end-of-file) before either algorithm's
threshold is hit - very short clips, mostly - is marked watched
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

| Option                   | Default     | Meaning                                                        |
|--------------------------|-------------|-----------------------------------------------------------------|
| `enabled`                | `yes`       | Master on/off switch.                                          |
| `algorithm`               | `threshold` | `threshold` or `adaptive` - see above.                          |
| `profile`                | `balanced`  | threshold algorithm: `immediate`/`seconds_only`/`percent_only`/`balanced`/`near_completion`/`custom`. |
| `min_seconds`            | `30`        | threshold algorithm, `profile=custom` only.                    |
| `min_percent`            | `50`        | threshold algorithm, `profile=custom` only.                    |
| `adaptive_short_minutes` | `2`         | adaptive algorithm: duration (minutes) at/below which `adaptive_short_percent` applies. |
| `adaptive_short_percent` | `70`        | adaptive algorithm: percent target for short videos.            |
| `adaptive_long_minutes`  | `20`        | adaptive algorithm: duration (minutes) at/above which `adaptive_long_percent` applies. |
| `adaptive_long_percent`  | `15`        | adaptive algorithm: percent target for long videos.              |
| `adaptive_min_seconds`   | `5`         | adaptive algorithm: floor under the percent target.              |

## License

MPL-2.0, see [LICENSE](LICENSE).
