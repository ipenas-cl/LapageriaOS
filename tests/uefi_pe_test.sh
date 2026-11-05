#!/usr/bin/env bash
# HR-01: comprobación estática del BOOTX64.EFI (no arranca nada, no necesita OVMF).
#
# El stub UEFI lo arma src/uefi/pe.asm alrededor de build/uefi/stub.bin. Aquí se
# lee la imagen con od y se comprueba lo que un cargador UEFI exige: MZ, PE\0\0,
# máquina x86-64, PE32+, subsistema 10 (aplicación EFI), entry dentro de .text,
# alineaciones, que las secciones quepan en el archivo, que .text sea exactamente
# el stub, y que el stub no tenga operandos absolutos (tiene que cargarse en
# cualquier dirección: el .reloc es una tabla vacía).
#
# Uso: tests/uefi_pe_test.sh [BOOTX64.EFI] [stub.bin] [stub.asm]
set -u
EFI=${1:-build/uefi/esp/EFI/BOOT/BOOTX64.EFI}
STUB=${2:-build/uefi/stub.bin}
ASM=${3:-build/uefi/stub.asm}
fail() { echo "FAIL: $*"; exit 1; }
[ -f "$EFI" ] || fail "no hay $EFI (make uefi-image)"
[ -f "$STUB" ] || fail "no hay $STUB"

u8()  { od -An -v -tu1 -j "$1" -N1 "$EFI" | tr -d ' '; }
u16() { od -An -v -tu2 -j "$1" -N2 "$EFI" | tr -d ' '; }
u32() { od -An -v -tu4 -j "$1" -N4 "$EFI" | tr -d ' '; }
# od -tu2/-tu4 usan el orden del anfitrión; x86-64 y arm64 son little-endian.
chk() { [ "$2" = "$3" ] || fail "$1: se esperaba $3 y hay $2"; }

size=$(wc -c < "$EFI" | tr -d ' ')
chk "MZ" "$(u16 0)" 23117
lfanew=$(u32 60)
chk "e_lfanew" "$lfanew" 64
chk "firma PE" "$(u32 "$lfanew")" 17744       # 'P' 'E' 0 0
c=$((lfanew + 4))
chk "Machine" "$(u16 "$c")" 34404             # 0x8664
nsec=$(u16 $((c + 2)))
chk "NumberOfSections" "$nsec" 2
optsz=$(u16 $((c + 16)))
o=$((c + 20))
chk "magic PE32+" "$(u16 "$o")" 523           # 0x20B
entry=$(u32 $((o + 16)))
chk "AddressOfEntryPoint" "$entry" 4096
chk "SectionAlignment" "$(u32 $((o + 32)))" 4096
chk "FileAlignment" "$(u32 $((o + 36)))" 512
chk "Subsystem EFI application" "$(u16 $((o + 68)))" 10
soi=$(u32 $((o + 56)))
soh=$(u32 $((o + 60)))
chk "SizeOfHeaders" "$soh" 512
s=$((o + optsz))                              # primera sección
fsz=0
for i in 0 1; do
    h=$((s + i * 40))
    name=$(dd if="$EFI" bs=1 skip="$h" count=8 status=none | tr -d '\0')
    vsz=$(u32 $((h + 8))); va=$(u32 $((h + 12))); raw=$(u32 $((h + 16))); ptr=$(u32 $((h + 20)))
    [ $((va % 4096)) -eq 0 ] || fail "$name: RVA $va sin alinear a 4096"
    [ $((ptr % 512)) -eq 0 ] && [ $((raw % 512)) -eq 0 ] || fail "$name: archivo sin alinear a 512"
    [ $((ptr + raw)) -le "$size" ] || fail "$name: sale del archivo ($((ptr + raw)) > $size)"
    [ $((va + vsz)) -le "$soi" ] || fail "$name: sale de SizeOfImage"
    [ "$ptr" -ge "$soh" ] || fail "$name: pisa las cabeceras"
    if [ "$name" = ".text" ]; then
        [ "$entry" -ge "$va" ] && [ "$entry" -lt $((va + vsz)) ] || fail "el entry no cae en .text"
        chk ".text VirtualSize = tamaño del stub" "$vsz" "$(wc -c < "$STUB" | tr -d ' ')"
        cmp -s <(dd if="$EFI" bs=1 skip="$ptr" count="$vsz" status=none) "$STUB" || fail ".text no es el stub"
        text_ok=1
    fi
    echo "ok   sección $name rva=0x$(printf '%x' "$va") vsize=$vsz raw=$raw @0x$(printf '%x' "$ptr")"
done
[ "${text_ok:-0}" = 1 ] || fail "no hay sección .text"
echo "ok   PE32+ x86-64, subsistema 10, entry 0x1000, $size bytes"

# Independencia de la posición: el asm del stub no puede tener memoria absoluta
# a etiquetas (`[efi_msg8]`, `mov rax, efi_msg8`). Solo `[rel ...]`, pila y punteros.
if [ -f "$ASM" ]; then
    if grep -nE '(mov|lea|cmp|add|sub|call|jmp)[^;]*\[(efi_|__)[A-Za-z0-9_]*\]' "$ASM" | grep -v 'rel ' | grep -vE '__loc_' >/dev/null; then
        grep -nE '\[(efi_|__)[A-Za-z0-9_]*\]' "$ASM" | grep -v 'rel ' | head
        fail "el stub tiene operandos absolutos a etiquetas"
    fi
    if grep -qE '^[[:space:]]*res[bwdq] ' "$ASM"; then fail "el stub tiene .bss (globales)"; fi
    echo "ok   el stub no tiene globales ni operandos absolutos"
fi
echo "ok   uefi_pe_test"
