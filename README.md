# brightness-sync

Makes an external monitor follow your MacBook's screen brightness — brightness keys, Control Center
and auto-brightness — by setting the monitor's real backlight over DDC/CI, and dimming its picture
where the backlight can't go any lower.

Built and tested on a MacBook Pro (M3 Max, macOS 27) driving a Samsung LS24A600U over USB-C. It should
work with other DDC/CI monitors on Apple silicon whose brightness runs 0–100, one external monitor at
a time.

## Before you install

Turn **High Dynamic Range off** for the monitor (System Settings → Displays → the monitor). In HDR mode
the monitor ignores brightness commands: it stores each value, but the backlight doesn't change. (The
Brightness slider macOS shows for the monitor while HDR is on dims the picture in software instead.)

## Install

```sh
make install                    # build, copy to ~/.local/bin, start now and at every login
make install MIN=10 MAX=90      # use only part of the monitor's range
make install DIM_BELOW=0.25     # start dimming the picture sooner (0 turns picture dimming off)
```

macOS shows a "Background Items Added" notice the first time; that's this agent.

## Use

Change the MacBook's brightness — keys, Control Center or auto-brightness — and the monitor follows
within about half a second. Press the brightness keys with the pointer on the MacBook's screen.

```sh
make logs        # follow ~/Library/Logs/brightness-sync.log
make uninstall   # stop and remove
```

To watch every write, run `make uninstall`, then `.build/release/brightness-sync --verbose`.

## How it works

- Every 250 ms it reads the built-in display's light output (`DisplayServicesGetLinearBrightness`) as a
  fraction of its output at full slider. It doesn't use the slider position: that scale is perceptual,
  and in its bottom half each key step changes the light output about 1.8×.
- It maps that fraction onto `MIN…MAX` and writes VCP `0x10` (luminance) to the monitor with
  `IOAVServiceWriteI2C` once the value has moved ¾ of a step from the last one written, at most once
  every 0.4 s. The dead band stops a value hovering at a rounding boundary from flipping back and forth.
- The monitor's backlight can't get as dark as the MacBook's panel, so below `DIM_BELOW` (15%) of full
  output it also dims the picture in proportion by scaling the monitor's gamma table, never below 3%.
  macOS restores the picture when the agent stops.
- It re-sends after display changes, after the built-in display wakes or the lid opens, and after a
  failed write, and re-checks the monitor for 30 s after each of those events, because the LS24A600U has
  been seen to jump to a different brightness a few seconds after waking.

Both brightness APIs are private and may change in a future macOS release; if one disappears, the agent
logs which and launchd retries once a minute.
Design: [docs/superpowers/specs/2026-10-30-brightness-sync-design.md](docs/superpowers/specs/2026-10-30-brightness-sync-design.md).

## Development

```sh
make test
```
