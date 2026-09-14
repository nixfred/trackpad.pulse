# Changelog

Versions follow semver and live in `manifest.json`, which the panel header, the About page and `status` all read. Every release is tagged `vX.Y.Z`.

## 1.7.1 — 2026-09-14

- **The live chip survives a reboot.** `live.json` lives on tmpfs and was written only once a finger or the cursor moved, so after a reboot it did not exist when the shell first loaded the panel. The panel's `FileView` bound its watch to a missing path — a watch that never attaches when the file later appears — so the bar chip drew but never lit or counted until the shell was restarted, even though the recorder was running and every other file updated. The recorder now seeds an idle `live.json` at startup, before its first snapshot, and the panel's warm-up reload also reloads the live file, so the watch binds deterministically whichever process wins the boot race. No settings or data change.

## 1.7.0 — 2026-09-14

- **Every pad gets its own starting feel.** The Mac-inspired preset put the same gains on every pad. The recorder now measures each pad's width (the kernel's resolution, else udev's recorded size, else the size libinput itself assumes) and the widest screen, and the preset's gains scale with screen pixels per pad millimetre. The anchor is a 124 mm pad on a 1920-pixel screen, where the gains are exactly what Trackpad Plus ships; that anchor is a choice, not a measurement. A 160 mm pad on the same screen starts at 0.78×, a small pad on a wide desktop at up to 2×, clamped to 0.5–2. Fast swipes still stops at Device scale. Start and End are finger speeds and do not move. Optimize's first fit starts from the same sized gains.
- **Optimize tunes the pad it measured.** Sessions, the finger-speed histogram and the optimize log now carry the pad they came from, so a laptop pad and a Magic Trackpad no longer average into one curve. The standing check reviews the connected pad touched last, and auto-off follows it. History from before this release counts for either pad until it ages out of the week.
- **Every Mac.** Intel MacBooks (the kernel's `bcm5974`, which names no touchpad and sets no pointer property) are found by both the settings backend and the recorder, and their resolution-less pad is sized from libinput's Apple hint, 104 × 75 mm. T2 MacBooks, whose pad Hyprland calls `apple-inc.-apple-internal-keyboard-/-trackpad`, no longer fail name validation. A Magic Trackpad is its own settings group instead of sharing the built-in pad's; saved settings migrate to state version 5 with both keeping a copy, so nothing changes until you change one. Trackpad Pulse runs on Linux under Hyprland; this is Apple hardware there, not macOS.
- Recorder: `device` on sessions, a `pad_minutes` table, `device`, `hyprName`, `sizeSource` and `presetScale` on each pad, `screenPx` and `weekByDevice` in the snapshot; pads are also found by udev's own finger-tool test. Panel: the pointer-feel histogram is the selected pad's when more than one is known.

## 1.6.1 — 2026-09-14

- **The recorder starts on a fresh install.** `omarchy plugin add … --enable` publishes the panel but runs no installer, so on any machine installed that way the bar showed RECORDER OFFLINE and counted nothing until someone found **Start the recorder**. Once per load, if the snapshot is still stale after five seconds, the panel now asks the recorder to start itself. **Stop the recorder** leaves a `recorder-stopped` marker in the state dir and a stopped recorder stays stopped; **Start the recorder** clears it. No setting is touched.
- Recorder: `ensure-service` action.

## 1.6.0 — 2026-09-14

- **Stray touches.** The recorder now names touches that look accidental and moved the cursor: a *brush*, shorter than 0.25 s and 4 mm on a pad that had sat idle for 2 s, and a *rest*, a slow drift under 10 mm that began in the bottom thumb strip or a side edge. A click or a second finger means it was meant. Each session now records where it started, the idle gap before it, whether it clicked and how far the cursor moved. Counted on the Overview strip and the tooltip, kept per day, and mapped on the Touch lab (where they start).
- **Put back**, opt-in: 0.3 s after a stray touch lifts, if no finger is back on the pad and no mouse has moved the cursor since, the recorder warps the cursor to where it was before the finger landed, through Hyprland's own cursor dispatcher. The kernel already delivered the motion, so this is a put-back, not a block. A real move within a second of a put-back is counted as a regret, and the card says when the guard is fighting you. Never on by default.
- Touch lab: the day heatmap card, which the Overview hero carries since 1.4.1, becomes the Stray touches card with the map, the counts, the Put back switch and the state of Disable while typing.
- Recorder: `stray-guard-on`, `stray-guard-off` actions; `strays`, `strayReverts`, `strayRegrets` counters; `x0`, `y0`, `gap`, `cursor`, `stray` session columns; `strayHeat` in today.json; `strayGuard` in the snapshot and `strays` in the report.

## 1.5.0 — 2026-09-14

- **One change a pass, judged by the next.** Optimize now proposes a single change: the bigger miss of Start and End first, then Fast swipes, Precision, Scroll speed. Everything else the data would change is listed as *seen, waiting its turn*. The only exception is the first fit of a System or Flat profile, which sets the profile, Start and End together because a custom curve cannot exist with only one of them.
- **A logged reason to undo.** Every applied change carries what the next pass watches. A nudge must earn its keep: the rate it targeted has to fall by at least 2 points. A shape change is kept unless overshoot corrections or re-strokes rise by 5 points. Either is undone when the opposite fingerprint crosses its own trigger. The pass waits for 150 moves and 3 minutes of movement before judging, proposes nothing new while it waits, and writes the verdict and its reason into the log once. When the verdict is undo, the proposal is the undo itself with that reason, behind **Undo it**, and **Keep it anyway** logs your disagreement and moves on. An undone change is held until as many moves ask for it again. A value you changed by hand in the meantime is left alone.
- Report: the optimize history shows each pass's verdict and reason.
- Recorder: `optimize-keep` action; log rows carry `watch`, `judgement`, `judgeReason`, `hold`.

## 1.4.1 — 2026-09-14

- Overview: the touch heatmap now sits in the hero card beside the touch count, in the span left of the live speed readout.

## 1.4.0 — 2026-09-14

- **Fullscreen apps as gestures.** A new catalogue group with the default terminal and every launchable desktop entry on the machine, each opened as a fullscreen window. Omarchy's launchers detach through `setsid` and `uwsm-app`, so Hyprland's exec-rule prefix cannot follow them; the recorder launches, watches the client list for the window that appears, focuses it by address and fullscreens it. Searchable in every gesture dropdown.
- The live pad now rides in the header of every page except Overview, which has the hero-sized one, and About, which has its own.
- Overview no longer paints a red border on the palms card.
- Theme: the chip's disabled tint comes from the theme's muted colour instead of a fixed grey. Every colour in the panel is a theme role.
- Recorder: `open-fullscreen` action; `desktop_apps()` honours `XDG_DATA_HOME` and `XDG_DATA_DIRS`.

## 1.3.0 — 2026-09-14

- **Report page.** This week against last: distance, touches, clicks, active time, a bar per day, the busiest day and hour, palms rejected, and the last Optimize passes with what they changed.
- **Your hand.** Right or left, read from today's heatmap and where rejected palms land, with the reasons and a confidence.
- **Mouse vs trackpad.** Cursor motion with no finger on the pad is counted as a mouse; the Report shows the share of active time. **Auto-off**, opt-in: after 15 s of continuous mouse use the pad is switched off through Trackpad Plus's own per-device setting, and a tap or a 10 mm move on the pad switches it back on, because the kernel keeps reporting the pad while Hyprland ignores it. Never on by default.
- **Where you use it.** Each touch session is stamped with the focused window's class over the Hyprland socket; the Report lists the top windows by touches and distance for the week. The day table now keeps apps and mouse time.
- Recorder: `report`, `auto-off-on`, `auto-off-off` actions; `hand` and `mouse` in the snapshot. IPC: `report`.

## 1.2.0 — 2026-09-14

- **Gestures.** A new page assigns an action to every three- and four-finger swipe and pinch from a catalogue of 56: workspace slide, next and previous workspace, scratchpad, fullscreen, close, float, move, resize, focus in four directions, next, previous, random and picked **themes**, next and picked **backgrounds**, night light, the Omarchy menu, emoji, clipboard, keybindings, screenshots, recording, lock, screensaver, bar, do-not-disturb, terminal, browser, files, volume, mute, mic, audio output, brightness, media transport where playerctl exists, cursor zoom for pinches, and Trackpad Pulse itself. The panel writes one Lua file of `hl.gesture` lines into Omarchy's toggles through Trackpad Plus's hardened writer and asks Hyprland to reload. Suggested defaults are shown first and applied only on request.
- **Every clock.** Distance, touches, taps, clicks and active time over the trailing minute, the last hour, today, this week, this month, this year and all time. A per-day table is kept forever. Seven cards on the Overview, the full table in the Touch lab with touches per active hour.
- **Where you touch.** A per-day heatmap of finger positions over the pad, and touches per hour of the day, both in the Touch lab.
- **The standing check.** Every ten minutes the recorder re-runs the optimizer against the settings in use. When a proposal with real changes and at least medium confidence appears that you have not seen, the Optimize button and the Pointer feel tab light up and the Overview carries a one-line banner with Review and Later. Applying, dismissing or Later marks it seen until the proposal changes.
- Fix: the recorder crash-looped after 1.1.0 on a `today.json` written by 1.0.0, so counts and the live finger map froze. A missing counter is now merged in, and one bad tick can no longer stop the recording.
- Recorder: `hint`, `gestures-catalogue`, `gestures-apply`, `gestures-remove`, `theme-next`, `theme-prev`, `theme-random` actions; `days` table; ten-second buckets for the trailing minute.
- IPC: `gestures` opens the Gestures page.

## 1.1.0 — 2026-09-14

**Optimize for my hand.** The recorder now keeps one row per touch session for seven days and names the two fingerprints of a wrong curve as sessions end: an **overshoot correction** (a long move answered at once by a short move back) and a **re-stroke** (a long move continued at once in the same direction), plus their scroll equivalents.

- New button on Pointer feel. It fits Start to the speed below which 45% of your movement happens and End to the 90th percentile, then nudges Fast swipes, Precision and Scroll speed by at most 10% a pass when the correction or re-stroke rate in that speed band runs high. Each change comes with its reason and the evidence. Nothing changes until Apply, which goes through Trackpad Plus's journalled path, so Restore previous still works.
- Every applied pass is logged; the next pass judges it by the same rates since it was applied and by the target-practice time, which the curve editor now measures (median seconds from a target appearing to the click).
- A System or Flat profile gets a first fit: a custom curve from the Mac-inspired gains with your Start and End.
- Thin data fits the shape but withholds the gain nudges and says so. Both signals running high at once cancel and say so. A raise that would pass the chart ceiling points at Device scale instead.
- IPC: `optimize` opens Pointer feel with a fresh proposal.
- Recorder: `optimize` and `optimize-applied` actions; `sessions` table; `longMoves`, `corrections`, `restrokes`, `scrollCorrections`, `scrollRestrokes` counters.

## 1.0.0 — 2026-09-14

First release of Trackpad Pulse, forked from Trackpad Plus 2026.09.13.1.

- **The recorder** (`collectors/trackpad_pulse.py`, `trackpad-pulse.service`): reads the touchpad's evdev node without root when the user may, counts touches, taps, clicks, pointer moves, two-finger scrolls, pinches, three- and four-finger swipes and rejected palms, measures distance and speed in millimetres, keeps a time-weighted finger-speed histogram, and records one row per minute for seven days. Falls back to cursor-only telemetry from the Hyprland socket when the node is closed to the user.
- **Access model**: probes first; offers a udev `uaccess` rule scoped to `ID_INPUT_TOUCHPAD` through one polkit prompt, and removes it (and the ACL it granted) on request. Never asks for the `input` group.
- **The chip**: the bar entry is the pad itself, lit by live finger positions with trails, tap ripples and an idle scan line. No number. Right-click switches the pad off and on.
- **Overview**: today's counts, distance, peak and median speed, active time, an hour/day/week history graph and the finger-speed distribution with the curve's acceleration band shaded.
- **Pointer feel**: David Fano's editor with the recorded finger-speed histogram drawn under the curve and a plain-language reading of how the draft sits against it.
- **Controls**: Trackpad Plus's per-device controls on one screen, two columns, device scale in the open.
- **Touch lab**: every finger live, the pad's physical facts, access state and controls, this week's totals.
- **About**: version from the manifest, links, lineage.
- **IPC**: `open`, `close`, `show`, `hide`, `toggle`, `chooser`, `page`, `enable`, `status`.
- Nothing scrolls: every page fits a 1000-pixel-tall screen.
