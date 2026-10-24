-- mark-watched: marks a YouTube video as "watched" in the user's real
-- YouTube account once enough of it has actually played, via yt-dlp's own
-- --mark-watched flag - a real POST to YouTube's watch-history endpoint,
-- authenticated through the browser cookies already configured globally
-- for yt-dlp (see ~/.config/yt-dlp/config's --cookies-from-browser).
-- --simulate keeps this a pure metadata/side-effect call: nothing gets
-- (re-)downloaded.
--
-- mpv plays YouTube URLs by resolving a raw stream via yt-dlp and
-- streaming that directly - it never touches youtube.com's own web
-- player, so none of YouTube's normal watch-history tracking happens on
-- its own. This script is what makes that happen instead.
--
-- Fires once per file, the first time EITHER a minimum watched-seconds OR
-- a minimum watched-percentage is reached, whichever comes first. Both
-- count time actually played, not the playhead position - seeking ahead
-- does not count - and deliberately not "as soon as playback starts": a
-- video clicked and immediately skipped was not actually watched, and
-- letting that count
-- would feed YouTube's recommender the wrong signal, undermining the
-- whole point of doing this. See `algorithm`/`profile` below for the
-- available timing strategies and how to switch between them.

local options = require "mp.options"
local msg = require "mp.msg"

local opts = {
    enabled = true,

    -- Which algorithm decides when a video counts as "watched":
    --   threshold - fires once EITHER min_seconds or min_percent is
    --                reached (see `profile` for named presets)
    --   adaptive  - percent-watched target scales with the video's own
    --                duration instead of a flat number (see the
    --                adaptive_* options below)
    algorithm = "threshold",

    -- threshold algorithm: a named preset for min_seconds/min_percent -
    -- see PROFILES below for what each one means. "custom" uses the
    -- min_seconds/min_percent values below directly; every other profile
    -- overrides them.
    profile = "balanced",
    min_seconds = 30,
    min_percent = 50,

    -- adaptive algorithm: percent target linearly interpolated between
    -- (adaptive_short_minutes, adaptive_short_percent) and
    -- (adaptive_long_minutes, adaptive_long_percent), clamped at both
    -- ends - short videos need a bigger fraction watched to count,
    -- long ones a smaller one. adaptive_min_seconds is a floor under
    -- that percent, for degenerate very-short-duration edge cases.
    adaptive_short_minutes = 2,
    adaptive_short_percent = 70,
    adaptive_long_minutes = 20,
    adaptive_long_percent = 15,
    adaptive_min_seconds = 5,
}
options.read_options(opts, "mark_watched")

-- Named threshold-algorithm presets. immediate/seconds_only/percent_only/
-- near_completion are just different min_seconds/min_percent values, not
-- different logic - naming them here avoids hand-tuning the same handful
-- of combinations repeatedly. 101/1e9 are deliberate "never reached this
-- way" sentinels so the OR-check in the time-pos observer below still
-- degrades to a single effective condition without a separate code path.
local PROFILES = {
    immediate       = {min_seconds = 0,   min_percent = 0},
    seconds_only    = {min_seconds = 30,  min_percent = 101},
    percent_only    = {min_seconds = 1e9, min_percent = 50},
    balanced        = {min_seconds = 30,  min_percent = 50},
    near_completion = {min_seconds = 1e9, min_percent = 90},
}

-- Both validated once here, not inside threshold_targets() below - that
-- function runs on every time-pos tick, and a msg.warn there for an
-- invalid value would repeat dozens of times a second instead of once
-- (caught empirically while testing: the whole point of doing this once,
-- up front, isn't just style - it's what keeps a typo'd options file from
-- flooding the log).
if opts.algorithm ~= "threshold" and opts.algorithm ~= "adaptive" then
    msg.warn("unknown algorithm '" .. tostring(opts.algorithm) .. "', using threshold")
    opts.algorithm = "threshold"
end
if opts.profile ~= "custom" and not PROFILES[opts.profile] then
    msg.warn("unknown profile '" .. tostring(opts.profile) .. "', using custom min_seconds/min_percent")
    opts.profile = "custom"
end

-- Resolves the (target_seconds, target_percent) pair for the threshold
-- algorithm's current profile - a plain table lookup, "custom" simply
-- never being a PROFILES key is what makes it fall through to
-- min_seconds/min_percent below.
local function threshold_targets()
    local p = PROFILES[opts.profile]
    if p then return p.min_seconds, p.min_percent end
    return opts.min_seconds, opts.min_percent
end

-- Resolves the (target_seconds, target_percent) pair for the adaptive
-- algorithm: target_percent slides linearly between adaptive_short_percent
-- (at or below adaptive_short_minutes) and adaptive_long_percent (at or
-- above adaptive_long_minutes), clamped at both ends. A nil/unknown
-- duration is treated as 0 minutes (the short-video end of the scale) -
-- the min_seconds floor still applies either way.
local function adaptive_targets(duration)
    local minutes = (duration or 0) / 60
    local sm, sp = opts.adaptive_short_minutes, opts.adaptive_short_percent
    local lm, lp = opts.adaptive_long_minutes, opts.adaptive_long_percent
    local percent
    if minutes <= sm then
        percent = sp
    elseif minutes >= lm then
        percent = lp
    else
        percent = sp + (minutes - sm) / (lm - sm) * (lp - sp)
    end
    return opts.adaptive_min_seconds, percent
end

-- Strips a possible ytdl:// prefix ytdl_hook can leave on the live `path`
-- property (mirrors playlist_manager.lua/perpetual_playlist.lua's own
-- normalize_url) before matching against youtube.com/youtu.be.
local function is_youtube_url(path)
    if type(path) ~= "string" then return false end
    local url = path:gsub("^ytdl://", "")
    return url:match("^https?://[^/]*youtube%.com/") ~= nil
        or url:match("^https?://youtu%.be/") ~= nil
end

local current_url = nil
local marked_this_file = false
-- Seconds actually played this file, summed from small time-pos steps.
-- A seek is a big jump and is not counted, so skipping to 90% does not
-- count as having watched 90%.
local watched = 0
local last_pos = nil

-- No --cookies-from-browser here deliberately - relies on the
-- --cookies-from-browser already in yt-dlp's own global config
-- (~/.config/yt-dlp/config), same as playlist_manager.lua's and
-- ytdl-cache-wrapper's own bare `yt-dlp` calls already do implicitly -
-- keeps the machine-specific browser choice in one place instead of
-- duplicated here.
local function mark_watched(url)
    msg.info("marking watched: " .. url)
    mp.command_native_async({
        name = "subprocess",
        args = {"yt-dlp", "--simulate", "--mark-watched", url},
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            local err = res and res.stderr or ""
            msg.warn("failed to mark watched: " .. url .. (err ~= "" and (" (" .. err .. ")") or ""))
        else
            msg.debug("marked watched: " .. url)
        end
    end)
end

mp.register_event("file-loaded", function()
    marked_this_file = false
    watched = 0
    last_pos = nil
    local path = mp.get_property("path")
    if opts.enabled and is_youtube_url(path) then
        current_url = path:gsub("^ytdl://", "")
    else
        current_url = nil
    end
end)

-- A property observer, not a wall-clock mp.add_timeout, deliberately -
-- correctly tracks actual watched time (a pause doesn't advance
-- time-pos), at the cost of firing on every position update. Cheap once
-- marked (or once not a YouTube file): both early-return on their very
-- first check, so this never repeats ytdl_prefetch.lua's documented
-- near-end-of-video polling/audio-crackling issue (that was from real
-- per-call work - cache_key subprocess calls - concentrated at the tail
-- of every video; this is a couple of nil/boolean checks).
mp.observe_property("time-pos", "number", function(_, pos)
    if marked_this_file or not current_url or not pos then return end

    if last_pos then
        local delta = pos - last_pos
        if delta > 0 and delta <= 1 then
            watched = watched + delta
        end
    end
    last_pos = pos

    local duration = mp.get_property_number("duration")
    local target_seconds, target_percent
    if opts.algorithm == "adaptive" then
        target_seconds, target_percent = adaptive_targets(duration)
    else
        target_seconds, target_percent = threshold_targets()
    end

    if watched >= target_seconds then
        msg.debug(string.format(
            "%s: watched-seconds threshold hit (target %.1fs/%.0f%%)",
            current_url, target_seconds, target_percent))
        marked_this_file = true
        mark_watched(current_url)
        return
    end
    if duration and duration > 0 and (watched / duration * 100) >= target_percent then
        msg.debug(string.format(
            "%s: watched-percent threshold hit (target %.1fs/%.0f%%)",
            current_url, target_seconds, target_percent))
        marked_this_file = true
        mark_watched(current_url)
    end
end)

-- Safety net: a video that genuinely finishes (eof) before either
-- threshold was reached (very short clips, or a duration property that
-- was never available) is unambiguously "watched" regardless. Mirrors
-- perpetual_playlist.lua's own event.reason == "eof" idiom for detecting
-- genuine completion.
mp.register_event("end-file", function(event)
    if event.reason == "eof" and current_url and not marked_this_file then
        marked_this_file = true
        mark_watched(current_url)
    end
end)
