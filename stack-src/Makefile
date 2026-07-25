ZC := .toolchain/Zen-C/zc
COSMOCC := $(CURDIR)/.toolchain/cosmocc/bin/cosmocc
BUILD_DIR := build
ROOT_DIR := ..

.PHONY: all clean

all: $(ROOT_DIR)/stack-check.com $(ROOT_DIR)/stack-push.com

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/stack-check.com: stack-check.zc shared.zc | $(BUILD_DIR)
	$(ZC) build --cc $(COSMOCC) $< -o $@

$(BUILD_DIR)/stack-push.com: stack-push.zc shared.zc | $(BUILD_DIR)
	$(ZC) build -Dstack_push --cc $(COSMOCC) $< -o $@

$(ROOT_DIR)/stack-check.com: $(BUILD_DIR)/stack-check.com
	cp $< $@

$(ROOT_DIR)/stack-push.com: $(BUILD_DIR)/stack-push.com
	cp $< $@

clean:
	rm -f $(ROOT_DIR)/stack-check.com $(ROOT_DIR)/stack-push.com
	rm -f $(BUILD_DIR)/stack-check.com $(BUILD_DIR)/stack-check.com.dbg $(BUILD_DIR)/stack-check.aarch64.elf
	rm -f $(BUILD_DIR)/stack-push.com $(BUILD_DIR)/stack-push.com.dbg $(BUILD_DIR)/stack-push.aarch64.elf
	rmdir $(BUILD_DIR) 2>/dev/null || true
