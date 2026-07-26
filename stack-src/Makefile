NIM := .toolchain/nim/bin/nim
COSMOCC := $(CURDIR)/.toolchain/cosmocc/bin/cosmocc
BUILD_DIR := build
ROOT_DIR := ..
NIMFLAGS := --cc:env -d:release -d:useMalloc -d:useFork --mm:orc \
	--passC:-Wno-discarded-qualifiers

.PHONY: all clean

all: $(ROOT_DIR)/stack-check.com $(ROOT_DIR)/stack-push.com

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/stack-check.com: stack_check.nim stack_shared.nim | $(BUILD_DIR)
	CC=$(COSMOCC) $(NIM) c $(NIMFLAGS) --nimcache:$(BUILD_DIR)/stack-check -o:$@ $<

$(BUILD_DIR)/stack-push.com: stack_push.nim stack_shared.nim | $(BUILD_DIR)
	CC=$(COSMOCC) $(NIM) c $(NIMFLAGS) --nimcache:$(BUILD_DIR)/stack-push -o:$@ $<

$(ROOT_DIR)/stack-check.com: $(BUILD_DIR)/stack-check.com
	cp $< $@

$(ROOT_DIR)/stack-push.com: $(BUILD_DIR)/stack-push.com
	cp $< $@

clean:
	rm -f $(ROOT_DIR)/stack-check.com $(ROOT_DIR)/stack-push.com
	rm -rf $(BUILD_DIR)/stack-check $(BUILD_DIR)/stack-push
	rm -f $(BUILD_DIR)/stack-check.com $(BUILD_DIR)/stack-check.com.dbg $(BUILD_DIR)/stack-check.aarch64.elf
	rm -f $(BUILD_DIR)/stack-push.com $(BUILD_DIR)/stack-push.com.dbg $(BUILD_DIR)/stack-push.aarch64.elf
	rmdir $(BUILD_DIR) 2>/dev/null || true
