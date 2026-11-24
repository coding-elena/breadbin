; screen: an ANSI terminal on the serial line
;
;   screen /dev/ttyS0      connect the console to the device in argv[1];
;                          any further arguments are ignored
;
; Keys: CTRL-A k quits, CTRL-A a sends a CTRL-A.
;
; Keys: C64 -> ANSI. The console in raw mode gives Breadbin's own key
; codes (include/breadbin.inc), already ASCII, not PETSCII. Several of
; them are the same byte as a CTRL letter, so a C64 key and a control key
; can't be told apart here:
;
;   C64 key          raw code        sent on the line
;   RETURN           K_RET   $0a LF  $0d CR (what a terminal sends; a modem
;                                    or a BBS ends a line on CR)
;   INST/DEL         K_DEL   $08     $08 BS, as sent: the Hayes backspace
;                    (= CTRL-H)      (tcpser's S5 register, 8 by default)
;                                    and what most BBSes expect. Not $7f
;                                    (ASCII DEL, PuTTY's and xterm's key):
;                                    tcpser's command mode takes $7f as a
;                                    character, so "atdt" lines couldn't be
;                                    corrected. Breadbin's own serial login
;                                    erases on both.
;   CRSR up/down     K_UP $10, K_DOWN $0e   ESC [ A / ESC [ B (VT100 cursor
;   CRSR right/left  K_RIGHT $06, K_LEFT $02   keys: ESC [ C / ESC [ D)
;                    (= CTRL-P, CTRL-N, CTRL-F, CTRL-B: those four can't
;                    be sent as themselves)
;   CLR/HOME         K_HOME  $01     the CTRL-A prefix (= CTRL-A). HOME has
;                    (= CTRL-A)      no ANSI key here; CTRL-A a sends $01
;   SHIFT CLR        K_CLR   $0c     $0c, as sent (= CTRL-L, form feed)
;   CTRL-I           K_TAB   $09     $09 TAB, as sent
;   other CTRL keys  $01-$1a         as sent (CTRL-J is RETURN's code: CR)
;   letters, digits  ASCII $20-$7e   as sent (the console has done the
;                                    PETSCII -> ASCII translation)
;   F1-F8            $85-$8c         dropped: no VT100 code is sent
;   RUN/STOP         (no code)       the kernel's SIGINT: ends screen
;                                    without ending screenw (use CTRL-A k)
;
; A console read blocks and only the serial line has O_NONBLOCK, so one
; process can't wait for both ends. It is two processes, like talk/talkw:
;
;   screen  (stdin = the console): raw console keys -> the device.
;   screenw (stdin = the device, spawned with our pid as argv[1]): puts the
;           device in binary mode and draws what arrives straight into
;           screen RAM, as an ANSI (VT100) terminal (see screenw.s).
;
; The console goes into conmode 2 (raw keys, no blinking cursor: screenw
; draws its own). Raw and binary modes belong to the process that set
; them, so each ends with its process.
;
; RUN/STOP kills screen (the kernel's SIGINT) but cannot reach screenw,
; which is on the serial terminal: it notices that screen has gone at the
; next byte that arrives, and ends then. Use CTRL-A k.
;
; Leaving (CTRL-A k) on a modem line hangs the call up first, while
; screenw still draws the modem's answers: the Hayes escape, GUARD jiffies
; of silence, +++, GUARD jiffies of silence (the guard time: S12 = 50,
; 1 s, on tcpser and most modems), then ATH CR. Without a call the modem is
; in command mode already: it ignores the +++ and answers ATH with OK. DTR
; is not dropped for it: VICE's TCP line (without IP232) doesn't pass DTR
; on, and many modems ignore DTR anyway (AT&D0).
;
; Note: init's login on /dev/ttyS0 reads the same receive ring (not on a
; modem line: there init starts no login).
;
; vibed by Lenu

.include "../../include/breadbin.inc"
.import print, eprint, argn, perr

; tty_on lives in the kernel's LOWDATA ($02A7, first variable of tty.s):
; bit 6 set = a Hayes modem answered AT at boot (a modem line)
TTY_ON = $02A7
GUARD  = 70             ; jiffies of silence around +++ (more than 1 s)

.macro setr0 lbl
        lda #<lbl
        sta r0
        lda #>lbl
        sta r0+1
.endmacro

.segment "CODE"
start:
        lda #0
        jsr SYS_ISATTY      ; X = 0 console, 1 serial line
        bcs @no
        txa
        beq @tty            ; it draws on the C64's screen: console only
@no:    lda #<s_notty
        ldx #>s_notty
        jmp fail
@tty:   lda argc
        cmp #2              ; first argument: the device
        bcs @arg
        lda #<s_usage
        ldx #>s_usage
        jmp fail
@arg:   lda #1
        jsr argn
        sta devp
        stx devp+1
        jsr SYS_GETPID
        sta w_pid
        lda #<s_welcome     ; the welcome text
        ldx #>s_welcome
        jsr print
        lda devp
        ldx devp+1
        jsr print
        lda #<s_keys
        ldx #>s_keys
        jsr print
        lda devp
        sta r0
        lda devp+1
        sta r0+1
        lda #O_RDWR
        jsr SYS_OPEN
        bcc @open
        ldx devp            ; "screen: <device>: message"
        ldy devp+1
        jsr perr
        lda #1
        jmp SYS_EXIT
@open:  sta fd
        lda #2              ; raw console keys, and no console cursor:
        jsr SYS_CONMODE     ; screenw draws on the screen from now on
        setr0 p_screenw
        lda #<w_argv
        sta r1
        lda #>w_argv
        sta r1+1
        lda fd              ; screenw's stdin = the device, stdout = ours
        ldx #1
        ldy #0
        jsr SYS_SPAWN
        bcc @up
        lda #0
        jsr SYS_CONMODE
        ldx devp
        ldy devp+1
        jsr perr
        lda #1
        jmp SYS_EXIT
@up:    sta cpid

@key:   setr0 key
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #0              ; stdin
        jsr SYS_READ
        bcs @quit
        lda r1
        ora r1+1
        beq @quit
        lda key
        ldx prefix
        bne @pfx
        cmp #K_HOME         ; CTRL-A: the prefix
        bne @tr
        sta prefix
        jmp @key
@pfx:   ldx #0
        stx prefix
        cmp #'k'
        beq @quit
        cmp #'a'            ; CTRL-A a: a CTRL-A to the line
        bne @key
        lda #$01
        jsr put1
        jmp @key
; the key bindings (the table at the top): RETURN and the cursor keys are
; translated, codes $80 and up dropped, everything else sent as it is
@tr:    cmp #K_RET          ; RETURN (LF on the console) -> CR
        bne @n1
        lda #$0d
        bne @snd
@n1:    ldx #3              ; cursor codes -> ESC [ A-D
@c:     cmp ktab,x
        beq @esc
        dex
        bpl @c
        cmp #$80            ; F-keys and the like: dropped
        bcc @snd            ; DEL (K_DEL) goes out here as $08 BS
        jmp @key
@snd:   jsr put1
        jmp @key
@esc:   lda ltab,x
        sta out+2
        lda #ESC
        sta out
        lda #'['
        sta out+1
        ldx #3
        jsr putn
        jmp @key

@quit:  bit TTY_ON          ; a modem line: hang up first (bit 6 -> V)
        bvc @stop
        jsr hangup
@stop:  lda cpid            ; screenw ends, and the line is cooked again
        ldx #SIGTERM
        jsr SYS_KILL
        lda cpid
        ldx #0
        jsr SYS_WAIT
        lda #0
        jsr SYS_CONMODE
        lda fd
        jsr SYS_CLOSE
        lda #<s_bye         ; clears the screen: the console's own idea of
        ldx #>s_bye         ; it is out of date
        jsr print
        lda #0
        jmp SYS_EXIT

; put1: A = a byte -> the device.  putn: X bytes of out -> the device
put1:   sta out
        ldx #1
putn:   stx r1
        lda #0
        sta r1+1
        setr0 out
        lda fd
        jmp SYS_WRITE

; putp: X bytes at A/Y -> the device
putp:   sta r0
        sty r0+1
        stx r1
        lda #0
        sta r1+1
        lda fd
        jmp SYS_WRITE

; hangup: +++ between two guard times, then ATH CR; then a moment more,
; so the modem's OK (or NO CARRIER) is on the screen before screen clears it
hangup: jsr guard
        lda #<s_esc
        ldy #>s_esc
        ldx #3
        jsr putp
        jsr guard
        lda #<s_ath
        ldy #>s_ath
        ldx #4
        jsr putp
guard:  lda #GUARD
        ldx #0
        jmp SYS_SLEEP

; fail: the message at A/X on stderr, exit code 1
fail:   jsr eprint
        lda #1
        jmp SYS_EXIT

; ---------------------------------------------------------------------
.segment "DATA"
w_argv: .word w_arg0, w_pid, 0
w_pid:  .byte 0, 0          ; our pid, NUL terminated

.segment "RODATA"
p_screenw: .byte "/bin/screenw", 0
w_arg0:   .byte "screenw", 0
ktab:     .byte K_UP, K_DOWN, K_RIGHT, K_LEFT
ltab:     .byte "ABCD"
s_welcome: .byte "Welcome to screen.", 10, "Connecting to ", 0
s_keys:   .byte "...", 10
          .byte "Ctrl-A k: quit | Ctrl-A a: Ctrl-A", 10, 10, 0
s_bye:    .byte 12, "[screen is terminating]", 10, 0
s_esc:    .byte "+++"
s_ath:    .byte "ATH", 13
s_usage:  .byte "usage: screen /dev/ttyS0", 10, 0
s_notty:  .byte "screen: needs the console", 10, 0

.segment "BSS"
fd:     .res 1
cpid:   .res 1
prefix: .res 1
key:    .res 1
devp:   .res 2
out:    .res 3
