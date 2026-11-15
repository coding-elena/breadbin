; ============================================================================
; chess.s - Single-File 0x88 Chess for Breadbin Unix (ca65 / cx.py)
; Step 3: make_move / unmake_move + is_in_check + 1-ply AI opponent
; ============================================================================

.include "../../include/breadbin.inc"
.import print, putc

.setcpu "6502"
.export _start

; ----------------------------------------------------------------------------
; Zero Page Scratch ($23-$2F = 13 bytes free for user code)
; ----------------------------------------------------------------------------
zp_from     = $23   ; 1 byte : 0x88 source square
zp_to       = $24   ; 1 byte : 0x88 destination square
zp_turn     = $25   ; 1 byte : $00 = White, $80 = Black
zp_piece    = $26   ; 1 byte : moving piece code
zp_target   = $27   ; 1 byte : destination square content
zp_sq       = $28   ; 1 byte : current scan square
zp_delta    = $29   ; 1 byte : ray / step offset
zp_idx      = $2A   ; 1 byte : loop index
zp_cnt      = $2B   ; 1 byte : remaining direction count
zp_row      = $2C   ; 1 byte : board row counter
zp_fd       = $2D   ; 1 byte : file descriptor for /tmp save/load
zp_ptr      = $2E   ; 2 bytes: indirect jump / table pointer

; ----------------------------------------------------------------------------
; Piece Encoding (Bit 7 = Color: 0=White, 1=Black | Bits 0..2 = Piece Type)
; ----------------------------------------------------------------------------
EMPTY       = $00
PAWN        = $01
KNIGHT      = $02
BISHOP      = $03
ROOK        = $04
QUEEN       = $05
KING        = $06
BLACK       = $80
TYPE_MASK   = $07
MAX_UNDO    = 8

; ============================================================================
; CODE SEGMENT
; ============================================================================
.segment "CODE"

_start:
    jsr init_board
    lda #$00
    sta zp_turn
    sta undo_sp

game_loop:
    jsr render_board
    jsr is_in_check
    bcc @no_chk
    lda #<msg_check
    ldx #>msg_check
    jsr print
@no_chk:
    jsr print_prompt
    jsr read_line           ; returns length in A (0 if empty)
    beq game_loop

    lda in_buf
    cmp #'q'
    beq @do_quit
    cmp #'s'
    beq @do_save
    cmp #'l'
    beq @do_load
    cmp #'a'
    beq @do_ai
    jmp do_move

@do_quit:
    jmp cmd_quit
@do_save:
    jmp cmd_save
@do_load:
    jmp cmd_load
@do_ai:
    jmp cmd_ai

do_move:
    jsr parse_move          ; C=0 valid syntax, C=1 error
    bcs err_syn

    jsr try_move            ; C=0 legal & applied, C=1 illegal
    bcs err_ill

    lda zp_turn
    eor #BLACK
    sta zp_turn
    jmp game_loop

cmd_ai:
    jsr ai_move
    bcs ai_no_moves
    lda zp_turn
    eor #BLACK
    sta zp_turn
    jmp game_loop

ai_no_moves:
    jsr is_in_check
    bcs @mate
    lda #<msg_stale
    ldx #>msg_stale
    jsr print
    jmp game_loop
@mate:
    lda #<msg_mate
    ldx #>msg_mate
    jsr print
    jmp game_loop

err_syn:
    lda #<msg_bad_syn
    ldx #>msg_bad_syn
    jsr print
    jmp game_loop

err_ill:
    lda #<msg_illegal
    ldx #>msg_illegal
    jsr print
    jmp game_loop

cmd_save:
    jsr save_tmp
    bcs io_err
    lda #<msg_saved
    ldx #>msg_saved
    jsr print
    jmp game_loop

cmd_load:
    jsr load_tmp
    bcs io_err
    lda #<msg_loaded
    ldx #>msg_loaded
    jsr print
    jmp game_loop

io_err:
    lda #<msg_io_err
    ldx #>msg_io_err
    jsr print
    jmp game_loop

cmd_quit:
    lda #0
    jmp SYS_EXIT

; ----------------------------------------------------------------------------
; init_board: Set up standard chess starting position on 0x88 array
; ----------------------------------------------------------------------------
init_board:
    ldx #$00
    lda #EMPTY
@clr:
    sta board,x
    inx
    cpx #128
    bne @clr

    ldx #$00
@setup:
    lda back_rank,x
    ora #BLACK
    sta board+$00,x
    lda #(BLACK | PAWN)
    sta board+$10,x

    lda #PAWN
    sta board+$60,x
    lda back_rank,x
    sta board+$70,x

    inx
    cpx #$08
    bne @setup
    rts

; ----------------------------------------------------------------------------
; render_board: Print 8x8 ASCII board with rank/file labels
; ----------------------------------------------------------------------------
render_board:
    lda #<msg_header
    ldx #>msg_header
    jsr print

    lda #$00
    sta zp_row

@row_loop:
    lda #'8'
    sec
    sbc zp_row
    jsr putc
    lda #' '
    jsr putc

    lda zp_row
    asl a
    asl a
    asl a
    asl a
    sta zp_sq
    lda #$08
    sta zp_cnt

@col_loop:
    ldx zp_sq
    lda board,x
    jsr piece_to_ascii
    jsr putc
    lda #' '
    jsr putc
    inc zp_sq
    dec zp_cnt
    bne @col_loop

    lda #10
    jsr putc

    inc zp_row
    lda zp_row
    cmp #$08
    bne @row_loop

    lda #<msg_footer
    ldx #>msg_footer
    jsr print
    rts

piece_to_ascii:
    cmp #EMPTY
    bne @not_empty
    lda #'.'
    rts
@not_empty:
    sta zp_idx
    and #TYPE_MASK
    tax
    lda piece_chars,x
    bit zp_idx
    bpl @done
    ora #$20
@done:
    rts

; ----------------------------------------------------------------------------
; parse_move: Convert "e2e4" in in_buf to 0x88 zp_from and zp_to
; ----------------------------------------------------------------------------
parse_move:
    lda in_buf+0
    ldx in_buf+1
    jsr parse_sq
    bcs @fail
    sta zp_from

    lda in_buf+2
    ldx in_buf+3
    jsr parse_sq
    bcs @fail
    sta zp_to

    lda in_buf+4
    beq @ok
    cmp #10
    beq @ok
    cmp #13
    beq @ok
@fail:
    sec
    rts
@ok:
    clc
    rts

parse_sq:
    sec
    sbc #'a'
    cmp #$08
    bcs @bad
    sta zp_idx

    txa
    sec
    sbc #'1'
    cmp #$08
    bcs @bad
    eor #$07
    asl a
    asl a
    asl a
    asl a
    ora zp_idx
    clc
    rts
@bad:
    sec
    rts

; ----------------------------------------------------------------------------
; make_move / unmake_move: In-place board mutation with BSS undo stack
; ----------------------------------------------------------------------------
make_move:
    ldx undo_sp
    cpx #MAX_UNDO
    bcs @full

    ldy zp_from
    lda board,y
    sta zp_piece
    sta undo_piece,x

    ldy zp_to
    lda board,y
    sta zp_target
    sta undo_cap,x

    lda zp_from
    sta undo_from,x
    lda zp_to
    sta undo_to,x

    inx
    stx undo_sp

    lda zp_piece
    and #TYPE_MASK
    cmp #PAWN
    bne @store

    lda zp_to
    and #$F0
    beq @promote
    cmp #$70
    bne @store
@promote:
    lda zp_piece
    and #BLACK
    ora #QUEEN
    sta zp_piece

@store:
    ldx zp_to
    lda zp_piece
    sta board,x
    ldx zp_from
    lda #EMPTY
    sta board,x
    clc
    rts

@full:
    sec
    rts

unmake_move:
    ldx undo_sp
    beq @empty
    dex
    stx undo_sp

    lda undo_from,x
    sta zp_from
    lda undo_to,x
    sta zp_to
    lda undo_piece,x
    sta zp_piece
    lda undo_cap,x
    sta zp_target

    ldy zp_from
    lda zp_piece
    sta board,y
    ldy zp_to
    lda zp_target
    sta board,y
    clc
    rts

@empty:
    sec
    rts

; ----------------------------------------------------------------------------
; find_king / is_sq_attacked / is_in_check
; ----------------------------------------------------------------------------
find_king:
    ora #KING
    sta zp_target
    ldx #$00
@scan:
    txa
    and #$88
    bne @next
    lda board,x
    cmp zp_target
    beq @found
@next:
    inx
    cpx #128
    bne @scan
    sec
    rts
@found:
    txa
    clc
    rts

is_sq_attacked:
    sta zp_sq
    lda zp_turn
    eor #BLACK
    sta zp_delta

    lda zp_delta
    bne @enemy_black

    lda zp_sq
    clc
    adc #$0F
    jsr check_enemy_pawn
    bcs @hit_jmp
    lda zp_sq
    clc
    adc #$11
    jsr check_enemy_pawn
    bcs @hit_jmp
    jmp @check_knights

@hit_jmp:
    jmp is_sq_attacked_hit

@enemy_black:
    lda zp_sq
    sec
    sbc #$11
    jsr check_enemy_pawn
    bcs @hit_jmp
    lda zp_sq
    sec
    sbc #$0F
    jsr check_enemy_pawn
    bcs @hit_jmp

@check_knights:
    ldx #$00
    lda #$08
    sta zp_cnt
@k_loop:
    jsr check_enemy_knight
    bcs @hit_jmp
    inx
    dec zp_cnt
    bne @k_loop

    ldx #$08
    lda #$08
    sta zp_cnt
@kg_loop:
    jsr check_enemy_king
    bcs @hit_jmp
    inx
    dec zp_cnt
    bne @kg_loop

    ldx #$08
    lda #$08
    sta zp_cnt
@ray_dir:
    lda step_deltas,x
    sta zp_idx
    lda zp_sq
    sta zp_target

@ray_step:
    lda zp_target
    clc
    adc zp_idx
    sta zp_target
    and #$88
    bne @next_ray

    ldy zp_target
    lda board,y
    beq @ray_step

    sta zp_piece
    and #BLACK
    cmp zp_delta
    bne @next_ray

    lda zp_piece
    and #TYPE_MASK
    cmp #QUEEN
    beq @hit_jmp

    cpx #$0C
    bcs @orth
    cmp #BISHOP
    beq @hit_jmp
    bne @next_ray
@orth:
    cmp #ROOK
    beq @hit_jmp

@next_ray:
    inx
    dec zp_cnt
    bne @ray_dir

    clc
    rts

is_sq_attacked_hit:
    sec
    rts

check_enemy_pawn:
    sta zp_from
    and #$88
    bne @no
    ldy zp_from
    lda board,y
    sta zp_piece
    and #BLACK
    cmp zp_delta
    bne @no
    lda zp_piece
    and #TYPE_MASK
    cmp #PAWN
    beq @yes
@no:
    clc
    rts
@yes:
    sec
    rts

check_enemy_knight:
    lda #KNIGHT
    jmp check_enemy_fixed

check_enemy_king:
    lda #KING
check_enemy_fixed:
    sta zp_row
    txa
    pha
    lda zp_sq
    clc
    adc step_deltas,x
    sta zp_from
    and #$88
    bne @no
    ldy zp_from
    lda board,y
    sta zp_piece
    and #BLACK
    cmp zp_delta
    bne @no
    lda zp_piece
    and #TYPE_MASK
    cmp zp_row
    beq @yes
@no:
    pla
    tax
    clc
    rts
@yes:
    pla
    tax
    sec
    rts

is_in_check:
    lda zp_turn
    jsr find_king
    bcs @safe
    jmp is_sq_attacked
@safe:
    clc
    rts

; ----------------------------------------------------------------------------
; try_move: Validate pseudo-legal move, make_move, reject if self-check
; ----------------------------------------------------------------------------
try_move:
    lda zp_from
    and #$88
    bne @fail_jmp
    lda zp_to
    and #$88
    bne @fail_jmp

    lda zp_from
    cmp zp_to
    beq @fail_jmp

    ldx zp_from
    lda board,x
    beq @fail_jmp
    sta zp_piece
    and #BLACK
    cmp zp_turn
    bne @fail_jmp

    ldx zp_to
    lda board,x
    sta zp_target
    beq @dispatch
    and #BLACK
    cmp zp_turn
    beq @fail_jmp

@dispatch:
    lda zp_piece
    and #TYPE_MASK
    beq @fail_jmp
    cmp #(KING + 1)
    bcs @fail_jmp
    sec
    sbc #1
    tax
    lda val_lo,x
    sta zp_ptr
    lda val_hi,x
    sta zp_ptr+1
    jsr call_zp_ptr
    bcs @fail_jmp

    jsr make_move
    bcs @fail_jmp

    jsr is_in_check
    bcs @undo_fail
    clc
    rts

@fail_jmp:
    jmp try_move_fail

@undo_fail:
    jsr unmake_move
try_move_fail:
    sec
    rts

call_zp_ptr:
    jmp (zp_ptr)

validate_pawn:
    lda zp_turn
    bne @black_pawn

    lda zp_from
    sec
    sbc #$10
    cmp zp_to
    bne @w_double
    lda zp_target
    bne @bad
    clc
    rts

@w_double:
    lda zp_from
    and #$F0
    cmp #$60
    bne @w_cap
    lda zp_from
    sec
    sbc #$10
    tax
    lda board,x
    bne @bad
    lda zp_from
    sec
    sbc #$20
    cmp zp_to
    bne @w_cap
    lda zp_target
    bne @bad
    clc
    rts

@w_cap:
    lda zp_target
    beq @bad
    lda zp_from
    sec
    sbc #$11
    cmp zp_to
    beq @w_ok
    lda zp_from
    sec
    sbc #$0F
    cmp zp_to
    beq @w_ok
@bad:
    sec
    rts
@w_ok:
    clc
    rts

@black_pawn:
    lda zp_from
    clc
    adc #$10
    cmp zp_to
    bne @b_double
    lda zp_target
    bne @bad
    clc
    rts

@b_double:
    lda zp_from
    and #$F0
    cmp #$10
    bne @b_cap
    lda zp_from
    clc
    adc #$10
    tax
    lda board,x
    bne @bad
    lda zp_from
    clc
    adc #$20
    cmp zp_to
    bne @b_cap
    lda zp_target
    bne @bad
    clc
    rts

@b_cap:
    lda zp_target
    beq @bad
    lda zp_from
    clc
    adc #$0F
    cmp zp_to
    beq @b_ok
    lda zp_from
    clc
    adc #$11
    cmp zp_to
    beq @b_ok
    sec
    rts
@b_ok:
    clc
    rts

validate_knight:
    ldx #$00
    lda #$08
    sta zp_cnt
    jmp check_steps

validate_king:
    ldx #$08
    lda #$08
    sta zp_cnt

check_steps:
    lda zp_from
    clc
    adc step_deltas,x
    cmp zp_to
    beq @ok
    inx
    dec zp_cnt
    bne check_steps
    sec
    rts
@ok:
    clc
    rts

validate_bishop:
    ldx #$08
    lda #$04
    sta zp_cnt
    jmp check_rays

validate_rook:
    ldx #$0C
    lda #$04
    sta zp_cnt
    jmp check_rays

validate_queen:
    ldx #$08
    lda #$08
    sta zp_cnt

check_rays:
    lda step_deltas,x
    sta zp_delta
    lda zp_from
    sta zp_sq

@ray_step:
    lda zp_sq
    clc
    adc zp_delta
    sta zp_sq
    and #$88
    bne @next_dir

    lda zp_sq
    cmp zp_to
    beq @ok

    ldy zp_sq
    lda board,y
    bne @next_dir
    jmp @ray_step

@next_dir:
    inx
    dec zp_cnt
    bne check_rays
    sec
    rts
@ok:
    clc
    rts

; ----------------------------------------------------------------------------
; eval_board: 16-bit signed board evaluation from zp_turn perspective
; ----------------------------------------------------------------------------
eval_board:
    lda #0
    sta score_lo
    sta score_hi

    ldx #0
@loop:
    txa
    and #$88
    bne @next

    lda board,x
    beq @next
    sta zp_piece
    and #TYPE_MASK
    tay

    lda piece_val_lo,y
    sta zp_delta
    lda piece_val_hi,y
    sta zp_cnt

    txa
    and #$07
    cmp #3
    beq @center
    cmp #4
    bne @no_center
@center:
    lda zp_delta
    clc
    adc #10
    sta zp_delta
    bcc @no_center
    inc zp_cnt
@no_center:
    lda zp_piece
    and #BLACK
    cmp zp_turn
    beq @add_side

    sec
    lda score_lo
    sbc zp_delta
    sta score_lo
    lda score_hi
    sbc zp_cnt
    sta score_hi
    jmp @next

@add_side:
    clc
    lda score_lo
    adc zp_delta
    sta score_lo
    lda score_hi
    adc zp_cnt
    sta score_hi

@next:
    inx
    cpx #128
    bne @loop
    rts

; ----------------------------------------------------------------------------
; ai_move: Lightweight 1-ply search over 0x88 moves for active zp_turn
; ----------------------------------------------------------------------------
ai_move:
    lda #0
    sta has_move
    sta best_lo
    lda #$80
    sta best_hi             ; -32768

    lda #0
    sta ai_from

@from_loop:
    lda ai_from
    and #$88
    bne @skip_from

    ldx ai_from
    lda board,x
    beq @skip_from
    and #BLACK
    cmp zp_turn
    bne @skip_from

    lda #0
    sta ai_to

@to_loop:
    lda ai_to
    and #$88
    bne @skip_to

    lda ai_from
    sta zp_from
    lda ai_to
    sta zp_to

    jsr try_move
    bcs @skip_to

    jsr eval_board
    jsr unmake_move

    jsr is_score_better
    bcc @skip_to

    lda #1
    sta has_move
    lda score_lo
    sta best_lo
    lda score_hi
    sta best_hi
    lda ai_from
    sta best_from
    lda ai_to
    sta best_to

@skip_to:
    inc ai_to
    lda ai_to
    cmp #128
    bne @to_loop

@skip_from:
    inc ai_from
    lda ai_from
    cmp #128
    bne @from_loop

    lda has_move
    beq @no_legal

    lda best_from
    sta zp_from
    lda best_to
    sta zp_to
    jsr try_move
    clc
    rts

@no_legal:
    sec
    rts

is_score_better:
    lda has_move
    beq @better

    sec
    lda score_lo
    sbc best_lo
    sta zp_idx
    lda score_hi
    sbc best_hi
    bvc @no_ovf
    eor #$80
@no_ovf:
    bmi @worse
    bne @better
    lda zp_idx
    bne @better
@worse:
    clc
    rts
@better:
    sec
    rts

; ----------------------------------------------------------------------------
; Console & /tmp (REU RAM disk) Syscall Helpers
; ----------------------------------------------------------------------------
print_prompt:
    lda zp_turn
    bne @b
    lda #<msg_w_prompt
    ldx #>msg_w_prompt
    jmp print
@b:
    lda #<msg_b_prompt
    ldx #>msg_b_prompt
    jmp print

read_line:
    lda #<in_buf
    sta r0
    lda #>in_buf
    sta r0+1
    lda #15
    sta r1
    lda #0
    sta r1+1
    lda #0                  ; fd 0 = stdin
    jsr SYS_READ
    bcs @empty
    lda r1                  ; r1 = byte count read
    beq @empty
    tax
    lda #0
    sta in_buf,x
    txa
    rts
@empty:
    lda #0
    sta in_buf
    rts

save_tmp:
    lda zp_turn
    sta save_turn

    lda #<tmp_path
    sta r0
    lda #>tmp_path
    sta r0+1
    lda #(O_WRONLY | O_CREAT | O_TRUNC)
    jsr SYS_OPEN
    bcs @err
    sta zp_fd

    lda #<board
    sta r0
    lda #>board
    sta r0+1
    lda #129
    sta r1
    lda #0
    sta r1+1
    lda zp_fd
    jsr SYS_WRITE
    bcs @close_err

    lda zp_fd
    jsr SYS_CLOSE
    clc
    rts

@close_err:
    lda zp_fd
    jsr SYS_CLOSE
@err:
    sec
    rts

load_tmp:
    lda #<tmp_path
    sta r0
    lda #>tmp_path
    sta r0+1
    lda #O_RDONLY
    jsr SYS_OPEN
    bcs @err
    sta zp_fd

    lda #<board
    sta r0
    lda #>board
    sta r0+1
    lda #129
    sta r1
    lda #0
    sta r1+1
    lda zp_fd
    jsr SYS_READ
    bcs @close_err

    lda zp_fd
    jsr SYS_CLOSE
    lda save_turn
    sta zp_turn
    clc
    rts

@close_err:
    lda zp_fd
    jsr SYS_CLOSE
@err:
    sec
    rts

; ============================================================================
; READ-ONLY DATA
; ============================================================================
.segment "RODATA"

val_lo:
    .lobytes validate_pawn, validate_knight, validate_bishop
    .lobytes validate_rook, validate_queen, validate_king
val_hi:
    .hibytes validate_pawn, validate_knight, validate_bishop
    .hibytes validate_rook, validate_queen, validate_king

piece_val_lo:
    .byte 0, <100, <320, <330, <500, <900, 0
piece_val_hi:
    .byte 0, >100, >320, >330, >500, >900, 0

back_rank:
    .byte ROOK, KNIGHT, BISHOP, QUEEN, KING, BISHOP, KNIGHT, ROOK

piece_chars:
    .byte '.', 'P', 'N', 'B', 'R', 'Q', 'K'

step_deltas:
    .byte $DF, $E1, $EE, $F2, $0E, $12, $1F, $21
    .byte $EF, $F1, $0F, $11
    .byte $F0, $10, $FF, $01

tmp_path:
    .byte "/tmp/chess.sav", 0

msg_header:
    .byte 10 ;, "  a b c d e f g h", 10, 0 -- keep printing msg_footer after NL
msg_footer:
    .byte "  a b c d e f g h", 10, 0
msg_check:
    .byte "check!", 10, 0
msg_mate:
    .byte "checkmate!", 10, 0
msg_stale:
    .byte "stalemate!", 10, 0
msg_w_prompt:
    .byte "white (e2e4/a/s/l/q)> ", 0
msg_b_prompt:
    .byte "black (e7e5/a/s/l/q)> ", 0
msg_bad_syn:
    .byte "err: use e2e4, a, s, l, q", 10, 0
msg_illegal:
    .byte "err: illegal move", 10, 0
msg_saved:
    .byte "saved /tmp/chess.sav", 10, 0
msg_loaded:
    .byte "loaded /tmp/chess.sav", 10, 0
msg_io_err:
    .byte "err: /tmp i/o", 10, 0

; ============================================================================
; BSS SEGMENT (Zero-initialized RAM: ~198 bytes)
; ============================================================================
.segment "BSS"

board:      .res 128
save_turn:  .res 1
in_buf:     .res 16
undo_sp:    .res 1
undo_from:  .res MAX_UNDO
undo_to:    .res MAX_UNDO
undo_piece: .res MAX_UNDO
undo_cap:   .res MAX_UNDO

ai_from:    .res 1
ai_to:      .res 1
best_from:  .res 1
best_to:    .res 1
has_move:   .res 1
score_lo:   .res 1
score_hi:   .res 1
best_lo:    .res 1
best_hi:    .res 1