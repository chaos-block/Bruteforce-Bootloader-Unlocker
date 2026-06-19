# Bruteforce Bootloader Unlocker

Script-only Fastboot helper for authorized bootloader unlock attempts on Android devices. It can send unlock commands, detect common Fastboot unlock flows, and generate candidate unlock codes from prioritized pattern masks.

> **Use only on devices you own or are explicitly authorized to service.** This project does not bypass carrier locks, OEM policy blocks, Factory Reset Protection, or hardware restrictions.

## Features

- **Fastboot-first device support:** targets devices that expose bootloader unlock over Fastboot or Fastboot-like modes.
- **Command profile autodetect:** selects common unlock flows when safe to infer:
  - `fastboot flashing unlock`
  - `fastboot oem unlock <code>`
  - manual profiles for other Fastboot variants
- **Pattern DSL:** express likely code formats such as `X{20}`, `A{19}9`, `9{6}`, `H{32}`.
- **Priority scheduler:** smart mode weights higher-probability patterns before broader fallbacks.
- **Persistent resume:** stores device-specific settings and offsets in `<device>.dat`.
- **Hard safety stops:** exits when no Fastboot device is present or multiple devices are connected.
- **Clear terminal UI:** shows command profile, pattern schedule, offsets, and progress.

## Compatibility

### Supported targets

This script is intended for Android devices that:

1. Have **OEM unlocking enabled** in Developer Options, and
2. Accept bootloader unlock through Fastboot/Fastboot-like commands.

Known Fastboot-style families include Pixel / AOSP-style devices, Motorola devices, OnePlus-style devices, and other OEMs that expose standard Fastboot unlock behavior. Some OEMs require official portals or vendor tools before any Fastboot command will work.

### Not supported

- Carrier-locked devices where OEM unlocking is greyed out
- Devices blocked by FRP / enterprise policy / OEM policy
- Vendor unlock tools that do not expose a Fastboot unlock command
- Mobile ADB clients such as BugJaeger or Termux ADB
- Windows PowerShell script execution in this repo

## Requirements

- Linux or WSL shell with Bash
- Android SDK Platform Tools (`fastboot` in PATH)
- USB cable and working USB permissions
- Device in bootloader/Fastboot mode
- Legal authorization to unlock the device

`adb` is optional. It is useful for `adb reboot bootloader`, but the unlock loop itself uses Fastboot.

## Windows / WSL setup

This repo no longer ships Windows PowerShell support. Recommended Windows path:

1. Install [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools) on Windows.
2. Add `platform-tools` to Windows `PATH`.
3. Install WSL.
4. From WSL, either ensure `fastboot.exe` is on PATH or set `FASTBOOT_BIN`:

   ```bash
   fastboot.exe devices
   FASTBOOT_BIN=fastboot.exe ./bootloader_unlocker
   ```

If `fastboot` is missing but `fastboot.exe` is on PATH, the script automatically falls back to `fastboot.exe`. Using Windows `fastboot.exe` from WSL often gives more reliable USB device detection than Linux Fastboot inside WSL.

## Installation

```bash
git clone https://github.com/samuelcaldas/bruteforce-bootloader-unlocker.git
cd bruteforce-bootloader-unlocker
chmod +x bootloader_unlocker
```

Install Fastboot on Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install android-tools-fastboot
```

## Usage

1. Enable Developer Options.
2. Enable **OEM unlocking**.
3. Boot device into Fastboot mode:

   ```bash
   adb reboot bootloader
   ```

4. Confirm exactly one device is visible:

   ```bash
   fastboot devices
   ```

5. Run:

   ```bash
   ./bootloader_unlocker
   ```

6. Type `AUTHORIZED` when prompted.

## Command profiles

Default profile is `auto`.

```bash
./bootloader_unlocker --command auto
```

Manual profiles:

```bash
./bootloader_unlocker --command flashing-unlock
./bootloader_unlocker --command flashing-unlock-code
./bootloader_unlocker --command oem-unlock-code
./bootloader_unlocker --command oem-unlock
./bootloader_unlocker --command oem-unlock-go
```

Notes:

- `flashing-unlock`, `oem-unlock`, and `oem-unlock-go` do not take candidate codes. Script sends the command once, then the device may ask for confirmation.
- `oem-unlock-code` and `flashing-unlock-code` use generated codes.
- Autodetect uses safe probes such as unlock ability, unlock-data response, and product info. It does not fire destructive unlock commands as probes.

## Pattern DSL

Pattern symbols:

| Symbol | Meaning | Charset |
|---|---|---|
| `9` | digit | `0-9` |
| `A` | uppercase letter | `A-Z` |
| `a` | lowercase letter | `a-z` |
| `X` | uppercase alphanumeric | `A-Z0-9` |
| `x` | mixed alphanumeric | `A-Za-z0-9` |
| `H` | uppercase hex | `0-9A-F` |
| `h` | lowercase hex | `0-9a-f` |
| `?` | active charset | selected by `--type` |

Repeats use `{n}`:

```text
X{20}       # 20 uppercase alphanumeric chars
A{19}9      # 19 uppercase letters, then digit
A{4}9A{15}  # 4 uppercase letters, digit, 15 uppercase letters
9{6}        # 6-digit numeric code
H{32}       # 32-char uppercase hex token
```

Other characters are literals, useful for separators:

```text
XXXX-XXXX
```

## Built-in priorities

Show built-ins:

```bash
./bootloader_unlocker --list-patterns
```

Default smart schedule uses weighted priority:

1. `motorola-portal-20` — `X{20}`
2. `motorola-last-digit` — `A{19}9`
3. `motorola-pos5-digit` — `A{4}9A{15}`
4. `hex-16` — `H{16}`
5. `hex-32` — `H{32}`
6. `numeric-8` — `9{8}`
7. `numeric-6` — `9{6}`

Custom single pattern:

```bash
./bootloader_unlocker --pattern 'X{20}' --command oem-unlock-code
```

Custom weighted schedule:

```bash
./bootloader_unlocker --patterns 'moto:X{20}:10;pin6:9{6}:1' --strategy smart
```

## Persistence

State is saved in a sanitized per-device file:

```text
<device>.dat
```

Saved data includes:

- command profile
- code type
- strategy
- pattern list
- global attempt cursor
- per-pattern offsets
- known positions

Successful code is written to:

```text
SUCCESS_<device>.txt
```

## Common official flows

- AOSP / modern Android: `fastboot flashing unlock`
- Older devices: often `fastboot oem unlock`
- Critical partitions may use `fastboot flashing unlock_critical`
- Motorola often requires official unlock-data portal flow before `fastboot oem unlock <UNIQUE_KEY>`
- Xiaomi often requires Xiaomi account/device pairing and Xiaomi unlock tooling before Fastboot unlock succeeds

## Limitations

- No Windows PowerShell implementation
- No tests or CI; manual verification only
- No carrier-lock bypass
- No FRP / enterprise-policy bypass
- No vendor portal automation
- No guarantee against device lockout after repeated attempts

## Disclaimer

This script is experimental and for educational, repair, recovery, and authorized device-administration use only. Unlocking a bootloader may erase user data and can void warranty or reduce device security. Unauthorized access to devices may be illegal.

## Sources

- [AOSP: Lock and unlock the bootloader](https://source.android.com/docs/core/architecture/bootloader/locking_unlocking)
- [AOSP: Flash with Fastboot](https://source.android.com/docs/setup/test/running)
- [Google Pixel Help: enter Fastboot mode](https://support.google.com/pixelphone/answer/16493042)
- [Motorola Support: bootloader unlock program compatibility](https://en-us.support.motorola.com/app/answers/detail/a_id/89973/~/what-devices-are-compatible-with-the-bootloader-unlock-program)
- [Motorola Support: Factory Reset Protection / OEM unlocking](https://en-us.support.motorola.com/app/answers/detail/a_id/104893/~/factory-reset-protection)
- [Motorola Bootloader Legal Agreement PDF](https://en-us.support.motorola.com/euf/assets/docs/Bootloader-Legal_Agreement_and_Warning.pdf)
- [Xiaomi Support: unlock bootloader FAQ](https://www.mi.com/uk/support/faq/details/KA-07238/)
- [Xiaomi Support: bootloader unlock process](https://www.mi.com/global/support/faq/details/KA-533394)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions welcome. Keep changes script-only unless project scope changes.

## Support

Open an issue on the [GitHub repository](https://github.com/samuelcaldas/bruteforce-bootloader-unlocker/issues).
