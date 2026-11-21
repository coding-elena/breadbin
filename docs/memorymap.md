# Breadbin memory map

Addresses from a build of `fa949b6` (`build/kernel.map`, `build/kernel.lbl`), with `src/kernel.cfg`, `src/kernel/k.inc` and [docs/programming.md](programming.md). Segment addresses move when the kernel changes; rebuild and check `build/kernel.map`.

The kernel runs with `$01 = $36` (BASIC ROM out, KERNAL ROM and I/O in). Code under the ROM runs with `$01 = $35` (both ROMs out, I/O in) and interrupts off.

## C64 address space

| Range | Size | Owner | Contents |
|---|---|---|---|
| `$0000`–`$0001` | 2 B | CPU | 6510 port; `$01` selects the memory layout |
| `$0002`–`$0007` | 6 B | per process | `r0`, `r1`, `r2`: system call argument registers |
| `$0008`–`$001F` | 24 B | per process | kernel scratch (`r3`, `s0`–`s4`, `sb0`–`sb7`, `k_entry`) |
| `$0020`–`$0022` | 3 B | per process | `argv`, `argc` |
| `$0023`–`$002F` | 13 B | per process | free for the program |
| `$0030`–`$003F` | 16 B | per process | user library scratch; free if the program doesn't call the library |
| `$0040`–`$008D` | 78 B | kernel | kernel zero page (`cur` `$72`, `in_kernel` `$73`, ...) |
| `$008E`–`$00FF` | | KERNAL | KERNAL zero page |
| `$0100`–`$01FF` | 256 B | shared | one stack for all processes; up to 130 bytes of each are saved on a switch |
| `$0200`–`$02A6` | | KERNAL | input buffer, KERNAL variables |
| `$02A7`–`$02F8` | 82 B | ttyS0 | **LOWDATA**: serial-line variables and small hooks |
| `$0300`–`$0333` | | KERNAL | vectors; Breadbin sets `$0314`/`$0316` (IRQ, BRK) and `$0318` (NMI) |
| `$0334`–`$03EE` | 187 B | ttyS0 | **LOWCODE** (the cassette buffer): serial-line hooks |
| `$0400`–`$07E7` | 1000 B | console | screen (KERNAL screen editor) |
| `$07FF`–`$0850` | | boot | load address and BASIC `SYS` stub of `breadbin.prg` |
| `$0800`–`$84FF` | 125 pages | user pool | programs, in 256-byte pages (`mem.s`, from page `$08`) |
| ↳ `$4809`–`$4E92` | 1.6 KB | boot only | **INIT** (`kmain`, `tty_boot`, `tty_init`, ...); runs where loaded, the pool gets the pages back after boot |
| `$8500`–`$BF98` | 14.6 KB | kernel | **CODE** (`nmi_handler` `$B6D0`, `sched` `$B80B`, `irq` `$B945`); includes RAM under the BASIC ROM |
| `$BF99`–`$C2B1` | 793 B | kernel | **RODATA** |
| `$C2B2`–`$CEFE` | 3.1 KB | kernel | **BSS** (see below) |
| `$CEFF` | 1 B | | free |
| `$CF00`–`$CFA7` | 168 B | kernel | **JUMPTAB**: the system call jump table, at a fixed address |
| `$CFA8`–`$CFF8` | 81 B | ttyS0 | **JTCODE**: `tcall`, `tty_hold`, `tty_write`, `tty_read` |
| `$CFF9`–`$CFFF` | 7 B | | free |
| `$D000`–`$DFFF` | 4 KB | I/O | VIC, SID, colour RAM `$D800`, CIA1 `$DC00`, CIA2 `$DD00` |
| ↳ `$DE00`–`$DE03` | | cartridge | 6551 ACIA (SwiftLink/Turbo232), or the GeoRAM window |
| ↳ `$DF00` | | cartridge | REU registers; GeoRAM block register `$DFFF` |
| `$E000`–`$FFFF` | 8 KB | KERNAL ROM | ROM switched in; the RAM underneath holds kernel data (see below) |

### Kernel BSS (`$C2B2`–`$CEFE`)

| Address | Contents |
|---|---|
| `$C2B2`–`$C8B1` | `bufs`: block cache, 6 × 256 bytes |
| `$C8B2`– | buffer state, inodes, open-file table (`f_type` `$CAAF`) |
| `$CD36` | `pg_used`: user pool page map |
| `$CDB8`– | process tables (`p_state` `$CDB8`, `p_fd` `$CE90`) |

## RAM under the KERNAL ROM (`$E000`–`$FFFF`)

Reachable only with `$01 = $35` and interrupts off.

| Range | Size | Contents |
|---|---|---|
| `$E000`–`$E8FF` | 2304 B | `P_SAVE`: each process's saved zero page and stack (12 × 192 B) |
| `$E900`–`$EB3F` | 576 B | `P_CWD`: working directory names (12 × 48 B) |
| `$EB40`–`$EBC3` | 132 B | `P_NAME`: process names (12 × 11 B) |
| `$EBC4`–`$EBFF` | 60 B | free |
| `$EC00`–`$EE20` | 545 B | **HICODE**: swap code (`swap.s`) |
| `$EE21`–`$F240` | 1056 B | **HICODE**: ttyS0 driver, line discipline, ANSI translation |
| `$F241`–`$F2D5` | 149 B | **HIBSS**: swap state |
| `$F2D6`–`$F438` | 355 B | **TTYBSS**: serial rings, line buffer, line state |
| `$F439`–`$FEFF` | ~2.7 KB | free (end of the HI region in `kernel.cfg`) |
| `$FF00`–`$FFF9` | | not used |
| `$FFFA`–`$FFFF` | | NMI (`$FFFA`) and IRQ (`$FFFE`) vectors for when the ROM is out (set in `main.s`) |

## ttyS0 driver in detail

| Segment | Range | Used / available | Symbols |
|---|---|---|---|
| LOWDATA | `$02A7`–`$02F8` | 82 / 89 B | `tty_on` `$02A7`, `tty_st` `$02A8`, `tvec` `$02A9`, `hold_cnt` `$02AB`, `fg_tty` `$02AC`, `t_x` `$02AD`, `tty_of` `$02AE`, `tty_irqhook` `$02D8`, `tty_athook` `$02E5`, `tty_rdhook` `$02EF` |
| LOWCODE | `$0334`–`$03EE` | 187 / 204 B | `tty_nmihook` `$0334`, `tty_sigchk` `$0379`, `tty_chrhook` `$0393`, `tty_wrhook` `$03C5`, `tty_cmhook` `$03CF` |
| INIT | `$4E26`–`$4E92` | 109 B | `tty_boot` `$4E26`, `tty_init` `$4E3D` |
| JTCODE | `$CFA8`–`$CFF8` | 81 / 88 B | `tcall` `$CFA8`, `tty_hold` `$CFC2`, `tty_write` `$CFD4`, `tty_read` `$CFD7` |
| HICODE | `$EE21`–`$F240` | 1056 B | `tty_nmi` `$EE21`, `tty_tick` `$EEA6`, `hangup` `$EF00`, `tty_mode` `$EF3E`, `raw_alive` `$EF58`, `tty_rw` `$EF79`, `tty_rd` `$EF9E`, `rx_get` `$F06F`, `in_map` `$F087`, `tty_wr` `$F0EF`, `tx_room` `$F12E`, `out_byte` `$F13A`, `put_dec1` `$F1E0`, `put_str` `$F1FD`, `tx_put` `$F209`, `strs` `$F21D`–`$F238`, `esc_in`/`esc_out` `$F239`–`$F240` |
| TTYBSS | `$F2D6`–`$F438` | 355 B | `rx_buf` `$F2D6` (128), `tx_buf` `$F356` (128), `lbuf` `$F3D6` (80), `rx_head`/`rx_tail`/`tx_head`/`tx_tail` `$F426`–`$F429`, `lb_len`/`lb_rpos`/`lb_ready` `$F42A`–`$F42C`, `t_raw` `$F42D`, `t_rawpid` `$F42E`, `i_esc` `$F42F`, `i_cr` `$F430`, `o_esc` `$F431`, `o_row` `$F432`, `t_dcd` `$F433`, `tf_wake`/`tf_int`/`tf_stp`/`tf_hup` `$F434`–`$F437`, `t_px` `$F438` |
| I/O | `$DE00`–`$DE03` | | ACIA data, status, command, control |

In kernel RAM the driver has only its 3-byte `jsr` hooks: `main.s` (`nmi_handler`), `proc.s` (IRQ, `sigint_fg` loop), `file.s` (open, `isatty`, read, write), `con.s` (`sys_conmode`), and `tty_hold` calls in `iec.s` and `blk.s`.

## Outside the 64 KB

| Where | Contents |
|---|---|
| REU | All of it, up to 128 banks (8 MB). With 4+ banks (256 KB) and a 1541 as drive 8, the top 3 banks (192 KB) cache drive 8's blocks. The other `rd_banks` banks are the `/tmp` RAM disk, except its top 32 KB (the upper half of bank `rd_banks-1`), which is the swap area ([design-swap.md](design-swap.md)). With no drive 8, the REU is the boot device. |
| GeoRAM | RAM disk only: no swapping, and no serial line (both at `$DE00`) |
| Drives 8–11 | c64fs or CBM DOS filesystems over the serial bus |

## Room left

- Under the ROM: `$F439`–`$FEFF` (~2.7 KB) and `$EBC4`–`$EBFF` (60 B).
- Kernel RAM: 1 byte at `$CEFF` and 7 at `$CFF9`–`$CFFF`.
- LOWDATA: 7 B; LOWCODE: 17 B.
