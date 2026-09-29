bits 16
org 0x7C00

KERNEL_SEG     equ 0x1000
KERNEL_SECTORS equ 128
SECTORS_TRACK  equ 18

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl

    ; Enter BIOS VGA mode 13h (320x200, 256 colors) before protected mode.
    mov ax, 0x0013
    int 0x10

    xor ax, ax
    mov es, ax
    mov bx, KERNEL_SEG
    mov byte [sector], 2
    mov byte [head], 0
    mov byte [track], 0
    mov byte [sectors_left], KERNEL_SECTORS

.read_sector:
    mov ah, 0x02
    mov al, 1
    mov ch, [track]
    mov cl, [sector]
    mov dh, [head]
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    add bx, 512
    jnc .buffer_ok
    mov ax, es
    add ax, 0x1000
    mov es, ax
    xor bx, bx
.buffer_ok:

    inc byte [sector]
    cmp byte [sector], SECTORS_TRACK + 1
    jb .same_track
    mov byte [sector], 1
    inc byte [head]
    cmp byte [head], 2
    jb .same_track
    mov byte [head], 0
    inc byte [track]
.same_track:

    dec byte [sectors_left]
    jnz .read_sector

    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp 0x08:protected_mode

disk_error:
    mov si, disk_error_msg
.print:
    lodsb
    test al, al
    jz $
    mov ah, 0x0E
    int 0x10
    jmp .print

bits 32
protected_mode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000
    jmp 0x08:0x1000

boot_drive db 0
sector db 2
head db 0
track db 0
sectors_left db KERNEL_SECTORS
disk_error_msg db "NovaOS: kernel disk read failed.", 0

align 8
gdt_start:
    dq 0
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

times 510-($-$$) db 0
dw 0xAA55
