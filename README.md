# PowerA Enhanced Wired Controller on macOS

I wrote this workaround to get my PowerA controller working on my MacBook. I used to rely on [360Controller](https://github.com/360Controller/360Controller/), but it no longer works on newer versions of macOS. Writing a new driver wasn't an option either, because macOS only runs one with an entitlement that Apple has to grant.

macOS doesn't support the PowerA Enhanced Wired Controller for Xbox One (model 1505660-03, USB ID `24C6:581A`). It speaks Microsoft's Xbox protocol (GIP) over USB, and Apple's built-in driver only loads for Microsoft's own product IDs.

`powera-flash` installs PowerA's own v1.15 firmware on the controller with one change. The controller reports the USB ID of an Xbox One S controller (`045E:02EA`), so macOS loads its built-in Xbox driver. Apple's GameController framework, which App Store and Apple Arcade games use, then lists it as a gamepad.

> [!WARNING]
> This rewrites the controller's firmware. The bootloader doesn't allow reading the existing firmware, so you can't back it up. You can always reinstall PowerA's unmodified v1.15 firmware. The tool has only run on one controller, which shipped with v1.13. This project isn't affiliated with PowerA or Microsoft. Use it at your own risk.

## System requirements

- A PowerA Enhanced Wired Controller for Xbox One, model 1505660-03. The model number is on the label on the back.
- macOS 15 or later, which added Apple's wired Xbox driver. Development and testing used macOS 26.5.1 on Apple Silicon.
- Xcode Command Line Tools, which provide `clang`, `make` and `python3`. Install them with `xcode-select --install`.
- An internet connection the first time, to download PowerA's updater from powera.com.
- A USB data cable. `curl` and `tar` come with macOS.

`xboxmap` also needs libusb and pkg-config (`brew install libusb pkg-config`).

## Instructions

1. Get the code and build the tool.

   ```sh
   git clone <this repository's URL>
   cd <repository folder>
   make
   ```

2. Download PowerA's firmware. The script downloads PowerA's Windows updater, extracts the v1.15 image into `firmware/`, and checks its SHA-256. The image isn't included in this repository.

   ```sh
   ./get-firmware.sh
   ```

3. Plug the controller in normally, without holding any buttons, and run the tool.

   ```sh
   ./powera-flash
   ```

4. Choose option 1 and follow the prompts. The tool switches the controller into update mode, waits for you to type `FLASH`, writes and verifies the firmware, and asks you to reconnect the controller.

5. Calibrate the sticks when the tool asks. See "Calibrate after updating" below.

### Menu options

1. **Update.** Installs v1.15 with the Xbox One S ID, then checks that macOS sees a gamepad.
2. **Restore.** Installs PowerA's unmodified v1.15.
3. **Check.** Writes nothing. It checks that macOS sees the gamepad, measures the idle stick positions, and waits for you to press A.

`powera-flash` checks the firmware's SHA-256 again before writing. Run `./powera-flash --simulate` to walk through the steps against a simulated controller.

### Calibrate after updating

Installing the firmware erases the stick calibration, so the sticks read about 40% off center until you calibrate. PowerA's instructions say calibration is required after this update. The tool measures the sticks and walks you through these steps:

1. Unplug the controller.
2. Hold Xbox, Menu and View, and plug the controller in while holding them. The Xbox button's light flashes quickly. Release the buttons.
3. Rotate both sticks clockwise three full turns.
4. Press both triggers all the way and release them, three times.
5. Press D-pad Down and Y together to save. The light stops flashing.

## Troubleshooting

If writing fails partway, leave the controller plugged in and run `./powera-flash` again with option 2. The controller stays in update mode, and the tool detects it.

If the controller doesn't switch to update mode, nothing has been written. Its firmware may not respond to the update request. See "How it works" below.

If the sticks drift, calibrate again and run option 3 to check. The check passes when the sticks rest within 10% of center.

## How it works

### Firmware

PowerA's [v1.15 repair updater](https://www.powera.com/support-articles/xbox-xs-one-product-support/firmware-updates-for-xbox-one-controllers/xbox-enhanced-wired-controller-firmware-v1.15-for-windows-10-not-an-update/) for Windows embeds a 64 KB firmware image, `LBX902_V1.1.5_1.bin`, as a zlib-compressed Qt resource. The image isn't encrypted or signed. The chip identifies as a Weltrend WT60F168 and runs Andes NDS32 code. GNU binutils 2.40, built with `--target=nds32le-elf`, disassembles it with `objdump -b binary -m n1h_v3 -EB`.

### Entering update mode

The firmware switches to its bootloader when it receives a standard USB GET_DESCRIPTOR request for string index `0xAC` with language ID `0x6068`. It answers with the string "DS60F168", writes the value "UISP" (`0x55495350`) to RAM at `0x207400`, and jumps to the ROM bootloader at `0x400000`. The bootloader then appears as a HID device named "USB ISP" with ID `2E2C:8008`. PowerA's updater sends the same request while it scans USB devices, so no button combination is involved.

In the firmware, the request handlers at `0x4646` (Xbox mode) and `0x4722` (PC mode) set bit `0x10` of a flag byte. The transfer-complete handler at `0x4B5E` turns that into bit `0x08`. The main loop at `0x2E08` then calls the jump routine at `0x2D98`.

### Bootloader protocol

The bootloader uses two HID feature reports. Report 1 is 264 bytes and report 2 is 40 bytes, plus the report ID byte. PowerA's updater sends a 265-byte buffer for both reports. macOS rejects the oversized report 2, so `powera-flash` sends each report at its declared size.

| Step | Report | Bytes |
|---|---|---|
| Start, which probably erases the flash | set 1 | `01 A7 FF 00 01 00 01 ...` |
| Write a 256-byte page, for pages 0 to 255 | set 1 | `01 A8 <page> 00 01 00 01 00 00 <data>` |
| Read a page back | set 2, then get 1 | `02 AA <page> 00`, then 256 bytes from byte 1 |
| Finish and restart | set 2 | `02 A9 ...` |

The bootloader rejects read requests until it has received the start command, which is why the existing firmware can't be backed up. The updater adds up the image as a checksum but never sends the total. The last four bytes of the image are a valid-image marker, `55 AA 33 CC`.

### The patch

The image contains the ID `24C6:581A` in two places. One is the USB device descriptor at `0x5784`, and the other is at `0x586C`. `powera-flash` changes both to `045E:02EA`. Apple's driver, `/System/Library/DriverExtensions/XboxGamepad.dext`, loads for vendor `045E` with product `02EA` and interface class `FF/47/D0`, which matches the controller's existing interface.

### Controller modes

| How it's plugged in | USB ID | Mode |
|---|---|---|
| Normally | `24C6:581A` | Xbox protocol (GIP) |
| Holding View and Menu | `2E2C:000A` | Generic USB HID gamepad |
| Holding Xbox, Menu and View | `24C6:581A` | Calibration |
| After the update request | `2E2C:8008` | ROM bootloader |

In the HID gamepad mode, byte 11 of the 12-byte input report holds the firmware version. Version 1.13 reports 113 and the v1.15 image reports 115.

## xboxmap

`xboxmap` is an alternative that leaves the firmware alone. It reads the unmodified controller over libusb and turns its input into keyboard and mouse events, so it only helps in games that accept keyboard and mouse. It needs libusb, pkg-config and Accessibility permission for your terminal.

```sh
make xboxmap        # Intel Homebrew on Apple Silicon: make xboxmap ARCH=x86_64
./xboxmap --dry-run # prints decoded button presses without sending input
./xboxmap
```

The default mapping puts the left stick on WASD, the right stick on the mouse, the triggers on mouse clicks, and A, B, X and Y on Space, Esc, E and Q. Change the `MAPPING` section in `xboxmap.c` and rebuild to customize it.

## Related projects

- [PowerA PC HQ for macOS (PowerA-HQ-for-OPS-v1)](https://github.com/darthdragneel1/PowerA-HQ-for-OPS-v1) — Companion application and user-space IOKit/hidapi driver for the **PowerA OPS v1 & OPS v3 Pro Wireless/Wired Controller** family (`VID: 0x20D6`), providing low-latency input streaming, RGB lighting, dual rumble testing, calibration, and `.pwa` profile management without firmware modifications.

