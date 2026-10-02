/*
 * crt0.S - C runtime start-up: stack, .data copy, .bss clear, main().
 */
    .section .text.init
    .globl _start
_start:
    la   sp, _stack_top

    /* Copy the .data initialisers from ROM (load address) to RAM. */
    la   a0, _data_load
    la   a1, _data_start
    la   a2, _data_end
1:  bgeu a1, a2, 2f
    lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    j    1b

    /* Zero .bss. */
2:  la   a1, _bss_start
    la   a2, _bss_end
3:  bgeu a1, a2, 4f
    sw   zero, 0(a1)
    addi a1, a1, 4
    j    3b

4:  call main
    /* main() never returns on this SoC; park the core if it does. */
5:  j    5b
