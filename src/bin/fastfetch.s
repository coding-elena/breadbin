; fastfetch: two-column dynamic system info for c64 breadbin
.include "../../include/breadbin.inc"
.import print, newline, print_dec, print_dec_w, pw_find_uid, pw_name
.importzp lp1

; tty_on lives in the kernel's LOWDATA ($02A7, first variable of tty.s):
; bit 7 set = a 6551 ACIA (SwiftLink / Turbo232) was found at boot.
; Check the link map if LOWDATA ever gets another variable before it.
TTY_ON = $02A7

; C128 MMU version register: reads $20 on a C128, anything else on a C64
C128_ID = $d50b

.segment "CODE"
start:
        ; --- Machine: C128 or C64 ---
        lda C128_ID
        ldx #0
        cmp #$20
        bne @not128
        inx
@not128:
        stx is128

        ; 1. Pre-gather dynamic system data into variables/buffers

        ; --- UID & Username ---
        jsr SYS_GETUID
        sta uid
        jsr pw_find_uid
        lda #0                  ; carry is clobbered by the time we print,
        rol a                   ; so remember it: 1 = no passwd entry
        sta nouser

        ; --- Uptime ---
        jsr SYS_TIME            ; A/X/Y = jiffies
        sta t
        stx t+1
        sty t+2
        lda #60
        jsr div24
        lda #60
        jsr div24
        lda rem
        sta secs
        lda #60
        jsr div24
        lda rem
        sta mins
        lda t
        ldx t+1
        sta hours
        stx hours+1

        ; --- Memory Info ---
        lda #<meminfo_buf
        sta r0
        lda #>meminfo_buf
        sta r0+1
        jsr SYS_MEMINFO

        ; --- Theme ---
        lda #<s_theme_default
        ldx #>s_theme_default
        jsr copy_theme
        lda #<p_theme
        sta r0
        lda #>p_theme
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @theme_default
        sta theme_fd
        lda #<theme_name
        sta r0
        lda #>theme_name
        sta r0+1
        lda #15
        sta r1
        lda #0
        sta r1+1
        lda theme_fd
        jsr SYS_READ
        bcs @theme_close
        ldx r1
        bne @theme_read
        lda #<s_theme_default
        ldx #>s_theme_default
        jsr copy_theme
        jmp @theme_close
@theme_read:
        lda #0
        sta theme_name,x
        dex
        bmi @theme_close
        lda theme_name,x
        cmp #10
        beq @theme_trim
        cmp #13
        bne @theme_close
@theme_trim:
        lda #0
        sta theme_name,x
@theme_close:
        lda theme_fd
        jsr SYS_CLOSE
        jmp @theme_done
@theme_default:
        lda #<s_theme_default
        ldx #>s_theme_default
        jsr copy_theme
@theme_done:

        ; 2. Print row by row: logo slice + one info handler.
        ; row_idx is the only loop state (print/handlers clobber A/X/Y);
        ; it steps by 2 and indexes both row_ptrs and handlers (.word tables).
        lda #0
        sta row_idx
@row_loop:
        ldy row_idx
        lda row_ptrs,y
        ora row_ptrs+1,y
        beq @done               ; NULL pointer = end of list

        lda row_ptrs+1,y        ; left column (logo slice)
        tax
        lda row_ptrs,y
        jsr print

        lda #' '                ; gap between logo and text
        jsr SYS_PUTC

        ldy row_idx             ; right column
        lda handlers,y
        sta hptr
        lda handlers+1,y
        sta hptr+1
        jsr call_handler

        jsr newline

        inc row_idx
        inc row_idx
        jmp @row_loop

@done:
        lda #0
        jmp SYS_EXIT

call_handler:
        jmp (hptr)

; Subroutines for right-side metrics
print_username:
        lda nouser
        bne @def_user
        lda #<pw_name
        ldx #>pw_name
        jsr print
        jmp @print_at
@def_user:
        lda uid
        ldx #0
        jsr print_dec
@print_at:
        lda #<s_at_host
        ldx #>s_at_host
        jmp print

print_os:
        lda #<s_os
        ldx #>s_os
        jmp print

print_kernel:
        lda #<s_kernel
        ldx #>s_kernel
        jmp print

print_uptime_str:
        lda #<s_up_prefix
        ldx #>s_up_prefix
        jsr print
        lda hours
        ldx hours+1
        jsr print_dec
        lda #<s_hours_mins
        ldx #>s_hours_mins
        jsr print
        lda mins
        jsr two_digits
        lda #<s_mins_suffix
        ldx #>s_mins_suffix
        jmp print

print_shell:
        lda #<s_shell
        ldx #>s_shell
        jmp print

print_res:
        lda #<s_res
        ldx #>s_res
        jmp print

print_theme:
        lda #<s_theme
        ldx #>s_theme
        jsr print
        lda #<theme_name
        ldx #>theme_name
        jmp print

print_cpu:
        lda is128
        bne @c128
        lda #<s_cpu
        ldx #>s_cpu
        jmp print
@c128:  lda #<s_cpu128
        ldx #>s_cpu128
        jmp print

print_serial:
        bit TTY_ON
        bpl @off
        lda #<s_ser_on
        ldx #>s_ser_on
        jmp print
@off:   lda #<s_ser_off
        ldx #>s_ser_off
        jmp print

print_mem_str:
        lda #<s_mem_prefix
        ldx #>s_mem_prefix
        jsr print
        lda meminfo_buf+1
        sec
        sbc meminfo_buf
        jsr kb_print
        lda #<s_slash
        ldx #>s_slash
        jsr print
        lda meminfo_buf+1
        jsr kb_print
        lda #<s_kb
        ldx #>s_kb
        jmp print

print_reu_str:
        lda meminfo_buf+2
        beq @no_reu
        lda #<s_reu_prefix
        ldx #>s_reu_prefix
        ldy meminfo_buf+5
        cpy #2
        bne @reu_p
        lda #<s_geo_prefix
        ldx #>s_geo_prefix
@reu_p:
        jsr print
        lda meminfo_buf+2
        ldx #0
        stx tmp
        ldy #6
@m_l:
        asl a
        rol tmp
        dey
        bne @m_l
        ldx tmp
        ldy #0
        jsr print_dec_w
        lda #<s_kb
        ldx #>s_kb
        jsr print
@no_reu:
        rts

kb_print:
        lsr a
        lsr a
        ldx #0
        ldy #0
        jmp print_dec_w

two_digits:
        cmp #10
        bcs @td_ok
        pha
        lda #'0'
        jsr SYS_PUTC
        pla
@td_ok:
        ldx #0
        jmp print_dec

div24:  sta dv
        lda #0
        ldx #24
@l:     asl t
        rol t+1
        rol t+2
        rol a
        bcs @s
        cmp dv
        bcc @n
@s:     sbc dv
        inc t
@n:     dex
        bne @l
        sta rem
        rts

copy_theme:
        sta lp1
        stx lp1+1
        ldy #0
@copy:
        lda (lp1),y
        sta theme_name,y
        beq @done
        iny
        bne @copy
@done:
        rts

.segment "RODATA"
; Logo lines (19 characters wide)
l_00: .byte "     $$$$$$        ", 0
l_01: .byte "  ,$$$$$$$$$       ", 0
l_02: .byte "  $$$'      $$$$$$$", 0
l_03: .byte " $$$$       $$$$$  ", 0
l_04: .byte "$$$$        $$$$   ", 0
l_05: .byte "$$$$               ", 0
l_06: .byte "$$$$        ;;;;   ", 0
l_07: .byte " $$$$       ;;;;;  ", 0
l_08: .byte "  $$$.      ;;;;;;;", 0
l_09: .byte "  '$$$$$$$$$       ", 0
l_10: .byte "     $$$$$$        ", 0

row_ptrs:
        .word l_00, l_01, l_02, l_03, l_04
        .word l_05, l_06, l_07, l_08, l_09, l_10
        .word 0

; One handler per logo row (same index as row_ptrs)
handlers:
        .word print_username, print_os, print_kernel, print_uptime_str
        .word print_shell, print_res, print_theme, print_cpu
        .word print_mem_str, print_serial, print_reu_str

s_at_host:    .byte "@breadbin", 0
s_os:         .byte "OS: breadbin 0.9", 0
s_kernel:     .byte "Kern: 6.1-breadbin", 0
s_up_prefix:  .byte "Uptime: ", 0
s_hours_mins: .byte "h ", 0
s_mins_suffix:.byte "m", 0
s_shell:      .byte "Shell: sh 5.2", 0
s_res:        .byte "Res: 40x25", 0
s_theme:      .byte "Theme: ", 0
s_theme_default:.byte "green", 0
p_theme:      .byte "/etc/theme", 0
s_cpu:        .byte "CPU: 6510 @ 1.0MHz", 0
s_cpu128:     .byte "CPU: 8502 @ 1.0MHz", 0
s_ser_on:     .byte "Serial: 6551 ACIA", 0
s_ser_off:    .byte "Serial: no card", 0
s_mem_prefix: .byte "Memory: ", 0
s_slash:      .byte " / ", 0
s_kb:         .byte "k", 0
s_reu_prefix: .byte "REU: ", 0
s_geo_prefix: .byte "GeoRAM: ", 0

.segment "BSS"
uid:         .res 1
is128:       .res 1
nouser:      .res 1
hptr:        .res 2
row_idx:     .res 1
t:           .res 3
dv:          .res 1
rem:         .res 1
secs:        .res 1
mins:        .res 1
hours:       .res 2
tmp:         .res 1
meminfo_buf: .res 8
theme_fd:    .res 1
theme_name:  .res 16