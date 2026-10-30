# brightness-sync

Makes an external monitor follow your MacBook's screen brightness — brightness keys, Control Center
and auto-brightness — by setting the monitor's real backlight over DDC/CI.

Built and tested on a MacBook Pro (M3 Max, macOS 27) driving a Samsung LS24A600U over USB-C. It should
work with other DDC/CI monitors on Apple silicon whose brightness runs 0–100, one external monitor at
a time.

## Install

```sh
make install                 # build, copy to ~/.local/bin, start now and at every login
make install MIN=10 MAX=90   # use only part of the monitor's range
```

macOS shows a "Background Items Added" notice the first time; that's this agent.

## Use

Change the MacBook's brightness — keys, Control Center or auto-brightness — and the monitor follows
within about half a second. Press the brightness keys with the pointer on the MacBook's screen: with
the pointer on the external monitor, macOS may send them to that monitor's own slider instead.

Keep the monitor's own Brightness slider in System Settings → Displays at maximum. It is separate
from the backlight that brightness-sync drives.

```sh
make logs        # follow ~/Library/Logs/brightness-sync.log
make uninstall   # stop and remove
```

To watch every write, run `make uninstall`, then `.build/release/brightness-sync --verbose`.

## How it works

- Every 250 ms it reads the built-in display's brightness (`DisplayServicesGetBrightness`).
- It maps 0…1 onto `MIN…MAX` and writes VCP `0x10` (luminance) to the monitor with
  `IOAVServiceWriteI2C` once the value has moved ¾ of a step from the last one written, at most once
  every 0.4 s. The dead band stops a value hovering at a rounding boundary from flipping back and forth.
- It re-sends after display changes, after the built-in display wakes or the lid opens, and after a
  failed write.

Both APIs are private and may change in a future macOS release; if one disappears, the agent logs which
and launchd retries once a minute.
Design: [docs/superpowers/specs/2026-10-30-brightness-sync-design.md](docs/superpowers/specs/2026-10-30-brightness-sync-design.md).

## Development

```sh
make test
```
