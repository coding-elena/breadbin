; who: list the users logged in, one line per terminal ("name     term")
; (any arguments are accepted and ignored)
;
; Terminal 0 is the console, terminal 1 the serial line. init runs one login
; (then the shell, "sh") per terminal, so a session is a child of init (pid 1)
; named "sh" that has not exited; a terminal still at "login:" has no "sh",
; so it is not listed. Names come from the uid, as whoami does (the number
; if there is no such name in /etc/passwd).
;
; SYS_PROCINFO does not say which terminal a process is on. Our own is found
; with isatty (on stdin, stdout or stderr, whichever is still a terminal), and
; our own session's shell is found by walking up from our pid to the child of
; init, as talk does. That shell is on our terminal, so the only other
; session is on the other one. If none of our files is a terminal (all
; redirected), the terminal is shown as "?".
.include "../../include/breadbin.inc"
.import print, putc, newline, print_dec_w, pw_find_uid, pw_name

NAMECOL = 9             ; the name, padded to this many columns (at least 1 space)

.macro setr0 lbl
        lda #<lbl
        sta r0
        lda #>lbl
        sta r0+1
.endmacro

.segment "CODE"
start:  jsr getterm         ; term, known
        jsr SYS_GETPID
        sta mypid
        jsr find_mysh
        lda #0
        sta slot
@l:     jsr pinfo
        beq @done
        bcs @n              ; empty slot
        lda pi+1            ; ppid: a child of init
        cmp #1
        bne @n
        lda pi+2            ; state: not a zombie
        cmp #3
        beq @n
        lda pi+5            ; name: "sh"
        cmp #'s'
        bne @n
        lda pi+6
        cmp #'h'
        bne @n
        lda pi+7
        bne @n
        jsr show
@n:     inc slot
        jmp @l
@done:  rts

; getterm: the terminal of the first of stdin, stdout, stderr that is one ->
; term, known = 1; known stays 0 if there is none
getterm:
        lda #0
        sta known
        sta fdn
@t:     lda fdn
        jsr SYS_ISATTY
        bcc @ok
        inc fdn
        lda fdn
        cmp #3
        bne @t
        rts
@ok:    stx term
        lda #1
        sta known
        rts

; show: the session in pi -> "name     terminal" and a newline
show:   lda pi+16           ; uid
        sta uid
        jsr pw_find_uid
        bcs @num
        lda #0
        sta col
@c:     ldx col
        lda pw_name,x
        beq @pad
        jsr putc
        inc col
        bne @c
@pad:   lda #' '
        jsr putc
        inc col
        lda col
        cmp #NAMECOL
        bcc @pad
        jmp @term
@num:   lda uid             ; no such name: the number
        ldx #0
        ldy #NAMECOL-1
        jsr print_dec_w
        lda #' '
        jsr putc
@term:  lda known
        beq @unk
        lda term            ; our shell is on our terminal,
        ldx pi              ; the other one on the other
        cpx mysh
        beq @pn
        eor #1
@pn:    cmp #0
        bne @tty
        lda #<s_console
        ldx #>s_console
        jmp @p
@tty:   lda #<s_tty
        ldx #>s_tty
        jmp @p
@unk:   lda #<s_unk
        ldx #>s_unk
@p:     jsr print
        jmp newline

; find_mysh: walk up from our pid to the child of init (pid 1): our own
; session's shell -> mysh
find_mysh:
        lda mypid
        sta cur
        lda #8
        sta hops
@next:  lda #0
        sta slot
@scan:  jsr pinfo
        beq @fail
        bcs @adv
        lda pi
        cmp cur
        beq @found
@adv:   inc slot
        jmp @scan
@found: lda pi+1
        cmp #1
        beq @top
        sta cur
        dec hops
        bne @next
@fail:  lda mypid
        sta mysh
        rts
@top:   lda cur
        sta mysh
        rts

; pinfo: the process in slot -> pi. Z set: no slots left; otherwise carry
; set if the slot is empty
pinfo:  lda slot
        cmp #16
        beq @r
        setr0 pi
        lda slot
        jsr SYS_PROCINFO
        lda #1              ; Z clear (lda keeps the carry)
@r:     rts

.segment "RODATA"
s_console: .byte "console", 0
s_tty:     .byte "tty", 0
s_unk:     .byte "?", 0

.segment "BSS"
term:   .res 1
known:  .res 1
fdn:    .res 1
mypid:  .res 1
mysh:   .res 1
cur:    .res 1
hops:   .res 1
slot:   .res 1
uid:    .res 1
col:    .res 1
pi:     .res 17