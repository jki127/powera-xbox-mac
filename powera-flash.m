// powera-flash: interactive tool that makes a PowerA Enhanced Wired Controller for Xbox One
// (model 1505660-03, USB 24C6:581A) report itself as an Xbox One S controller (045E:02EA),
// which macOS drives natively.
//
// It flashes PowerA's own v1.15 firmware (from their Windows repair updater) with only the USB
// vendor/product ID changed, or restores that firmware unmodified. The bootloader can't read the
// controller's existing firmware, so there is no backup step. The bootloader protocol and the
// request that starts it were reverse-engineered from PowerA's updater and firmware; see
// README.md.
//
//   ./powera-flash             run interactively
//   ./powera-flash --simulate  run against an in-memory fake controller (no hardware touched)

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/usb/IOUSBLib.h>

enum {
    BOOT_VID = 0x2E2C, BOOT_PID = 0x8008,          // PowerA bootloader (update mode)
    PC_PID = 0x000A,                               // PC gamepad mode (View + Menu while plugging in), VID 2E2C
    ORIG_VID = 0x24C6, ORIG_PID = 0x581A,          // PowerA "XB1 Classic Controller"
    XBOX_VID = 0x045E, XBOX_PID = 0x02EA,          // Microsoft Xbox One S controller
    // Asking the firmware for string descriptor 0xAC in language 0x6068 makes it jump to the bootloader.
    ISP_STRING_INDEX = 0xAC, ISP_LANGID = 0x6068,
    FLASH_SIZE = 0x10000, FW_PAGE_SIZE = 0x100, PAGE_COUNT = FLASH_SIZE / FW_PAGE_SIZE,
    REPORT_LEN = 0x109,                            // feature report 1: report ID + 264 bytes
    REPORT2_LEN = 0x29,                            // feature report 2: report ID + 40 bytes
    DATA_OFFSET = 9,                               // page data offset inside a write command
};

static NSString *const FIRMWARE_FILE = @"firmware/LBX902_V1.1.5_1.bin";
static NSString *const FIRMWARE_SHA256 = @"62d7011a2e3918a830ec4b6156866fb245fe8e3234ef0a2f34ab18e11ee31829";
static const uint8_t IMAGE_MARKER[4] = {0x55, 0xAA, 0x33, 0xCC};

static bool simulate = false;

// ---------------------------------------------------------------- console helpers

static NSString *prompt(NSString *question) {
    printf("%s", question.UTF8String);
    fflush(stdout);
    char line[256];
    if (!fgets(line, sizeof line, stdin)) { printf("\n"); exit(1); }
    return [[NSString stringWithUTF8String:line]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void wait_enter(NSString *message) {
    printf("\n%s\n", message.UTF8String);
    prompt(@"Press Return when done... ");
}

static bool confirm_word(NSString *word, NSString *message) {
    printf("\n%s\n", message.UTF8String);
    NSString *answer = prompt([NSString stringWithFormat:@"Type %@ to continue, anything else to cancel: ", word]);
    return [answer isEqualToString:word];
}

static void progress(const char *label, int done, int total) {
    int width = 40, filled = done * width / total;
    printf("\r  %-10s [", label);
    for (int i = 0; i < width; i++) putchar(i < filled ? '#' : '.');
    printf("] %3d%%", done * 100 / total);
    if (done == total) putchar('\n');
    fflush(stdout);
}

static void sleep_runloop(double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

// ---------------------------------------------------------------- simulated controller

static uint8_t sim_flash[FLASH_SIZE];
static int sim_read_page = -1;
static bool sim_erased = false, sim_in_bootloader = false;

// Like the real bootloader, reading back is only allowed after the start (erase) command.
static bool sim_set_feature(const uint8_t *r) {
    switch (r[1]) {
    case 0xA7: memset(sim_flash, 0xFF, FLASH_SIZE); sim_erased = true; return true;
    case 0xA8: if (!sim_erased) return false; memcpy(sim_flash + r[2] * FW_PAGE_SIZE, r + DATA_OFFSET, FW_PAGE_SIZE); return true;
    case 0xAA: if (!sim_erased) return false; sim_read_page = r[2]; return true;
    case 0xA9: sim_erased = false; return true;
    }
    return false;
}

static bool sim_get_feature(uint8_t *r, CFIndex *len) {
    if (sim_read_page < 0) return false;
    memset(r, 0, REPORT_LEN);
    r[0] = 1;
    memcpy(r + 1, sim_flash + sim_read_page * FW_PAGE_SIZE, FW_PAGE_SIZE);
    *len = REPORT_LEN;
    return true;
}

// ---------------------------------------------------------------- USB / HID access

static bool usb_device_present(uint16_t vid, uint16_t pid) {
    if (simulate) return vid == ORIG_VID || (vid == XBOX_VID && !sim_erased);
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), (__bridge CFNumberRef)@(vid));
    CFDictionarySetValue(match, CFSTR(kUSBProductID), (__bridge CFNumberRef)@(pid));
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) return false;
    io_object_t dev = IOIteratorNext(it);
    bool found = dev != 0;
    if (dev) IOObjectRelease(dev);
    IOObjectRelease(it);
    return found;
}

// Sends GET_DESCRIPTOR(string ISP_STRING_INDEX, ISP_LANGID) to the controller. The firmware answers
// "DS60F168", then jumps to the ROM bootloader, which re-enumerates as BOOT_VID:BOOT_PID.
// PowerA's updater sends the same request while scanning USB hubs.
static bool request_bootloader(uint16_t vid, uint16_t pid) {
    if (simulate) { sim_in_bootloader = true; return true; }
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), (__bridge CFNumberRef)@(vid));
    CFDictionarySetValue(match, CFSTR(kUSBProductID), (__bridge CFNumberRef)@(pid));
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) return false;

    IOCFPlugInInterface **plugin = NULL;
    IOUSBDeviceInterface **dev = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !plugin) return false;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (!dev) return false;

    uint8_t reply[255] = {0};
    IOUSBDevRequest req = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice),
        .bRequest = kUSBRqGetDescriptor,
        .wValue = (kUSBStringDesc << 8) | ISP_STRING_INDEX,
        .wIndex = ISP_LANGID,
        .wLength = sizeof reply,
        .pData = reply,
    };
    IOReturn r = (*dev)->DeviceRequest(dev, &req);
    (*dev)->Release(dev);
    // The controller may drop off the bus right after answering, so a failed status stage is fine.
    if (r == kIOReturnSuccess && req.wLenDone >= 2) {
        NSString *name = [[NSString alloc] initWithBytes:reply + 2 length:req.wLenDone - 2
                                                encoding:NSUTF16LittleEndianStringEncoding];
        printf("The controller answered \"%s\".\n", name.UTF8String);
    }
    return true;
}

static IOHIDManagerRef hid_manager;

static IOHIDDeviceRef find_bootloader(void) {
    if (simulate) return sim_in_bootloader ? (IOHIDDeviceRef)(uintptr_t)1 : NULL;
    if (!hid_manager) {
        hid_manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSDictionary *match = @{@kIOHIDVendorIDKey: @(BOOT_VID), @kIOHIDProductIDKey: @(BOOT_PID)};
        IOHIDManagerSetDeviceMatching(hid_manager, (__bridge CFDictionaryRef)match);
        IOHIDManagerScheduleWithRunLoop(hid_manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDManagerOpen(hid_manager, kIOHIDOptionsTypeNone);
    }
    sleep_runloop(0.2);
    NSSet *devices = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(hid_manager);
    return (__bridge IOHIDDeviceRef)devices.anyObject;
}

static bool set_feature(IOHIDDeviceRef dev, const uint8_t *report) {
    if (simulate) return sim_set_feature(report);
    // Like hidapi on macOS: numbered reports are passed with the report ID as byte 0. PowerA's
    // updater always sends 265 bytes, which Windows accepts, but macOS needs each report's
    // declared size: report 1 is 264 bytes and report 2 is 40 bytes, plus the ID byte.
    CFIndex len = report[0] == 2 ? REPORT2_LEN : REPORT_LEN;
    IOReturn r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, report[0], report, len);
    if (r != kIOReturnSuccess) printf("\n  (Sending report %d command %02X failed: error 0x%x)", report[0], report[1], r);
    return r == kIOReturnSuccess;
}

// Reads feature report 1 and returns a pointer to the page data inside `buf`, or NULL.
static const uint8_t *get_page_data(IOHIDDeviceRef dev, uint8_t *buf) {
    CFIndex len = REPORT_LEN;
    memset(buf, 0, REPORT_LEN);
    if (simulate) {
        if (!sim_get_feature(buf, &len)) return NULL;
    } else {
        IOReturn r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, buf, &len);
        if (r != kIOReturnSuccess) { printf("\n  (Reading report 1 failed: error 0x%x)", r); return NULL; }
    }
    if (len == REPORT_LEN && buf[0] == 1) return buf + 1;  // report ID included
    if (len == REPORT_LEN - 1) return buf;                 // report ID stripped
    return NULL;
}

// ---------------------------------------------------------------- bootloader protocol

// PowerA's updater reuses one command buffer and only changes the first few bytes per command,
// so bytes left over from earlier commands are sent along. This mirrors that exactly.
static uint8_t cmd[REPORT_LEN];

static bool read_page(IOHIDDeviceRef dev, int page, uint8_t *out) {
    cmd[0] = 0x02; cmd[1] = 0xAA; cmd[2] = (uint8_t)page; cmd[3] = 0x00;
    if (!set_feature(dev, cmd)) return false;
    uint8_t buf[REPORT_LEN];
    const uint8_t *data = get_page_data(dev, buf);
    if (!data) return false;
    memcpy(out, data, FW_PAGE_SIZE);
    return true;
}

static bool write_flash(IOHIDDeviceRef dev, const uint8_t *image) {
    memset(cmd, 0, sizeof cmd);
    cmd[0] = 0x01; cmd[1] = 0xA7; cmd[2] = 0xFF; cmd[4] = 0x01; cmd[6] = 0x01;
    if (!set_feature(dev, cmd)) { printf("  The controller rejected the start command. Nothing was written.\n"); return false; }
    sleep_runloop(0.5);

    for (int page = 0; page < PAGE_COUNT; page++) {
        cmd[0] = 0x01; cmd[1] = 0xA8; cmd[2] = (uint8_t)page; cmd[3] = 0x00; cmd[4] = 0x01; cmd[5] = 0x00;
        memcpy(cmd + DATA_OFFSET, image + page * FW_PAGE_SIZE, FW_PAGE_SIZE);
        if (!set_feature(dev, cmd)) { printf("\n  Writing page %d failed.\n", page); return false; }
        progress("Writing", page + 1, PAGE_COUNT);
    }

    uint8_t readback[FW_PAGE_SIZE];
    for (int page = 0; page < PAGE_COUNT; page++) {
        if (!read_page(dev, page, readback) || memcmp(readback, image + page * FW_PAGE_SIZE, FW_PAGE_SIZE)) {
            printf("\n  Verification failed at page %d.\n", page);
            return false;
        }
        progress("Verifying", page + 1, PAGE_COUNT);
    }

    cmd[0] = 0x02; cmd[1] = 0xA9;
    if (!set_feature(dev, cmd)) printf("  (The finish command got no answer; this is often fine because the controller restarts.)\n");
    return true;
}

// ---------------------------------------------------------------- firmware image

static const uint8_t ORIG_IDS[4] = {ORIG_VID & 0xFF, ORIG_VID >> 8, ORIG_PID & 0xFF, ORIG_PID >> 8};
static const uint8_t XBOX_IDS[4] = {XBOX_VID & 0xFF, XBOX_VID >> 8, XBOX_PID & 0xFF, XBOX_PID >> 8};

static NSString *sha256(const uint8_t *data, size_t len) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data, (CC_LONG)len, digest);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

// Loads PowerA's v1.15 image from next to this program and checks it's exactly the expected file.
static bool load_firmware(uint8_t *image) {
    NSString *dir = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    NSString *path = [dir stringByAppendingPathComponent:FIRMWARE_FILE];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length != FLASH_SIZE) { printf("Couldn't load PowerA's firmware from %s.\nRun ./get-firmware.sh first.\n", path.UTF8String); return false; }
    if (![sha256(data.bytes, FLASH_SIZE) isEqualToString:FIRMWARE_SHA256]) {
        printf("%s isn't the expected PowerA v1.15 firmware (checksum mismatch). Stopping.\n", path.UTF8String);
        return false;
    }
    memcpy(image, data.bytes, FLASH_SIZE);
    return !memcmp(image + FLASH_SIZE - 4, IMAGE_MARKER, 4);
}

// Replaces every occurrence of the PowerA ID with the Xbox One S ID. Returns the count.
static int patch_ids(uint8_t *image) {
    int n = 0;
    for (int i = 0; i + 4 <= FLASH_SIZE; i++)
        if (!memcmp(image + i, ORIG_IDS, 4)) { memcpy(image + i, XBOX_IDS, 4); n++; }
    return n;
}

// ---------------------------------------------------------------- steps

static IOHIDDeviceRef open_bootloader(IOHIDDeviceRef dev) {
    if (simulate) return dev;
    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) { printf("Couldn't open it (error 0x%x).\n", r); return NULL; }
    NSNumber *size = (__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey));
    if (size.intValue != REPORT_LEN) {
        printf("Its feature report size is %d bytes, but %d was expected. Stopping to be safe.\n",
               size.intValue, REPORT_LEN);
        return NULL;
    }
    return dev;
}

static IOHIDDeviceRef enter_update_mode(void) {
    const uint16_t modes[][2] = {{ORIG_VID, ORIG_PID}, {BOOT_VID, PC_PID}, {XBOX_VID, XBOX_PID}};
    while (true) {
        IOHIDDeviceRef dev = find_bootloader();
        if (dev) { printf("\nThe controller is already in update mode.\n"); return open_bootloader(dev); }

        wait_enter(@"STEP: Plug in the controller normally (don't hold any buttons).");
        uint16_t vid = 0, pid = 0;
        for (int i = 0; i < 3 && !vid; i++)
            if (usb_device_present(modes[i][0], modes[i][1])) vid = modes[i][0], pid = modes[i][1];

        if (!vid) {
            printf("The controller wasn't found.\n");
        } else {
            printf("Found the controller (%04X:%04X). Asking it to switch to update mode...\n", vid, pid);
            if (!request_bootloader(vid, pid)) printf("Couldn't send the request to the controller.\n");
            printf("Waiting for update mode");
            for (int i = 0; i < 20; i++) {
                if ((dev = find_bootloader())) { printf("\nIt's in update mode.\n"); return open_bootloader(dev); }
                printf(".");
                sleep_runloop(0.5);
            }
            printf("\nThe controller didn't switch to update mode. Nothing was changed.\n");
        }
        if (![prompt(@"Try again? [y/n] ") hasPrefix:@"y"]) return NULL;
    }
}

static bool wait_for_usb(uint16_t vid, uint16_t pid, double seconds) {
    for (double t = 0; t < seconds; t += 0.5) {
        if (usb_device_present(vid, pid)) return true;
        sleep_runloop(0.5);
    }
    return false;
}

static uint8_t last_input[64];
static CFIndex last_input_len;

static void on_input(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t id,
                     uint8_t *report, CFIndex len) {
    (void)ctx; (void)result; (void)sender; (void)type; (void)id;
    last_input_len = MIN(len, (CFIndex)sizeof last_input);
    memcpy(last_input, report, last_input_len);
}

// Returns the largest idle stick deflection (percent) reported through Apple's Xbox driver, or -1
// if no input arrived. Reports use the GIP layout: sticks are int16 at bytes 10, 12, 14 and 16.
static double max_stick_offset(void) {
    if (simulate) return 0;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *match = @{@kIOHIDVendorIDKey: @(XBOX_VID), @kIOHIDProductIDKey: @(XBOX_PID)};
    IOHIDManagerSetDeviceMatching(m, (__bridge CFDictionaryRef)match);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    sleep_runloop(0.3);
    NSSet *devices = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(m);
    static uint8_t buf[256];
    last_input_len = 0;
    if (devices.count) {
        IOHIDDeviceRegisterInputReportCallback((__bridge IOHIDDeviceRef)devices.anyObject, buf, sizeof buf, on_input, NULL);
        // Reports can pause briefly right after the GameController framework connects, so wait up to 2 s.
        for (int i = 0; i < 20 && last_input_len < 18; i++) sleep_runloop(0.1);
    }
    IOHIDManagerClose(m, kIOHIDOptionsTypeNone);
    CFRelease(m);
    if (last_input_len < 18) return -1;
    double worst = 0;
    for (int off = 10; off <= 16; off += 2) {
        int16_t v = (int16_t)(last_input[off] | last_input[off + 1] << 8);
        worst = MAX(worst, fabs(v / 327.68));
    }
    return worst;
}

// Walks the user through PowerA's calibration until the sticks rest near center.
static void calibrate(void) {
    while (true) {
        double offset = max_stick_offset();
        if (offset < 0) { printf("Couldn't read the sticks to check calibration.\n"); return; }
        if (offset <= 10) { printf("The sticks rest near center (largest offset %.0f%%). Calibration is good.\n", offset); return; }
        printf("\nThe sticks read %.0f%% off center while untouched, so the controller needs calibrating.\n"
               "This is expected after the update. PowerA's instructions call calibration required.\n", offset);
        if (![prompt(@"Calibrate now? [y/n] ") hasPrefix:@"y"]) return;
        wait_enter(@"STEP: Calibrate the controller.\n"
                   @"  1. Unplug the controller.\n"
                   @"  2. Hold the Xbox, Menu and View buttons, and plug the controller back in while holding them.\n"
                   @"     The Xbox button's light flashes rapidly. Release the buttons.\n"
                   @"  3. Rotate both sticks clockwise 3 full turns.\n"
                   @"  4. Press both triggers all the way and release, 3 times.\n"
                   @"  5. Press D-pad Down and Y together to save. The light stops flashing.\n"
                   @"  Then leave the sticks untouched.");
        if (!wait_for_usb(XBOX_VID, XBOX_PID, 15)) { printf("The controller didn't reappear.\n"); return; }
        sleep_runloop(1.0);
    }
}

static GCController *wait_for_gamepad(void) {
    GCController.shouldMonitorBackgroundEvents = YES;
    for (int i = 0; i < 20; i++) {
        GCController *pad = GCController.controllers.firstObject;
        if (pad.extendedGamepad) return pad;
        sleep_runloop(0.5);
    }
    return nil;
}

// Checks Apple's GameController framework sees the updated controller, calibration, and a button press.
static void verify_gamepad_connected(void) {
    if (simulate) { printf("(Simulated: skipping the GameController check.)\n"); return; }
    GCController *pad = wait_for_gamepad();
    if (!pad) {
        printf("But it isn't showing up as a game controller, so Apple's driver may not accept it.\n"
               "Check System Settings > Game Controllers, or run this tool again and restore PowerA's firmware.\n");
        return;
    }
    printf("macOS recognizes it as a game controller: \"%s\".\n", pad.vendorName.UTF8String ?: "unknown");

    calibrate();
    if (!(pad = wait_for_gamepad())) { printf("The controller isn't connected as a gamepad anymore.\n"); return; }

    __block bool pressed = false;
    pad.extendedGamepad.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL down) {
        (void)b; (void)v;
        if (down) pressed = true;
    };
    printf("Press the A button on the controller...\n");
    for (int i = 0; i < 60 && !pressed; i++) sleep_runloop(0.25);
    printf(pressed ? "A button received. Your controller works as a gamepad on this Mac.\n"
                   : "No A button press arrived within 15 seconds. Run option 3 to try the check again.\n");
}

static void verify_gamepad(void) {
    wait_enter(@"STEP: Unplug the controller and plug it back in normally (don't hold any buttons).");
    printf("Waiting for an Xbox One S controller to appear...\n");
    if (!wait_for_usb(XBOX_VID, XBOX_PID, 15)) {
        if (usb_device_present(ORIG_VID, ORIG_PID))
            printf("It came back with its old PowerA ID, so the update didn't take effect.\n");
        else
            printf("No controller appeared. Run this tool again and choose \"Restore PowerA's firmware\".\n");
        return;
    }
    printf("macOS sees it as an Xbox One S controller (045E:02EA).\n");
    verify_gamepad_connected();
}

// Flashes PowerA's v1.15 firmware, with the Xbox One S ID (patch = true) or unmodified.
static void do_flash(bool patch) {
    static uint8_t image[FLASH_SIZE];
    if (!load_firmware(image)) return;
    if (patch) {
        int n = patch_ids(image);
        if (n != 2) { printf("Expected the PowerA ID in 2 places in the firmware, found %d. Stopping.\n", n); return; }
        printf("Prepared PowerA's v1.15 firmware with the USB ID changed to %04X:%04X.\n", XBOX_VID, XBOX_PID);
    } else {
        printf("Prepared PowerA's unmodified v1.15 firmware.\n");
    }

    IOHIDDeviceRef dev = enter_update_mode();
    if (!dev) return;

    NSString *warning = patch
        ? @"STEP: Write the update.\n"
          @"This replaces the controller's firmware with PowerA's v1.15, changed to identify as an Xbox One S\n"
          @"controller. The original firmware can't be backed up, but option 2 restores PowerA's v1.15 later.\n"
          @"Keep the controller plugged in until this finishes."
        : @"STEP: Write PowerA's firmware.\nKeep the controller plugged in until this finishes.";
    if (!confirm_word(@"FLASH", warning)) {
        printf("Cancelled. Nothing was written. Unplug the controller and it will start normally.\n");
        return;
    }

    if (!write_flash(dev, image)) {
        printf("\nThe write didn't complete. Leave the controller plugged in, run this tool again and choose\n"
               "\"Restore PowerA's firmware\". It should still be in update mode.\n");
        return;
    }
    printf("Firmware written and verified.\n");

    if (patch) { verify_gamepad(); return; }
    wait_enter(@"STEP: Unplug the controller and plug it back in normally (don't hold any buttons).");
    printf(wait_for_usb(ORIG_VID, ORIG_PID, 15) ? "The controller is back as a PowerA controller (%04X:%04X).\n"
                                                : "The controller didn't reappear as %04X:%04X.\n", ORIG_VID, ORIG_PID);
    printf("Calibrate it now: hold Xbox + Menu + View while plugging in, rotate both sticks clockwise 3 times,\n"
           "press both triggers fully 3 times, then press D-pad Down + Y to save.\n");
}

static void do_check(void) {
    printf("\nChecking the controller (nothing is written).\n");
    if (!wait_for_usb(XBOX_VID, XBOX_PID, 5)) {
        printf(usb_device_present(ORIG_VID, ORIG_PID) ? "It's connected with its PowerA ID, so it hasn't been updated.\n"
                                                      : "No updated controller is connected.\n");
        return;
    }
    printf("macOS sees it as an Xbox One S controller (045E:02EA).\n");
    verify_gamepad_connected();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        for (int i = 1; i < argc; i++)
            if (!strcmp(argv[i], "--simulate")) simulate = true;
        if (simulate) printf("SIMULATION MODE: no hardware is touched.\n");

        printf("\nPowerA controller updater for macOS\n"
               "For the PowerA Enhanced Wired Controller for Xbox One (model 1505660-03).\n"
               "Makes it appear as an Xbox One S controller so macOS supports it natively.\n\n"
               "  1) Update (install PowerA v1.15 firmware with the Xbox One S ID)\n"
               "  2) Restore PowerA's firmware (unmodified v1.15)\n"
               "  3) Check the controller (gamepad, calibration and buttons; writes nothing)\n"
               "  q) Quit\n");
        NSString *choice = prompt(@"Choose: ");
        if ([choice isEqualToString:@"1"]) do_flash(true);
        else if ([choice isEqualToString:@"2"]) do_flash(false);
        else if ([choice isEqualToString:@"3"]) do_check();
    }
    return 0;
}
