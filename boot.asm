; Minimal x86 boot sector
; BIOS loads this sector at 0x7C00 and jumps to it.

bits 16
org 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov si, message
.print:
    lodsb
    test al, al
    jz .hang
    mov ah, 0x0E
    mov bh, 0
    int 0x10
    jmp .print

.hang:
    cli
    hlt
    jmp .hang

message db "Hello from NovaOS bootloader!", 0

times 510-($-$$) db 0
dw 0xAA55
