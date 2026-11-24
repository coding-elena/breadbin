# The serial terminal: a second user on /dev/ttyS0

With a SwiftLink or Turbo232 cartridge, Breadbin has two terminals:

- **The console:** the C64's screen and keyboard.
- **The serial line:** `/dev/ttyS0`, at 9600 baud, 8N1.

When `/etc/passwd` exists, `init` runs a `login` on each, so two people can work at once: one at the C64 and one at a PC terminal (or over TCP in VICE). Each has their own shell, jobs, CTRL-C and CTRL-Z.

This page covers using it. [design-tty.md](design-tty.md) explains how it works inside.

## What you need

| | |
|---|---|
| Cartridge | SwiftLink or Turbo232 (a 6551 ACIA at `$DE00`, interrupting through NMI) |
| Not at the same time | GeoRAM: it also sits at `$DE00`. An REU (at `$DF00`) is fine. |
| Far end | any ANSI/VT100 terminal |
| Flow control | RTS/CTS, recommended (see [Limits](#limits)) |

At boot the console shows whether the line is on:

```
serial: on, /dev/ttyS0 9600 8n1
```

If Breadbin is using GeoRAM, it shows `serial: off (georam is at $de00)`. With no card, there is no `serial:` line at all.

### Modems

At boot, after finding the card, Breadbin raises DTR and checks DSR: if nothing is at the far end (in VICE: nothing listening on the TCP port), it sends nothing and goes on booting. Otherwise it asks the terminal for its status (`ESC [ 5 n`); an ANSI terminal (xterm, Windows Terminal, PuTTY, also behind socat) answers, and Breadbin stops there. If nothing answers, it sends `AT` and waits about 0.4 s for `OK`. If a Hayes-style modem answers (tcpser, a WiFi modem), the line is marked as a **modem line**:
- no `login` is started on `/dev/ttyS0`;
- the line itself still works, so a program can open `/dev/ttyS0` and talk to the modem (dial, answer);
- this is checked only at boot: switch the modem on before the C64.

A terminal, or a card with nothing attached, gets a login as before; a terminal never sees the `AT`. The check raises DTR for a moment (in VICE this connects the TCP line, as the boot does anyway).

## Trying it in VICE

VICE emulates the SwiftLink and joins its serial line to a TCP connection. **VICE connects out**, so start the listener first.

1. Start the listener in one terminal window. It becomes the serial terminal:
   ```
   socat -,raw,echo=0 tcp-listen:25232
   ```
   - `raw` sends each key at once.
   - `echo=0` stops your terminal echoing what you type, because Breadbin echoes it itself.
2. Start the C64 in another window:
   ```
   make run-tty
   ```
   or by hand, here with an REU:
   ```
   x64sc +georam -reu -reusize 512 -acia1 -acia1base 0xde00 -acia1irq 1 -acia1mode 1 \
         -myaciadev 0 -rsdev1 127.0.0.1:25232 -rsdev1baud 9600 -autostart build/breadbin.d64
   ```
3. A few seconds after the boot, `breadbin login:` appears in the socat window. Log in as `root` or `user`.

Notes:
- `+georam` makes sure GeoRAM is off even when your saved VICE settings turn it on. With GeoRAM on, VICE never shows the SwiftLink to the C64.
- VICE connects only once, at boot. If it is restarted, restart socat too, and before it.
- socat in raw mode passes CTRL-C on to the C64, so close its window to stop it.

## A modem in VICE: tcpser

[tcpser](https://github.com/FozzTexx/tcpser) emulates a Hayes modem over TCP. Run it instead of socat, and start it before VICE (VICE connects out, as above):

```
tcpser -v 25232 -s 9600 -l 4
```

- `-v 25232`: tcpser listens on this port for the emulator's serial line (the same port as `-rsdev1` below).
- `-s 9600`: the line speed, matching Breadbin's 9600 baud.
- `-l 4`: log level; the log shows the `AT` command Breadbin sends at boot.

Then start the C64 with the same options as before (`make run-tty`, or the `x64sc` line with `-rsdev1 127.0.0.1:25232 -rsdev1baud 9600`).

At boot tcpser answers the `AT` with `OK`, so Breadbin marks the line as a modem line: **no `login:` is started** on `/dev/ttyS0`, and the line is left free for a program that talks to the modem. If tcpser isn't running (or you use socat), the line gets its login as before.

## Calling out: screen

`screen /dev/ttyS0` turns the C64 into an ANSI (VT100) terminal on the serial line, 40 x 25 in colour. With tcpser, dial a BBS or a telnet host with `atdt host:port`:

```
screen /dev/ttyS0
atdtoasisbbs.hopto.org:6400
```

- **CTRL-A k** quits (the screen is cleared), **CTRL-A a** sends a CTRL-A. On a modem line it hangs up first: a second of silence, `+++`, another second, then `ATH` (the Hayes escape and hang-up; tcpser closes the call). That takes about 2.5 s; without a call the modem just answers `OK`. On a terminal line nothing is sent.
- The C64's keys become what an ANSI terminal sends:

  | C64 key | Sent |
  |---|---|
  | RETURN | CR (`$0D`) |
  | INST/DEL | BS (`$08`): the Hayes backspace (tcpser's `S5`), so `atdt` lines can be corrected; most BBSes take it too |
  | cursor keys | `ESC [ A` / `B` / `C` / `D` |
  | CLR/HOME | nothing: it is the same key code as CTRL-A, the prefix |
  | SHIFT CLR/HOME | form feed (`$0C`, CTRL-L) |
  | CTRL-letters | `$01`-`$1A`, except CTRL-A (the prefix), CTRL-B/F/N/P (the cursor keys' codes) and CTRL-J (RETURN's code: sends CR) |
  | F1-F8 | nothing |

  A host that wants DEL (`$7F`) to erase, such as a Linux shell with `stty erase ^?`, sees BS instead: use `stty erase ^H` there (bash's line editor takes both).
- While it runs the line is in binary mode: every byte passes as it is, both ways, and what arrives is drawn straight into screen RAM by `screenw`, its second process.
- Understood: cursor movement and positioning, erasing (`J`, `K`, `X`), inserting and deleting lines and characters, the scroll region, save and restore, colours 30-37 and 90-97 with bold as bright, reverse video, wrapping, and the replies to `ESC [ 6 n` (cursor position) and `ESC [ c`, which BBSes use to detect ANSI. Bytes `$80`-`$FF` are code page 437: box drawing and blocks become PETSCII graphics, accented letters plain ones.
- Not on a C64 screen: background colours (one for the whole screen) and 80 columns (positions past column 40 stay on the last one). Most BBSes ask how wide the screen is: answer 40. A BBS that asks about linefeeds wants yes: a CR alone only returns to the start of the line.
- It runs on the console only. On a modem line no `login` runs there. Without a modem, `init`'s login on `/dev/ttyS0` waits while `screen` runs (the line is `screen`'s alone in binary mode) and answers again after CTRL-A k.

## On a real C64

- **SwiftLink or Turbo232 with a null-modem cable** to a PC serial port. Use a terminal program (PuTTY, minicom, screen) set to 9600 baud, 8N1, RTS/CTS flow control, VT100/ANSI emulation.
- **A WiFi modem** on the cartridge's port gives telnet access from the network.

## What works there

Everything that works with lines of text:
- the shell, with pipes, redirections, `&` jobs, history (cursor up and down) and TAB completion
- `ls`, `cat`, `grep`, `more`, `ps`, `kill`, `passwd`, `basic`, `as` and the rest

`more` reads its keys from `/dev/tty`, the terminal it runs on, so a remote `more` waits for the remote keyboard.

The full-screen programs, `edit` and `htop`, run only on the console. On the serial line they stop at once:

```
/ $ edit notes
edit: needs the console
```

and exit with status 1. They check `isatty`, which tells them which terminal they're on (below). Cursor positioning is still translated for other programs that use it.

### Keys

| On the remote keyboard | Becomes |
|---|---|
| Enter (CR, LF or CR LF) | RETURN |
| Backspace (DEL or BS) | DEL |
| cursor keys (`ESC [ A`/`B`/`C`/`D`) | cursor up / down / right / left |
| CTRL-C | interrupts this terminal's foreground job (SIGINT) |
| CTRL-Z | stops it (SIGTSTP), except in raw mode, where it is an ordinary key, as on the console |
| CTRL-D on an empty line | end of input |
| CTRL-U | throws away the line being typed |
| other `ESC [ …` sequences (Home, End, F-keys, PgUp…) | ignored |
| bytes `$80` and up | ignored (7-bit ASCII) |

RUN/STOP and RESTORE on the C64 only ever affect the console's jobs. CTRL-C on the serial line only affects the serial line's.

### What the screen gets

Programs write the same bytes as on the console. The serial line translates them:

| A program writes | The terminal receives |
|---|---|
| LF | CR LF |
| 8 (backspace) | `\b \b` (erases the character) |
| 12 (form feed, `clear`) | `ESC [ H` `ESC [ 2 J` (cursor home, clear the screen) |
| 7 (BEL) | BEL unchanged: the terminal beeps (the console beeps on the SID) |
| `ESC = row col` (cursor to row 0–24, column 0–39) | `ESC [ row+1 ; col+1 H` (rows and columns past the screen are clamped, as on the console) |
| `ESC R` / `ESC r` | `ESC [ 7 m` / `ESC [ m` (reverse video on / off) |
| `ESC K` | `ESC [ K` (clear to the end of the line) |
| `ESC C fg bg border` | nothing: colours are dropped (`theme` has no effect remotely) |

## Logging out, hanging up

- **`exit`** in the remote shell ends the session, and `init` shows `login:` again.
- **Losing the carrier** (DCD drops, for example the modem hangs up): every process of the serial line gets SIGHUP, and a new login starts.

## For programs

| | |
|---|---|
| `isatty(fd)` | carry clear for both terminals; **X** says which (0 console, 1 serial line) |
| `conmode` | acts on the terminal of your standard input. Mode 2 on the serial line is binary (no translation either way, CTRL-C is data, a read returns all that is waiting); on the console it is raw without the blinking cursor |
| `/dev/tty` | always the terminal you run on |
| `/dev/ttyS0` | the serial line itself (`ENODEV` without the cartridge) |
| `O_NONBLOCK` | opened with it, a read with nothing typed (cooked: no whole line yet) returns `EAGAIN` instead of waiting; serial line only |

See [programming.md](programming.md).

## Limits

- **No file owners or permissions.** Every user can read, change or delete every file. c64fs inodes have no owner field yet.
- **One serial line, 9600 baud.** A full 40×25 screen takes about a second to draw.
- **Typing during disk activity.** While the disk is busy, the serial line is paused for a few jiffies at a time (RTS off) so that its interrupts can't spoil the disk's timing. A terminal with RTS/CTS waits; one without it (VICE's TCP line) can lose characters typed during long disk work. Typing at normal speed is fine; pasting a lot at once while the disk runs is not.
- **RESTORE during a disk transfer** may be ignored. Press it again.
- **Memory:** every logged-in user has a shell, about 20 pages of the 125-page program pool and 2 of the 12 process slots.
- **Not with GeoRAM** (same address as the cartridge).