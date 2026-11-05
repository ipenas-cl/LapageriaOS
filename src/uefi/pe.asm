; Envoltorio PE32+ del stub UEFI (HR-01). Solo empaqueta: el código es
; build/uefi/stub.bin, compilado de src/uefi/stub.lap con `copihue --flat 0x1000`.
;
;   nasm -f bin -DSTUB_FILE='"build/uefi/stub.bin"' -DSTUB_SIZE=<bytes> \
;        -DTEXT_RAW=<bytes redondeado a 512> -o BOOTX64.EFI src/uefi/pe.asm
;
; Disposición (FileAlignment 0x200, SectionAlignment 0x1000):
;   file 0x000  cabeceras (DOS, PE, opcional, 2 secciones), relleno hasta 0x200
;   file 0x200  .text   RVA 0x1000  el stub; AddressOfEntryPoint = 0x1000
;   file +TEXT_RAW  .reloc  RVA 0x2000  un bloque vacío (una entrada ABSOLUTE)
; Subsistema 10 (EFI application), máquina x86-64, sin relocaciones reales
; porque el stub es independiente de la posición.

bits 64
default rel

%ifndef STUB_FILE
%error "falta -DSTUB_FILE"
%endif

IMAGE_BASE      equ 0x0000000140000000
TEXT_RVA        equ 0x1000
; .reloc va en la página que sigue a .text, sea cual sea su tamaño.
RELOC_RVA       equ TEXT_RVA + ((STUB_SIZE + 0xFFF) & ~0xFFF)
SIZE_OF_IMAGE   equ RELOC_RVA + 0x1000
HEADERS_RAW     equ 0x200

; --- DOS ---------------------------------------------------------------
        dw 0x5A4D                       ; "MZ"
        times 0x3A db 0
        dd pe_sig                       ; e_lfanew (0x3C)
        times 0x40 - ($ - $$) db 0
pe_sig:
        db 'P', 'E', 0, 0
; --- COFF --------------------------------------------------------------
        dw 0x8664                       ; Machine: AMD64
        dw 2                            ; NumberOfSections
        dd 0                            ; TimeDateStamp
        dd 0                            ; PointerToSymbolTable
        dd 0                            ; NumberOfSymbols
        dw opt_end - opt                ; SizeOfOptionalHeader
        dw 0x0022                       ; EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE
; --- Opcional PE32+ -----------------------------------------------------
opt:
        dw 0x020B                       ; PE32+
        db 0, 0                         ; versión del enlazador
        dd TEXT_RAW                     ; SizeOfCode
        dd 0                            ; SizeOfInitializedData
        dd 0                            ; SizeOfUninitializedData
        dd TEXT_RVA                     ; AddressOfEntryPoint
        dd TEXT_RVA                     ; BaseOfCode
        dq IMAGE_BASE
        dd 0x1000                       ; SectionAlignment
        dd 0x200                        ; FileAlignment
        dw 0, 0                         ; versión del SO
        dw 0, 0                         ; versión de la imagen
        dw 0, 0                         ; versión del subsistema
        dd 0                            ; Win32VersionValue
        dd SIZE_OF_IMAGE
        dd HEADERS_RAW                  ; SizeOfHeaders
        dd 0                            ; CheckSum
        dw 10                           ; Subsystem: EFI application
        dw 0                            ; DllCharacteristics
        dq 0x10000                      ; SizeOfStackReserve
        dq 0x10000                      ; SizeOfStackCommit
        dq 0x10000                      ; SizeOfHeapReserve
        dq 0x10000                      ; SizeOfHeapCommit
        dd 0                            ; LoaderFlags
        dd 16                           ; NumberOfRvaAndSizes
        times 5 dq 0                    ; export, import, resource, exception, security
        dd RELOC_RVA, 12                ; directorio 5: relocaciones base
        times 10 dq 0                   ; el resto
opt_end:
; --- Secciones ----------------------------------------------------------
        db '.text', 0, 0, 0
        dd STUB_SIZE                    ; VirtualSize
        dd TEXT_RVA
        dd TEXT_RAW                     ; SizeOfRawData
        dd HEADERS_RAW                  ; PointerToRawData
        dd 0, 0
        dw 0, 0
        dd 0x60000020                   ; CODE | EXECUTE | READ

        db '.reloc', 0, 0
        dd 12
        dd RELOC_RVA
        dd 0x200
        dd HEADERS_RAW + TEXT_RAW
        dd 0, 0
        dw 0, 0
        dd 0x42000040                   ; INITIALIZED_DATA | DISCARDABLE | READ

        times HEADERS_RAW - ($ - $$) db 0

; --- .text --------------------------------------------------------------
        incbin STUB_FILE
        times HEADERS_RAW + TEXT_RAW - ($ - $$) db 0

; --- .reloc: bloque de la página 0x1000, una entrada ABSOLUTE (no hace nada) --
        dd TEXT_RVA                     ; PageRVA
        dd 12                           ; BlockSize
        dw 0, 0                         ; entrada ABSOLUTE + relleno
        times HEADERS_RAW + TEXT_RAW + 0x200 - ($ - $$) db 0
