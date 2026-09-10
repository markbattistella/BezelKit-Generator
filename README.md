<div align="center">

<img alt="BezelKit Generator icon" src="https://raw.githubusercontent.com/markbattistella/BezelKit/main/data/kit-icon.png" width="128" height="128"/>

# BezelKit — Generator

<small>Perfecting Corners, One Radius at a Time</small>

![Language](https://img.shields.io/badge/Language-Swift-white?labelColor=orange&style=flat)
![Platform](https://img.shields.io/badge/Platform-macOS_13%2B-white?labelColor=gray&style=flat)
![Licence](https://img.shields.io/badge/Licence-MIT-white?labelColor=blue&style=flat)

</div>

## Overview

The Generator is a Swift CLI tool that extracts device bezel (corner radius) data from iOS Simulators and writes the results into the `BezelKit` package resource.

It uses a SwiftUI app (`FetchBezel`) that reads the private `UIScreen._displayCornerRadius` API from within a simulator — keeping the public-facing package completely free of private API usage.

## Requirements

- macOS 13 or later
- Xcode with at least one iOS Simulator runtime installed
- Swift 6.0+

Pure Swift — no external toolchain required.

## Building

From the `Generator/` directory:

```bash
swift build
```

Dependencies are resolved automatically on first build.

## Usage

Run from the `Generator/` directory of the BezelKit repo:

```bash
swift run BezelGenerator
```

This processes any devices listed in `pending` inside `apple-device-database.json`, boots the corresponding simulators, captures their bezel values, and updates both the cache database and the minified package resource.

### Subcommands

| Command | Description |
| ------- | ----------- |
| `generate` *(default)* | Process pending devices and update the database |
| `scan` | Discover devices from Xcode's device type catalog and reconcile the database |
| `generate-docs` | Regenerate `SupportedDeviceList.md` from `bezel.min.json` |
| `test` | Test the full pipeline on one simulator without touching the database |

---

### `generate` — process pending devices

```bash
swift run BezelGenerator
# or explicitly:
swift run BezelGenerator generate
```

| Option | Default | Description |
| ------ | ------- | ----------- |
| `--database` | `./apple-device-database.json` | Path to the device database JSON |
| `--project` | `./FetchBezel/FetchBezel.xcodeproj` | Path to the FetchBezel Xcode project |
| `--scheme` | `FetchBezel` | Xcode scheme name |
| `--bundle-id` / `-b` | `com.markbattistella.FetchBezel` | App bundle ID |
| `--output` | `../Sources/BezelKit/Resources/bezel.min.json` | Output path for the minified resource |
| `--app-output` | `./output` | Xcode build output directory |
| `--verbose` / `--no-verbose` | enabled | Toggle terminal output |

---

### `scan` — discover devices without booting anything

```bash
swift run BezelGenerator scan
```

Every `.simdevicetype` bundle Xcode installs carries the display corner radius as static
data, in `Contents/Resources/capabilities.plist` under `DeviceCornerRadius`. `scan` reads
that catalog directly, so discovering devices costs milliseconds instead of one simulator
boot each — and needs no simulator runtimes installed at all.

The plist is not a blanket replacement for the runtime value. Measured against the
simulator-verified entries already in the database, it has two known failure modes:

- **Lossy rounding.** iPhone 12 / 12 Pro / 12 Pro Max store `47`/`53` where the runtime
  reports `47.33`/`53.33`. The same chassis in the iPhone 13 generation stores the full
  `47.33333206176758`, so the precision loss is a per-generation authoring slip.
- **Panel geometry vs. reported geometry.** iPad Air (3rd generation) stores `18`, but iOS
  reports `0` because it does not mask the display corners.

So `scan` does not take the catalog at its word. Each value is triaged first:

| Condition | Action |
| --------- | ------ |
| Value is fractional | Trust — it has not been rounded |
| Whole, and a device sharing its `chromeIdentifier` is already verified at that radius | Trust |
| Whole, but verified devices in that chassis family disagree | Boot a simulator |
| Whole, and no verified device exists yet in that chassis family | Boot a simulator |

`chromeIdentifier` is Apple's chassis-design ID from `profile.plist` — devices sharing one
are the same physical design, which is what makes cross-device corroboration meaningful.
Only entries marked `"source": "simulator"` may corroborate; otherwise a single bad reading
could bootstrap itself into looking verified.

Two further rules keep the ground truth safe:

- A value already marked `"source": "simulator"` is **never** overwritten from a plist. Only
  a fresh boot can change it.
- Device names come from Xcode, which is authoritative for labelling.

| Option | Default | Description |
| ------ | ------- | ----------- |
| `--verify` | `flagged` | `none`, `flagged`, or `unverified` — see below |
| `--apply` | off | Write results. Without it, `scan` only reports |
| `--summary` | *(none)* | Write a markdown summary of the run to this path |
| `--profiles-path` | *(auto)* | Directory of `.simdevicetype` bundles. Repeatable |
| `--database` | `./apple-device-database.json` | Path to the device database JSON |
| `--output` | `../Sources/BezelKit/Resources/bezel.min.json` | Output path for the minified resource |
| `--project`, `--scheme`, `--bundle-id`, `--app-output` | *(same as generate)* | Used when booting simulators |
| `--verbose` / `--no-verbose` | enabled | Toggle terminal output |

#### Verification modes

| Mode | Behaviour |
| ---- | --------- |
| `none` | Never boot. Report only — a fast look at what changed |
| `flagged` | Boot only devices the triage could not vouch for |
| `unverified` | Boot everything not yet simulator-confirmed: flagged devices, every newly discovered device, and every entry still marked `"source": "profile"` from an earlier run |

`unverified` is the mode for scheduled CI. It closes the one gap in the triage — a reused
chassis ID whose rounded value happens to match an existing peer — by confirming every new
device outright, and it promotes older profile-derived values to ground truth as soon as a
runtime for them exists. No value stays plist-derived indefinitely.

```bash
# Fast local look at what a new Xcode has added
swift run BezelGenerator scan --verify none

# Apply, booting simulators only where the triage is unsure
swift run BezelGenerator scan --apply

# Scheduled CI: confirm everything not yet simulator-verified
swift run BezelGenerator scan --apply --verify unverified --summary summary.md
```

---

### `test` — verify the pipeline without modifying the database

```bash
swift run BezelGenerator test --name "iPhone 16 Pro"
```

Boots the named simulator, reads its bezel value, and tears everything down — without reading or writing `apple-device-database.json`. Use this to verify the pipeline works for a specific device before adding it to `pending`.

| Option | Default | Description |
| ------ | ------- | ----------- |
| `--name` / `-n` | *(required)* | Simulator display name to test |
| `--project`, `--scheme`, `--bundle-id`, `--app-output` | *(same as generate)* | Same options as `generate` |

---

### `generate-docs` — regenerate the supported device list

```bash
swift run BezelGenerator generate-docs
```

Reads `bezel.min.json` and writes `SupportedDeviceList.md` in the repo root. This is also called automatically by the pre-push git hook.

| Option | Default | Description |
| ------ | ------- | ----------- |
| `--input` | `../Sources/BezelKit/Resources/bezel.min.json` | Path to the minified JSON |
| `--output` | `../SupportedDeviceList.md` | Output path for the markdown file |

---

## Database Structure

All device data lives in `apple-device-database.json`:

```json
{
  "_metadata": { "Author": "...", "Project": "...", "Website": "..." },
  "devices": {
    "iPad":   { "iPad16,1":   { "bezel": 21.5, "name": "iPad mini (A17 Pro)" } },
    "iPhone": { "iPhone17,1": { "bezel": 62,   "name": "iPhone 16 Pro", "source": "simulator" } },
    "iPod":   {}
  },
  "pending": {
    "iPhone18,1": { "name": "iPhone 17 Pro" }
  },
  "problematic": {}
}
```

| Section | Purpose |
| ------- | ------- |
| `devices` | Processed devices with confirmed bezel values, split by `iPad`, `iPhone`, and `iPod` |
| `source` | How a value was obtained: `simulator` (booted, ground truth) or `profile` (read from Xcode's catalog and accepted by `scan`). A missing value means `simulator`. Written only to this file — never to `bezel.min.json` |
| `pending` | Devices queued for processing on the next `generate` run |
| `problematic` | Devices that could not be processed (no simulator runtime available); automatically retried on every run |

### Adding new devices

1. Add the device identifier and its simulator display name to `pending` in `apple-device-database.json`:

    ```json
    "pending": {
      "iPhone18,1": { "name": "iPhone 17 Pro" }
    }
    ```

    The name must match the **Device Type** shown in Xcode's *Create New Simulator* screen.

    ![Add New Simulator](https://raw.githubusercontent.com/markbattistella/BezelKit/main/data/simulator.jpg)

2. Run the generator:

    ```bash
    swift run BezelGenerator
    ```

Identifiers that share the same simulator name (e.g. Wi-Fi and Cellular variants) are grouped and processed in a single simulator boot — the bezel value is written to all matching identifiers automatically.

### Success and failure

| Outcome | Result |
| ------- | ------ |
| Simulator boots and returns data | Entry moves from `pending` → `devices` with the captured bezel value |
| No runtime available for the device | Entry moves from `pending` → `problematic`; retried automatically on future runs |

## Contributing

Contributions are welcome. If you find a bug or want to add device support, please open an issue or pull request.

> [!Note]
> Pull request titles must follow this format:
>
> ```text
> YYYY-mm-dd - {title}
> eg. 2025-03-01 - Add iPhone 17 series
> ```

## Licence

Released under the MIT licence. See [LICENCE](./LICENCE) for details.
