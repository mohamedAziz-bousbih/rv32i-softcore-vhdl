/*
 * link.ld - memory layout of the RV32I SoC.
 *
 * Code and read-only data live in the ROM, which the core can both fetch
 * from and load from. Initialised data is placed in RAM but loaded into ROM
 * behind .rodata; crt0.S copies it over before main() runs. The assembly
 * tests have no crt0 and keep their data in .rodata or write RAM directly.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
  RAM (rw)  : ORIGIN = 0x10000000, LENGTH = 16K
}

SECTIONS
{
  .text : {
    KEEP(*(.text.init))
    *(.text .text.*)
  } > ROM

  .rodata : ALIGN(4) {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > ROM

  .data : ALIGN(4) {
    _data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    _data_end = .;
  } > RAM AT > ROM
  _data_load = LOADADDR(.data);

  .bss (NOLOAD) : ALIGN(4) {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > RAM

  _stack_top = ORIGIN(RAM) + LENGTH(RAM);

  /* Unwind tables are useless without an unwinder and would land in ROM. */
  /DISCARD/ : { *(.eh_frame .eh_frame_hdr) }
}
