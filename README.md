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
- Swift 5.10+

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
    "iPhone": { "iPhone17,1": { "bezel": 62,   "name": "iPhone 16 Pro" } },
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
