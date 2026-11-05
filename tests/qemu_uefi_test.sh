#!/usr/bin/env bash
# HR-02: el cargador UEFI lee kernel.bin de la ESP, sale de los servicios de
# arranque y el kernel arranca (banner y prompt por COM1, PIT, teclado).
#
# La ESP es un directorio (fat:rw:, sin mkfs) con EFI/BOOT/BOOTX64.EFI y
# kernel.bin. Dos corridas:
#   1. ESP completa: se exige la secuencia del cargador (tamaño de kernel.bin
#      igual al del anfitrión, páginas reservadas, ExitBootServices), después el
#      kernel (banner, e820, pmm, ticks del PIT, prompt) y un comando tecleado
#      por PS/2 que el shell contesta.
#   2. ESP sin kernel.bin: el cargador debe fallar en el paso 4 (Open) con un
#      código de EFI, apagar la máquina y NO llegar a ningún banner del kernel.
#
# Firmware (hay que dar uno de los dos; el Makefile busca rutas conocidas):
#   OVMF_CODE=/ruta/OVMF_CODE.fd [OVMF_VARS=/ruta/OVMF_VARS.fd]   (dos pflash)
#   OVMF_BIOS=/ruta/OVMF.fd                                       (-bios)
# Sin firmware la prueba FALLA con un mensaje claro: no se da por buena.
#
# Uso: tests/qemu_uefi_test.sh [directorio-ESP]
# Necesita: qemu-system-x86_64, socat y OVMF/EDK2.
set -u
ESP=${1:-build/uefi/esp}
EFI=$ESP/EFI/BOOT/BOOTX64.EFI
KBIN=$ESP/kernel.bin
[ -f "$EFI" ] || { echo "FAIL: no hay $EFI (make uefi-image)"; exit 1; }
[ -f "$KBIN" ] || { echo "FAIL: no hay $KBIN (make uefi-image)"; exit 1; }
if [ -z "${OVMF_CODE:-}" ] && [ -z "${OVMF_BIOS:-}" ]; then
    echo "FAIL: no hay firmware UEFI. Instala OVMF/EDK2 y pasa OVMF_CODE=... (y OVMF_VARS=...)"
    echo "      o OVMF_BIOS=... (ver docs/hr02-uefi-ahci.md). Esta prueba no corrió."
    exit 1
fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); SERIAL=$TMP/serial.log; MON=$TMP/mon.sock
QPID=""
stop_qemu() {
    if [ -n "${QPID:-}" ] && kill -0 "$QPID" 2>/dev/null; then
        echo quit | socat - UNIX-CONNECT:"$MON" >/dev/null 2>&1 || true
        local i
        for i in $(seq 30); do
            kill -0 "$QPID" 2>/dev/null || break
            sleep 0.1
        done
        kill "$QPID" 2>/dev/null || true
    fi
    [ -n "${QPID:-}" ] && wait "$QPID" 2>/dev/null
    QPID=""
}
trap 'stop_qemu; rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*"
    echo "--- serial ---"
    tr -d '\r' < "$SERIAL" 2>/dev/null | tail -40 || true
    exit 1
}

if [ -n "${OVMF_CODE:-}" ]; then
    [ -f "$OVMF_CODE" ] || { echo "FAIL: no existe OVMF_CODE=$OVMF_CODE"; exit 1; }
    fw=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE")
    if [ -n "${OVMF_VARS:-}" ]; then
        [ -f "$OVMF_VARS" ] || { echo "FAIL: no existe OVMF_VARS=$OVMF_VARS"; exit 1; }
        cp "$OVMF_VARS" "$TMP/vars.fd"
        fw+=(-drive "if=pflash,format=raw,unit=1,file=$TMP/vars.fd")
    fi
else
    [ -f "$OVMF_BIOS" ] || { echo "FAIL: no existe OVMF_BIOS=$OVMF_BIOS"; exit 1; }
    fw=(-bios "$OVMF_BIOS")
fi

# start_qemu <directorio ESP>
start_qemu() {
    : > "$SERIAL"
    rm -f "$MON"
    # shellcheck disable=SC2086
    qemu-system-x86_64 -machine q35 -m 256 "${fw[@]}" ${QEMU_EXTRA:-} \
        -drive "format=raw,file=fat:rw:$1" -net none \
        -display none -no-reboot -serial "file:$SERIAL" \
        -monitor unix:"$MON",server,nowait &
    QPID=$!
    sleep 0.5
    kill -0 "$QPID" 2>/dev/null || fail "qemu no arrancó"
}

has() { tr -d '\r' < "$SERIAL" | grep -qx "$1"; }
hasre() { tr -d '\r' < "$SERIAL" | grep -qE "$1"; }
mon() { echo "$1" | socat - UNIX-CONNECT:"$MON" >/dev/null; }
typeline() {
    local s=$1 i c k
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in " ") k=spc ;; "-") k=minus ;; *) k=$c ;; esac
        mon "sendkey $k"
    done
    mon "sendkey ret"
}
# wait_for <regex> <décimas de segundo>
wait_for() {
    local i
    for ((i = 0; i < $2; i++)); do
        hasre "$1" && return 0
        kill -0 "$QPID" 2>/dev/null || { hasre "$1" && return 0; return 1; }
        sleep 0.1
    done
    return 1
}

# --- 1. ESP completa: el kernel arranca --------------------------------------
KSIZE=$(wc -c < "$KBIN" | tr -d ' ')
start_qemu "$ESP"
wait_for "^lapageria> " "${UEFI_WAIT:-1800}" || fail "no llegó el prompt del shell del kernel (espera ${UEFI_WAIT:-1800} décimas de s)"
has "uefi: LapageriaOS UEFI loader" || fail "falta la línea del cargador"
echo "ok   OVMF cargó el cargador de Copihue (BOOTX64.EFI)"
want=$(printf 'uefi: esp kernel.bin size=0x%08x' "$KSIZE")
has "$want" || fail "kernel.bin leído de la ESP: se esperaba '$want'"
echo "ok   kernel.bin leído de la ESP: $KSIZE bytes (el mismo tamaño que en el anfitrión)"
has "uefi: kernel at=0x00400000" || fail "el kernel no quedó en 0x400000"
has "uefi: low pages 0x1000-0x9ffff reserved" || fail "no se reservaron las páginas bajas"
echo "ok   kernel en físico 0x400000 y páginas bajas 0x1000-0x9ffff reservadas al firmware"
hasre '^uefi: memmap entries=0x[0-9a-f]{8}$' || fail "falta el conteo del mapa de memoria"
hasre '^uefi: e820 entries=0x[0-9a-f]{8}$' || fail "falta el conteo E820"
has "uefi: ExitBootServices ok, jumping to kernel" || fail "no se salió de los servicios de arranque"
echo "ok   GetMemoryMap + ExitBootServices ($(tr -d '\r' < "$SERIAL" | grep -E '^uefi: (memmap|e820) entries' | tr '\n' ' '))"
has "LapageriaOS 0.8 (x86-64)" || fail "no hay banner del kernel por COM1"
echo "ok   el kernel arrancó: banner LapageriaOS 0.8 (x86-64) por COM1"
hasre '^e820 n=[1-9][0-9]*$' || fail "el kernel no leyó un E820 en 0x8000"
hasre '^pmm free=[1-9][0-9]* ' || fail "pmm_init no encontró páginas libres con el mapa de UEFI"
echo "ok   pmm.lap leyó el mapa convertido: $(tr -d '\r' < "$SERIAL" | grep -E '^(e820 n=|pmm free=)' | tr '\n' ' ')"
tr -d '\r' < "$SERIAL" | grep -E '^e820\[' | sed 's/^/       /'
hasre '^timer: ticks=[0-9]+$' || fail "el PIT no entregó ticks (¿IDT/PIC bajo UEFI?)"
echo "ok   el PIT del kernel corre (interrupciones bajo las tablas de páginas armadas por el cargador)"
typeline "echo uefi-ok"
wait_for '^uefi-ok$' 100 || fail "el shell no contestó a 'echo uefi-ok' tecleado por PS/2"
echo "ok   shell interactivo: echo uefi-ok por PS/2 contestado"
stop_qemu

# --- 2. ESP sin kernel.bin: falla limpia ----------------------------------------
mkdir -p "$TMP/esp2/EFI/BOOT"
cp "$EFI" "$TMP/esp2/EFI/BOOT/BOOTX64.EFI"
start_qemu "$TMP/esp2"
for _ in $(seq 600); do
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$QPID" 2>/dev/null; then fail "sin kernel.bin: QEMU no terminó (el cargador debía apagar)"; fi
wait "$QPID" 2>/dev/null; QPID=""
hasre '^uefi: FAIL step=0x00000004 status=0x[0-9a-f]{16}$' || fail "sin kernel.bin debía fallar en el paso 4 (Open) con un código de EFI"
if has "LapageriaOS 0.8 (x86-64)"; then fail "sin kernel.bin NO debía haber banner del kernel"; fi
echo "ok   sin kernel.bin: $(tr -d '\r' < "$SERIAL" | grep -E '^uefi: FAIL' | head -1), apaga y no finge un arranque"
echo "ok   qemu_uefi_test"
