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
;
; Each end reads lines from its own terminal and writes each one, prefixed
; with "name@term: ", straight to the other terminal's device
; (/dev/console or /dev/ttyS0) in a single write, so nothing has to poll
; for messages. Only setting up the chat uses files in /tmp:
;
;   /tmp/talk.N.req  request addressed to terminal N: caller's pid, uid
;   /tmp/talk.N.acc  answer to the request made BY terminal N: pid, uid
;
; Both are removed once read. A process killed with CTRL-C can't clean
; up, so each end checks the other's pid (kill with signal 0): a request
; from a dead caller is removed. During the chat, a one-page watcher
; (talkw, our own user's: only root may signal another user's process)
; ends this talk when the other end has gone, by CTRL-D or killed.
.include "../../include/breadbin.inc"
.import print, eprint, fprint, fputc, argn, perr
.import dec_str, pw_find_uid, pw_find_name, pw_name, pw_uid, newline

POLL    = 20            ; jiffies between looks while calling
RING    = 30            ; looks between two rings (10 s)
RINGS   = 6             ; rings before giving up (1 min)
LINEMAX = 80            ; a line from the terminal: 79 characters and its LF
IDMAX   = 26           ; "name@console: " (a name is at most 15 characters)

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

.segment "ZEROPAGE"
sp:     .res 2          ; mkid: the string being copied

.segment "CODE"
start:                          ; (BSS starts out zero: haswant too)
        jsr getterm
        bcc @tty
        lda #<s_notty
        ldx #>s_notty
        jmp fail
@tty:   jsr SYS_GETUID
        sta myuid
        jsr SYS_GETPID
        sta mypid
        lda argc
        cmp #3
        bcc @args
        lda #<s_usage
        ldx #>s_usage
        jmp fail
@args:  cmp #2
        bcc @go
        lda #1
        jsr argn
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
        lda other
        ora #'0'
        sta rq_ot+10
        sta ac_ot+10
        clc
@r:     rts

; mkme: obuf = our own "name@term: ". Every line sent starts with it, so
; /etc/passwd is read once, not once a line.
mkme:   lda myuid
        ldx term
        ; fall through
; mkid: A = uid, X = terminal -> obuf = "name@console: " or "name@tty: ";
; plen = its length, nlen = the name's
mkid:   stx idterm
        sta idnum
        lda #0
        sta plen
        lda idnum
        jsr pw_find_uid
        bcs @num
        lda #<pw_name
        ldx #>pw_name
        jsr app
        jmp @at
@num:   lda idnum           ; as whoami: no such name, the number
        ldx #0
        jsr dec_str
        jsr app
@at:    lda plen
        sta nlen
        lda #'@'
        jsr app1
        lda idterm
        bne @t
        lda #<s_console
        ldx #>s_console
        jmp @p
@t:     lda #<s_tty
        ldx #>s_tty
@p:     jsr app
        lda #':'
        jsr app1
        lda #' '
        ; fall through
; app1: A -> the end of obuf (keeps Y)
app1:   ldx plen
        cpx #IDMAX
        bcs @r
        sta obuf,x
        inc plen
@r:     rts
; app: the NUL-terminated string at A/X -> the end of obuf
app:    sta sp
        stx sp+1
        ldy #0
@l:     lda (sp),y
        beq @r
        jsr app1
        iny
        bne @l
@r:     rts

; ---------------------------------------------------------------------
; the caller: ask the other terminal, ring again every 10 s, give up
; after a minute
call:   jsr peer_logged     ; or "User not logged in"
        setr0 ac_me         ; an old answer must not count
        jsr SYS_UNLINK
        setr0 rq_ot
        jsr wr_pair         ; request: my pid, my uid
        jcs ioerr
        lda #<s_wait        ; "talk: waiting for name@term"
        ldx #>s_wait
        jsr print
        lda peeruid
        ldx other
        jsr mkid
        jsr id_len
        ldy #1
        jsr wr_obuf
        jsr newline
        jsr mkme
        jsr notify
        lda #RINGS
        sta rings
        lda #RING
        sta tick
@wait:  setr0 ac_me         ; answered?
        jsr rd_pair
        bcs @cross
        lda buf             ; the end that answered
        sta peerpid
        lda buf+1
        sta peeruid
        setr0 ac_me
        jsr SYS_UNLINK
        jmp chat
@cross: lda term            ; both ends called at once: the console answers
        bne @live           ; the serial line's request, the serial line
        jsr have_request    ; waits for that answer
        bcs @live
        setr0 rq_ot
        jsr SYS_UNLINK
        jmp accept
@live:  lda utpid           ; still someone there?
        jsr alive
        bcc @tick
        jsr withdraw
        jmp notlogged
@tick:  dec tick
        bne @sleep
        lda #RING
        sta tick
        dec rings
        beq @noans
        jsr notify          ; ring again
@sleep: lda #<POLL
        ldx #>POLL
        jsr SYS_SLEEP
        jmp @wait
@noans: jsr withdraw
        lda #<s_noans
        ldx #>s_noans
        jmp fail

; withdraw: remove our request
withdraw:
        setr0 rq_ot
        jmp SYS_UNLINK

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

; find_peer: a child of init named "sh", alive, that is not ours. Carry
; clear: utpid = its pid, peeruid = its uid
find_peer:
        lda #0
        sta slot
@l:     jsr pinfo
        beq @none
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

; alive: A = pid -> carry set if it has gone (another error: as if alive)
alive:  ldx #0
        jsr SYS_KILL
        bcc @r
        cmp #ESRCH
        beq @r              ; carry set: gone
        clc
@r:     rts

; notify: on the other terminal's device:
;   talk: connection requested by name@term
;   talk: answer with: talk name
notify: jsr open_peer
        bcs @r
        jsr newline_p
        lda #<s_req
        ldx #>s_req
        ldy pfd
        jsr fprint
        jsr id_len
        ldy pfd
        jsr wr_obuf
        jsr newline_p
        lda #<s_ans
        ldx #>s_ans
        ldy pfd
        jsr fprint
        lda nlen
        ldy pfd
        jsr wr_obuf
        jsr newline_p
        lda pfd
        jmp SYS_CLOSE
@r:     rts

; open_peer: the other terminal's device -> pfd (carry set: error)
open_peer:
        lda other
        bne @ser
        setr0 d_con
        jmp @op
@ser:   setr0 d_ser
@op:    lda #O_WRONLY
        jsr SYS_OPEN
        bcs @r
        sta pfd
@r:     rts

; newline_p: a newline on the other terminal
newline_p:
        lda #10
        ldy pfd
        jmp fputc

; id_len: A = the length of "name@term" in obuf (without its ": ")
id_len: lda plen
        sec
        sbc #2
        rts

; wr_obuf: the first A bytes of obuf -> fd Y
wr_obuf:
        sta r1
        lda #0
        sta r1+1
        setr0 obuf
        tya
        jmp SYS_WRITE

; ---------------------------------------------------------------------
; the invited: a request waits for us
; have_request: carry clear if a live caller's request is addressed to this
; terminal (peerpid, peeruid = the caller). A dead caller's is removed.
have_request:
        setr0 rq_me
        jsr rd_pair
        bcs @stale
        lda buf
        sta peerpid
        lda buf+1
        sta peeruid
        lda peerpid
        jsr alive
        bcc @r
@stale: setr0 rq_me         ; none, half written, or the caller gave up
        jsr SYS_UNLINK
        sec
@r:     rts

; accept: answer the request
accept: setr0 rq_me
        jsr SYS_UNLINK
        setr0 ac_ot         ; the caller is waiting for this one
        jsr wr_pair
        jcs ioerr
        jsr mkme
        ; fall through

; ---------------------------------------------------------------------
; both ends: the chat itself (obuf = our prefix). Each line typed goes,
; behind the prefix, to the other terminal in one write (the line is read
; straight in behind it in obuf). CTRL-D: we end; the other end's watcher
; sees it and ends that one.
chat:   jsr open_peer
        jcs ioerr
        lda peerpid         ; the watcher: talkw <peer pid><our pid>
        sta w_arg1
        lda mypid
        sta w_arg1+1
        setr0 p_talkw
        lda #<w_argv
        sta r1
        lda #>w_argv
        sta r1+1
        lda #0              ; our stdin, stdout; in the foreground, so
        ldx #1              ; CTRL-C ends it with us
        ldy #0
        jsr SYS_SPAWN
        jcs ioerr
        sta wpid
        lda #<s_est
        ldx #>s_est
        jsr print
@line:  lda #<obuf
        clc
        adc plen
        sta r0
        lda #>obuf
        adc #0
        sta r0+1
        lda #LINEMAX
        sta r1
        lda #0
        sta r1+1
        lda #0              ; stdin
        jsr SYS_READ
        bcs @end
        lda r1
        beq @end            ; CTRL-D
        cmp #1
        beq @line           ; an empty line is not sent
        clc
        adc plen
        sta olen
        lda peerpid
        jsr alive
        bcs @gone
        lda olen
        ldy pfd
        jsr wr_obuf
        jmp @line
@end:   lda wpid            ; our watcher: ended and waited for
        ldx #SIGTERM
        jsr SYS_KILL
@gone:  lda wpid            ; (the other end gone before the watcher saw
        ldx #0              ; it: it does in a moment, says so and ends us)
        jsr SYS_WAIT
        lda #0
        jmp SYS_EXIT

; ---------------------------------------------------------------------
; helpers
; rd_pair: r0 = path -> buf = the two bytes in it; carry set if it is
; missing or not written yet
rd_pair:
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @r
        sta fd
        jsr bufargs
        lda fd
        jsr SYS_READ
        bcc @rd
        lda #0
        sta r1
@rd:    lda r1
        sta cnt
        lda fd
        jsr SYS_CLOSE
        lda #1              ; carry set unless cnt >= 2
        cmp cnt
@r:     rts

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
        jsr bufargs
        lda fd
        jsr SYS_WRITE
        lda fd
        jsr SYS_CLOSE
        clc
@r:     rts

; bufargs: r0 = buf, r1 = 2
bufargs:
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #2
        sta r1
        lda #0
        sta r1+1
        rts

notlogged:
        lda #<s_notlog
        ldx #>s_notlog
        ; fall through
; fail: the message at A/X on stderr, exit code 1
fail:   jsr eprint
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
; the watcher's arguments: w_arg1 = the other end's pid and ours (chat)
w_arg1: .byte 0, 0, 0
w_argv: .word w_arg0, w_arg1, 0

.segment "RODATA"
p_talkw:  .byte "/bin/talkw", 0
w_arg0:   .byte "talkw", 0
d_con:    .byte "/dev/console", 0
d_ser:    .byte "/dev/ttyS0", 0
s_console: .byte "console", 0
s_tty:    .byte "tty", 0
s_req:    .byte "talk: connection requested by ", 0
s_ans:    .byte "talk: answer with: talk ", 0
s_wait:   .byte "talk: waiting for ", 0
s_est:    .byte "talk: connection established", 10, 0
s_noans:  .byte "talk: no answer", 10, 0
s_notlog: .byte "User not logged in", 10, 0
s_notty:  .byte "talk: not a terminal", 10, 0
s_usage:  .byte "usage: talk [user]", 10, 0

.segment "BSS"
term:    .res 1
other:   .res 1
myuid:   .res 1
mypid:   .res 1
peerpid: .res 1
peeruid: .res 1
utpid:   .res 1
want:    .res 1
haswant: .res 1
fd:      .res 1
pfd:     .res 1
idterm:  .res 1
idnum:   .res 1
slot:    .res 1
cur:     .res 1
hops:    .res 1
mysh:    .res 1
pi:      .res 17
cnt:     .res 1
rings:   .res 1
tick:    .res 1
plen:    .res 1
nlen:    .res 1
olen:    .res 1
wpid:    .res 1
buf:     .res 2
obuf:    .res IDMAX + LINEMAX
