bits 32
org 0x1000

VGA equ 0xB8000
KEYBOARD equ 0x60

start:
    cli
    call clear_screen
    mov esi, banner
    call print_string
    call newline
    mov esi, help_text
    call print_string
    call newline

shell:
    mov esi, prompt
    call print_string
    mov edi, command_buffer
    xor ecx, ecx

.read:
    in al, KEYBOARD
    test al, al
    jz .read
    test al, 0x80
    jnz .read
    cmp al, 0x1C
    je .enter
    cmp al, 0x0E
    je .backspace
    call scan_to_ascii
    test al, al
    jz .read
    cmp ecx, 63
    jae .read
    stosb
    inc ecx
    call put_char
    jmp .read

.enter:
    mov byte [edi], 0
    call newline
    call execute_command
    jmp shell

.backspace:
    test ecx, ecx
    jz .read
    dec edi
    dec ecx
    call erase_char
    jmp .read

execute_command:
    mov esi, command_buffer
    mov edi, cmd_help
    call strcmp
    test eax, eax
    jz .help

    mov esi, command_buffer
    mov edi, cmd_clear
    call strcmp
    test eax, eax
    jz .clear

    mov esi, command_buffer
    mov edi, cmd_about
    call strcmp
    test eax, eax
    jz .about

    mov esi, command_buffer
    mov edi, cmd_reboot
    call strcmp
    test eax, eax
    jz .reboot

    mov esi, command_buffer
    mov edi, cmd_halt
    call strcmp
    test eax, eax
    jz .halt

    cmp byte [command_buffer], 0
    je .done
    mov esi, unknown
    call print_string
    call newline
.done:
    ret

.help:
    mov esi, help_text
    call print_string
    call newline
    ret
.clear:
    call clear_screen
    ret
.about:
    mov esi, about_text
    call print_string
    call newline
    ret
.reboot:
    mov al, 0xFE
    out 0x64, al
.reboot_wait:
    hlt
    jmp .reboot_wait
.halt:
    cli
    hlt
    jmp .halt

strcmp:
.next:
    mov al, [esi]
    mov dl, [edi]
    cmp al, dl
    jne .different
    test al, al
    jz .same
    inc esi
    inc edi
    jmp .next
.same:
    xor eax, eax
    ret
.different:
    mov eax, 1
    ret

clear_screen:
    mov edi, VGA
    mov ecx, 2000
    mov ax, 0x0720
    rep stosw
    mov dword [cursor], 0
    ret

put_char:
    push eax
    push edi
    mov edi, VGA
    mov eax, [cursor]
    shl eax, 1
    add edi, eax
    pop eax
    mov ah, 0x07
    stosw
    inc dword [cursor]
    pop eax
    ret

erase_char:
    dec dword [cursor]
    mov eax, [cursor]
    shl eax, 1
    mov edi, VGA
    add edi, eax
    mov ax, 0x0720
    stosw
    ret

newline:
    mov eax, [cursor]
    xor edx, edx
    mov ebx, 80
    div ebx
    inc eax
    imul eax, 80
    mov [cursor], eax
    ret

print_string:
.next:
    lodsb
    test al, al
    jz .done
    call put_char
    jmp .next
.done:
    ret

scan_to_ascii:
    push ebx
    movzx ebx, al
    mov al, [scan_table + ebx]
    pop ebx
    ret

banner db "========================================",0
       db " NovaOS 0.1 - 32-bit kernel",0
       db "========================================",0
prompt db "Nova> ",0
help_text db "Commands: HELP CLEAR ABOUT REBOOT HALT",0
about_text db "NovaOS: a tiny x86 BIOS operating system.",0
unknown db "Unknown command. Type HELP.",0
cmd_help db "help",0
cmd_clear db "clear",0
cmd_about db "about",0
cmd_reboot db "reboot",0
cmd_halt db "halt",0
cursor dd 0
command_buffer times 64 db 0

scan_table times 256 db 0
