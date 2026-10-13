// xboxmap: userspace driver for PowerA (and other GIP / Xbox One) wired controllers on macOS.
// Reads the controller over libusb and emits keyboard/mouse events via CoreGraphics.
//
//   ./xboxmap            run the driver (needs Accessibility permission for your terminal)
//   ./xboxmap --dry-run  print decoded controller state instead of sending input
//
// Edit the MAPPING section below, then `make xboxmap` to rebuild.

#include <ApplicationServices/ApplicationServices.h>
#include <libusb.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// ---------------------------------------------------------------- MAPPING
// macOS virtual key codes (Carbon/HIToolbox Events.h)
enum {
    K_A = 0x00, K_S = 0x01, K_D = 0x02, K_F = 0x03, K_Q = 0x0C, K_W = 0x0D, K_E = 0x0E, K_R = 0x0F,
    K_1 = 0x12, K_2 = 0x13, K_RETURN = 0x24, K_TAB = 0x30, K_SPACE = 0x31, K_ESCAPE = 0x35,
    K_SHIFT = 0x38, K_CONTROL = 0x3B, K_LEFT = 0x7B, K_RIGHT = 0x7C, K_DOWN = 0x7D, K_UP = 0x7E,
    MOUSE_LEFT = 0x1000, MOUSE_RIGHT = 0x1001, MOUSE_MIDDLE = 0x1002, NONE = 0xFFFF,
};

enum { B_MENU, B_VIEW, B_A, B_B, B_X, B_Y, B_UP, B_DOWN, B_LEFT, B_RIGHT,
       B_LB, B_RB, B_LS, B_RS, B_LT, B_RT, B_STICK_UP, B_STICK_DOWN, B_STICK_LEFT, B_STICK_RIGHT, B_COUNT };

static const char *button_names[B_COUNT] = {
    "Menu", "View", "A", "B", "X", "Y", "Up", "Down", "Left", "Right",
    "LB", "RB", "LS", "RS", "LT", "RT", "LStick-Up", "LStick-Down", "LStick-Left", "LStick-Right",
};

static const unsigned mapping[B_COUNT] = {
    [B_MENU] = K_RETURN,   [B_VIEW] = K_TAB,
    [B_A] = K_SPACE,       [B_B] = K_ESCAPE,       [B_X] = K_E,          [B_Y] = K_Q,
    [B_UP] = K_UP,         [B_DOWN] = K_DOWN,      [B_LEFT] = K_LEFT,    [B_RIGHT] = K_RIGHT,
    [B_LB] = K_1,          [B_RB] = K_2,           [B_LS] = K_SHIFT,     [B_RS] = K_CONTROL,
    [B_LT] = MOUSE_RIGHT,  [B_RT] = MOUSE_LEFT,
    [B_STICK_UP] = K_W,    [B_STICK_DOWN] = K_S,   [B_STICK_LEFT] = K_A, [B_STICK_RIGHT] = K_D,
};

static const double STICK_DEADZONE = 0.20;   // fraction of full deflection
static const double STICK_KEY_THRESHOLD = 0.50;
static const double TRIGGER_THRESHOLD = 0.30;
static const double MOUSE_SPEED = 18.0;      // pixels per poll at full deflection
// ---------------------------------------------------------------- END MAPPING

static const struct { uint16_t vid, pid; } known_devices[] = {
    {0x24c6, 0x581a},  // PowerA XB1 Classic Controller
};

static volatile sig_atomic_t running = 1;
static bool dry_run = false;
static bool pressed[B_COUNT];

static void on_signal(int sig) { (void)sig; running = 0; }

static void send_mouse_button(unsigned which, bool down) {
    CGEventRef pos = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(pos);
    CFRelease(pos);
    CGEventType type;
    CGMouseButton btn;
    switch (which) {
    case MOUSE_LEFT:  type = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;   btn = kCGMouseButtonLeft;   break;
    case MOUSE_RIGHT: type = down ? kCGEventRightMouseDown : kCGEventRightMouseUp; btn = kCGMouseButtonRight;  break;
    default:          type = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp; btn = kCGMouseButtonCenter; break;
    }
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, btn);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void set_button(int b, bool down) {
    if (pressed[b] == down) return;
    pressed[b] = down;
    if (dry_run) { printf("%-12s %s\n", button_names[b], down ? "down" : "up"); return; }
    unsigned target = mapping[b];
    if (target == NONE) return;
    if (target >= MOUSE_LEFT) { send_mouse_button(target, down); return; }
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)target, down);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void release_all(void) {
    for (int b = 0; b < B_COUNT; b++) set_button(b, false);
}

static double axis(int16_t raw) {
    double v = raw / 32768.0;
    double mag = fabs(v);
    if (mag < STICK_DEADZONE) return 0;
    return copysign((mag - STICK_DEADZONE) / (1 - STICK_DEADZONE), v);
}

static void move_mouse(double dx, double dy) {
    if (dx == 0 && dy == 0) return;
    if (dry_run) return;
    CGEventRef pos = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(pos);
    CFRelease(pos);
    // Square the curve for finer control near the center.
    double mx = copysign(dx * dx, dx) * MOUSE_SPEED, my = copysign(dy * dy, dy) * MOUSE_SPEED;
    p.x += mx;
    p.y += my;
    CGEventType type = pressed[B_RT] && mapping[B_RT] == MOUSE_LEFT ? kCGEventLeftMouseDragged
                     : pressed[B_LT] && mapping[B_LT] == MOUSE_RIGHT ? kCGEventRightMouseDragged
                     : kCGEventMouseMoved;
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)lround(mx));
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)lround(my));
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

// GIP input report (type 0x20) layout, as in the Linux xpad driver.
static void handle_input(const uint8_t *d, int n) {
    if (n < 18) return;
    uint8_t b0 = d[4], b1 = d[5];
    set_button(B_MENU, b0 & 0x04);  set_button(B_VIEW, b0 & 0x08);
    set_button(B_A, b0 & 0x10);     set_button(B_B, b0 & 0x20);
    set_button(B_X, b0 & 0x40);     set_button(B_Y, b0 & 0x80);
    set_button(B_UP, b1 & 0x01);    set_button(B_DOWN, b1 & 0x02);
    set_button(B_LEFT, b1 & 0x04);  set_button(B_RIGHT, b1 & 0x08);
    set_button(B_LB, b1 & 0x10);    set_button(B_RB, b1 & 0x20);
    set_button(B_LS, b1 & 0x40);    set_button(B_RS, b1 & 0x80);

    double lt = (d[6] | d[7] << 8) / 1023.0, rt = (d[8] | d[9] << 8) / 1023.0;
    set_button(B_LT, lt > TRIGGER_THRESHOLD);
    set_button(B_RT, rt > TRIGGER_THRESHOLD);

    double lx = axis((int16_t)(d[10] | d[11] << 8)), ly = axis((int16_t)(d[12] | d[13] << 8));
    double rx = axis((int16_t)(d[14] | d[15] << 8)), ry = axis((int16_t)(d[16] | d[17] << 8));
    set_button(B_STICK_UP, ly > STICK_KEY_THRESHOLD);
    set_button(B_STICK_DOWN, ly < -STICK_KEY_THRESHOLD);
    set_button(B_STICK_LEFT, lx < -STICK_KEY_THRESHOLD);
    set_button(B_STICK_RIGHT, lx > STICK_KEY_THRESHOLD);
    move_mouse(rx, -ry);  // GIP reports Y up as positive; screen Y grows downward.
}

static libusb_device_handle *open_controller(libusb_context *ctx) {
    for (size_t i = 0; i < sizeof known_devices / sizeof *known_devices; i++) {
        libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, known_devices[i].vid, known_devices[i].pid);
        if (h) return h;
    }
    return NULL;
}

static void run_controller(libusb_device_handle *h) {
    // macOS leaves the device unconfigured since no driver matches it.
    libusb_set_configuration(h, 1);
    int r = libusb_claim_interface(h, 0);
    if (r) { fprintf(stderr, "claim interface failed: %s\n", libusb_error_name(r)); return; }

    uint8_t seq = 1;
    int n, n_ack;
    uint8_t power_on[] = {0x05, 0x20, seq++, 0x01, 0x00};
    libusb_interrupt_transfer(h, 0x02, power_on, sizeof power_on, &n, 1000);
    printf("Controller connected.%s\n", dry_run ? " (dry run: printing input only)" : "");

    while (running) {
        uint8_t buf[64];
        r = libusb_interrupt_transfer(h, 0x81, buf, sizeof buf, &n, 100);
        if (r == LIBUSB_ERROR_TIMEOUT) continue;
        if (r) { fprintf(stderr, "controller disconnected (%s)\n", libusb_error_name(r)); break; }
        if (n < 4) continue;
        // Acknowledge packets that request it, or the controller resends them.
        if (buf[1] & 0x10) {
            uint8_t ack[] = {0x01, 0x20, buf[2], 0x09, 0x00, buf[0], 0x20, buf[3], 0x00, 0x00, 0x00, 0x00, 0x00};
            libusb_interrupt_transfer(h, 0x02, ack, sizeof ack, &n_ack, 100);
        }
        switch (buf[0]) {
        case 0x02:  // re-announce after reset: power it on again
            power_on[2] = seq++;
            libusb_interrupt_transfer(h, 0x02, power_on, sizeof power_on, &n, 1000);
            break;
        case 0x20:
            handle_input(buf, n);
            break;
        }
    }
    release_all();
    libusb_release_interface(h, 0);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--dry-run")) dry_run = true;

    const void *keys[] = {kAXTrustedCheckOptionPrompt}, *values[] = {kCFBooleanTrue};
    CFDictionaryRef ax_opts = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    bool trusted = dry_run || AXIsProcessTrustedWithOptions(ax_opts);
    CFRelease(ax_opts);
    if (!trusted) {
        fprintf(stderr, "Grant Accessibility permission to your terminal app in System Settings > "
                        "Privacy & Security > Accessibility, then run xboxmap again.\n");
        return 1;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    libusb_context *ctx;
    if (libusb_init(&ctx)) { fprintf(stderr, "libusb init failed\n"); return 1; }

    bool waiting_msg = false;
    while (running) {
        libusb_device_handle *h = open_controller(ctx);
        if (!h) {
            if (!waiting_msg) { printf("Waiting for controller...\n"); waiting_msg = true; }
            sleep(1);
            continue;
        }
        waiting_msg = false;
        run_controller(h);
        libusb_close(h);
    }
    libusb_exit(ctx);
    printf("\nStopped.\n");
    return 0;
}
