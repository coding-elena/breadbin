; screen: an ANSI terminal on the serial line
;
;   screen /dev/ttyS0      connect the console to the device in argv[1];
;                          any further arguments are ignored
;
; Keys: CTRL-A k quits, CTRL-A a sends a CTRL-A.
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
; Note: init's login on /dev/ttyS0 reads the same receive ring (not on a
; modem line: there init starts no login).
;
; vibed by Lenu

.include "../../include/breadbin.inc"
.import print, eprint, argn, perr

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
@tr:    cmp #K_RET          ; RETURN -> CR
        bne @n1
        lda #$0d
        bne @snd
@n1:    cmp #K_DEL          ; DEL -> $7f
        bne @n2
        lda #$7f
        bne @snd
@n2:    ldx #3              ; cursor codes -> ESC [ A-D
@c:     cmp ktab,x
        beq @esc
        dex
        bpl @c
        cmp #$80            ; F-keys and the like: dropped
        bcc @snd
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

@quit:  lda cpid            ; screenw ends, and the line is cooked again
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
s_usage:  .byte "usage: screen /dev/ttyS0", 10, 0
s_notty:  .byte "screen: needs the console", 10, 0

.segment "BSS"
fd:     .res 1
cpid:   .res 1
prefix: .res 1
key:    .res 1
devp:   .res 2
out:    .res 3
