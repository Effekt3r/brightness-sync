# brightness-sync — design

**Date:** 2026-10-30 · **Status:** implemented 2026-10-31, updated after code review and live tuning

## Goal

When the MacBook's built-in display brightness changes — brightness keys, Control Center, or
auto-brightness — the external Samsung LS24A600U follows by changing its **hardware backlight**
over DDC/CI, dimming its picture where the backlight can't go any lower.

## Environment (verified 2026-10-30)

| | |
|---|---|
| Mac | MacBook Pro, Apple M3 Max, built-in Liquid Retina XDR with ambient light sensor |
| OS / toolchain | macOS 27.2, Xcode, Swift 6.4 |
| Monitor | Samsung LS24A600U, 2560×1440 @ 75 Hz, EDID vendor `0x4C2D`, model `0x7163` |
| Link | USB-C, DisplayPort end to end (I/O registry `Transport` = DP → DP) |
| Required setting | High Dynamic Range **off** for the monitor (see verified fact 7) |
| Other brightness tools | None installed (no MonitorControl, Lunar, BetterDisplay) |

## Verified facts

1. **Reading the built-in display.** The private `DisplayServices.framework` (loaded with
   `dlopen`/`dlsym`) answers over XPC from the brightness daemon on every call, so values are live in a
   long-running process without a run loop.
   - `DisplayServicesGetBrightness(displayID, &float)` is the slider position, 0…1. The scale is
     perceptual (see fact 9), so it is not used to drive the monitor.
   - `DisplayServicesGetLinearBrightness(displayID, &float)` is the light output; it reads 2/3 at full
     slider on this MacBook Pro.
   - `CoreDisplay_Display_GetUserBrightness` and `CoreDisplay_Display_GetLinearBrightness` are stuck at
     1.0, and `CoreDisplay_Display_GetDisplayBrightnessInNits` crashes when called as `(id) -> Double`.
2. **DDC channel.** The I/O registry has exactly one `DCPAVServiceProxy` with `Location = "External"`.
   `IOAVServiceCreateWithService` on it returns a handle; `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`
   (private IOKit symbols) with chip address `0x37` and data address `0x51` talk DDC/CI to the Samsung.
3. **Wire format.** Request checksum = XOR of `0x6E`, `0x51` and every payload byte. Reply checksum =
   XOR of `0x50` and every reply byte before it.
   - Get brightness (VCP `0x10`): `82 01 10 AC` → reply `6E 88 02 00 10 00 00 64 00 64 A4`
     (max 100, current 100).
   - Set brightness 50: `84 03 10 00 32 9A`; set 100: `84 03 10 00 64 CC`. Both confirmed by read-back.
     Each packet was written twice, 10 ms apart.
4. **macOS's own Samsung brightness** (`DisplayServicesSetBrightness` on the Samsung, the slider System
   Settings shows) only exists because HDR was on (fact 7): it dims the picture in software and never
   changed the monitor's DDC brightness. It is not used.
5. `DisplayServicesAmbientLightCompensationEnabled` does not have the signature `(displayID) -> Bool`
   and crashes when called that way. Do not call it.
6. **Something resets the Samsung after a wake.** In three sleep/wake tests (2026-10-31, HDR on) the
   monitor kept answering DDC with the agent's last value through sleep, then jumped to a different
   value (100, or an older one) about 3–5 s after the displays woke, after the agent's resend. Whether
   the monitor or macOS does this is unknown. `CGDisplayIsAsleep` updates live in the agent.
7. **HDR blocks the backlight.** With High Dynamic Range on, macOS reports 10× EDR headroom for the
   Samsung and the monitor ignores DDC brightness: it stores and reads back each value, but the backlight
   doesn't change. This is why the brightness keys first seemed to do nothing. With HDR off the backlight
   follows (confirmed by the user, 2026-10-31).
8. **Picture dimming.** `CGSetDisplayTransferByFormula` on the Samsung scales its picture; its normal
   gamma table is linear. macOS restores the table when the process that set it exits, so a crash or an
   uninstall never leaves the picture dimmed.
9. **The slider is perceptual.** Light output (`DisplayServicesGetLinearBrightness`) against slider
   position, measured 2026-10-31:

   | Slider | 1/16 | 2/16 | 3/16 | 4/16 | 6/16 | 8/16 | 10/16 | 12/16 | 14/16 | 16/16 |
   |---|---|---|---|---|---|---|---|---|---|---|
   | Linear | 0.0033 | 0.0061 | 0.0112 | 0.0206 | 0.0693 | 0.2333 | 0.2913 | 0.3746 | 0.4945 | 0.6670 |

   In the bottom half each key step multiplies the output by about 1.8; the top half only triples it.

## Approach

Drive the Samsung's hardware brightness over DDC (VCP `0x10`) from the MacBook's **light output**, not
its slider position, so both screens dim in proportion. Below the point where the Samsung's backlight
can't follow, also dim its picture through the gamma table.

Rejected:
- **macOS's own Samsung brightness**: it only exists with HDR on, and it dims the picture in software,
  which greys out blacks in a dark room.
- **Slider position mapped straight onto 0–100**: the first implementation. The Samsung stayed far too
  bright as the MacBook dimmed (fact 9).

## Architecture

A Swift package with a library target `BrightnessSyncCore` and an executable target
`brightness-sync`, started at login by a per-user LaunchAgent.

| Unit | Kind | Responsibility |
|---|---|---|
| `DDC` | pure | Encode "set VCP" and "get VCP" packets with checksums; decode and validate replies. |
| `BrightnessMapper` | pure | Map built-in brightness 0…1 to a monitor value: `level = min + (max − min) × clamp(b, 0, 1)`, written as `round(level)`; and to a picture level, `b / dimBelow` below `dimBelow` (never under 0.03), else 1. Defaults `min = 0`, `max = 100`, `dimBelow = 0.15`. |
| `SyncPolicy` | pure | Given the unrounded level, the last value successfully written, the time of that write, the current time and a *force* flag, decide whether to write now. |
| `Options` | pure | Parse and validate the command-line flags. |
| `Syncer` | pure | The data flow below, one step per tick; talks to the hardware only through the `BrightnessSource`, `MonitorLink` and `PictureDimmer` protocols, so it is unit-tested with fakes. |
| `BuiltInDisplay` | system | Find the built-in display (`CGDisplayIsBuiltin`); return its light output as a fraction of the output at full slider (`linear / (2/3)`, clamped to 0…1), or `nil` when offline (lid closed), asleep (`CGDisplayIsAsleep`) or unreadable. |
| `ExternalDDCDisplay` | system | Discover the external `DCPAVServiceProxy`, own the `IOAVService` handle, send packets built by `DDC`, report failures. |
| `ExternalGamma` | system | Scale the external display's gamma table to a picture level; restore ColorSync's table at 1. |
| `BrightnessSync.swift` | glue | Entry point (`@main`): parse flags, build the adapters, call `Syncer.tick` every 250 ms, log. |

Pure units import only Foundation and are fully unit-tested. System units are thin wrappers verified
on the real hardware.

## Data flow

Every 250 ms on the main thread:

1. Snapshot the online display IDs. If the set changed since the previous tick, drop the DDC handle,
   set *force*, and re-apply any picture dimming on this tick.
2. Read the built-in brightness. If `nil` (offline, asleep or unreadable), restore the Samsung's
   picture to full (with the lid closed nothing else would) and skip the tick; on the first tick it is
   available again, set *force*.
3. Apply `BrightnessMapper.pictureLevel(brightness)` through `PictureDimmer` when it differs by at
   least 0.005 from the applied level, and every 2 s while it is below 1, because macOS resets gamma
   tables on events such as wake.
4. `level = BrightnessMapper.level(brightness)`; the value written is `target = round(level)`.
5. If `SyncPolicy` says write, make sure a DDC handle exists (discovering it per *Error handling*;
   if none is found, skip the tick), then send the set-brightness packet twice, 10 ms apart. The
   write counts as delivered if either send is accepted.
   - Success: `lastWritten = target`, `lastWriteTime = now`, clear *force*.
   - Failure: drop the handle and set *force*, because the value may have reached the panel anyway;
     leave `lastWritten` unchanged so the value is retried.

### Re-checking after events

After start-up, a display change, or the built-in display coming back (wake, lid opened), the agent
re-reads the monitor's brightness 2, 4, 6, 8, 10, 15, 20 and 30 s later. If it is more than 1 away from
`lastWritten`, it logs the drift and sets *force*, so the value is resent on the same tick. Checks are
scheduled only by those events, never by a correction, so a monitor that always reads back differently
costs at most eight extra writes per event. This exists because of verified fact 6.

### SyncPolicy rules

- Write when *force* is set or `level` is at least 0.75 of a step away from `lastWritten` — a 0.25
  dead band past the rounding midpoint, so a level hovering at x.5 doesn't flip the monitor back and
  forth,
- but never sooner than 400 ms after the previous write. The loop keeps running, so the latest
  target is delivered as soon as the window opens. A negative interval (the clock stepped back)
  counts as expired, here and for the 5 s rediscovery backoff.
- The first tick after start-up is a forced write.

Effect: a brightness-key press or an auto-brightness ramp produces a handful of whole-number writes
and no smooth fades, keeping DDC traffic to the monitor's controller and settings memory low. Picture
dimming goes through the gamma table only, never the monitor.

## Error handling

- **No DDC handle:** rediscover right after a display change, otherwise at most every 5 s.
- **More than one external `DCPAVServiceProxy`:** use the first and log a warning (single-monitor scope).
- **Missing private symbol at start-up:** log which one and exit non-zero. launchd restarts the agent
  at most once a minute (`ThrottleInterval` 60); the log explains why.
- **Picture dimming fails:** log it once; the backlight keeps following.
- **Crash:** launchd `KeepAlive` restarts the agent; macOS has already restored the picture (fact 8).
- **Logging:** a log write that fails (for example, a full disk) is dropped instead of crashing.

## Interface and operations

- **CLI:** `brightness-sync [--min N] [--max N] [--dim-below F] [--verbose]`, with
  `0 ≤ min < max ≤ 100` and `0 ≤ F < 1` (`0` turns picture dimming off). Invalid flags print usage and
  exit with status 64.
- **Logs:** stderr, redirected by launchd to `~/Library/Logs/brightness-sync.log`. Always log the
  start-up configuration, discovery results, picture dimming starting and stopping, and errors; a status
  message identical to the previous one on the same topic is dropped, except that a reconnection after
  a display change is always logged. `--verbose` also logs every write and picture change.
- **Makefile:**
  - `make test` — `swift test`.
  - `make install [MIN=… MAX=… DIM_BELOW=…]` — release build; validate the options with the new binary
    before the running agent is touched; copy the binary to `~/.local/bin/brightness-sync`; render
    `~/Library/LaunchAgents/io.github.effekt3r.brightness-sync.plist` (absolute paths, `RunAtLoad`,
    `KeepAlive`, `ThrottleInterval` 60); (re)load it with `launchctl bootstrap gui/$UID`.
  - `make uninstall` — `launchctl bootout`, then remove the binary and the plist.
  - `make logs` — `tail -F` the log.

## Testing

**Unit tests (Swift Testing):**
- `DDC`: set packets for 50 and 100 equal the verified bytes; the get request equals `82 01 10 AC`;
  the captured reply decodes to current 100 / max 100; replies with a bad checksum, wrong opcode,
  non-zero result code or wrong VCP code are rejected; values above 255 use the high byte.
- `BrightnessMapper`: endpoints, rounding, unrounded level, custom min/max, out-of-range input clamped;
  picture level in proportion below the threshold, never black, off at threshold 0.
- `BuiltInDisplay.relativeOutput`: scaled to the value at full slider, clamped above it.
- `SyncPolicy`: first tick writes; unchanged target does not write; a change inside the 400 ms window
  waits, then writes the latest target; *force* writes an unchanged target; a level hovering at a
  rounding boundary is not rewritten; a clock that steps back does not block writes; a failed write
  does not advance `lastWritten`.
- `Syncer` (fake source, monitor and dimmer): first write; no rewrite when unchanged; rate limit; no
  chatter at a rounding boundary; replug; built-in display returning; failed-write retry, including the
  forced resend when the target returns to the last written value; clock stepping back; missing-monitor
  backoff; drift after a wake corrected; corrections bounded per event; picture dimmed below the
  threshold and restored above it, re-applied every 2 s, restored while the built-in display is
  unavailable; log messages.
- `Options` (including `--dim-below`, and that `--help` still validates the options, which
  `make install` relies on) and `PrivateSymbol` lookups.

**Live checklist (this Mac and monitor):**
1. Brightness keys up and down: the Samsung follows within about 0.5 s, and the two screens look
   matched across the range.
2. Auto-brightness: change the room lighting or cover the sensor next to the camera; the Samsung follows.
3. Display sleep and wake, Samsung power-cycle, unplug and replug: the value is re-sent.
4. Lid closed (clamshell): the agent idles without errors and the Samsung's picture is at full.

**Live results (2026-10-31, installed agent):**
- Item 1 — passed. The keys first seemed to do nothing because HDR was on (fact 7). With HDR off the
  Samsung followed, but its levels didn't match until the agent switched to the light output (fact 9)
  and added picture dimming; the user confirmed both screens now match across the range. Picture
  dimming checked: MacBook at 2/16 → Samsung DDC 1 with its picture at 6%; back at full → DDC 100,
  picture restored.
- Item 3, display sleep and wake — passed after the fix in *Re-checking after events*: sleep is detected
  at once; the reset to 100 after waking was corrected about 1 s later (HDR on at the time).
- Not yet run, because they need someone at the Mac: item 2 (auto-brightness), the power-cycle and
  unplug parts of item 3, and item 4 (lid closed).

## Non-goals

Menu bar UI, two-way sync, multiple external monitors, smooth transitions, a signed or notarized app
bundle.
