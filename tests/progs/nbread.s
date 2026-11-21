; nbread [raw]: open /dev/tty with O_NONBLOCK and read it until something
; comes. Prints "again" for the first read that would have waited, then
; "got:" and what was read. With "raw", in raw mode (one key per read).
.include "../../include/breadbin.inc"
.import argn, perr
fd    = $23
said  = $24
raw   = $25
.segment "CODE"
        lda #0
        sta said
        sta raw
        lda #1
        jsr argn
        bcs @open           ; no argument: cooked
        sta r0
        stx r0+1
        ldy #0
        lda (r0),y
        cmp #'r'
        bne @open
        inc raw
        lda #1
        jsr SYS_CONMODE
@open:  lda #<path
        sta r0
        lda #>path
        sta r0+1
        lda #(O_RDONLY | O_NONBLOCK)
        jsr SYS_OPEN
        bcs @err
        sta fd
@read:  lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #80
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_READ
        bcc @got
        cmp #EAGAIN
        bne @err
        lda said
        bne @y
        inc said
        lda #<s_again
        ldx #>s_again
        jsr SYS_PRINT
@y:     jsr SYS_YIELD
        jmp @read
@got:   lda #<s_got
        ldx #>s_got
        jsr SYS_PRINT
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #1
        jsr SYS_WRITE       ; r1 = the count read
        lda #10
        jsr SYS_PUTC
        lda raw
        beq @x
        lda #0
        jsr SYS_CONMODE
@x:     lda #0
        jmp SYS_EXIT
@err:   ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
.segment "RODATA"
path:    .byte "/dev/tty", 0
s_again: .byte "again", 10, 0
s_got:   .byte "got:", 0
.segment "BSS"
buf:     .res 81
