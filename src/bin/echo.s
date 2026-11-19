; echo [-n] [-e] [args]: print arguments
;   -n  no newline at the end
;   -e  read \n \e \b \xHH \\ in the arguments
; Each option is its own argument. The first argument that is not
; exactly -n or -e is text, and so is everything after it.
; Branches only (no jmp/jsr inside the program): no relocations.
.include "../../include/breadbin.inc"
.import putc, newline, argn

idx  = $23          ; argument number
p    = $24          ; 2 bytes: the argument being printed
fn   = $26          ; nonzero: -n
fe   = $27          ; nonzero: -e
hx   = $28          ; \x value
ofs  = $29          ; offset into the argument
od   = $2a          ; nonzero: past the options

.segment "CODE"
        ldx #0
        stx fn
        stx fe
        stx od
        inx
        stx idx
        bne @loop
@end:   lda fn
        bne @rts
        jmp newline
@rts:   rts
@next:  inc idx             ; a space between arguments
        lda idx
        cmp argc
        bcs @end
        lda #' '
        jsr putc
@loop:  lda idx
        jsr argn
        bcs @end
        sta p
        stx p+1
        ldy #0
        sty ofs
        lda od
        bne @arg
        lda (p),y           ; an option is exactly "-n" or "-e"
        cmp #'-'
        bne @text
        ldy #2
        lda (p),y
        bne @text
        dey
        lda (p),y
        cmp #'n'
        bne @oe
        sta fn
        beq @onext          ; Z still set by the cmp
@oe:    cmp #'e'
        bne @text
        sta fe
@onext: inc idx
        bne @loop
@text:  inc od
        bne @arg
@put:   jsr putc
@arg:   ldy ofs
        inc ofs
        lda (p),y
        beq @next
        ldx fe
        beq @put
        cmp #$5c            ; backslash
        bne @put
        ldy ofs
        inc ofs
        lda (p),y
        beq @unk            ; at the end: print the backslash
        ldx #$0a
        cmp #'n'
        beq @x
        ldx #$1b
        cmp #'e'
        beq @x
        ldx #$08
        cmp #'b'
        beq @x
        cmp #$5c
        beq @put
        cmp #'x'
        bne @unk
        lda #0              ; \x: one or two hex digits
        sta hx
        ldx #2
@hl:    ldy ofs
        lda (p),y
        ora #$20            ; A-F -> a-f (digits keep their value)
        eor #'0'            ; 0-9 -> 0-9
        cmp #10
        bcc @dg
        sbc #'a'^'0'        ; carry set: a-f -> 0-5
        cmp #6
        bcs @hd             ; not a hex digit
        adc #10             ; carry clear
@dg:    asl hx
        asl hx
        asl hx
        asl hx
        ora hx
        sta hx
        inc ofs
        dex
        bne @hl
@hd:    lda hx
        cpx #2
        bcc @put            ; got a digit
@unk:   dec ofs             ; anything else: print the backslash, and
        lda #$5c            ; the byte after it is read again as text
        bne @put
@x:     txa
        bne @put
