# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware
# SPDX-FileCopyrightText: Copyright (c) 2025 @paxx12, @horzadome

include vars.mk

# Profiles are consumed by overlay scripts as well as by make itself.
# Export the selected profile so the staged rootfs records exactly what was built.
export PROFILE

all: tools

# ================= Build Tools =================

OUTPUT_FILE := firmware/firmware.bin
BUILD_DIR ?= tmp/firmware

ifneq (,$(PROFILE))
PROFILE_PARTS := $(subst -, ,$(PROFILE))
FIRMWARE_NAME := $(firstword $(PROFILE_PARTS))
MOD_NAMES := $(wordlist 2,$(words $(PROFILE_PARTS)),$(PROFILE_PARTS))
OVERLAYS += $(wildcard overlays/common/*/)
OVERLAYS += $(wildcard overlays/firmware-$(FIRMWARE_NAME)/*/)
OVERLAYS += $(foreach p,$(MOD_NAMES),$(wildcard overlays/mods/$(p)/*/))
endif

FIRMWARES := $(patsubst overlays/firmware-%,%,$(wildcard overlays/firmware-*))
MOD_LIST := $(patsubst overlays/mods/%/,%,$(wildcard overlays/mods/*/))
INVALID_MOD_NAMES := $(filter-out $(MOD_LIST),$(MOD_NAMES))

$(OUTPUT_FILE): firmware/$(FIRMWARE_FILE) tools
ifeq (,$(PROFILE))
	@echo "Please specify a firmware using 'make PROFILE=<firmware>[-<mod>]*'. Available firmwares are: $(FIRMWARES). Available mods are: $(MOD_LIST)."
	@exit 1
else ifeq (,$(filter $(FIRMWARE_NAME),$(FIRMWARES)))
	@echo "Invalid firmware '$(FIRMWARE_NAME)'. Available firmwares are: $(FIRMWARES)."
	@exit 1
else ifneq (,$(INVALID_MOD_NAMES))
	@echo "Invalid mod(s) '$(INVALID_MOD_NAMES)'. Available mods are: $(MOD_LIST)."
	@exit 1
endif
	./scripts/create_firmware.sh $< $(BUILD_DIR) $@ $(OVERLAYS)

.PHONY: build
build: validate-build

.PHONY: validate-build
validate-build: $(OUTPUT_FILE) firmware/$(FIRMWARE_FILE)
	./scripts/validate_firmware.sh \
		--firmware "$(OUTPUT_FILE)" \
		--base-firmware "firmware/$(FIRMWARE_FILE)" \
		--profile "$(PROFILE)" \
		--report "$(OUTPUT_FILE).validation.txt"

EXTRACT_DIR := tmp/extracted-$(FIRMWARE_VERSION)

.PHONY: extract
extract: firmware/$(FIRMWARE_FILE) tools
	./scripts/extract_squashfs.sh $< $(EXTRACT_DIR)

.PHONY: overlays
overlays:
	@echo $(OVERLAYS)

.PHONY: mods
mods:
	@echo "Available firmwares: $(FIRMWARES)"
	@echo "Available mods: $(MOD_LIST)"

# ================= Tools =================

.PHONY: tools
tools: tools/rk2918_tools tools/upfile tools/resource_tool

tools/%: FORCE
	make -C $@

# =============== Firmware ===============

.PHONY: firmware
firmware: firmware/$(FIRMWARE_FILE)

firmware/$(FIRMWARE_FILE): FORCE
	@mkdir -p firmware
	@if [ -f "$@" ] && echo "$(FIRMWARE_SHA256)  $@" | sha256sum -c --status; then \
		echo "Verified cached base firmware: $@"; \
	else \
		rm -f "$@.tmp"; \
		wget -O "$@.tmp" "https://public.resource.snapmaker.com/firmware/U1/$(FIRMWARE_FILE)"; \
		echo "$(FIRMWARE_SHA256)  $@.tmp" | sha256sum -c --quiet; \
		mv "$@.tmp" "$@"; \
	fi

# ================= Test =================

test: test-validation firmware/$(FIRMWARE_FILE)
	make -C tools test FIRMWARE_FILE=$(CURDIR)/firmware/$(FIRMWARE_FILE)

.PHONY: test-validation
test-validation:
	bash scripts/tests/validate_firmware_test.sh || { echo "::error title=Validation test failed::validate_firmware_test.sh"; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/firmware_upgrade_preflight_test.py || { echo "::error title=Validation test failed::firmware_upgrade_preflight_test.py"; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/cache_file_test.py || { echo "::error title=Validation test failed::cache_file_test.py"; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/spoollink_mapping_test.py || { echo "::error title=Validation test failed::spoollink_mapping_test.py"; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/spoollink_behavior_test.py || { echo "::error title=Validation test failed::spoollink_behavior_test.py"; exit 1; }
	bash scripts/tests/camera_hook_test.sh || { echo "::error title=Validation test failed::camera_hook_test.sh"; exit 1; }
	bash scripts/tests/firmware_upgrade_health_test.sh || { echo "::error title=Validation test failed::firmware_upgrade_health_test.sh"; exit 1; }
	bash scripts/tests/upgrade_path_test.sh || { echo "::error title=Validation test failed::upgrade_path_test.sh"; exit 1; }

# ================= Helpers =================

.PHONY: changelog
changelog:
	@echo "## Changes since last release\n"
	@git log $$(git describe --tags --abbrev=0)..HEAD --pretty=format:"- %s (%h) by @%an"

.PHONY: FORCE
FORCE:
