# brightness-sync — design

**Date:** 2026-10-30 · **Status:** design approved, implementation plan next

## Goal

When the MacBook's built-in display brightness changes — brightness keys, Control Center, or
auto-brightness — the external Samsung LS24A600U follows by changing its **hardware backlight**
over DDC/CI.

## Environment (verified 2026-10-30)

| | |
|---|---|
| Mac | MacBook Pro, Apple M3 Max, built-in Liquid Retina XDR with ambient light sensor |
| OS / toolchain | macOS 27.2, Xcode, Swift 6.4 |
| Monitor | Samsung LS24A600U, 2560×1440 @ 75 Hz, EDID vendor `0x4C2D`, model `0x7163` |
| Link | USB-C, DisplayPort end to end (I/O registry `Transport` = DP → DP) |
| Other brightness tools | None installed (no MonitorControl, Lunar, BetterDisplay) |

## Verified facts (feasibility probe)

1. **Reading built-in brightness.** `DisplayServicesGetBrightness(displayID, &float)` from the private
   `DisplayServices.framework` (loaded with `dlopen`/`dlsym`) returns 0…1 and reflects changes live
   inside a long-running process, without a run loop. `CoreDisplay_Display_GetUserBrightness` is stuck
   at 1.0 and is not usable.
2. **DDC channel.** The I/O registry has exactly one `DCPAVServiceProxy` with `Location = "External"`.
   `IOAVServiceCreateWithService` on it returns a handle; `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`
   (private IOKit symbols) with chip address `0x37` and data address `0x51` talk DDC/CI to the Samsung.
3. **Wire format.** Request checksum = XOR of `0x6E`, `0x51` and every payload byte. Reply checksum =
   XOR of `0x50` and every reply byte before it.
   - Get brightness (VCP `0x10`): `82 01 10 AC` → reply `6E 88 02 00 10 00 00 64 00 64 A4`
     (max 100, current 100).
   - Set brightness 50: `84 03 10 00 32 9A`; set 100: `84 03 10 00 64 CC`. Both confirmed by read-back.
     Each packet was written twice, 10 ms apart.
4. **macOS's own Samsung brightness** (`DisplayServicesSetBrightness` on the Samsung — the slider
   System Settings shows) changed only macOS's stored value; the monitor's DDC brightness stayed at 100.
   It is not used. That slider should stay at max.
5. `DisplayServicesAmbientLightCompensationEnabled` does not have the signature `(displayID) -> Bool`
   and crashes when called that way. Do not call it.

## Approach

Write the Samsung's hardware brightness directly over DDC (VCP `0x10`).

Rejected:
- **macOS's own Samsung brightness** — did not change the backlight in testing; at best it dims the
  image, which greys out blacks in a dark room.
- **Hybrid** (DDC down to the monitor's minimum, software dimming below it) — not needed yet.

## Architecture

A Swift package with a library target `BrightnessSyncCore` and an executable target
`brightness-sync`, started at login by a per-user LaunchAgent.

| Unit | Kind | Responsibility |
|---|---|---|
| `DDC` | pure | Encode "set VCP" and "get VCP" packets with checksums; decode and validate replies. |
| `BrightnessMapper` | pure | Map built-in brightness 0…1 to a monitor value: `round(min + (max − min) × clamp(b, 0, 1))`. Defaults `min = 0`, `max = 100`. |
| `SyncPolicy` | pure | Given the target, the last value successfully written, the time of that write, the current time and a *force* flag, decide whether to write now. |
| `BuiltInDisplay` | system | Find the built-in display (`CGDisplayIsBuiltin`); return its brightness 0…1, or `nil` when offline (lid closed) or asleep (`CGDisplayIsAsleep`). |
| `ExternalDDCDisplay` | system | Discover the external `DCPAVServiceProxy`, own the `IOAVService` handle, send packets built by `DDC`, report failures. |
| `main.swift` | glue | Parse flags, run the loop, log. |

Pure units import only Foundation and are fully unit-tested. System units are thin wrappers verified
on the real hardware.

## Data flow

Every 250 ms on the main thread:

1. Snapshot the online display IDs. If the set changed since the previous tick, drop the DDC handle
   and set *force*.
2. Read the built-in brightness. If `nil` (offline or asleep), skip the tick; on the first tick it is
   available again, set *force*.
3. `target = BrightnessMapper.map(brightness)`.
4. If `SyncPolicy` says write, make sure a DDC handle exists (discovering it per *Error handling*;
   if none is found, skip the tick), then send the set-brightness packet (twice, 10 ms apart).
   - Success: `lastWritten = target`, `lastWriteTime = now`, clear *force*.
   - Failure: drop the handle; leave `lastWritten` unchanged so the value is retried.

### SyncPolicy rules

- Write when *force* is set or `target != lastWritten`,
- but never sooner than 400 ms after the previous write. The loop keeps running, so the latest
  target is delivered as soon as the window opens.
- The first tick after start-up is a forced write.

Effect: a brightness-key press or an auto-brightness ramp produces a handful of whole-number writes
and no smooth fades, keeping DDC traffic to the monitor's controller and settings memory low.

## Error handling

- **No DDC handle:** rediscover right after a display change, otherwise at most every 5 s.
- **More than one external `DCPAVServiceProxy`:** use the first and log a warning (single-monitor scope).
- **Missing private symbol at start-up:** log which one and exit non-zero. launchd throttles the
  restarts; the log explains why.
- **Crash:** launchd `KeepAlive` restarts the agent.

## Interface and operations

- **CLI:** `brightness-sync [--min N] [--max N] [--verbose]`, with `0 ≤ min < max ≤ 100`. Invalid
  flags print usage and exit with status 64.
- **Logs:** stderr, redirected by launchd to `~/Library/Logs/brightness-sync.log`. Always log the
  start-up configuration, discovery results and errors; `--verbose` also logs every write.
- **Makefile:**
  - `make test` — `swift test`.
  - `make install [MIN=… MAX=…]` — release build, copy the binary to `~/.local/bin/brightness-sync`,
    render `~/Library/LaunchAgents/io.github.effekt3r.brightness-sync.plist` (absolute paths,
    `RunAtLoad`, `KeepAlive`), and (re)load it with `launchctl bootstrap gui/$UID`.
  - `make uninstall` — `launchctl bootout`, then remove the binary and the plist.
  - `make logs` — `tail -f` the log.

## Testing

**Unit tests (Swift Testing):**
- `DDC`: set packets for 50 and 100 equal the verified bytes; the get request equals `82 01 10 AC`;
  the captured reply decodes to current 100 / max 100; replies with a bad checksum, wrong opcode,
  non-zero result code or wrong VCP code are rejected; values above 255 use the high byte.
- `BrightnessMapper`: endpoints, rounding, custom min/max, out-of-range input clamped.
- `SyncPolicy`: first tick writes; unchanged target does not write; a change inside the 400 ms window
  waits, then writes the latest target; *force* writes an unchanged target; a failed write does not
  advance `lastWritten`.

**Live checklist (this Mac and monitor):**
1. Brightness keys up and down: the Samsung follows within about 0.5 s.
2. Auto-brightness: change the room lighting or cover the sensor next to the camera; the Samsung follows.
3. Display sleep and wake, Samsung power-cycle, unplug and replug: the value is re-sent.
4. Lid closed (clamshell): the agent idles without errors.
5. No double dimming from macOS's own Samsung slider. During probing, macOS's stored value for the
   Samsung moved once after a raw DDC write; confirm this is harmless.

## Non-goals

Menu bar UI, two-way sync, multiple external monitors, software dimming below the monitor's minimum,
smooth transitions, a signed or notarized app bundle.
