bits 32
org 0x1000

VGA equ 0xB8000
KEYBOARD equ 0x60
MAX_CMD equ 127

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
    cmp al, 0x39
    je .space

    call scan_to_ascii
    test al, al
    jz .read
    cmp ecx, MAX_CMD
    jae .read

    stosb
    inc ecx
    call put_char
    jmp .read

.space:
    cmp ecx, MAX_CMD
    jae .read
    mov al, ' '
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

; ------------------------------------------------------------
; Bash-like command dispatcher
; ------------------------------------------------------------
execute_command:
    call skip_spaces
    cmp byte [esi], 0
    je .done

    mov edi, cmd_help
    call command_is
    jz .help

    mov edi, cmd_clear
    call command_is
    jz .clear

    mov edi, cmd_about
    call command_is
    jz .about

    mov edi, cmd_reboot
    call command_is
    jz .reboot

    mov edi, cmd_halt
    call command_is
    jz .halt

    mov edi, cmd_pwd
    call command_is
    jz .pwd

    mov edi, cmd_uname
    call command_is
    jz .uname

    mov edi, cmd_whoami
    call command_is
    jz .whoami

    mov edi, cmd_echo
    call command_is
    jz .echo

    mov edi, cmd_env
    call command_is
    jz .env

    mov edi, cmd_true
    call command_is
    jz .true

    mov edi, cmd_false
    call command_is
    jz .false

    mov edi, cmd_history
    call command_is
    jz .history

    mov edi, cmd_cd
    call command_is
    jz .cd

    mov edi, cmd_ls
    call command_is
    jz .ls

    mov edi, cmd_cat
    call command_is
    jz .cat

    mov edi, cmd_mkdir
    call command_is
    jz .mkdir

    mov edi, cmd_touch
    call command_is
    jz .touch

    mov edi, cmd_rm
    call command_is
    jz .rm

    mov edi, cmd_exit
    call command_is
    jz .exit

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

.pwd:
    mov esi, cwd
    call print_string
    call newline
    ret

.uname:
    mov esi, uname_text
    call print_string
    call newline
    ret

.whoami:
    mov esi, user_text
    call print_string
    call newline
    ret

.echo:
    call get_args
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

.history:
    mov esi, history_text
    call print_string
    call newline
    ret

.cd:
    ; Filesystem support is not present yet, so expose shell semantics
    ; without pretending the directory actually changed.
    call get_args
    cmp byte [esi], 0
    jne .cd_arg
    mov esi, cwd
    call print_string
    call newline
    ret
.cd_arg:
    mov esi, cd_message
    call print_string
    call newline
    mov dword [last_status], 1
    ret

.ls:
    mov esi, ls_message
    call print_string
    call newline
    ret

.cat:
    mov esi, cat_message
    call print_string
    call newline
    mov dword [last_status], 1
    ret

.mkdir:
    mov esi, mkdir_message
    call print_string
    call newline
    mov dword [last_status], 1
    ret

.touch:
    mov esi, touch_message
    call print_string
    call newline
    mov dword [last_status], 1
    ret

.rm:
    mov esi, rm_message
    call print_string
    call newline
    mov dword [last_status], 1
    ret

.exit:
    mov esi, exit_message
    call print_string
    call newline
    cli
.hang:
    hlt
    jmp .hang

.reboot:
    mov esi, reboot_message
    call print_string
    call newline
    mov al, 0xFE
    out 0x64, al
.reboot_wait:
    hlt
    jmp .reboot_wait

.halt:
    cli
    hlt
    jmp .halt

; ------------------------------------------------------------
; command_is
; ESI points at typed command, EDI points at command name.
; Returns ZF=1 when the command matches a complete token.
; ------------------------------------------------------------
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
.skip:
    cmp byte [esi], ' '
    jne .done
    inc esi
    jmp .skip
.done:
    ret

get_args:
    ; Find first whitespace after command.
.find:
    cmp byte [esi], 0
    je .empty
    cmp byte [esi], ' '
    je .found
    inc esi
    jmp .find
.found:
    call skip_spaces
    ret
.empty:
    ret

; ------------------------------------------------------------
; Screen I/O
; ------------------------------------------------------------
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
    cmp eax, 2000
    jb .position_ok
    call clear_screen
    mov edi, VGA
.position_ok:
    shl eax, 1
    add edi, eax
    pop eax
    mov ah, 0x07
    stosw
    inc dword [cursor]
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

; ------------------------------------------------------------
; Set-1 US keyboard scan code conversion
; ------------------------------------------------------------
scan_to_ascii:
    cmp al, 0x02
    je .1
    cmp al, 0x03
    je .2
    cmp al, 0x04
    je .3
    cmp al, 0x05
    je .4
    cmp al, 0x06
    je .5
    cmp al, 0x07
    je .6
    cmp al, 0x08
    je .7
    cmp al, 0x09
    je .8
    cmp al, 0x0A
    je .9
    cmp al, 0x0B
    je .0
    cmp al, 0x0C
    je .minus
    cmp al, 0x0D
    je .equals

    cmp al, 0x10
    je .q
    cmp al, 0x11
    je .w
    cmp al, 0x12
    je .e
    cmp al, 0x13
    je .r
    cmp al, 0x14
    je .t
    cmp al, 0x15
    je .y
    cmp al, 0x16
    je .u
    cmp al, 0x17
    je .i
    cmp al, 0x18
    je .o
    cmp al, 0x19
    je .p
    cmp al, 0x1A
    je .lbracket
    cmp al, 0x1B
    je .rbracket

    cmp al, 0x1E
    je .a
    cmp al, 0x1F
    je .s
    cmp al, 0x20
    je .d
    cmp al, 0x21
    je .f
    cmp al, 0x22
    je .g
    cmp al, 0x23
    je .h
    cmp al, 0x24
    je .j
    cmp al, 0x25
    je .k
    cmp al, 0x26
    je .l
    cmp al, 0x27
    je .semicolon
    cmp al, 0x28
    je .quote

    cmp al, 0x29
    je .backtick
    cmp al, 0x2B
    je .backslash
    cmp al, 0x2C
    je .z
    cmp al, 0x2D
    je .x
    cmp al, 0x2E
    je .c
    cmp al, 0x2F
    je .v
    cmp al, 0x30
    je .b
    cmp al, 0x31
    je .n
    cmp al, 0x32
    je .m
    cmp al, 0x33
    je .comma
    cmp al, 0x34
    je .dot
    cmp al, 0x35
    je .slash

    xor eax, eax
    ret

.1: mov al,'1'; ret
.2: mov al,'2'; ret
.3: mov al,'3'; ret
.4: mov al,'4'; ret
.5: mov al,'5'; ret
.6: mov al,'6'; ret
.7: mov al,'7'; ret
.8: mov al,'8'; ret
.9: mov al,'9'; ret
.0: mov al,'0'; ret
.minus: mov al,'-'; ret
.equals: mov al,'='; ret
.q: mov al,'q'; ret
.w: mov al,'w'; ret
.e: mov al,'e'; ret
.r: mov al,'r'; ret
.t: mov al,'t'; ret
.y: mov al,'y'; ret
.u: mov al,'u'; ret
.i: mov al,'i'; ret
.o: mov al,'o'; ret
.p: mov al,'p'; ret
.lbracket: mov al,'['; ret
.rbracket: mov al,']'; ret
.a: mov al,'a'; ret
.s: mov al,'s'; ret
.d: mov al,'d'; ret
.f: mov al,'f'; ret
.g: mov al,'g'; ret
.h: mov al,'h'; ret
.j: mov al,'j'; ret
.k: mov al,'k'; ret
.l: mov al,'l'; ret
.semicolon: mov al,';'; ret
.quote: mov al,39; ret
.backtick: mov al,'`'; ret
.backslash: mov al,'\\'; ret
.z: mov al,'z'; ret
.x: mov al,'x'; ret
.c: mov al,'c'; ret
.v: mov al,'v'; ret
.b: mov al,'b'; ret
.n: mov al,'n'; ret
.m: mov al,'m'; ret
.comma: mov al,','; ret
.dot: mov al,'.'; ret
.slash: mov al,'/'; ret

; ------------------------------------------------------------
; Strings/state
; ------------------------------------------------------------
banner db "========================================",0
       db " NovaOS 0.2 - Bash-like shell",0
       db "========================================",0
prompt db "Nova> ",0

help_text db "Builtins:",0
          db " help clear about echo pwd uname whoami env",0
          db " true false history cd ls cat mkdir touch rm",0
          db " reboot halt exit",0

about_text db "NovaOS: x86 BIOS kernel with a Bash-like command shell.",0
unknown db "bash: command not found",0
cwd db "/",0
uname_text db "NovaOS nova 0.2 i386 x86",0
user_text db "root",0
env_text db "USER=root HOME=/ PATH=/bin:/usr/bin SHELL=/bin/nova",0
history_text db "1  help",0
cd_message db "cd: filesystem support is not implemented yet",0
ls_message db "ls: virtual root is empty",0
cat_message db "cat: filesystem support is not implemented yet",0
mkdir_message db "mkdir: filesystem support is not implemented yet",0
touch_message db "touch: filesystem support is not implemented yet",0
rm_message db "rm: filesystem support is not implemented yet",0
reboot_message db "Rebooting...",0
exit_message db "NovaOS shell halted.",0

cmd_help db "help",0
cmd_clear db "clear",0
cmd_about db "about",0
cmd_reboot db "reboot",0
cmd_halt db "halt",0
cmd_pwd db "pwd",0
cmd_uname db "uname",0
cmd_whoami db "whoami",0
cmd_echo db "echo",0
cmd_env db "env",0
cmd_true db "true",0
cmd_false db "false",0
cmd_history db "history",0
cmd_cd db "cd",0
cmd_ls db "ls",0
cmd_cat db "cat",0
cmd_mkdir db "mkdir",0
cmd_touch db "touch",0
cmd_rm db "rm",0
cmd_exit db "exit",0

cursor dd 0
last_status dd 0
command_buffer times 128 db 0
