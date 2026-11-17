; mail: personal asynchronous messages, as in early Unix
;
;   mail user   write a message to user's mailbox
;   mail        read your unread messages, one at a time
;   mail -a     read all messages, the ones already read too
;   mail -c     the login check: silent if nothing is unread, else as `mail`
;
; The mailbox is the directory /tmp/mail/<user>. Every message is a file
; named by its id (1 to 9), so nothing is lost when a new one arrives:
;
;   /tmp/mail/root/3     N Subject LF sender LF 2026-11-15 14:03 LF Text
;
; That is: the read flag (N = new, R = read) immediately followed by the
; subject, LF, the user name of the sender, LF, the date sent as text, LF,
; and the text of the message (200 characters at most). Reading a message marks it R; after it you can
; delete it or go on. A message that is not deleted stays, and `mail -a`
; shows it again. /tmp/mail and the user's directory are created when
; missing (/tmp itself exists).
;
; Writing: "Subject: " is asked for, then the text, ended by a line holding
; only "." or by CTRL-D, or when 200 characters have been typed. Input can
; come from a pipe as well:
;   echo "see you at 5" | mail root     (the first line is the subject)
;
; Ids are found by trying 1..9 (there is no directory listing call): a new
; message gets the highest id in use plus one; past 9 it takes the lowest
; free id. The date comes from SYS_CLOCK (local time) through src/lib/date.s.
;
; vibed by Lenu
;

.include "../../include/breadbin.inc"
.import print, eprint, newline, print_dec, dec_str, argn, perr, set_input, getc
.import ep2cal, dt_ep, dt_year, dt_mon, dt_day, dt_h, dt_m
.import pw_find_uid, pw_find_name, pw_name
.importzp lp1

.macro setr0 lbl
        lda #<lbl
        sta r0
        lda #>lbl
        sta r0+1
.endmacro

LMAX    = 120           ; longest input line kept in one piece
MAXID   = 9
TEXTMAX = 200           ; longest text of a message
mp      = $24           ; zero page: pointer into the message (2 bytes)

.segment "CODE"
start:
        lda #0
        sta quiet
        sta all
        sta istty
        lda argc
        cmp #2
        bcc @read           ; no argument: read our mail
        lda #1
        jsr argn
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @send
        iny
        lda (lp1),y
        ldx #0
        cmp #'c'
        beq @opt
        inx
        cmp #'a'
        bne @send
@opt:   iny
        lda (lp1),y
        bne @send           ; "-cx" is a user name
        cpx #0
        bne @all
        inc quiet           ; -c
        jmp @read
@all:   inc all             ; -a
@read:  jmp readmail
@send:  lda lp1             ; mail user
        ldx lp1+1
        jsr pw_find_name
        bcc @known
        lda #<s_nouser
        ldx #>s_nouser
        jmp fail
@known: jmp sendmail

; ---------------------------------------------------------------------
; mail user
sendmail:
        jsr mkpath          ; path = /tmp/mail/<user>/
        bcc @ok
        lda #<s_badname
        ldx #>s_badname
        jmp fail
@ok:    jsr mkfrom          ; fbuf/flen = our own user name, LF
        bcc @frok
        lda #<s_unknown
        ldx #>s_unknown
        jmp fail
@frok:  setr0 s_mdir        ; /tmp/mail, then the user's directory
        jsr SYS_MKDIR       ; (errors ignored: it may exist, and a real
        ldx plen            ; problem shows at the open below)
        dex
        lda #0
        sta path,x
        setr0 path
        jsr SYS_MKDIR
        ldx plen
        dex
        lda #'/'
        sta path,x
        jsr findid          ; newid = the id for this message
        bcc @id
        lda #<s_full
        ldx #>s_full
        jmp fail
@id:    lda #0
        jsr SYS_ISATTY
        bcs @pipe
        inc istty           ; a person is typing: prompt
@pipe:  lda #0
        jsr set_input       ; getc reads stdin
        lda istty
        beq @nop1
        lda #<s_subj
        ldx #>s_subj
        jsr print
@nop1:  jsr getline
        bcc @typed
        jmp @none           ; nothing typed: no message
@typed:
        lda newid
        jsr setid
        setr0 path
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcc @open
        jmp ioerr_path
@open:  sta fd
        lda #<s_new         ; the flag: N = unread
        sta r0
        lda #>s_new
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_WRITE
        bcc @subj
        jmp ioerr_path
@subj:  jsr wrline          ; the subject: first line
        bcc @from
        jmp ioerr_path
@from:  lda #<fbuf          ; the sender: second line
        sta r0
        lda #>fbuf
        sta r0+1
        lda flen
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_WRITE
        bcc @date
        jmp ioerr_path
@date:  jsr mkdate          ; the date sent: third line
        lda #<dbuf
        sta r0
        lda #>dbuf
        sta r0+1
        lda dlen
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_WRITE
        bcc @hint
        jmp ioerr_path
@hint:  lda istty
        beq @body
        lda #<s_hint
        ldx #>s_hint
        jsr print
@body:  jsr getline
        bcs @end            ; CTRL-D or end of the pipe
        lda llen
        cmp #2
        bne @w
        lda lbuf
        cmp #'.'
        beq @end            ; a line holding just "."
@w:     lda blen            ; keep the text within TEXTMAX
        clc
        adc llen
        bcs @cut
        cmp #TEXTMAX+1
        bcc @fits
@cut:   lda #TEXTMAX        ; only what still fits of this line
        sec
        sbc blen
        sta llen
@fits:  lda llen
        beq @fin
        jsr wrline
        bcc @a
        jmp ioerr_path
@a:     lda blen
        clc
        adc llen
        sta blen
        cmp #TEXTMAX
        bcc @body
@fin:   lda istty           ; the limit is reached: no more input
        beq @end
        lda #<s_limit
        ldx #>s_limit
        jsr print
@end:   lda fd
        jsr SYS_CLOSE
@none:  lda #0
        jmp SYS_EXIT

; mkfrom: fbuf/flen = the name of the user running mail, then LF. Must run
; after mkpath: the lookup replaces pw_name (the recipient). Carry set if
; we are not in /etc/passwd.
mkfrom: jsr SYS_GETUID
        jsr pw_find_uid
        bcc @f
        rts                 ; carry set
@f:     ldy #0
@c:     lda pw_name,y
        beq @e
        sta fbuf,y
        iny
        cpy #15
        bcc @c
@e:     lda #10
        sta fbuf,y
        iny
        sty flen
        clc
        rts

; mkdate: dbuf/dlen = "YYYY-MM-DD HH:MM", LF (local time, from SYS_CLOCK)
mkdate: setr0 dt_ep
        lda #0
        jsr SYS_CLOCK
        jsr ep2cal
        lda dt_year
        ldx dt_year+1
        jsr dec_str         ; A/X = the digits, Y = how many
        sta mp
        stx mp+1
        sty hlen
        ldx #0
        ldy #0
@y:     cpy hlen
        bcs @yd
        lda (mp),y
        sta dbuf,x
        inx
        iny
        jmp @y
@yd:    lda #'-'
        sta dbuf,x
        inx
        lda dt_mon
        jsr put2
        lda #'-'
        sta dbuf,x
        inx
        lda dt_day
        jsr put2
        lda #' '
        sta dbuf,x
        inx
        lda dt_h
        jsr put2
        lda #':'
        sta dbuf,x
        inx
        lda dt_m
        jsr put2
        lda #10
        sta dbuf,x
        inx
        stx dlen
        rts

; put2: A = 0..99 -> two digits at dbuf+X, X advanced
put2:   ldy #0
@t:     cmp #10
        bcc @u
        sbc #10             ; carry is set here
        iny
        jmp @t
@u:     pha
        tya
        ora #'0'
        sta dbuf,x
        inx
        pla
        ora #'0'
        sta dbuf,x
        inx
        rts

; getline: one input line into lbuf (llen bytes, the LF included, which is
; added when the input ends without one). Carry set at end of input.
getline:
        lda #0
        sta llen
@l:     jsr getc
        bcs @eof
        ldx llen
        sta lbuf,x
        inx
        stx llen
        cmp #10
        beq @ok
        cpx #LMAX
        bcc @l              ; a longer line goes out in pieces
@ok:    clc
        rts
@eof:   lda llen
        beq @none
        ldx llen
        lda #10
        sta lbuf,x
        inc llen
        clc
        rts
@none:  sec
        rts

; wrline: write lbuf to the open message (fd)
wrline: lda #<lbuf
        sta r0
        lda #>lbuf
        sta r0+1
        lda llen
        sta r1
        lda #0
        sta r1+1
        lda fd
        jmp SYS_WRITE

; findid: newid = highest id in use + 1, or the lowest free one when 99 is
; taken. Carry set if all 99 are in use.
findid: lda #0
        sta high
        lda #1
        sta cur
@l:     lda cur
        jsr setid
        jsr exists
        bcs @n
        lda cur
        sta high
@n:     inc cur
        lda cur
        cmp #MAXID+1
        bcc @l
        lda high
        cmp #MAXID
        bcs @wrap
        clc
        adc #1
        sta newid
        rts                 ; carry clear
@wrap:  lda #1
        sta cur
@w:     lda cur
        jsr setid
        jsr exists
        bcs @free
        inc cur
        lda cur
        cmp #MAXID+1
        bcc @w
        sec                 ; no free id
        rts
@free:  lda cur
        sta newid
        clc
        rts

; exists: carry clear if the file `path` can be opened
exists: setr0 path
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @r
        jsr SYS_CLOSE       ; A = fd
        clc
@r:     rts

; ---------------------------------------------------------------------
; mail, mail -a, mail -c
readmail:
        jsr SYS_GETUID      ; our name, as whoami finds it
        jsr pw_find_uid
        bcc @named
        lda #<s_unknown
        ldx #>s_unknown
        jmp fail
@named: jsr mkpath
        bcc @ok
        lda #<s_badname
        ldx #>s_badname
        jmp fail
@ok:    lda #0
        sta seen
        lda #1
        sta cur
@loop:  lda cur
        jsr setid
        jsr showmsg         ; shows it if it is there and unread (or -a)
        lda shown
        beq @next
        inc seen
@next:  inc cur
        lda cur
        cmp #MAXID+1
        bcc @loop
        lda seen
        bne @done
        lda quiet           ; nothing to read
        bne @done
        lda all
        bne @none
        lda #<s_nonew
        ldx #>s_nonew
        jsr print
        jmp @done
@none:  lda #<s_nomail
        ldx #>s_nomail
        jsr print
@done:  lda #0
        jmp SYS_EXIT

; showmsg: message `cur`, file `path`. If it exists and is new (or -a),
; show it, mark it read and ask what next; shown = 1. Quitting exits.
showmsg:
        lda #0
        sta shown
        setr0 path
        lda #O_RDONLY
        jsr SYS_OPEN
        bcc @open
        rts                 ; no such message
@open:  sta fd
        jsr load
        lda fd
        jsr SYS_CLOSE
        lda tot
        ora tot+1
        bne @nonempty
        jmp @ret            ; an empty file
@nonempty:
        lda mbuf
        sta flag
        cmp #'N'
        beq @disp
        lda all
        beq @ret            ; already read: skip it
@disp:  inc shown
        lda #<s_msg
        ldx #>s_msg
        jsr print
        lda cur
        ldx #0
        jsr print_dec
        jsr newline
        lda #<s_subj
        ldx #>s_subj
        jsr print
        lda #<mbuf          ; the subject follows the flag
        clc
        adc #1
        sta mp
        lda #>mbuf
        adc #0
        sta mp+1
        jsr emitline
        jsr newline
        lda #<s_from
        ldx #>s_from
        jsr print
        jsr emitline        ; the sender line
        jsr newline
        lda #<s_date
        ldx #>s_date
        jsr print
        jsr emitline        ; the date line
        lda #<s_nl2
        ldx #>s_nl2
        jsr print
        jsr emitrest        ; the text
        lda flag
        cmp #'N'
        bne @ask
        jsr markread
@ask:   jsr askkey
        cmp #'d'
        bne @q
        setr0 path
        jsr SYS_UNLINK
        bcs @ret
        lda #<s_deleted
        ldx #>s_deleted
        jsr print
        rts
@q:     cmp #'q'
        bne @ret
        lda #0
        jmp SYS_EXIT
@ret:   rts

; load: the whole file (fd) into mbuf, tot bytes, then a 0 after it. Reads
; of 255 while less than 256 are in, so mbuf (512) cannot overflow.
load:   lda #0
        sta tot
        sta tot+1
@l:     lda #<mbuf
        clc
        adc tot
        sta r0
        lda #>mbuf
        adc tot+1
        sta r0+1
        lda #255
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_READ
        bcc @got
        jmp ioerr_path
@got:   lda r1
        beq @done
        clc
        adc tot
        sta tot
        bcc @c
        inc tot+1
@c:     lda tot+1
        beq @l
@done:  lda #<mbuf
        clc
        adc tot
        sta mp
        lda #>mbuf
        adc tot+1
        sta mp+1
        ldy #0
        tya
        sta (mp),y          ; the end marker
        rts

; emitline: write the bytes at mp up to the next LF (or the end) to
; stdout, and move mp past that LF
emitline:
        ldy #0
@s:     lda (mp),y
        beq @e
        cmp #10
        beq @e
        iny
        cpy #254
        bcc @s
@e:     sty hlen
        tya
        beq @adv
        jsr emitn
@adv:   lda mp
        clc
        adc hlen
        sta mp
        bcc @n
        inc mp+1
@n:     ldy #0
        lda (mp),y
        cmp #10
        bne @r
        inc mp
        bne @r
        inc mp+1
@r:     rts

; emitrest: write everything from mp to the end marker
emitrest:
@c:     ldy #0
@s:     lda (mp),y
        beq @e
        iny
        cpy #254
        bcc @s
@e:     sty hlen
        tya
        beq @r
        jsr emitn
        lda mp
        clc
        adc hlen
        sta mp
        bcc @c
        inc mp+1
        jmp @c
@r:     rts

; emitn: write hlen bytes at mp to stdout
emitn:  lda mp
        sta r0
        lda mp+1
        sta r0+1
        lda hlen
        sta r1
        lda #0
        sta r1+1
        lda #1
        jmp SYS_WRITE

; markread: the first byte of the file becomes R
markread:
        setr0 path
        lda #O_RDWR
        jsr SYS_OPEN
        bcs @r
        sta fd2
        lda #<s_rd
        sta r0
        lda #>s_rd
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda fd2             ; the position is 0 after an open
        jsr SYS_WRITE
        lda fd2
        jsr SYS_CLOSE
@r:     rts

; askkey: prompt, read a line from the terminal; A = its first character
; in lower case, 0 if none
askkey: lda #<s_ask
        ldx #>s_ask
        jsr print
        setr0 s_tty
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @none           ; no terminal: keep the message
        sta fd2
        lda #<kbuf
        sta r0
        lda #>kbuf
        sta r0+1
        lda #8
        sta r1
        lda #0
        sta r1+1
        lda fd2
        jsr SYS_READ
        bcs @c0
        lda r1
        beq @c0
        lda kbuf
        ora #$20            ; D = d
        sta key
        jmp @c
@c0:    lda #0
        sta key
@c:     lda fd2
        jsr SYS_CLOSE
        lda key
        rts
@none:  lda #0
        rts

; ---------------------------------------------------------------------
; mkpath: path = /tmp/mail/<pw_name>/ and plen = its length. Carry set if
; the name is too long for a file name (14).
mkpath: ldx #0
@a:     lda s_dir,x
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
        sec
        rts
@d:     lda #'/'
        sta path,x
        inx
        stx plen
        lda #0
        sta path,x
        clc
        rts

; setid: A = id (1..9): path = the directory path + that digit
setid:  ldx plen
        ora #'0'
        sta path,x
        inx
        lda #0
        sta path,x
        rts

; fail: A/X = message, exit 1
fail:   jsr eprint
        lda #1
        jmp SYS_EXIT

; ioerr_path: A = errno, report it with the message path, exit 1
ioerr_path:
        ldx #<path
        ldy #>path
        jsr perr
        lda #1
        jmp SYS_EXIT

; ---------------------------------------------------------------------
.segment "RODATA"
s_dir:    .byte "/tmp/mail/", 0
s_mdir:   .byte "/tmp/mail", 0
s_tty:    .byte "/dev/tty", 0
s_new:    .byte "N"
s_rd:     .byte "R"
s_msg:    .byte "Message ", 0
s_from:   .byte "From: ", 0
s_subj:   .byte "Subject: ", 0
s_date:   .byte "Date: ", 0
s_nl2:    .byte 10, 10, 0
s_hint:   .byte "Enter msg (max 200), end: . or CTRL-D", 10, 0
s_limit:  .byte "200 chars limit reached", 10, 0
s_ask:    .byte 10, "d)el, q)uit, else next: ", 0
s_deleted: .byte "Message deleted.", 10, 0
s_nonew:  .byte "No new mail.", 10, 0
s_nomail: .byte "No mail.", 10, 0
s_nouser: .byte "mail: no such user", 10, 0
s_unknown: .byte "mail: you are not in /etc/passwd", 10, 0
s_badname: .byte "mail: bad user name", 10, 0
s_full:   .byte "mail: mailbox is full", 10, 0

.segment "BSS"
quiet:   .res 1
all:     .res 1
istty:   .res 1
fd:      .res 1
fd2:     .res 1
shown:   .res 1
seen:    .res 1
flag:    .res 1
key:     .res 1
hlen:    .res 1
blen:    .res 1
dlen:    .res 1
flen:    .res 1
tot:     .res 2
llen:    .res 1
plen:    .res 1
cur:     .res 1
high:    .res 1
newid:   .res 1
path:    .res 32
kbuf:    .res 8
lbuf:    .res LMAX + 2
dbuf:    .res 24
fbuf:    .res 16            ; sender name (15 at most) + LF
mbuf:    .res 512