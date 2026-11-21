; mailc: the login check, a small `mail -c`
;
; Prints "You have mail." if /tmp/mail/<user>/1 .. 9 holds an unread
; message (its first byte is N), else nothing. Exit code 0 either way.
; See mail.s for the mailbox format.

.include "../../include/breadbin.inc"
.import print, pw_find_uid, pw_name

.segment "CODE"
start:  jsr SYS_GETUID
        jsr pw_find_uid
        bcs done            ; not in /etc/passwd: silent
        ldx #0
@a:     lda s_dir,x         ; path = /tmp/mail/<user>/
        beq @n
        sta path,x
        inx
        bne @a
@n:     ldy #0
@b:     lda pw_name,y
        beq @d
        sta path,x
        inx
        iny
        cpy #15
        bcc @b
@d:     lda #'/'
        sta path,x
        inx
        lda #0
        sta path+1,x        ; the id digit goes at path,x
        stx plen
        lda #'1'
        sta cur
@l:     ldx plen
        lda cur
        sta path,x
        lda #<path
        sta r0
        lda #>path
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @next           ; no such message
        sta fd
        lda #0
        sta buf             ; stays 0 if the read fails
        sta r1+1
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #1
        sta r1
        lda fd
        jsr SYS_READ        ; the flag byte
        lda fd
        jsr SYS_CLOSE
        lda buf
        cmp #'N'
        beq found
@next:  inc cur
        lda cur
        cmp #'9'+1
        bcc @l
done:   lda #0
        jmp SYS_EXIT
found:  lda #<s_mail
        ldx #>s_mail
        jsr print
        jmp done

.segment "RODATA"
s_dir:  .byte "/tmp/mail/", 0
s_mail: .byte "You have mail.", 10, 0

.segment "BSS"
plen:   .res 1
cur:    .res 1
fd:     .res 1
buf:    .res 1
path:   .res 32