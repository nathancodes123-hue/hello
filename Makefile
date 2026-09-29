NASM ?= nasm
BUILD := build
KERNEL_SECTORS := 128

.PHONY: all clean run

all: $(BUILD)/novaos.img

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/boot.bin: boot.asm | $(BUILD)
	$(NASM) -f bin boot.asm -o $@
	test $$(wc -c < $@) -eq 512

$(BUILD)/kernel.bin: kernel.asm | $(BUILD)
	$(NASM) -f bin kernel.asm -o $@
	@test $$(wc -c < $@) -le $$(($(KERNEL_SECTORS) * 512))
	dd if=/dev/zero of=$@.pad bs=512 count=$(KERNEL_SECTORS) 2>/dev/null
	dd if=$@ of=$@.pad conv=notrunc 2>/dev/null
	mv $@.pad $@

$(BUILD)/novaos.img: $(BUILD)/boot.bin $(BUILD)/kernel.bin
	dd if=/dev/zero of=$@ bs=512 count=2880 2>/dev/null
	dd if=$(BUILD)/boot.bin of=$@ conv=notrunc 2>/dev/null
	dd if=$(BUILD)/kernel.bin of=$@ bs=512 seek=1 conv=notrunc 2>/dev/null

run: $(BUILD)/novaos.img
	qemu-system-i386 -drive format=raw,file=$(BUILD)/novaos.img

clean:
	rm -rf $(BUILD)
