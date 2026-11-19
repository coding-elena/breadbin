# REU and GeoRAM support (analysis)

How Breadbin uses a RAM Expansion Unit (REU) or a GeoRAM, how big that code is, and what it does with
the expansion RAM. Sizes were measured from `build/kernel.map` and `build/kernel.lbl` (commit `246ec88`).

## Where the code is

| File | What |
|---|---|
| `src/kernel/blk.s` | Detection (`reu_detect`, `geo_detect`), block reads and writes (`reu_read`, `reu_write`, `geo_*`), the copy of drive 8 (`dc_*`) |
| `src/kernel/swap.s` | Swapping processes that aren't running to the REU (REU only) |
| `src/kernel/fs.s` | `fs_mkfs_reu` (formats the RAM disk), `fs_mount` (mounts it at `/tmp`, turns swapping on) |
| `src/kernel/main.s`, `mem.s`, `tty.s` | Boot banner, `meminfo` for `free`, serial port off when a GeoRAM is at `$DE00` |

## How it works

### Detection

- **REU:** a test pattern is written to the address registers `$DF02–$DF05` and read back. To find the
  size, byte 0 of each of 128 banks is saved, each bank gets its own number (highest first, so banks past
  the end alias lower ones and are overwritten), the banks that read back their number are counted, and
  the saved bytes are put back. The save and restore keep a disk image that was preloaded into the REU.
- **GeoRAM** (tried only without an REU): the window at `$DE00` must keep what is written to it. The size
  is found the same way with the 16 KB blocks (`$DFFF`), and is reported in 64 KB units, up to 64 (4 MB).

### One block numbering for both

Block `b` (256 bytes) is at REU bank `b>>8`, page `b&$FF`, or at GeoRAM 16 KB block `b>>6`, page `b&63`
(`geo_sel`). Both are byte offset `b*256`, so `reu_read` and `reu_write` serve both: the REU copies by DMA
(commands `$91` fetch, `$90` stash, one page), the GeoRAM with a CPU loop through `$DE00`.

### How the expansion RAM is split

With a 1541 as drive 8 and 4 or more banks (256 KB):

| Part | What it holds |
|---|---|
| Top 3 banks | A copy of drive 8's 683 blocks (`dc_*`, one bit per block in `dc_have`). A command's second load comes from here: the test measured 1387 jiffies for the first read and 44 for the second. |
| Banks `0 … rd_banks-1` | The `/tmp` RAM disk (c64fs) |
| Upper half of bank `rd_banks-1` | 32 KB of swap space (REU only), taken out of `/tmp` |

With no drive 8, the REU or GeoRAM holds the boot disk image (`root_reu`), and there is no `/tmp`, no swap
and no drive 8 copy.

### Swapping

When an allocation fails, `alloc_pages` moves the biggest process that isn't the caller to the REU
(first fit in a 128-page map) and tries again. `sched` brings a process back through `in_core` before
it runs, always to the pages it had, moving out whoever holds them first. The swap code and its tables sit
in the RAM under the KERNAL ROM and run with interrupts off. The kernel can't be preempted inside a
system call (`proc.s`), so no two users of the REU registers can interleave.

## Size

### Code

| Part | Where it sits | Bytes |
|---|---|---|
| REU transfer (`reu_setup`, `reu_read`, `reu_write`) | kernel | 79 |
| GeoRAM transfer (`geo_sel`, `geo_read`, `geo_write`) | kernel | 60 |
| `is_reu` | kernel | 14 |
| Drive 8 copy (`dc_get`, `dc_put`, `dc_bit`, `dc_to`, `dc_back`) | kernel | 110 |
| Swap entry points (`in_core`, `alloc_pages`) | kernel | 52 |
| **Kernel total** | `$8500–$CFFF` | **315** |
| Swap code (`sw_room` … `sw_dma`) | under the KERNAL ROM (`$EC7E–$EE20`) | 419 |
| Detection (`reu_byte`, `reu_detect`, `pat`, `geo_detect`) | `INIT`, boot only | 283 |
| Formatting `/tmp` (`fs_mkfs_reu`, `rd_iblk`, `rd_nino`) | `INIT`, boot only | 380 |

`INIT` is loaded at `$4809`, inside the program pool, and is overwritten after boot. The totals leave out
the few branches into this code from `bread`, `bwrite`, `blk_init`, `fs_mount` and `main` (not measured,
but small). The RAM disk alone needs 153 bytes of kernel code; the drive 8 copy and swapping are the rest.

### Variables

| What | Where | Bytes |
|---|---|---|
| `dc_have` | kernel `BSS` | 86 |
| `reu_banks`, `ram_type`, `reu_tmp`, `root_reu`, `rd_banks`, `dc_on`, `dc_base`, `dc_hi`, `sw_on`, `sw_bank` | kernel `BSS` | 10 |
| `sw_map` (128), `sw_pg` (12), scratch (9) | `HIBSS`, under the ROM | 149 |
| `reu_save` | the block cache buffers, at boot only | 0 |
| Zero page | reuses `bp` and `rq_*` | 0 |

So the resident cost in the kernel area is about 411 bytes (2% of the ~19 KB kernel), plus 568 bytes
under the ROM for swapping. The 125-page program pool at `$0800–$84FF` is not affected.

### Expansion RAM, by size

`/tmp` gives up blocks to its own filesystem data: 1 superblock, 1 bitmap block per 8 banks, and 64
inode blocks (16 KB), or 16 when the disk has fewer than 512 blocks. With a 1541 as drive 8:

| Size | Drive 8 copy | Swap | `/tmp` blocks | Filesystem data | Free for files |
|---|---|---|---|---|---|
| REU 128 KB | – | 32 KB | 384 | 18 | 366 (≈ 91 KB) |
| REU 256 KB | 192 KB | 32 KB | 128 | 18 | 110 (≈ 27 KB) |
| REU 512 KB | 192 KB | 32 KB | 1152 | 66 | 1086 (≈ 271 KB) |
| REU 16 MB (8 MB used) | 192 KB | 32 KB | 31872 | 81 | 31791 (≈ 7.8 MB) |
| GeoRAM 512 KB | 192 KB | – | 1280 | 66 | 1214 (≈ 303 KB) |

Timing: by `docs/design-swap.md`, the REU moves a page in about 256 cycles, so the largest program
(125 pages) takes about 2 jiffies with interrupts off. A GeoRAM copies a 256-byte block with the CPU,
about 3.6k cycles.

## Things to look at

1. **A stale test.** `tests/test_system.py`, `GeoRAM.test_georam_ramdisk`, copies `/home/readme`, which
   `rootfs/home` doesn't have (only `alice` and `user`). Both `wc` calls report "no such file", and the
   comparison fails only because the two messages wrap at different places on the 40-column screen. The
   GeoRAM checks before it pass.
2. **The drive 8 copy is also on with a GeoRAM.** `blk_init` turns it on for 4 or more banks without
   checking `ram_type`. It works (same block numbering), but each copied block costs about 3.6k CPU
   cycles, and the README describes it for an REU only.
3. **The GeoRAM probe writes `$5A` and `$A5` to `$DE00` before `tty_init`.** With a SwiftLink and no
   GeoRAM, that is the ACIA's transmit register. It should be harmless after a reset (the transmitter is
   off), but the write is not guarded.
4. **The REU register addresses are defined twice**, in `blk.s` and `swap.s`. They could move to `k.inc`.
5. **Documented limits:** at most 128 REU banks (8 MB) and 256 GeoRAM blocks (4 MB) are used.

## Test results

Run in VICE (x64sc) under WSL: `test_system.REU`, `test_system.GeoRAM`, `test_bugs.SmallRAMDisk`,
`test_bugs.SmallREUWithDriveCopy`, `test_bugs.BigGeoRAM`, `test_bugs.GeoRAMRoot`,
`test_features.BigRAMDisk`, `test_features.DriveCopyInREU`, `test_features.Swap`. 9 of 10 passed in
about 14 minutes; the failure is the stale test in item 1.
