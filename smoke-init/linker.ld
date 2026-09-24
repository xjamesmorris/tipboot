OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

PHDRS
{
    image PT_LOAD FILEHDR PHDRS FLAGS(5);
    stack PT_GNU_STACK FLAGS(6);
}

SECTIONS
{
    . = 0x400000 + SIZEOF_HEADERS;

    .text : ALIGN(16)
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } :image

    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
    } :image

    .data : ALIGN(16)
    {
        *(.data .data.*)
    } :image

    .bss (NOLOAD) : ALIGN(16)
    {
        *(.bss .bss.*)
        *(COMMON)
    } :image

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
        *(.llvm_addrsig)
    }
}
