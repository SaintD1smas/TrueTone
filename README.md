# TrueTone

A personal macOS menu-bar app that reproduces Apple's **True Tone** on an
**external monitor** (Xiaomi "Mi Monitor", 5K), driven by the MacBook's own
ambient-light sensor.

Target machine: MacBook Air M3 (`Mac15,12`), macOS 15.7.2, Apple Silicon.
Personal use only — private APIs are fair game, App Store is not a goal.

---

## Spike findings (2026-08-29)

Run the probe: `swift run ttprobe`  (add `--watch 20` to watch live fields,
`--cb` to also probe CoreBrightness — it destabilises the ObjC runtime in-process,
off by default).

### 1. Applying a white point to the Mi Monitor — OK

- CoreGraphics display id **2** = Mi Monitor, vendor `0x61a9`, model `0x27a1`,
  1024-entry gamma table, currently identity.
- `CGGetDisplayTransferByTable` / `CGSetDisplayTransferByTable` work → we drive the
  white point by scaling the per-channel transfer ramps. No root, no entitlement.
- The **built-in** panel also shows identity gamma while running real True Tone →
  Apple applies its shift in DCP/hardware, *below* CoreGraphics. So we cannot read
  Apple's live shift back, and we don't try to — we compute our own from the sensor.

### 2. Reading ambient light **and colour** — OK, unentitled

The sensor is an **STMicro VD6286** CRGB colour ALS
(`AppleSPUVD6286`, driver `com.apple.driver.AppleALSColorSensor`, `crgb = 1`).
It publishes a HID `AmbientLightSensor` event (type 12) on a vendor page
(`PrimaryUsagePage 0xFF00`, `PrimaryUsage 4`, transport SPU).

Read path — no entitlement, no TCC prompt, plain `swift build` binary:

```
client  = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
          IOHIDEventSystemClientSetMatching(client, NULL)          // match all
services = IOHIDEventSystemClientCopyServices(client)
for svc in services:
    ev = IOHIDServiceClientCopyEvent(svc, 12 /*ALS*/, 0, 0)
    if ev: value = IOHIDEventGetFloatValue(ev, 0xC0000 + offset)
```

Observed fields (`base = 12 << 16 = 0xC0000`), M3 Air, typical room light:

| offset | value      | meaning (historical IOKit layout) |
|-------:|-----------:|-----------------------------------|
| +0x00  | 150        | illuminance / lux                 |
| +0x01  | 1539       | raw channel 0                     |
| +0x02  | 1188       | raw channel 1                     |
| +0x03  | 1495       | raw channel 2                     |
| +0x04  | 1667       | raw channel 3                     |
| +0x06  | 1          | colour-space / channel flag       |
| +0x07  | 151.7      | colour component (fractional)     |
| +0x08  | 150.7      | colour component (fractional)     |
| +0x09  | 120.6      | ?                                 |
| **+0x0a** | **~4900** | **correlated colour temp, Kelvin** |
| +0x0b  | 150.7      | = +0x08                           |

`+0x0a` (CCT in Kelvin) is the clean, directly usable signal. Raw channels are
there if we want to refine chromaticity / tint. Exact channel→RGBC mapping and the
meaning of +0x07/+0x08 still need a `--watch` run under changing light.

`AppleSPUVD6286` also exposes `CurrentLux` as a plain ioreg property (lux only) —
a zero-dependency fallback.

### Verdict

**Path A — a real True Tone clone — is feasible.** Same sensor Apple uses, raw
CRGB + a ready CCT, all from an unsandboxed unentitled binary. Apply via gamma
tables on the Mi.

---

## Install (runs at login)

```
scripts/install.sh      # build release → ~/Applications/TrueTone.app → LaunchAgent
scripts/uninstall.sh    # stop + remove everything
```

`install.sh` registers `~/Library/LaunchAgents/com.dmitriy.truetone.plist`
(`RunAtLoad`, `KeepAlive` only on crash). Prefs live in
`~/Library/Preferences/com.dmitriy.truetone.plist`; `enabled` defaults to **on**.
On quit / SIGTERM / SIGINT the calibrated gamma is restored — a killed process
never leaves the Mi tinted. Errors go to `/tmp/truetone.log`.

Quick run without installing: `swift build && ./.build/debug/TrueTone`.
Env: `TRUETONE_DEBUG=1` (per-tick stderr log), `TRUETONE_FORCE_ON=1` (start on).

Menu: on/off · **Сила** slider (0–100 %) · live readout · 10 s test sweep · Выйти.

**Verified 2026-08-29:** enabled → Mi gamma top entry `R 1.000 / G 0.91 / B 0.78`
(≈5560 K screen) at ambient `~4900 K @ 150 lx`; gamma-readback matches; SIGTERM
restores identity.

### Menu-bar icon note

On the dev machine, macOS Sequoia has hidden **every** third-party menu-bar item
(`defaults read com.apple.controlcenter` → `NSStatusItem Visible Item-* = 0`), not
just this app's. The status item is created correctly (`button ok, isVisible
true`); macOS just isn't drawing it. Bring hidden items back with:

```
for i in $(seq 0 15); do defaults write com.apple.controlcenter "NSStatusItem Visible Item-$i" -bool true; done
killall ControlCenter
```

A menu-bar manager (e.g. Ice) is the durable fix if Sequoia keeps re-hiding them.

### Tuning the curve

`WhitePointModel` tunables: `maxAdapt 0.85`, `baseFrac 0.22`, `floor 3900 K`,
`tau 6 s`. Compare the Mi against the built-in (which runs real True Tone) and
adjust, or watch raw sensor fields with `swift run ttprobe --watch 30`.

## App design (v1)

Menu-bar app (`LSUIElement` / `.accessory`), ~1 Hz loop:

1. **AmbientSensor** — read `lux` + ambient `CCT` from the ALS event (above),
   with the ioreg `CurrentLux` fallback.
2. **WhitePointModel** — ambient → target display white:
   - partial adaptation from D65 (6500 K) toward ambient CCT, in mired space;
   - adaptation fraction scales with lux (less in dim light) and an Intensity
     setting; hard floor ~4000 K so it never goes orange;
   - exponential time-smoothing (τ ≈ 5–15 s) + dead-band → calm, True-Tone-like.
3. **DisplayController** — target CCT → per-channel gains (≤ 1.0), applied to the
   Mi via `CGSetDisplayTransferByTable`; re-apply on display-reconfig / wake;
   restore identity on disable / quit.
4. **MenuBarController** — on/off, Intensity slider, live readout
   ("ambient 4900 K → display 5800 K · 150 lx"), 10 s test sweep, launch-at-login.
5. **Settings** — `UserDefaults`.

Not in v1: DDC/CI, camera colour, driving the built-in display, CoreBrightness
toggle, per-lighting calibration profiles.

## Layout

```
Sources/
  ttprobe/          hardware-discovery probe (dev tool, keep)
  TrueTone/         the app
```
