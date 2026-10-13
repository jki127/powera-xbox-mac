# `make` builds the flashing tool. `make xboxmap` builds the optional keyboard/mouse mapper.
all: powera-flash

# Uses IOKit directly, so it needs no libraries.
powera-flash: powera-flash.m
	clang -fobjc-arc -O2 -Wall -Wextra $< -o $@ -framework Foundation -framework IOKit -framework GameController

# Needs libusb (brew install libusb). ARCH must match your libusb build: an Intel Homebrew
# (/usr/local) on Apple Silicon needs `make xboxmap ARCH=x86_64`.
ARCH ?= $(shell uname -m)
xboxmap: xboxmap.c
	clang -arch $(ARCH) -O2 -Wall -Wextra $(shell pkg-config --cflags libusb-1.0) $< -o $@ \
		$(shell pkg-config --libs libusb-1.0) -framework ApplicationServices -framework CoreFoundation

clean:
	rm -f powera-flash xboxmap

.PHONY: all clean
