; talkw: talk's watcher (talk starts it; not a command of its own)
;
;   talkw PP        P P: two bytes, the other end's pid and our talk's pid
;
; A process may only signal its own user's processes (root excepted), so
; the end that leaves a chat can't always end the other end's talk. Each
; talk runs one of these instead, as its own user: every 20 jiffies it
; checks that the other end is still there (kill with signal 0: no files,
; no disk). When it has gone, by CTRL-D or killed, this prints
; "talk: connection closed" and ends our talk. When our talk has gone
; first, this just exits. One page of memory.
.include "../../include/breadbin.inc"
.import print, argn

POLL = 20

.segment "ZEROPAGE"
ap:     .res 2

.segment "CODE"
start:  lda argc
        cmp #2
        bcc @bye
        lda #1
        jsr argn
        sta ap
        stx ap+1
        ldy #0
        lda (ap),y
        sta peer
        iny
        lda (ap),y
        sta par
@l:     lda #<POLL
        ldx #>POLL
        jsr SYS_SLEEP
        lda par             ; our talk has gone: nothing to watch for
        jsr alive
        bcs @bye
        lda peer
        jsr alive
        bcc @l
        lda #<s_closed
        ldx #>s_closed
        jsr print
        lda par
        ldx #SIGTERM
        jsr SYS_KILL
@bye:   lda #0
        jmp SYS_EXIT

; alive: A = pid -> carry set if it has gone (another error: as if alive)
alive:  ldx #0
        jsr SYS_KILL
        bcc @r
        cmp #ESRCH
        beq @r
        clc
@r:     rts

.segment "RODATA"
s_closed: .byte "talk: connection closed", 10, 0

.segment "BSS"
peer:   .res 1
par:    .res 1
