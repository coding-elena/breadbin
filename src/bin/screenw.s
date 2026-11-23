; screenw: screen's receiver (screen starts it; not a command of its own)
;
;   screenw P       P: one byte, screen's pid; stdin is the serial line
;
; Puts the serial line in binary mode (conmode 2: every byte as it comes,
; a read returns all that is waiting) and draws what arrives straight
; into screen RAM ($0400) and colour RAM ($D800), as an ANSI (VT100)
; terminal of 40 x 25. screen has put the console in conmode 2 (raw keys,
; no blinking cursor), so nothing else draws there; this draws its own
; cursor while it waits.
;
; Understood:
;   BEL BS TAB LF VT FF CR, CAN/SUB (cancel a sequence), DEL ignored
;   ESC 7 / 8 (save, restore), D M E (index, reverse index, next line),
;   ESC c (reset), ESC ( ) # x (charset: ignored)
;   CSI A B C D E F G H f d (cursor), J K X (erase), L M (lines),
;   @ P (characters), m (colours), s u, r (scroll region),
;   n (5n, 6n: replies on the line), c (device attributes),
;   ? 25 h/l (cursor), ? 7 h/l (wrap)
;   m: 0 1 7 22 27 30-37 39 90-97; backgrounds (one per screen on the
;   C64) and the rest are ignored
;   bytes $80-$FF as code page 437 (box drawing and blocks -> the nearest
;   PETSCII graphics, accented letters -> plain ones)
; Columns past 40 are clamped to the last one.
;
; It ends when the line hangs up, on a read error, or when it sees that
; screen has gone (checked once per read, with kill signal 0).
;
; vibed by Lenu
;

.include "../../include/breadbin.inc"
.import argn

SCR    = $0400
COLR   = $D800
BUFSZ  = 64

.segment "ZEROPAGE"
scr:    .res 2          ; the row being drawn: screen RAM
colp:   .res 2          ;                       colour RAM
src:    .res 2          ; scroll: from
csrc:   .res 2
dst:    .res 2          ; scroll: to
cdst:   .res 2

.segment "CODE"
start:
        lda #0
        jsr SYS_ISATTY      ; stdin must be the serial line
        bcs @no
        cpx #1
        beq @yes
@no:    jmp @bad
@yes:
        lda #1              ; screen's pid
        jsr argn
        bcs @bad
        sta src
        stx src+1
        ldy #0
        lda (src),y
        sta ppid
        lda #2              ; binary: no translation, whole reads
        jsr SYS_CONMODE
        lda $0286           ; the console's text colour
        and #15
        sta defcol
        jsr reset
        lda $d6             ; carry on below screen's welcome text
        cmp #25
        bcc @r
        lda #24
@r:     sta row
        lda #0
        sta cx

@main:  jsr cur_draw
        lda #<ibuf
        sta r0
        lda #>ibuf
        sta r0+1
        lda #BUFSZ
        sta r1
        lda #0
        sta r1+1
        lda #0              ; stdin = the line; waits for a byte
        jsr SYS_READ
        bcs @end
        lda r1
        beq @end
        sta n
        jsr cur_hide
        lda ppid            ; screen gone (RUN/STOP): end too
        ldx #0
        jsr SYS_KILL
        bcc @live
        cmp #ESRCH
        beq @end
@live:  ldx #0
@feed:  stx ip
        lda ibuf,x
        jsr feed
        ldx ip
        inx
        cpx n
        bne @feed
        jmp @main
@end:   jsr cur_hide
@bad:   lda #0
        jmp SYS_EXIT

; ---------------------------------------------------------------------
; reset: attributes, modes and margins as at the start
reset:  lda #$ff
        sta fgidx
        lda #0
        sta bold
        sta rev
        sta wrap
        sta st
        sta top
        sta sv_row
        sta sv_cx
        lda #24
        sta bot
        lda #1
        sta awrap
        sta curvis
        lda defcol
        sta curcol
        sta sv_col
        rts

; rowptr: X = row -> scr, colp.  setrow: the cursor's row
setrow: ldx row
rowptr: lda rowlo,x
        sta scr
        sta colp
        lda rowhi,x
        sta scr+1
        clc
        adc #>(COLR - SCR)
        sta colp+1
        rts

; cur_draw / cur_hide: our cursor, a reversed cell
cur_draw:
        lda curvis
        beq @r
        lda row
        sta cur_r
        tax
        jsr rowptr
        ldy cx
        sty cur_c
        lda (scr),y
        sta cur_ch
        eor #$80
        sta (scr),y
        lda #1
        sta cur_on
@r:     rts

cur_hide:
        lda cur_on
        beq @r
        ldx cur_r
        jsr rowptr
        ldy cur_c
        lda cur_ch
        sta (scr),y
        lda #0
        sta cur_on
@r:     rts

; ---------------------------------------------------------------------
; feed: A = one byte from the line
feed:   cmp #$20
        bcs @nc
        jmp ctrl            ; control codes act in any state
@nc:    ldx st
        bne @state
        cmp #$7f
        ;; beq @r              ; DEL: nothing
        beq @del
        jsr map
        jmp putc
@del:   
        lda cx
        beq @r  ; start of line
        dec cx
        bpl @r
@state: cpx #1
        bne @s2
        jmp esc
@s2:    cpx #2
        bne @s3
        jmp csi
@s3:    lda #0              ; ESC ( x and the like: x is dropped
        sta st
@r:     rts

; map: A = a byte $20-$FF -> its screen code (lowercase charset)
map:    cmp #$80
        bcs @hi
        cmp #$40
        bcc @r              ; $20-$3F: the same
        tax
        lda asctab-$40,x
@r:     rts
@hi:    tax
        lda cptab-$80,x
        rts

; putc: A = a screen code -> the cursor, then the cursor moves on
putc:   eor rev
        pha
        lda wrap            ; the last column was written: wrap first
        beq @nw
        lda #0
        sta wrap
        sta cx
        jsr index
@nw:    jsr setrow
        ldy cx
        pla
        sta (scr),y
        lda curcol
        sta (colp),y
        cpy #39
        bcc @inc
        lda awrap
        sta wrap
        rts
@inc:   inc cx
        rts

; ---------------------------------------------------------------------
; control codes
ctrl:   cmp #$1b
        bne @c1
        lda #1
        sta st
        rts
@c1:    cmp #$18            ; CAN, SUB: cancel a sequence
        beq @can
        cmp #$1a
        bne @c2
@can:   lda #0
        sta st
        rts
@c2:    ldx #0
        stx wrap
        cmp #13
        bne @c3
        stx cx
        rts
@c3:    cmp #10
        bcc @c4
        cmp #13
        bcs @r              ; 14-31: nothing
        jmp index           ; LF, VT, FF
@c4:    cmp #8
        bne @c5
        lda cx
        beq @r
        dec cx
        rts
@c5:    cmp #9
        bne @c6
        lda cx
        ora #7
        cmp #39
        bcs @t
        adc #1
@t:     sta cx
        rts
@c6:    cmp #7
        bne @r
        lda #<s_bel         ; BEL: the console beeps
        sta r0
        lda #>s_bel
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #1
        jmp SYS_WRITE
@r:     rts

; ---------------------------------------------------------------------
; ESC x
esc:    ldx #0
        stx st
        stx wrap
        cmp #'['
        bne @e1
        lda #2
        sta st
        stx np
        stx priv
        stx par
        stx par+1
        stx par+2
        stx par+3
        rts
@e1:    cmp #'7'
        bne @e2
        jmp save
@e2:    cmp #'8'
        bne @e3
        jmp restore
@e3:    cmp #'D'
        bne @e4
        jmp index
@e4:    cmp #'M'
        bne @e5
        jmp rindex
@e5:    cmp #'E'
        bne @e6
        stx cx
        jmp index
@e6:    cmp #'c'
        bne @e7
        jsr reset
        jsr clr_all
        jmp home
@e7:    cmp #'('
        beq @sk
        cmp #')'
        beq @sk
        cmp #'#'
        bne @r
@sk:    lda #3
        sta st
@r:     rts

; ---------------------------------------------------------------------
; ESC [ ... : parameters, then the final byte
csi:    cmp #'0'
        bcc @nd
        cmp #'9'+1
        bcs @nd
        and #$0f            ; a digit: par = par * 10 + digit, at most 255
        sta tmp
        ldx np
        lda par,x
        cmp #26
        bcs @max
        asl a
        sta tmp2
        asl a
        asl a
        adc tmp2
        adc tmp
        bcc @st
@max:   lda #255
@st:    sta par,x
        rts
@nd:    cmp #';'
        bne @n1
        lda np
        cmp #3
        bcs @r
        inc np
@r:     rts
@n1:    cmp #'?'
        bcc @n2
        cmp #'@'
        bcs @fin
        lda #1              ; ? > = : a private sequence
        sta priv
        rts
@n2:    rts                 ; intermediate bytes: nothing
@fin:   ldx #0
        stx st
        ldx #ntab-1
@f:     cmp ftab,x
        beq @go
        dex
        bpl @f
        rts
@go:    cmp #'m'            ; moving the cursor ends a pending wrap
        beq @sgr
        ldy #0
        sty wrap
@sgr:   lda jhi,x           ; rts to the routine (no jmp (): its page bug)
        pha
        lda jlo,x
        pha
        rts

; n1: A = the first parameter, 0 counting as 1
n1:     lda par
        bne @r
        lda #1
@r:     rts

; tocol / torow: A = a 1-based parameter (0 = 1) -> 0-based, clamped
tocol:  jsr dec0
        cmp #40
        bcc @r
        lda #39
@r:     rts
torow:  jsr dec0
        cmp #25
        bcc @r
        lda #24
@r:     rts
dec0:   sec
        sbc #1
        bcs @r
        lda #0
@r:     rts

c_up:   jsr n1              ; CSI n A
        sta tmp
        lda row
        sec
        sbc tmp
        bcs @s
        lda #0
@s:     sta row
        rts
c_down: jsr n1              ; CSI n B
        clc
        adc row
        bcs @c
        cmp #25
        bcc @s
@c:     lda #24
@s:     sta row
        rts
c_right:
        jsr n1              ; CSI n C
        clc
        adc cx
        bcs @c
        cmp #40
        bcc @s
@c:     lda #39
@s:     sta cx
        rts
c_left: jsr n1              ; CSI n D
        sta tmp
        lda cx
        sec
        sbc tmp
        bcs @s
        lda #0
@s:     sta cx
        rts
c_nextl:
        jsr c_down          ; CSI n E
        lda #0
        sta cx
        rts
c_prevl:
        jsr c_up            ; CSI n F
        lda #0
        sta cx
        rts
c_col:  lda par             ; CSI n G
        jsr tocol
        sta cx
        rts
c_row:  lda par             ; CSI n d
        jsr torow
        sta row
        rts
c_pos:  lda par             ; CSI row ; col H (and f)
        jsr torow
        sta row
        lda par+1
        jsr tocol
        sta cx
        rts
home:   lda #0
        sta row
        sta cx
        rts

; CSI n J: 0 to the end of the screen, 1 from its start, 2 all (and home,
; as ANSI.SYS does: BBSes count on it)
c_ed:   lda par
        bne @e1
        jsr eol             ; 0: the rest of this line, the rows below
        ldx row
@l0:    inx
        cpx #25
        bcs @r
        jsr clr_row
        jmp @l0
@e1:    cmp #1
        bne @e2
        jsr bol             ; 1: the rows above, this line up to us
        ldx row
@l1:    dex
        bmi @r
        jsr clr_row
        jmp @l1
@e2:    jsr clr_all
        jmp home
@r:     rts

; CSI n K: 0 to the end of the line, 1 from its start, 2 all of it
c_el:   lda par
        beq eol
        cmp #1
        beq bol
        ldx row
        jmp clr_row
eol:    lda cx
        ldx #39
        jmp span
bol:    lda #0
        ldx cx
        jmp span

; CSI n X: n characters from the cursor
c_ech:  jsr n1
        clc
        adc cx
        bcs @c
        sbc #0              ; carry clear: - 1
        cmp #40
        bcc @s
@c:     lda #39
@s:     tax
        lda cx
        ; fall through

; span: blank columns A..X of the cursor's row
span:   sta tmp
        stx tmp2
        jsr setrow
        ldy tmp
@l:     cpy tmp2
        beq @w
        bcs @r
@w:     lda #$20
        sta (scr),y
        lda curcol
        sta (colp),y
        iny
        bne @l
@r:     rts

; clr_row: X = row, blanked.  clr_all: every row
clr_row:
        jsr rowptr
        ldy #39
@l:     lda #$20
        sta (scr),y
        lda curcol
        sta (colp),y
        dey
        bpl @l
        rts
clr_all:
        ldx #24
@l:     jsr clr_row
        dex
        bpl @l
        rts

; CSI n L / M: insert / delete n lines at the cursor (inside the region)
c_il:   jsr inreg
        bcs @r
        jsr n1
        sta tmp3
@l:     lda row
        ldx bot
        jsr scr_down
        dec tmp3
        bne @l
        lda #0
        sta cx
@r:     rts
c_dl:   jsr inreg
        bcs @r
        jsr n1
        sta tmp3
@l:     lda row
        ldx bot
        jsr scr_up
        dec tmp3
        bne @l
        lda #0
        sta cx
@r:     rts
; inreg: carry clear if the cursor is inside the scroll region
inreg:  lda row
        cmp top
        bcc @no
        lda bot
        cmp row
        bcc @no
        clc
        rts
@no:    sec
        rts

; CSI n P / @: delete / insert n characters at the cursor
c_dch:  jsr n1
        jsr cnt
        jsr setrow
        ldy cx              ; move cx+n.. left by n
@l:     tya
        clc
        adc tmp
        cmp #40
        bcs @fill
        sty tmp2
        tay
        lda (scr),y
        pha
        lda (colp),y
        ldy tmp2
        sta (colp),y
        pla
        sta (scr),y
        iny
        bne @l
@fill:  tya                 ; blank the last n
        ldx #39
        jmp span
c_ich:  jsr n1
        jsr cnt
        jsr setrow
        ldy #39             ; move ..39-n right by n
@l:     tya
        sec
        sbc tmp
        bcc @fill
        cmp cx
        bcc @fill
        sty tmp2
        tay
        lda (scr),y
        pha
        lda (colp),y
        ldy tmp2
        sta (colp),y
        pla
        sta (scr),y
        dey
        bpl @l
@fill:  lda cx              ; blank cx .. cx+n-1
        clc
        adc tmp
        sbc #0
        tax
        lda cx
        jmp span
; cnt: A = n -> tmp = min(n, 40 - cx)
cnt:    sta tmp
        lda #40
        sec
        sbc cx
        cmp tmp
        bcs @r
        sta tmp
@r:     rts

; CSI top ; bottom r: the scroll region; the cursor goes home
c_stbm: lda par
        jsr torow
        sta tmp
        lda par+1
        bne @b
        lda #25
@b:     jsr torow
        cmp tmp
        beq @all
        bcs @ok
@all:   lda #0
        sta tmp
        lda #24
@ok:    sta bot
        lda tmp
        sta top
        jmp home

; CSI ? n h / l: 25 the cursor, 7 wrapping
c_set:  lda #1
        .byte $2c           ; bit abs: skip the lda #0
c_res:  lda #0
        ldx priv
        beq @r
        ldx par
        cpx #25
        bne @w
        sta curvis
        rts
@w:     cpx #7
        bne @r
        sta awrap
@r:     rts

c_save: jmp save
c_rest: jmp restore

; CSI 5 n / 6 n: status, cursor position (ESC [ row ; col R)
c_dsr:  lda par
        cmp #5
        bne @p
        lda #<s_ok
        ldx #>s_ok
        ldy #4
        jmp reply
@p:     cmp #6
        bne @r
        ldy #0
        lda #$1b
        sta rbuf,y
        iny
        lda #'['
        sta rbuf,y
        iny
        lda row
        jsr dec1
        lda #';'
        sta rbuf,y
        iny
        lda cx
        jsr dec1
        lda #'R'
        sta rbuf,y
        iny
        lda #<rbuf
        ldx #>rbuf
        jmp reply
@r:     rts
; dec1: A = 0-39 -> A + 1 in decimal at rbuf,y
dec1:   clc
        adc #1
        ldx #0
@t:     cmp #10
        bcc @u
        sbc #10
        inx
        bne @t
@u:     pha
        txa
        beq @n
        ora #'0'
        sta rbuf,y
        iny
@n:     pla
        ora #'0'
        sta rbuf,y
        iny
        rts

; CSI c: device attributes (a VT100 with no options)
c_da:   lda priv
        bne @r
        lda #<s_da
        ldx #>s_da
        ldy #7
        jmp reply
@r:     rts

; reply: Y bytes at A/X -> the line (stdin is the line, open read/write)
reply:  sta r0
        stx r0+1
        sty r1
        lda #0
        sta r1+1
        lda #0
        jmp SYS_WRITE

; CSI ... m: colours and attributes
c_sgr:  ldx #0
@l:     stx tmp3
        lda par,x
        bne @p1
        lda #$ff            ; 0: everything off
        sta fgidx
        lda #0
        sta bold
        sta rev
        beq @nx
@p1:    cmp #1
        bne @p2
        lda #8
        sta bold
        bne @nx
@p2:    cmp #22
        bne @p3
        lda #0
        sta bold
        beq @nx
@p3:    cmp #7
        bne @p4
        lda #$80
        sta rev
        bne @nx
@p4:    cmp #27
        bne @p5
        lda #0
        sta rev
        beq @nx
@p5:    cmp #39
        bne @p6
        lda #$ff
        sta fgidx
        bne @nx
@p6:    cmp #30
        bcc @nx
        cmp #38
        bcs @p7
        sbc #29             ; carry clear: - 30
        sta fgidx
        jmp @nx
@p7:    cmp #90
        bcc @nx
        cmp #98
        bcs @nx
        sbc #81             ; carry clear: - 90 + 8
        sta fgidx
@nx:    ldx tmp3
        inx
        cpx np
        beq @l
        bcc @l
        ; the colour from fgidx and bold
        lda fgidx
        bmi @def
        ora bold
        tax
        lda ctab,x
        sta curcol
        rts
@def:   lda defcol
        sta curcol
        rts

; ---------------------------------------------------------------------
; save / restore: the cursor and its attributes (ESC 7 / 8, CSI s / u)
save:   lda row
        sta sv_row
        lda cx
        sta sv_cx
        lda curcol
        sta sv_col
        lda fgidx
        sta sv_fg
        lda bold
        sta sv_bold
        lda rev
        sta sv_rev
        rts
restore:
        lda sv_row
        sta row
        lda sv_cx
        sta cx
        lda sv_col
        sta curcol
        lda sv_fg
        sta fgidx
        lda sv_bold
        sta bold
        lda sv_rev
        sta rev
        lda #0
        sta wrap
        rts

; index: down a line, scrolling the region at its bottom
index:  lda row
        cmp bot
        beq @s
        cmp #24
        bcs @r
        inc row
@r:     rts
@s:     lda top
        ldx bot
        bne scr_up          ; always (bot > top >= 0)

; rindex: up a line, scrolling the region down at its top
rindex: lda row
        cmp top
        beq @s
        cmp #0
        beq @r
        dec row
@r:     rts
@s:     ldx bot
        jmp scr_down

; scr_up: rows A..X move up one, row X is blanked. The whole screen has
; a fast path (absolute copies, about 17 ms)
scr_up: cmp #0
        bne @sl
        cpx #24
        beq @fast
@sl:    jmp @slow
@fast:  ldx #39
@f:     .repeat 24, I
        lda SCR+40*(I+1),x
        sta SCR+40*I,x
        .endrepeat
        .repeat 24, I
        lda COLR+40*(I+1),x
        sta COLR+40*I,x
        .endrepeat
        dex
        bmi @fd
        jmp @f
@fd:    ldx #24
        jmp clr_row
@slow:  stx tmp2
        tax
@l:     cpx tmp2
        bcs @clr
        jsr rowptr
        jsr to_dst
        inx
        jsr rowptr
        jsr copyrow
        jmp @l
@clr:   ldx tmp2
        jmp clr_row

; scr_down: rows A..X move down one, row A is blanked
scr_down:
        sta tmp
@l:     cpx tmp
        beq @clr
        bcc @clr
        jsr rowptr
        jsr to_dst
        dex
        jsr rowptr
        jsr copyrow
        jmp @l
@clr:   ldx tmp
        jmp clr_row

; to_dst: scr/colp -> dst/cdst.  copyrow: scr/colp's row -> dst/cdst's
to_dst: lda scr
        sta dst
        sta cdst
        lda scr+1
        sta dst+1
        lda colp+1
        sta cdst+1
        rts
copyrow:
        lda scr
        sta src
        sta csrc
        lda scr+1
        sta src+1
        lda colp+1
        sta csrc+1
        ldy #39
@c:     lda (src),y
        sta (dst),y
        lda (csrc),y
        sta (cdst),y
        dey
        bpl @c
        rts

; ---------------------------------------------------------------------
.segment "RODATA"
; final bytes and their routines
ftab:   .byte "ABCDEFGHfdJKXLMP@rhlsunc", "m"
ntab = * - ftab
; -1 each: they are reached by rts
.define JT c_up-1, c_down-1, c_right-1, c_left-1, c_nextl-1, c_prevl-1, c_col-1, c_pos-1, c_pos-1, c_row-1, c_ed-1, c_el-1, c_ech-1, c_il-1, c_dl-1, c_dch-1, c_ich-1, c_stbm-1, c_set-1, c_res-1, c_save-1, c_rest-1, c_dsr-1, c_da-1, c_sgr-1
jlo:    .lobytes JT
jhi:    .hibytes JT
.assert * - jhi = ntab, error, "ftab and the jump table differ"

rowlo:  .repeat 25, I
        .byte <(SCR+40*I)
        .endrepeat
rowhi:  .repeat 25, I
        .byte >(SCR+40*I)
        .endrepeat

; ANSI colours -> C64: black red green yellow blue magenta cyan white,
; then the bright ones (bold or 90-97)
ctab:   .byte 0, 2, 5, 9, 6, 4, 3, 15
        .byte 11, 10, 13, 7, 14, 4, 3, 1

; ASCII $40-$7F -> screen codes (lowercase charset): \ is the pound sign,
; ^ the up arrow, _ a low line, | a vertical line, as on the console
asctab: .byte $00
        .repeat 26, I
        .byte $41+I         ; A-Z
        .endrepeat
        .byte $1b, $1c, $1d, $1e, $64, $27
        .repeat 26, I
        .byte $01+I         ; a-z
        .endrepeat
        .byte $1b, $5d, $1d, $2d, $20

; code page 437 $80-$FF -> screen codes
cptab:  .byte $43,$15,$05,$01,$01,$01,$01,$03  ; 80 Ç ü é â ä à å ç
        .byte $05,$05,$05,$09,$09,$09,$41,$41  ; 88 ê ë è ï î ì Ä Å
        .byte $45,$01,$41,$0f,$0f,$0f,$15,$15  ; 90 É æ Æ ô ö ò û ù
        .byte $19,$4f,$55,$03,$1c,$59,$50,$06  ; 98 ÿ Ö Ü ¢ £ ¥ Pt ƒ
        .byte $01,$09,$0f,$15,$0e,$4e,$01,$0f  ; A0 á í ó ú ñ Ñ ª º
        .byte $3f,$70,$6e,$2f,$2f,$21,$3c,$3e  ; A8 ¿ ⌐ ¬ ½ ¼ ¡ « »
        .byte $66,$66,$e6,$5d,$73,$73,$73,$6e  ; B0 ░ ▒ ▓ │ ┤ ╡ ╢ ╖
        .byte $6e,$73,$5d,$6e,$7d,$7d,$7d,$6e  ; B8 ╕ ╣ ║ ╗ ╝ ╜ ╛ ┐
        .byte $6d,$71,$72,$6b,$40,$5b,$6b,$6b  ; C0 └ ┴ ┬ ├ ─ ┼ ╞ ╟
        .byte $6d,$70,$71,$72,$6b,$40,$5b,$71  ; C8 ╚ ╔ ╩ ╦ ╠ ═ ╬ ╧
        .byte $71,$72,$72,$6d,$6d,$70,$70,$5b  ; D0 ╨ ╤ ╥ ╙ ╘ ╒ ╓ ╫
        .byte $5b,$7d,$70,$a0,$62,$61,$e1,$e2  ; D8 ╪ ┘ ┌ █ ▄ ▌ ▐ ▀
        .byte $01,$13,$47,$10,$53,$13,$15,$14  ; E0 α ß Γ π Σ σ µ τ
        .byte $4f,$4f,$4f,$04,$38,$0f,$05,$0e  ; E8 Φ Θ Ω δ ∞ φ ε ∩
        .byte $3d,$2b,$3e,$3c,$5d,$5d,$2f,$2d  ; F0 ≡ ± ≥ ≤ ⌠ ⌡ ÷ ≈
        .byte $0f,$2e,$2e,$56,$0e,$32,$a0,$20  ; F8 ° ∙ · √ ⁿ ² ■ nbsp

s_bel:  .byte 7
s_ok:   .byte $1b, "[0n"
s_da:   .byte $1b, "[?1;0c"

.segment "BSS"
ibuf:   .res BUFSZ
rbuf:   .res 10
n:      .res 1
ip:     .res 1
ppid:   .res 1
st:     .res 1          ; 0 text, 1 after ESC, 2 in ESC [, 3 drop one byte
np:     .res 1          ; index of the parameter being read
par:    .res 4
priv:   .res 1
row:    .res 1
cx:     .res 1
wrap:   .res 1          ; the last column was written: wrap before the next
awrap:  .res 1
top:    .res 1
bot:    .res 1
defcol: .res 1
curcol: .res 1
fgidx:  .res 1          ; $ff default, 0-7 normal, 8-15 bright
bold:   .res 1          ; 0 or 8
rev:    .res 1          ; 0 or $80
curvis: .res 1
cur_on: .res 1
cur_r:  .res 1
cur_c:  .res 1
cur_ch: .res 1
sv_row: .res 1
sv_cx:  .res 1
sv_col: .res 1
sv_fg:  .res 1
sv_bold: .res 1
sv_rev: .res 1
tmp:    .res 1
tmp2:   .res 1
tmp3:   .res 1
