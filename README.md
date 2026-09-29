# NovaOS

A tiny 32-bit x86 BIOS operating system written in NASM.

Features:
- BIOS boot sector
- Kernel loaded from disk
- 32-bit protected mode and GDT
- VGA text output
- PS/2 keyboard input
- Interactive Nova shell
- HELP, CLEAR, ABOUT, REBOOT, and HALT commands
- Makefile build
- GitHub Actions build artifact

Build:
    make

Run in QEMU:
    make run

The project is intentionally small so it can grow into a larger operating system.
