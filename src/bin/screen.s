; screen: a basic terminal on the serial line
;
;   screen /dev/ttyS0      connect the console to the device in argv[1];
;                          any further arguments are ignored
;
; Keys: CTRL-A k quits, CTRL-A a sends a CTRL-A.
;
; A console read blocks and only the serial line has O_NONBLOCK, so one
; process can't wait for both ends. It is two processes, the same program:
;
;   the parent (stdin = the console): raw console keys -> the device.
;   the child  (stdin = the device, spawned by the parent as "/bin/screen"
;              with the parent's pid as argv[2]): sets the device raw (with
;              stdin on the serial line conmode acts on it) and copies what
;              arrives to the console.
;
; The child tells itself from the parent by isatty: its stdin is terminal 1.
; Raw mode belongs to the process that set it, so it ends with the child.
;
; RUN/STOP kills the parent (the kernel's SIGINT) but cannot reach the
; child, which is on the serial terminal: it notices that its parent has
; gone at the next byte that arrives, and ends then. Use CTRL-A k.
;
; Note: init's login on /dev/ttyS0 reads the same receive ring.

.include "../../include/breadbin.inc"
.import print, eprint, argn, perr

.macro setr0 lbl
        lda #<lbl
        sta r0
        lda #>lbl
        sta r0+1
.endmacro

.segment "ZEROPAGE"
ptr:    .res 2

.segment "CODE"
start:
        lda #0
        jsr SYS_ISATTY      ; X = 0 console, 1 serial line
        bcc @tty
        lda #<s_notty
        ldx #>s_notty
        jmp fail
@tty:   stx term
        lda argc
        cmp #2              ; first argument: the device
        bcs @arg
        lda #<s_usage
        ldx #>s_usage
        jmp fail
@arg:   lda term
        beq parent
        jmp child           ; stdin on the serial line: we are the child

; ---------------------------------------------------------------------
; the parent: keyboard -> device
parent: lda #1
        jsr argn
        sta devp
        stx devp+1
        sta w_argv+2        ; the child gets the same device argument
        stx w_argv+3
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
        setr0 p_screen
        lda #<w_argv
        sta r1
        lda #>w_argv
        sta r1+1
        lda fd              ; the child's stdin = the device, stdout = ours
        ldx #1
        ldy #0
        jsr SYS_SPAWN
        bcc @up
        ldx devp
        ldy devp+1
        jsr perr
        lda #1
        jmp SYS_EXIT
@up:    sta cpid
        lda #1              ; raw console keys: no echo, no line editing
        jsr SYS_CONMODE

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

@quit:  lda cpid            ; the child ends, and the line is cooked again
        ldx #SIGTERM
        jsr SYS_KILL
        lda cpid
        ldx #0
        jsr SYS_WAIT
        lda #0
        jsr SYS_CONMODE
        lda fd
        jsr SYS_CLOSE
        lda #<s_bye
        ldx #>s_bye
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

; ---------------------------------------------------------------------
; the child: device -> screen
child:  lda #1              ; stdin is the serial line: it goes raw
        jsr SYS_CONMODE
        lda #2              ; the parent's pid
        jsr argn
        bcs @end            ; no pid given: nothing to do
        sta ptr
        stx ptr+1
        ldy #0
        lda (ptr),y
        sta ppid
@rd:    setr0 key
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #0              ; stdin = the device; waits for a byte
        jsr SYS_READ
        bcs @end
        lda r1
        ora r1+1
        beq @end
        lda ppid            ; the parent gone (RUN/STOP): end too
        ldx #0
        jsr SYS_KILL
        bcc @live
        cmp #ESRCH
        beq @end
@live:  lda key
        cmp #K_RET          ; RETURN, backspace, bell, tab and printable
        beq @ok             ; ASCII; other control codes (the cursor keys
        cmp #K_DEL          ; the line driver maps) are dropped
        beq @ok
        cmp #7
        beq @ok
        cmp #K_TAB
        beq @ok
        cmp #$20
        bcc @rd
        cmp #$7f
        bcs @rd
@ok:    lda #1
        sta r1
        lda #0
        sta r1+1
        setr0 key
        lda #1              ; stdout
        jsr SYS_WRITE
        jmp @rd
@end:   lda #0
        jmp SYS_EXIT

; fail: the message at A/X on stderr, exit code 1
fail:   jsr eprint
        lda #1
        jmp SYS_EXIT

; ---------------------------------------------------------------------
.segment "DATA"
; the child's arguments: argv[1] (the device) is patched in
w_argv: .word w_arg0, 0, w_pid, 0
w_pid:  .byte 0, 0          ; our pid, NUL terminated

.segment "RODATA"
p_screen: .byte "/bin/screen", 0
w_arg0:   .byte "screen", 0
ktab:     .byte K_UP, K_DOWN, K_RIGHT, K_LEFT
ltab:     .byte "ABCD"
s_welcome: .byte "Welcome to screen.", 10, "Connecting to ", 0
s_keys:   .byte "...", 10
          .byte "Ctrl-A k: quit | Ctrl-A a: Ctrl-A", 10, 10, 0
s_bye:    .byte 10, "[screen is terminating]", 10, 0
s_usage:  .byte "usage: screen /dev/ttyS0", 10, 0
s_notty:  .byte "screen: not a terminal", 10, 0

.segment "BSS"
term:   .res 1
fd:     .res 1
cpid:   .res 1
ppid:   .res 1
prefix: .res 1
key:    .res 1
devp:   .res 2
out:    .res 3