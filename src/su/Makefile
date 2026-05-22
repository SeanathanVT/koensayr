# su/Makefile — cross-compile su.c + start.S for ARMv7 Android 4.2.2.
#
# No-libc build: this binary uses direct ARM-EABI syscalls (svc 0) with no
# libc dependency. The only library it links is libgcc.a (for compiler
# builtins like __aeabi_*), which the EPEL gcc-arm-linux-gnu package ships.
#
# Install:
#   Debian / Ubuntu:  sudo apt install gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi
#   Rocky/Fedora:     sudo dnf install epel-release && \
#                     sudo dnf install gcc-arm-linux-gnu binutils-arm-linux-gnu
#
# Fedora/RHEL ships arm-linux-gnu-gcc; Debian/Ubuntu ships arm-linux-gnueabi-gcc.
# Both target the same ARM EABI triplet for this no-libc build.

CROSS_PREFIX ?=
ifeq ($(CROSS_PREFIX),)
  ifneq ($(shell command -v arm-linux-gnu-gcc 2>/dev/null),)
    CROSS_PREFIX := arm-linux-gnu-
  else ifneq ($(shell command -v arm-linux-gnueabi-gcc 2>/dev/null),)
    CROSS_PREFIX := arm-linux-gnueabi-
  endif
endif

CC      := $(CROSS_PREFIX)gcc
STRIP   := $(CROSS_PREFIX)strip
READELF := $(CROSS_PREFIX)readelf

CFLAGS := -nostdlib -ffreestanding -fno-builtin -fno-stack-protector \
          -Os -Wall -Wextra -std=gnu99 \
          -march=armv7-a -mthumb -mfloat-abi=soft \
          -fno-asynchronous-unwind-tables -fno-unwind-tables

LDFLAGS := -nostdlib -static -Wl,--build-id=none -Wl,--gc-sections

# libgcc.a path varies by gcc version; let the driver find it.
LIBS := -lgcc

BUILD_DIR := build
TARGET    := $(BUILD_DIR)/su
OBJS      := $(BUILD_DIR)/start.o $(BUILD_DIR)/su.o

.PHONY: all clean check verify-toolchain strip-info

all: $(TARGET)

verify-toolchain:
	@command -v $(CC) >/dev/null 2>&1 || { \
	  echo "ERROR: ARM cross-compiler not in PATH (tried arm-linux-gnu-gcc, arm-linux-gnueabi-gcc)"; \
	  echo "  Debian / Ubuntu: sudo apt install gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi"; \
	  echo "  Rocky / Fedora:  sudo dnf install gcc-arm-linux-gnu binutils-arm-linux-gnu"; \
	  exit 1; }
	@$(CC) --version | head -n1

$(BUILD_DIR):
	@mkdir -p $@

$(BUILD_DIR)/start.o: start.S | $(BUILD_DIR) verify-toolchain
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD_DIR)/su.o: su.c | $(BUILD_DIR) verify-toolchain
	$(CC) $(CFLAGS) -c -o $@ $<

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)
	$(STRIP) --strip-all $@
	@echo ""
	@echo "Built: $@"
	@file $@ | sed 's/^/  /'
	@echo "  size: $$(wc -c < $@) bytes"
	@echo "  md5:  $$(md5sum $@ | awk '{print $$1}')"

# Sanity-check: ARM ELF, statically linked, no NEEDED libs (no dynamic deps).
check: $(TARGET)
	@file $(TARGET) | grep -q "ELF 32-bit LSB.*ARM"   || { echo "FAIL: not ARM ELF"; exit 1; }
	@file $(TARGET) | grep -q "statically linked"     || { echo "FAIL: not statically linked"; exit 1; }
	@! $(READELF) -d $(TARGET) | grep -q NEEDED || { echo "FAIL: has NEEDED entries"; exit 1; }
	@echo "OK: $(TARGET) is a self-contained statically-linked ARM ELF"

clean:
	rm -rf $(BUILD_DIR)
