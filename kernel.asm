bits 32
org 0x1000

; ============================================================
; NovaOS kernel 0.3
; 32-bit protected-mode kernel
;
; Hardware:
;   - VGA text console
;   - 8259 PIC
;   - PIT timer
;   - PS/2 keyboard IRQ
;
; Kernel services:
;   - interrupt handling
;   - bump allocator
;   - in-memory VFS
;   - command shell
;   - command history
;   - basic process/status placeholders
;
; This is a real kernel foundation, not GNU Bash itself.
; ============================================================

VGA             equ 0xB8000
PIC1_COMMAND     equ 0x20
PIC1_DATA        equ 0x21
PIC2_COMMAND     equ 0xA0
PIC2_DATA        equ 0xA1
PIT_COMMAND      equ 0x43
PIT_CHANNEL0     equ 0x40
KEYBOARD_DATA    equ 0x60
MAX_CMD          equ 127
MAX_FILES        equ 32
MAX_NAME         equ 15
MAX_FILE_DATA    equ 127
KERNEL_HEAP      equ 0x200000

start:
    cli
    mov esp, kernel_stack_top
    call clear_screen
    call init_idt
    call init_pmm
    call init_paging
    call init_pic
    call init_pit
    call init_vfs
    call init_heap
    call gui_init

    sti

    mov esi, banner
    call print_string
    call newline
    mov esi, boot_message
    call print_string
    call newline
    mov esi, help_hint
    call print_string
    call newline
    ; GUI owns the visible framebuffer; the legacy shell remains available
    ; internally until the terminal/window system is connected.
    call gui_render

kernel_idle:
    call keyboard_poll
    call timer_housekeeping
    jmp kernel_idle

; ============================================================
; Interrupt Descriptor Table
; ============================================================

init_idt:
    mov edi, idt
    xor eax, eax
    mov ecx, 512
    rep stosd

    ; CPU exceptions 0-31 all enter a fatal exception handler.
    mov eax, exception_stub
    xor ebx, ebx
.exception_loop:
    call set_idt_gate
    inc ebx
    cmp ebx, 32
    jb .exception_loop

    mov eax, timer_irq
    mov ebx, 0x20
    call set_idt_gate

    mov eax, keyboard_irq
    mov ebx, 0x21
    call set_idt_gate

    mov word [idtr.limit], (256 * 8) - 1
    mov dword [idtr.base], idt
    lidt [idtr]
    ret

set_idt_gate:
    push eax
    push ebx
    mov edx, eax
    and eax, 0xFFFF
    mov word [idt + ebx*8], ax
    mov word [idt + ebx*8 + 2], 0x08
    mov byte [idt + ebx*8 + 4], 0
    mov byte [idt + ebx*8 + 5], 0x8E
    shr edx, 16
    mov word [idt + ebx*8 + 6], dx
    pop ebx
    pop eax
    ret

; ============================================================
; 8259 PIC
; ============================================================

init_pic:
    mov al, 0x11
    out PIC1_COMMAND, al
    out PIC2_COMMAND, al

    mov al, 0x20
    out PIC1_DATA, al
    mov al, 0x28
    out PIC2_DATA, al

    mov al, 0x04
    out PIC1_DATA, al
    mov al, 0x02
    out PIC2_DATA, al

    mov al, 0x01
    out PIC1_DATA, al
    out PIC2_DATA, al

    ; Enable IRQ0 and IRQ1 only.
    mov al, 0xFC
    out PIC1_DATA, al
    mov al, 0xFF
    out PIC2_DATA, al
    ret

; ============================================================
; PIT: about 100 Hz
; ============================================================

init_pit:
    mov al, 0x36
    out PIT_COMMAND, al

    mov ax, 11931
    out PIT_CHANNEL0, al
    mov al, ah
    out PIT_CHANNEL0, al
    ret

timer_irq:
    pusha
    inc dword [ticks]
    mov al, 0x20
    out PIC1_COMMAND, al
    popa
    iretd

keyboard_irq:
    pusha
    in al, KEYBOARD_DATA
    test al, 0x80
    jnz .done

    movzx eax, al
    mov al, [scan_table + eax]
    test al, al
    jz .done

    mov edx, [kbd_head]
    mov [kbd_buffer + edx], al
    inc edx
    and edx, 127
    cmp edx, [kbd_tail]
    je .full
    mov [kbd_head], edx
.full:
.done:
    mov al, 0x20
    out PIC1_COMMAND, al
    popa
    iretd

; ============================================================
; Keyboard consumer
; ============================================================

keyboard_poll:
.next:
    mov eax, [kbd_tail]
    cmp eax, [kbd_head]
    je .done

    mov al, [kbd_buffer + eax]
    inc eax
    and eax, 127
    mov [kbd_tail], eax

    cmp al, 0x0D
    je .enter
    cmp al, 0x08
    je .backspace

    cmp byte [cmd_length], MAX_CMD
    jae .next

    movzx edx, byte [cmd_length]
    mov [cmdline + edx], al
    inc byte [cmd_length]
    call put_char
    jmp .next

.enter:
    movzx edx, byte [cmd_length]
    mov byte [cmdline + edx], 0
    call newline
    call save_history
    call execute_command
    mov byte [cmd_length], 0
    mov byte [cmdline], 0
    call shell_prompt
    jmp .next

.backspace:
    cmp byte [cmd_length], 0
    je .next
    dec byte [cmd_length]
    movzx edx, byte [cmd_length]
    mov byte [cmdline + edx], 0
    call erase_char
    jmp .next

.done:
    ret

; ============================================================
; Shell
; ============================================================

shell_prompt:
    mov esi, prompt
    call print_string
    ret

execute_command:
    mov esi, cmdline
    call skip_spaces
    cmp byte [esi], 0
    je .done

    mov edi, s_help
    call command_is
    jz .help

    mov edi, s_clear
    call command_is
    jz .clear

    mov edi, s_about
    call command_is
    jz .about

    mov edi, s_echo
    call command_is
    jz .echo

    mov edi, s_pwd
    call command_is
    jz .pwd

    mov edi, s_cd
    call command_is
    jz .cd

    mov edi, s_ls
    call command_is
    jz .ls

    mov edi, s_cat
    call command_is
    jz .cat

    mov edi, s_touch
    call command_is
    jz .touch

    mov edi, s_write
    call command_is
    jz .write

    mov edi, s_mkdir
    call command_is
    jz .mkdir

    mov edi, s_rm
    call command_is
    jz .rm

    mov edi, s_stat
    call command_is
    jz .stat

    mov edi, s_mem
    call command_is
    jz .mem

    mov edi, s_mm
    call command_is
    jz .mm

    mov edi, s_uptime
    call command_is
    jz .uptime

    mov edi, s_history
    call command_is
    jz .history

    mov edi, s_uname
    call command_is
    jz .uname

    mov edi, s_whoami
    call command_is
    jz .whoami

    mov edi, s_env
    call command_is
    jz .env

    mov edi, s_true
    call command_is
    jz .true

    mov edi, s_false
    call command_is
    jz .false

    mov edi, s_reboot
    call command_is
    jz .reboot

    mov edi, s_halt
    call command_is
    jz .halt

    mov esi, cmd_not_found
    call print_string
    call newline
    mov dword [last_status], 127
    ret

.done:
    ret

.help:
    mov esi, help_text
    call print_string
    call newline
    xor eax, eax
    mov [last_status], eax
    ret

.clear:
    call clear_screen
    xor eax, eax
    mov [last_status], eax
    ret

.about:
    mov esi, about_text
    call print_string
    call newline
    ret

.echo:
    call get_args
    call print_string
    call newline
    ret

.pwd:
    mov esi, cwd
    call print_string
    call newline
    ret

.cd:
    call get_args
    cmp byte [esi], 0
    je .cd_root
    cmp byte [esi], '/'
    je .cd_root
    mov esi, cd_error
    call print_string
    call newline
    mov dword [last_status], 1
    ret
.cd_root:
    mov byte [cwd], '/'
    mov byte [cwd+1], 0
    xor eax, eax
    mov [last_status], eax
    ret

.ls:
    call vfs_ls
    ret

.cat:
    call get_args
    cmp byte [esi], 0
    jne .cat_have_arg
    mov esi, usage_cat
    call print_string
    call newline
    ret
.cat_have_arg:
    call copy_arg
    call vfs_cat
    ret

.touch:
    call get_args
    cmp byte [esi], 0
    jne .touch_arg
    mov esi, usage_touch
    call print_string
    call newline
    ret
.touch_arg:
    call copy_arg
    call vfs_touch_file
    ret

.write:
    call parse_write
    ret

.mkdir:
    call get_args
    cmp byte [esi], 0
    jne .mkdir_arg
    mov esi, usage_mkdir
    call print_string
    call newline
    ret
.mkdir_arg:
    call copy_arg
    call vfs_mkdir
    ret

.rm:
    call get_args
    cmp byte [esi], 0
    jne .rm_arg
    mov esi, usage_rm
    call print_string
    call newline
    ret
.rm_arg:
    call copy_arg
    call vfs_rm
    ret

.stat:
    call get_args
    cmp byte [esi], 0
    jne .stat_arg
    mov esi, usage_stat
    call print_string
    call newline
    ret
.stat_arg:
    call copy_arg
    call vfs_stat
    ret

.mem:
    mov esi, mem_text
    call print_string
    mov eax, [heap_next]
    call print_hex
    call newline
    ret

.mm:
    mov esi, mm_text
    call print_string
    mov eax, [pmm_free_pages]
    call print_decimal
    mov esi, mm_pages
    call print_string
    mov eax, [heap_next]
    call print_hex
    mov esi, mm_heap
    call print_string
    call newline
    ret

.uptime:
    mov eax, [ticks]
    call print_decimal
    mov esi, uptime_text
    call print_string
    call newline
    ret

.history:
    call print_history
    ret

.uname:
    mov esi, uname_text
    call print_string
    call newline
    ret

.whoami:
    mov esi, whoami_text
    call print_string
    call newline
    ret

.env:
    mov esi, env_text
    call print_string
    call newline
    ret

.true:
    mov dword [last_status], 0
    ret

.false:
    mov dword [last_status], 1
    ret

.reboot:
    mov esi, reboot_text
    call print_string
    call newline
    cli
    mov al, 0xFE
    out 0x64, al
.reboot_wait:
    hlt
    jmp .reboot_wait

.halt:
    mov esi, halt_text
    call print_string
    call newline
    cli
.halt_loop:
    hlt
    jmp .halt_loop

; ============================================================
; Command parsing helpers
; ============================================================

command_is:
    push esi
    push edi
.compare:
    mov al, [esi]
    mov dl, [edi]
    cmp dl, 0
    je .name_end
    cmp al, dl
    jne .no
    inc esi
    inc edi
    jmp .compare
.name_end:
    cmp byte [esi], 0
    je .yes
    cmp byte [esi], ' '
    je .yes
.no:
    pop edi
    pop esi
    mov eax, 1
    ret
.yes:
    pop edi
    pop esi
    xor eax, eax
    ret

skip_spaces:
.loop:
    cmp byte [esi], ' '
    jne .done
    inc esi
    jmp .loop
.done:
    ret

get_args:
    mov esi, cmdline
    call skip_spaces
.find:
    cmp byte [esi], 0
    je .empty
    cmp byte [esi], ' '
    je .found
    inc esi
    jmp .find
.found:
    call skip_spaces
.empty:
    ret

copy_arg:
    mov edi, argbuf
    xor ecx, ecx
.loop:
    mov al, [esi]
    cmp al, 0
    je .done
    cmp al, ' '
    je .done
    cmp ecx, MAX_NAME
    jae .done
    stosb
    inc esi
    inc ecx
    jmp .loop
.done:
    mov al, 0
    stosb
    ret

parse_write:
    mov esi, cmdline
    call get_args
    cmp byte [esi], 0
    je .usage
    call copy_arg
    call skip_spaces
    cmp byte [esi], 0
    je .usage
    mov edi, writebuf
    xor ecx, ecx
.loop:
    mov al, [esi]
    test al, al
    jz .done
    cmp ecx, MAX_FILE_DATA
    jae .done
    stosb
    inc esi
    inc ecx
    jmp .loop
.done:
    mov al, 0
    stosb
    mov [write_length], ecx
    call vfs_write_file
    ret
.usage:
    mov esi, usage_write
    call print_string
    call newline
    mov dword [last_status], 2
    ret

; ============================================================
; In-memory VFS
; ============================================================

init_vfs:
    mov edi, file_used
    xor eax, eax
    mov ecx, MAX_FILES
    rep stosb

    ; Built-in /etc/motd
    mov byte [file_used], 1
    mov byte [file_type], 0
    mov edi, file_names
    mov esi, motd_name
    call copy_string_fixed
    mov edi, file_data
    mov esi, motd_data
    call copy_string
    mov byte [file_size], 26

    ; Built-in /README
    mov byte [file_used+1], 1
    mov byte [file_type+1], 0
    mov edi, file_names + 16
    mov esi, readme_name
    call copy_string_fixed
    mov edi, file_data + 128
    mov esi, readme_data
    call copy_string
    mov byte [file_size+1], 25
    ret

vfs_ls:
    xor ebx, ebx
.loop:
    cmp ebx, MAX_FILES
    jae .done
    cmp byte [file_used + ebx], 0
    je .next
    mov eax, ebx
    shl eax, 4
    mov esi, file_names
    add esi, eax
    call print_string
    mov al, ' '
    call put_char
    cmp byte [file_type + ebx], 1
    jne .file
    mov esi, dir_suffix
    call print_string
    jmp .line
.file:
    mov esi, file_suffix
    call print_string
.line:
    call newline
.next:
    inc ebx
    jmp .loop
.done:
    xor eax, eax
    mov [last_status], eax
    ret

find_file:
    xor ebx, ebx
.loop:
    cmp ebx, MAX_FILES
    jae .not_found
    cmp byte [file_used + ebx], 0
    je .next
    push esi
    mov edi, file_names
    mov eax, ebx
    shl eax, 4
    add edi, eax
    call strings_equal
    pop esi
    jz .found
.next:
    inc ebx
    jmp .loop
.not_found:
    mov ebx, -1
.found:
    ret

strings_equal:
    push esi
    push edi
.loop:
    mov al, [esi]
    mov dl, [edi]
    cmp al, dl
    jne .no
    test al, al
    jz .yes
    inc esi
    inc edi
    jmp .loop
.no:
    pop edi
    pop esi
    mov eax, 1
    ret
.yes:
    pop edi
    pop esi
    xor eax, eax
    ret

vfs_cat:
    mov esi, argbuf
    call find_file
    cmp ebx, -1
    je .missing
    cmp byte [file_type + ebx], 1
    je .is_dir
    mov eax, ebx
    shl eax, 7
    mov esi, file_data
    add esi, eax
    call print_string
    call newline
    xor eax, eax
    mov [last_status], eax
    ret
.missing:
    mov esi, file_missing
    call print_string
    call newline
    mov dword [last_status], 1
    ret
.is_dir:
    mov esi, is_directory
    call print_string
    call newline
    mov dword [last_status], 1
    ret

vfs_touch_file:
    mov esi, argbuf
    call find_file
    cmp ebx, -1
    jne .exists
    call alloc_file
    cmp ebx, -1
    je .full
    mov byte [file_type + ebx], 0
    mov edi, file_names
    mov eax, ebx
    shl eax, 4
    add edi, eax
    mov esi, argbuf
    call copy_string_fixed
    mov byte [file_size + ebx], 0
    mov edi, file_data
    mov eax, ebx
    shl eax, 7
    add edi, eax
    mov byte [edi], 0
.exists:
    xor eax, eax
    mov [last_status], eax
    ret
.full:
    mov esi, vfs_full
    call print_string
    call newline
    mov dword [last_status], 1
    ret

vfs_write_file:
    mov esi, argbuf
    call find_file
    cmp ebx, -1
    jne .found
    call vfs_touch_file
    mov esi, argbuf
    call find_file
.found:
    cmp ebx, -1
    je .fail
    cmp byte [file_type + ebx], 1
    je .fail
    mov eax, ebx
    shl eax, 7
    mov edi, file_data
    add edi, eax
    mov esi, writebuf
    call copy_string
    mov eax, [write_length]
    mov [file_size + ebx], al
    xor eax, eax
    mov [last_status], eax
    ret
.fail:
    mov esi, write_error
    call print_string
    call newline
    mov dword [last_status], 1
    ret

vfs_mkdir:
    mov esi, argbuf
    call find_file
    cmp ebx, -1
    jne .exists
    call alloc_file
    cmp ebx, -1
    je .full
    mov byte [file_type + ebx], 1
    mov edi, file_names
    mov eax, ebx
    shl eax, 4
    add edi, eax
    mov esi, argbuf
    call copy_string_fixed
    xor eax, eax
    mov [last_status], eax
    ret
.exists:
    mov esi, already_exists
    call print_string
    call newline
    mov dword [last_status], 1
    ret
.full:
    mov esi, vfs_full
    call print_string
    call newline
    mov dword [last_status], 1
    ret

vfs_rm:
    mov esi, argbuf
    call find_file
    cmp ebx, -1
    je .missing
    mov byte [file_used + ebx], 0
    xor eax, eax
    mov [last_status], eax
    ret
.missing:
    mov esi, file_missing
    call print_string
    call newline
    mov dword [last_status], 1
    ret

vfs_stat:
    mov esi, argbuf
    call find_file
    cmp ebx, -1
    je .missing
    mov esi, stat_name
    call print_string
    mov eax, ebx
    shl eax, 4
    mov esi, file_names
    add esi, eax
    call print_string
    mov esi, stat_size
    call print_string
    movzx eax, byte [file_size + ebx]
    call print_decimal
    mov esi, stat_bytes
    call print_string
    call newline
    ret
.missing:
    mov esi, file_missing
    call print_string
    call newline
    mov dword [last_status], 1
    ret

alloc_file:
    xor ebx, ebx
.loop:
    cmp ebx, MAX_FILES
    jae .full
    cmp byte [file_used + ebx], 0
    je .found
    inc ebx
    jmp .loop
.found:
    mov byte [file_used + ebx], 1
    ret
.full:
    mov ebx, -1
    ret

; ============================================================
; History
; ============================================================

save_history:
    cmp byte [cmd_length], 0
    je .done

    mov eax, [history_count]
    cmp eax, 16
    jb .no_shift

    mov esi, history + 128
    mov edi, history
    mov ecx, 15 * 128 / 4
    rep movsd
    dec dword [history_count]
.no_shift:
    mov eax, [history_count]
    imul eax, 128
    mov edi, history
    add edi, eax
    mov esi, cmdline
    call copy_string
    inc dword [history_count]
.done:
    ret

print_history:
    xor ebx, ebx
.loop:
    cmp ebx, [history_count]
    jae .done
    mov eax, ebx
    inc eax
    call print_decimal
    mov al, ' '
    call put_char
    mov eax, ebx
    imul eax, 128
    mov esi, history
    add esi, eax
    call print_string
    call newline
    inc ebx
    jmp .loop
.done:
    ret

; ============================================================
; Heap
; ============================================================

init_heap:
    mov dword [heap_next], KERNEL_HEAP
    ret

kmalloc:
    ; EAX = requested bytes. Returns EAX = old heap pointer.
    push ebx
    mov ebx, eax
    add ebx, 15
    and ebx, 0xFFFFFFF0
    mov eax, [heap_next]
    add [heap_next], ebx
    pop ebx
    ret

; ============================================================
; Console
; ============================================================

clear_screen:
    push eax
    push ecx
    push edi
    mov edi, VGA
    mov ax, 0x0720
    mov ecx, 2000
    rep stosw
    mov dword [cursor], 0
    pop edi
    pop ecx
    pop eax
    ret

put_char:
    push eax
    push ebx
    push edi
    mov edi, VGA
    mov ebx, [cursor]
    cmp ebx, 2000
    jb .ok
    call clear_screen
    xor ebx, ebx
.ok:
    cmp al, 0x0A
    je .newline
    shl ebx, 1
    add edi, ebx
    mov ah, 0x07
    stosw
    inc dword [cursor]
    jmp .done
.newline:
    call newline
.done:
    pop edi
    pop ebx
    pop eax
    ret

erase_char:
    cmp dword [cursor], 0
    je .done
    dec dword [cursor]
    mov eax, [cursor]
    shl eax, 1
    mov edi, VGA
    add edi, eax
    mov ax, 0x0720
    stosw
.done:
    ret

newline:
    push eax
    push ebx
    push edx
    mov eax, [cursor]
    xor edx, edx
    mov ebx, 80
    div ebx
    inc eax
    imul eax, 80
    mov [cursor], eax
    pop edx
    pop ebx
    pop eax
    ret

print_string:
    push eax
.next:
    lodsb
    test al, al
    jz .done
    call put_char
    jmp .next
.done:
    pop eax
    ret

print_hex:
    push eax
    push ebx
    push ecx
    push edx
    mov edx, eax
    mov esi, hex_prefix
    call print_string
    mov ecx, 8
.loop:
    rol edx, 4
    mov eax, edx
    and eax, 0x0F
    mov al, [hex_chars + eax]
    call put_char
    loop .loop
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

print_decimal:
    push eax
    push ebx
    push ecx
    push edx
    cmp eax, 0
    jne .convert
    mov al, '0'
    call put_char
    jmp .done
.convert:
    xor ecx, ecx
    mov ebx, 10
.loop:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    test eax, eax
    jnz .loop
.print:
    pop eax
    add al, '0'
    call put_char
    loop .print
.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

copy_string:
    push eax
.loop:
    lodsb
    stosb
    test al, al
    jnz .loop
    pop eax
    ret

copy_string_fixed:
    push eax
    push ecx
    mov ecx, MAX_NAME
.loop:
    lodsb
    test al, al
    jz .zero
    stosb
    loop .loop
    jmp .done
.zero:
    stosb
    dec ecx
    jz .done
    xor eax, eax
    rep stosb
.done:
    pop ecx
    pop eax
    ret

timer_housekeeping:
    ret

; ============================================================
; GUI / VGA Mode 13h
; ============================================================
; The bootloader selects 320x200x256 VGA mode 13h while still in
; real mode. The kernel then draws directly to A0000h after entering
; protected mode. This is intentionally a first GUI layer; a later
; VBE/GOP driver will replace the fixed VGA framebuffer.
;
; 320 * 200 = 64000 bytes, so the whole framebuffer is below 0xB0000
; and is covered by the initial identity mapping.

GUI_FB      equ 0xA0000
GUI_WIDTH   equ 320
GUI_HEIGHT  equ 200

gui_init:
    mov byte [gui_enabled], 1
    ret

; Draw a simple Nova desktop/window shell.
gui_render:
    cmp byte [gui_enabled], 0
    je .done

    ; Desktop.
    mov eax, 1
    xor ebx, ebx
    xor ecx, ecx
    mov edx, GUI_WIDTH
    mov esi, GUI_HEIGHT
    call gui_fill_rect

    ; Top bar.
    mov eax, 9
    xor ebx, ebx
    xor ecx, ecx
    mov edx, GUI_WIDTH
    mov esi, 18
    call gui_fill_rect

    ; Main window.
    mov eax, 7
    mov ebx, 24
    mov ecx, 30
    mov edx, 272
    mov esi, 140
    call gui_fill_rect

    ; Window body.
    mov eax, 0
    mov ebx, 28
    mov ecx, 52
    mov edx, 264
    mov esi, 114
    call gui_fill_rect

    ; Three window controls.
    mov eax, 15
    mov ebx, 34
    mov ecx, 36
    mov edx, 10
    mov esi, 6
    call gui_fill_rect

    mov eax, 15
    mov ebx, 50
    mov ecx, 36
    mov edx, 10
    mov esi, 6
    call gui_fill_rect

    mov eax, 15
    mov ebx, 66
    mov ecx, 36
    mov edx, 10
    mov esi, 6
    call gui_fill_rect

    ; Terminal-like panel.
    mov eax, 0
    mov ebx, 40
    mov ecx, 68
    mov edx, 240
    mov esi, 72
    call gui_fill_rect

    ; Status/task bar.
    mov eax, 8
    xor ebx, ebx
    mov ecx, 184
    mov edx, GUI_WIDTH
    mov esi, 16
    call gui_fill_rect

    ; Nova logo block.
    mov eax, 15
    mov ebx, 12
    mov ecx, 4
    mov edx, 8
    mov esi, 8
    call gui_fill_rect
    mov eax, 15
    mov ebx, 20
    mov ecx, 4
    mov edx, 8
    mov esi, 8
    call gui_fill_rect
    mov eax, 15
    mov ebx, 16
    mov ecx, 8
    mov edx, 8
    mov esi, 8
    call gui_fill_rect
.done:
    ret

; EAX=color, EBX=x, ECX=y, EDX=width, ESI=height.
gui_fill_rect:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp ebx, GUI_WIDTH
    jae .out
    cmp ecx, GUI_HEIGHT
    jae .out
    test edx, edx
    jz .out
    test esi, esi
    jz .out

    mov edi, ebx
    add edi, edx
    cmp edi, GUI_WIDTH
    jbe .width_ok
    mov edx, GUI_WIDTH
    sub edx, ebx
.width_ok:

    mov edi, ecx
    add edi, esi
    cmp edi, GUI_HEIGHT
    jbe .height_ok
    mov esi, GUI_HEIGHT
    sub esi, ecx
.height_ok:

    mov edi, ecx
    imul edi, GUI_WIDTH
    add edi, ebx
    add edi, GUI_FB

    mov ebp, esi
.row:
    push edx
    mov ecx, edx
    mov edi, edi
    mov ebx, eax
    mov al, bl
    rep stosb
    pop edx

    add edi, GUI_WIDTH
    sub edi, edx
    dec ebp
    jnz .row

.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ============================================================
; Memory Management
; ============================================================
; This first MM layer manages a conservative 32 MiB physical window.
; 4 KiB physical frames are tracked by a bitmap.
; Paging identity-maps the same 32 MiB so kernel addresses remain stable.
;
; Later the bootloader can pass an E820 memory map and this layer can
; replace the fixed window with firmware-reported usable regions.

PMM_MAX_MEMORY equ 0x02000000
PMM_PAGE_SIZE  equ 0x1000
PMM_PAGE_COUNT equ PMM_MAX_MEMORY / PMM_PAGE_SIZE

init_pmm:
    ; Start with every frame reserved.
    mov edi, pmm_bitmap
    mov ecx, PMM_PAGE_COUNT / 8
    mov al, 0xFF
    rep stosb

    ; Treat 1 MiB..32 MiB as initially usable.
    mov edi, pmm_bitmap + 32
    mov ecx, (PMM_PAGE_COUNT - 256) / 8
    xor eax, eax
    rep stosb

    ; Reserve the kernel image itself, rounded to pages.
    mov eax, 0x10000
    mov ebx, kernel_end
    add ebx, PMM_PAGE_SIZE - 1
    and ebx, 0xFFFFF000
.reserve_kernel:
    cmp eax, ebx
    jae .done
    push eax
    call pmm_mark_used
    pop eax
    add eax, PMM_PAGE_SIZE
    jmp .reserve_kernel
.done:
    ; Reserve the fixed paging structures.
    mov eax, 0x90000
.reserve_tables:
    call pmm_mark_used
    add eax, PMM_PAGE_SIZE
    cmp eax, 0xA0000
    jb .reserve_tables

    ; Count free frames.
    call pmm_recount
    ret

pmm_mark_used:
    push eax
    push ebx
    push ecx
    mov ebx, eax
    shr ebx, 12
    mov ecx, ebx
    shr ebx, 3
    and ecx, 7
    mov al, 1
    shl al, cl
    or [pmm_bitmap + ebx], al
    pop ecx
    pop ebx
    pop eax
    ret

pmm_mark_free:
    push eax
    push ebx
    push ecx
    mov ebx, eax
    shr ebx, 12
    mov ecx, ebx
    shr ebx, 3
    and ecx, 7
    mov al, 1
    shl al, cl
    not al
    and [pmm_bitmap + ebx], al
    pop ecx
    pop ebx
    pop eax
    ret

; EAX = physical 4 KiB frame, or 0 on failure.
pmm_alloc:
    push ebx
    push ecx
    push edx
    xor ebx, ebx
.find:
    cmp ebx, PMM_PAGE_COUNT / 8
    jae .fail
    mov dl, [pmm_bitmap + ebx]
    cmp dl, 0xFF
    jne .byte_found
    inc ebx
    jmp .find
.byte_found:
    xor ecx, ecx
.bit:
    test dl, 1
    jz .free
    shr dl, 1
    inc ecx
    cmp ecx, 8
    jb .bit
    inc ebx
    jmp .find
.free:
    mov eax, ebx
    shl eax, 3
    add eax, ecx
    shl eax, 12
    call pmm_mark_used
    dec dword [pmm_free_pages]
    pop edx
    pop ecx
    pop ebx
    ret
.fail:
    xor eax, eax
    pop edx
    pop ecx
    pop ebx
    ret

; EAX = physical 4 KiB frame.
pmm_free:
    cmp eax, PMM_MAX_MEMORY
    jae .done
    cmp eax, 0x100000
    jb .done
    call pmm_mark_free
    inc dword [pmm_free_pages]
.done:
    ret

pmm_recount:
    push eax
    push ebx
    push ecx
    push edx
    xor eax, eax
    xor ebx, ebx
    mov ecx, PMM_PAGE_COUNT
.count:
    mov edx, ebx
    shr edx, 3
    movzx edx, byte [pmm_bitmap + edx]
    mov esi, ebx
    and esi, 7
    bt edx, esi
    jc .used
    inc eax
.used:
    inc ebx
    loop .count
    mov [pmm_free_pages], eax
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; Build a simple legacy x86 page directory:
; PDE[0..7] point to eight page tables, covering 32 MiB.
init_paging:
    mov edi, 0x90000
    xor eax, eax
    mov ecx, 1024
    rep stosd

    mov ebx, 0
    mov edi, 0x91000
    mov edx, 0
.table_loop:
    mov eax, edx
    or eax, 0x003
    mov ecx, 1024
    push edi
    push edx
.entry_loop:
    stosd
    add edx, PMM_PAGE_SIZE
    loop .entry_loop
    pop edx
    pop edi

    mov eax, edi
    or eax, 0x003
    mov [0x90000 + ebx*4], eax
    add edi, 0x1000
    inc ebx
    cmp ebx, 8
    jb .table_loop

    mov eax, 0x90000
    mov cr3, eax
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    jmp .flush
.flush:
    ret

; Simple page-aligned kernel heap. Physical pages come from PMM;
; this bump layer is deliberately conservative until a free-list/slab
; allocator is added.
kfree:
    ret

; ============================================================
; Exceptions / fault containment
; ============================================================

exception_stub:
    cli
    mov esi, exception_text
    call print_string
    mov eax, [ticks]
    call print_decimal
    mov esi, exception_ticks
    call print_string
    mov eax, cr2
    test eax, eax
    jz .halt
    mov esi, exception_cr2
    call print_string
    call print_hex
.halt:
    call newline
    mov esi, panic_text
    call print_string
    call newline
.fatal:
    hlt
    jmp .fatal

; ============================================================
; Data
; ============================================================

banner db "========================================",0
       db " NovaOS 0.3 kernel",0
       db "========================================",0
boot_message db "Protected mode, IDT, PIC, PIT, keyboard and VFS online.",0
help_hint db "Type 'help' for commands.",0
prompt db "Nova> ",0

help_text db "Commands:",0
          db " help clear about echo pwd cd ls cat touch write",0
          db " mkdir rm stat mem uptime history uname whoami env",0
          db " true false reboot halt",0

about_text db "NovaOS 0.3 - a small x86 kernel with an in-memory VFS.",0
cmd_not_found db "nova: command not found",0
cwd db "/",0
uname_text db "NovaOS nova 0.3 i386 x86",0
whoami_text db "root",0
env_text db "USER=root HOME=/ PATH=/bin:/usr/bin SHELL=/bin/nova",0
exception_text db "KERNEL EXCEPTION at tick ",0
exception_ticks db " CR2=",0
panic_text db "fatal: CPU exception; system halted.",0
exception_cr2 db "",0
cd_error db "cd: only / exists in the current VFS.",0
mem_text db "heap next: ",0
mm_text db "PMM free pages: ",0
mm_pages db "  heap: ",0
mm_heap db "",0
uptime_text db " ticks",0
reboot_text db "Rebooting...",0
halt_text db "System halted.",0
file_missing db "vfs: file not found",0
is_directory db "cat: target is a directory",0
vfs_full db "vfs: no free file slots",0
already_exists db "mkdir: entry already exists",0
write_error db "write: cannot write target",0
dir_suffix db " <DIR>",0
file_suffix db "",0
stat_name db "name: ",0
stat_size db " size: ",0
stat_bytes db " bytes",0
usage_cat db "usage: cat NAME",0
usage_touch db "usage: touch NAME",0
usage_write db "usage: write NAME TEXT",0
usage_mkdir db "usage: mkdir NAME",0
usage_rm db "usage: rm NAME",0
usage_stat db "usage: stat NAME",0
hex_prefix db "0x",0
hex_chars db "0123456789ABCDEF",0

s_help db "help",0
s_clear db "clear",0
s_about db "about",0
s_echo db "echo",0
s_pwd db "pwd",0
s_cd db "cd",0
s_ls db "ls",0
s_cat db "cat",0
s_touch db "touch",0
s_write db "write",0
s_mkdir db "mkdir",0
s_rm db "rm",0
s_stat db "stat",0
s_mem db "mem",0
s_mm db "mm",0
s_uptime db "uptime",0
s_history db "history",0
s_uname db "uname",0
s_whoami db "whoami",0
s_env db "env",0
s_true db "true",0
s_false db "false",0
s_reboot db "reboot",0
s_halt db "halt",0

motd_name db "motd",0
motd_data db "Welcome to NovaOS kernel mode.",0
readme_name db "README",0
readme_data db "NovaOS kernel VFS is online.",0

align 4

; IDT
idt times 256 dq 0
idtr:
    dw 0
    dd 0

; Keyboard ring buffer
kbd_buffer times 128 db 0
kbd_head dd 0
kbd_tail dd 0

; Shell
cmdline times 128 db 0
cmd_length db 0
argbuf times 16 db 0
writebuf times 128 db 0
write_length dd 0

; History
history times 16*128 db 0
history_count dd 0

; VFS
file_used times MAX_FILES db 0
file_type times MAX_FILES db 0
file_size times MAX_FILES db 0
file_names times MAX_FILES*16 db 0
file_data times MAX_FILES*128 db 0

; Kernel state
pmm_free_pages dd 0
gui_enabled db 0
cursor dd 0
ticks dd 0
last_status dd 0
heap_next dd KERNEL_HEAP

; Physical memory bitmap: 8192 frames / 8 = 1024 bytes.
align 4
pmm_bitmap times PMM_PAGE_COUNT/8 db 0

; Stack
align 16
kernel_stack times 16384 db 0
kernel_stack_top:

kernel_end:

; Set-1 US keyboard map. Zero means ignore.
scan_table:
    db 27,0,'1','2','3','4','5','6','7','8','9','0','-','=',8,9
    db 'q','w','e','r','t','y','u','i','o','p','[',']',13,0,'a','s'
    db 'd','f','g','h','j','k','l',';',39,96,0,0,'z','x','c','v'
    db 'b','n','m',',','.','/',0,'*',0,' ',0,0,0,0,0,0
    times 64 db 0
    times 16 db 0
    times 16 db 0
    times 16 db 0
