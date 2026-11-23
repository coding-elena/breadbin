# Breadbin memory map

Addresses from a build of `d87485b` with the serial line's binary mode (`conmode` 2) and the smaller `tcall`/`tty_of` (`build/kernel.map`, `build/kernel.lbl`), with `src/kernel.cfg`, `src/kernel/k.inc` and [docs/programming.md](programming.md). Segment addresses move when the kernel changes; rebuild and check `build/kernel.map`.

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
| `$0040`–`$008F` | 80 B | kernel | kernel zero page (`cur` `$74`, `in_kernel` `$75`, `restore_pending` `$8F`, ...) |
| `$0090`–`$00FF` | | KERNAL | KERNAL zero page |
| `$0100`–`$01FF` | 256 B | shared | one stack for all processes; up to 130 bytes of each are saved on a switch |
| `$0200`–`$02A6` | | KERNAL | input buffer, KERNAL variables |
| `$02A7`–`$02F8` | 82 B | ttyS0 | **LOWDATA**: serial-line variables and small hooks |
| `$0300`–`$0333` | | KERNAL | vectors; Breadbin sets `$0314`/`$0316` (IRQ, BRK) and `$0318` (NMI) |
| `$0334`–`$03DF` | 172 B | ttyS0 | **LOWCODE** (the cassette buffer): serial-line hooks |
| `$03E0`–`$03FF` | 32 B | | free (the rest of the cassette buffer) |
| `$0400`–`$07E7` | 1000 B | console | screen (KERNAL screen editor) |
| `$07FF`–`$0850` | | boot | load address and BASIC `SYS` stub of `breadbin.prg` |
| `$0800`–`$84FF` | 125 pages | user pool | programs, in 256-byte pages (`mem.s`, from page `$08`) |
| ↳ `$47BF`–`$4ED0` | 1.8 KB | boot only | **INIT** (`kmain`, `tty_boot`, `tty_init`, ...); runs where loaded, the pool gets the pages back after boot |
| `$8500`–`$BF5A` | 14.6 KB | kernel | **CODE** (`nmi_handler` `$B692`, `sched` `$B7CD`, `irq` `$B907`); includes RAM under the BASIC ROM |
| `$BF5B`–`$C273` | 793 B | kernel | **RODATA** |
| `$C274`–`$CEC0` | 3.1 KB | kernel | **BSS** (see below) |
| `$CEC1`–`$CEFF` | 63 B | | free |
| `$CF00`–`$CFA7` | 168 B | kernel | **JUMPTAB**: the system call jump table, at a fixed address |
| `$CFA8`–`$CFFB` | 84 B | ttyS0 | **JTCODE**: `tcall`, `tty_hold`, `tty_write`, `tty_read` |
| `$CFFC`–`$CFFF` | 4 B | | free |
| `$D000`–`$DFFF` | 4 KB | I/O | VIC, SID, colour RAM `$D800`, CIA1 `$DC00`, CIA2 `$DD00` |
| ↳ `$DE00`–`$DE03` | | cartridge | 6551 ACIA (SwiftLink/Turbo232), or the GeoRAM window |
| ↳ `$DF00` | | cartridge | REU registers; GeoRAM block register `$DFFF` |
| `$E000`–`$FFFF` | 8 KB | KERNAL ROM | ROM switched in; the RAM underneath holds kernel data (see below) |

### Kernel BSS (`$C274`–`$CEC0`)

| Address | Contents |
|---|---|
| `$C274`–`$C873` | `bufs`: block cache, 6 × 256 bytes |
| `$C874`– | buffer state, inodes, open-file table (`f_type` `$CA71`) |
| `$CCF8` | `pg_used`: user pool page map |
| `$CD7A`– | process tables (`p_state` `$CD7A`, `p_fd` `$CE52`) |

## RAM under the KERNAL ROM (`$E000`–`$FFFF`)

Reachable only with `$01 = $35` and interrupts off.

| Range | Size | Contents |
|---|---|---|
| `$E000`–`$E8FF` | 2304 B | `P_SAVE`: each process's saved zero page and stack (12 × 192 B) |
| `$E900`–`$EB3F` | 576 B | `P_CWD`: working directory names (12 × 48 B) |
| `$EB40`–`$EBC3` | 132 B | `P_NAME`: process names (12 × 11 B) |
| `$EBC4`–`$EBFF` | 60 B | free |
| `$EC00`–`$EE20` | 545 B | **HICODE**: swap code (`swap.s`) |
| `$EE21`–`$F288` | 1128 B | **HICODE**: ttyS0 driver, line discipline, ANSI translation |
| `$F289`–`$F31D` | 149 B | **HIBSS**: swap state |
| `$F31E`–`$F480` | 355 B | **TTYBSS**: serial rings, line buffer, line state |
| `$F481`–`$FEFF` | ~2.6 KB | free (end of the HI region in `kernel.cfg`) |
| `$FF00`–`$FFF9` | | not used |
| `$FFFA`–`$FFFF` | | NMI (`$FFFA`) and IRQ (`$FFFE`) vectors for when the ROM is out (set in `main.s`) |

## ttyS0 driver in detail

| Segment | Range | Used / available | Symbols |
|---|---|---|---|
| LOWDATA | `$02A7`–`$02F8` | 82 / 89 B | `tty_on` `$02A7`, `tty_st` `$02A8`, `hold_cnt` `$02A9`, `fg_tty` `$02AA`, `tty_of` `$02AB`, `tty_irqhook` `$02D8`, `tty_athook` `$02E5`, `tty_rdhook` `$02EF` |
| LOWCODE | `$0334`–`$03DF` | 172 / 204 B | `tty_nmihook` `$0334`, `tty_sigchk` `$0373`, `tty_chrhook` `$0387`, `tty_wrhook` `$03B6`, `tty_cmhook` `$03C0` |
| INIT | `$4E15`–`$4ED0` | 188 B | `tty_boot` `$4E15`, `tty_init` `$4E2C`, `modem_probe` |
| JTCODE | `$CFA8`–`$CFFB` | 84 / 88 B | `tcall` `$CFA8`, `tty_hold` `$CFBF`, `tty_write` `$CFD1`, `tty_read` `$CFD4` |
| HICODE | `$EE21`–`$F288` | 1128 B | `tty_nmi` `$EE21`, `tty_tick` `$EEAD`, `hangup` `$EF07`, `tty_mode` `$EF45`, `raw_alive` `$EF5F`, `tty_rw` `$EF80`, `tty_rd` `$EFA5`, `rx_get` `$F0AA`, `in_map` `$F0C2`, `tty_wr` `$F12A`, `tx_room` `$F176`, `out_byte` `$F182`, `put_dec1` `$F228`, `put_str` `$F245`, `tx_put` `$F251`, `strs` `$F265`–`$F280`, `esc_in`/`esc_out` `$F281`–`$F288` |
| TTYBSS | `$F31E`–`$F480` | 355 B | `rx_buf` `$F31E` (128), `tx_buf` `$F39E` (128), `lbuf` `$F41E` (80), `rx_head`/`rx_tail`/`tx_head`/`tx_tail` `$F46E`–`$F471`, `lb_len`/`lb_rpos`/`lb_ready` `$F472`–`$F474`, `t_raw` `$F475` (2 = binary), `t_rawpid` `$F476`, `i_esc` `$F477`, `i_cr` `$F478`, `o_esc` `$F479`, `o_row` `$F47A`, `t_dcd` `$F47B`, `tf_wake`/`tf_int`/`tf_stp`/`tf_hup` `$F47C`–`$F47F`, `t_px` `$F480` |
| I/O | `$DE00`–`$DE03` | | ACIA data, status, command, control |

In kernel RAM the driver has only its 3-byte `jsr` hooks: `main.s` (`nmi_handler`), `proc.s` (IRQ, `sigint_fg` loop), `file.s` (open, `isatty`, read, write), `con.s` (`sys_conmode`), and `tty_hold` calls in `iec.s` and `blk.s`.

## Outside the 64 KB

| Where | Contents |
|---|---|
| REU | All of it, up to 128 banks (8 MB). With 4+ banks (256 KB) and a 1541 as drive 8, the top 3 banks (192 KB) cache drive 8's blocks. The other `rd_banks` banks are the `/tmp` RAM disk, except its top 32 KB (the upper half of bank `rd_banks-1`), which is the swap area ([design-swap.md](design-swap.md)). With no drive 8, the REU is the boot device. |
| GeoRAM | RAM disk only: no swapping, and no serial line (both at `$DE00`) |
| Drives 8–11 | c64fs or CBM DOS filesystems over the serial bus |

## Room left

- Under the ROM: `$F481`–`$FEFF` (~2.6 KB) and `$EBC4`–`$EBFF` (60 B).
- Kernel RAM: 63 bytes at `$CEC1`–`$CEFF` and 4 at `$CFFC`–`$CFFF`.
- LOWDATA: 7 B (`$02F9`–`$02FF`); LOWCODE: 32 B (`$03E0`–`$03FF`).
