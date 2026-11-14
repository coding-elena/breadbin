; talk [user]: chat with the user on the other terminal
;
;   talk            ask the other terminal to chat, or answer its request
;   talk user       the same, but only if `user` is the one logged in there
;
; Terminal 0 is the console, terminal 1 the serial line; our own is found
; with isatty. There is at most one other session: init runs one login
; (then the shell, "sh") per terminal, so the other end is the other child
; of init named "sh" (SYS_PROCINFO). A terminal still at "login:" has no
; "sh", so it is not logged in. Names come from the uid, as whoami does.
; State is a few files in /tmp:
;
;   /tmp/talk.N.req  request addressed to terminal N: caller's pid, uid
;   /tmp/talk.N.acc  answer to the request made BY terminal N: pid, uid
;   /tmp/talk.N.msg  text sent by terminal N (append only)
;   /tmp/talk.N.ses  this session, as terminal N's reader needs it
;
; Two processes per end, both in the foreground of the terminal, so one
; CTRL-C ends both:
;   the writer (the program itself) reads lines from the keyboard and
;       appends them to its msg file;
;   the reader ("talk -r", started by the writer) polls the other
;       terminal's msg file and prints what arrives.
; A process that is killed can't clean up, so each end watches the other's
; pid (kill with signal 0) instead.
.include "../../include/breadbin.inc"
.import print, eprint, fprint, fputc, putc, argn, perr
.import dec_str, pw_find_uid, pw_find_name, pw_name, pw_uid, newline
.importzp lp1

POLL = 20               ; jiffies between looks at the files

.macro setr0 lbl
        lda #<lbl
        sta r0
        lda #>lbl
        sta r0+1
.endmacro

; jcs: branch to a label out of short-branch range
.macro jcs lbl
        .local skip
        bcc skip
        jmp lbl
skip:
.endmacro

.segment "CODE"
start:
        lda #0
        sta haswant
        jsr getterm
        bcc @tty
        lda #<s_notty
        ldx #>s_notty
        jsr eprint
        lda #1
        jmp SYS_EXIT
@tty:   jsr SYS_GETUID
        sta myuid
        jsr SYS_GETPID
        sta mypid
        lda argc
        cmp #2
        bcc @go
        lda #1
        jsr argn
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @name
        iny
        lda (lp1),y
        cmp #'r'
        bne @name
        jmp reader          ; "talk -r": the reader half of a chat
@name:  lda lp1
        ldx lp1+1
        jsr pw_find_name
        bcc @known
        jmp notlogged       ; no such user is as good as not logged in
@known: lda pw_uid
        sta want
        inc haswant
@go:    jsr have_request
        bcs @call
        jmp accept
@call:  jmp call

; getterm: stdin's terminal -> term, other; patch the digit into the paths.
; Carry set if stdin is not a terminal.
getterm:
        lda #0
        jsr SYS_ISATTY
        bcs @r
        stx term
        txa
        eor #1
        sta other
        lda term
        ora #'0'
        sta rq_me+10
        sta ac_me+10
        sta msg_me+10
        sta ses_me+10
        lda other
        ora #'0'
        sta rq_ot+10
        sta ac_ot+10
        sta msg_ot+10
        clc
@r:     rts

; ---------------------------------------------------------------------
; the caller: ask the other terminal
call:   jsr peer_logged     ; or "User not logged in"
        setr0 ac_me         ; an old answer must not count
        jsr SYS_UNLINK
        setr0 rq_ot
        jsr wr_pair         ; request: my pid, my uid
        jcs ioerr
        jsr notify
@wait:  setr0 ac_me
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @none
        sta fd
        ldx #2
        jsr rdn
        bcc @rd
        lda #0
        sta r1
@rd:    lda r1
        sta cnt
        lda fd
        jsr SYS_CLOSE
        lda cnt
        cmp #2
        bcc @sleep          ; created but not written yet: look again
        lda buf
        sta peerpid
        lda buf+1
        sta peeruid
        jmp chat
@none:  lda utpid           ; still someone there?
        ldx #0
        jsr SYS_KILL
        bcc @sleep
        cmp #ESRCH
        bne @sleep
        setr0 rq_ot
        jsr SYS_UNLINK
        jmp notlogged
@sleep: lda #<POLL
        ldx #>POLL
        jsr SYS_SLEEP
        jmp @wait

; peer_logged: the other session's shell (utpid) and user (peeruid). Ends
; the program with "User not logged in" if there is none, or it is not the
; user asked for.
peer_logged:
        jsr find_mysh
        jsr find_peer
        bcc @a
        jmp notlogged
@a:     lda haswant
        beq @ok
        lda peeruid
        cmp want
        beq @ok
        jmp notlogged
@ok:    rts

; find_mysh: walk up from our pid to the child of init (pid 1): our own
; session's shell, which the other end must not be
find_mysh:
        lda mypid
        sta cur
        lda #8
        sta hops
@next:  lda #0
        sta slot
@scan:  lda slot
        cmp #16
        bcs @fail
        setr0 pi
        lda slot
        jsr SYS_PROCINFO
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

; find_peer: a child of init named "sh", alive, that is not ours. Carry
; clear: utpid = its pid, peeruid = its uid
find_peer:
        lda #0
        sta slot
@l:     lda slot
        cmp #16
        bcs @none
        setr0 pi
        lda slot
        jsr SYS_PROCINFO
        bcs @n
        lda pi+1            ; ppid
        cmp #1
        bne @n
        lda pi+2            ; state
        cmp #3              ; a zombie
        beq @n
        lda pi
        cmp mysh
        beq @n
        lda pi+5            ; name: "sh"
        cmp #'s'
        bne @n
        lda pi+6
        cmp #'h'
        bne @n
        lda pi+7
        bne @n
        lda pi
        sta utpid
        lda pi+16
        sta peeruid
        clc
        rts
@n:     inc slot
        jmp @l
@none:  sec
        rts

; notify: write "talk: connection requested by user@term" on the other
; terminal's device (the screen or the serial line)
notify: lda other
        bne @ser
        setr0 d_con
        jmp @op
@ser:   setr0 d_ser
@op:    lda #O_WRONLY
        jsr SYS_OPEN
        bcs @r
        sta nfd
        jsr newline
        lda #<s_req
        ldx #>s_req
        ldy nfd
        jsr fprint
        lda myuid
        ldx term
        ldy nfd
        jsr fident
        lda #10
        ldy nfd
        jsr fputc
        lda nfd
        jsr SYS_CLOSE
@r:     rts

; ---------------------------------------------------------------------
; the invited: a request waits for us
; have_request: carry clear if a live caller's request is addressed to this
; terminal (peerpid, peeruid = the caller). A dead caller's is removed.
have_request:
        setr0 rq_me
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @none
        sta fd
        ldx #2
        jsr rdn
        bcc @rd
        lda #0
        sta r1
@rd:    lda r1
        sta cnt
        lda fd
        jsr SYS_CLOSE
        lda cnt
        cmp #2
        bcc @stale
        lda buf
        sta peerpid
        lda buf+1
        sta peeruid
        lda peerpid
        ldx #0
        jsr SYS_KILL
        bcc @live
        cmp #ESRCH
        bne @live
@stale: setr0 rq_me         ; the caller gave up (CTRL-C)
        jsr SYS_UNLINK
@none:  sec
        rts
@live:  clc
        rts

; accept: answer the request: fresh message files, then the answer file
accept: setr0 rq_me
        jsr SYS_UNLINK
        setr0 msg_me
        jsr trunc
        setr0 msg_ot
        jsr trunc
        setr0 ac_ot         ; the caller is waiting for this one
        jsr wr_pair
        jcs ioerr
        jmp chat

; trunc: r0 = path -> an empty file
trunc:  lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcs @r
        jmp SYS_CLOSE
@r:     rts

; ---------------------------------------------------------------------
; both ends: the chat itself
chat:   lda #<s_est
        ldx #>s_est
        jsr print
        lda peerpid         ; what the reader needs to know
        sta buf
        lda peeruid
        sta buf+1
        lda mypid
        sta buf+2
        setr0 ses_me
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        jcs ioerr
        sta fd
        ldx #3
        jsr wrn
        lda fd
        jsr SYS_CLOSE
        setr0 p_self        ; the reader: this program with -r
        lda #<rd_argv
        sta r1
        lda #>rd_argv
        sta r1+1
        lda #0              ; stdin, stdout: ours
        ldx #1
        ldy #0              ; in the foreground, so CTRL-C reaches it
        jsr SYS_SPAWN
        jcs ioerr
        sta rdpid
wloop:  lda #<line
        sta r0
        lda #>line
        sta r0+1
        lda #80
        sta r1
        lda #0
        sta r1+1
        lda #0              ; stdin
        jsr SYS_READ
        bcs wdone
        lda r1
        beq wdone           ; CTRL-D: leave
        cmp #1
        beq wloop           ; an empty line is not sent
        sta cnt
        setr0 msg_me
        lda #(O_WRONLY | O_CREAT | O_APPEND)
        jsr SYS_OPEN
        jcs ioerr
        sta fd
        lda #<line
        sta r0
        lda #>line
        sta r0+1
        lda cnt
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_WRITE
        lda fd
        jsr SYS_CLOSE
        jmp wloop
wdone:  lda rdpid
        ldx #SIGTERM
        jsr SYS_KILL
        lda rdpid
        ldx #0
        jsr SYS_WAIT
        lda #0
        jmp SYS_EXIT

; ---------------------------------------------------------------------
; the reader ("talk -r")
reader: setr0 ses_me
        lda #O_RDONLY
        jsr SYS_OPEN
        jcs ioerr
        sta fd
        ldx #3
        jsr rdn
        lda fd
        jsr SYS_CLOSE
        lda buf
        sta peerpid
        lda buf+1
        sta peeruid
        lda buf+2
        sta parpid
        setr0 msg_ot
        lda #O_RDONLY
        jsr SYS_OPEN
        jcs ioerr
        sta ifd
        lda #1
        sta atbol
poll:   lda #0
        sta dead
        lda parpid          ; the writer has gone: so do we, quietly
        ldx #0
        jsr SYS_KILL
        bcc @p2
        cmp #ESRCH
        bne @p2
        lda #0
        jmp SYS_EXIT
@p2:    lda peerpid         ; the other end has gone? (checked before
        ldx #0              ; reading: its last words still get shown)
        jsr SYS_KILL
        bcc @drain
        cmp #ESRCH
        bne @drain
        inc dead
@drain: lda #<line
        sta r0
        lda #>line
        sta r0+1
        lda #64
        sta r1
        lda #0
        sta r1+1
        lda ifd
        jsr SYS_READ
        bcs @idle
        lda r1
        beq @idle
        sta n
        lda #0
        sta idx
@pl:    ldy idx
        cpy n
        bcs @drain
        lda atbol
        beq @ch
        lda #0
        sta atbol
        jsr prefix
@ch:    ldy idx
        lda line,y
        inc idx
        cmp #10
        bne @pc
        ldx #1
        stx atbol
@pc:    jsr putc
        jmp @pl
@idle:  lda dead
        bne @gone
        lda #<POLL
        ldx #>POLL
        jsr SYS_SLEEP
        jmp poll
@gone:  lda #<s_closed
        ldx #>s_closed
        jsr print
        lda parpid          ; end the writer too
        ldx #SIGTERM
        jsr SYS_KILL
        lda #0
        jmp SYS_EXIT

; prefix: "user@term: " at the start of a received line
prefix: lda peeruid
        ldx other
        ldy #1
        jsr fident
        lda #':'
        jsr putc
        lda #' '
        jmp putc

; ---------------------------------------------------------------------
; helpers
; fident: A = uid, X = terminal, Y = fd: write "name@console" / "name@tty"
fident: sty idfd
        stx idterm
        sta idnum
        jsr pw_find_uid
        bcs @num
        lda #<pw_name
        ldx #>pw_name
        ldy idfd
        jsr fprint
        jmp @at
@num:   lda idnum           ; as whoami: no such name, print the number
        ldx #0
        jsr dec_str
        ldy idfd
        jsr fprint
@at:    lda #'@'
        ldy idfd
        jsr fputc
        lda idterm
        bne @tty
        lda #<s_console
        ldx #>s_console
        jmp @p
@tty:   lda #<s_tty
        ldx #>s_tty
@p:     ldy idfd
        jmp fprint

; rdn / wrn: A = fd, X = count, data in buf (r1 = count done)
rdn:    pha
        jsr bufargs
        pla
        jmp SYS_READ
wrn:    pha
        jsr bufargs
        pla
        jmp SYS_WRITE
bufargs:
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        stx r1
        lda #0
        sta r1+1
        rts

; wr_pair: r0 = path -> that file holds mypid, myuid
wr_pair:
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcs @r
        sta fd
        lda mypid
        sta buf
        lda myuid
        sta buf+1
        lda fd
        ldx #2
        jsr wrn
        lda fd
        jsr SYS_CLOSE
        clc
@r:     rts

notlogged:
        lda #<s_notlog
        ldx #>s_notlog
        jsr eprint
        lda #1
        jmp SYS_EXIT

ioerr:  ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT

; ---------------------------------------------------------------------
.segment "DATA"
; the digit after "talk." (index 10) is patched in by getterm:
; _me paths carry this terminal's number, _ot paths the other's
rq_me:  .byte "/tmp/talk.0.req", 0
rq_ot:  .byte "/tmp/talk.0.req", 0
ac_me:  .byte "/tmp/talk.0.acc", 0
ac_ot:  .byte "/tmp/talk.0.acc", 0
msg_me: .byte "/tmp/talk.0.msg", 0
msg_ot: .byte "/tmp/talk.0.msg", 0
ses_me: .byte "/tmp/talk.0.ses", 0

.segment "RODATA"
d_con:    .byte "/dev/console", 0
d_ser:    .byte "/dev/ttyS0", 0
p_self:   .byte "/bin/talk", 0
rd_arg0:  .byte "talk", 0
rd_arg1:  .byte "-r", 0
rd_argv:  .word rd_arg0, rd_arg1, 0
s_console: .byte "console", 0
s_tty:    .byte "tty", 0
s_req:    .byte "talk: connection requested by ", 0
s_est:    .byte "talk: connection established", 10, 0
s_closed: .byte "talk: connection closed", 10, 0
s_notlog: .byte "User not logged in", 10, 0
s_notty:  .byte "talk: not a terminal", 10, 0

.segment "BSS"
term:    .res 1
other:   .res 1
myuid:   .res 1
mypid:   .res 1
peerpid: .res 1
peeruid: .res 1
parpid:  .res 1
utpid:   .res 1
want:    .res 1
haswant: .res 1
fd:      .res 1
nfd:     .res 1
ifd:     .res 1
idfd:    .res 1
idterm:  .res 1
idnum:   .res 1
slot:    .res 1
cur:     .res 1
hops:    .res 1
mysh:    .res 1
pi:      .res 17
cnt:     .res 1
rdpid:   .res 1
dead:    .res 1
atbol:   .res 1
n:       .res 1
idx:     .res 1
buf:     .res 4
line:    .res 84