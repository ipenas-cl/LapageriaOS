#!/usr/bin/env bash
# HR-03: bajo UEFI (q35 + OVMF, sin IDE) el shell usa disco por AHCI a través de blk.
#
# q35 no tiene IDE: `disk` y `fs` solo pueden andar por el backend AHCI de
# blk.lap. La ESP va en un virtio-blk (no en el SATA, para que el único disco
# SATA sea el de datos y `disk`/`fs` no toquen la ESP). Dos corridas:
#   1. Con un disco SATA de datos en un `-device ahci` explícito (el ICH9
#      integrado queda vacío; el kernel prueba un controlador tras otro). Disco
#      en cero, 2048 sectores: `blk` elige AHCI sin
#      que nadie lo pida (el ATA no existe), `disk` da ahci ok, blk ok, blk corrupt
#      detected; `fs format`/`mkdir`/`write`/`cat`/`scrub` andan. Con QEMU parado
#      el anfitrión ve AFS1 en el LBA 4 y ABLK en el LBA 5 del archivo SATA.
#   2. Sin disco SATA: `blk` -> `blk fail 3`, `disk` -> `ata fail 3`, `fs ls` ->
#      `fs fail 3`, y el shell sigue vivo.
#
# Firmware: OVMF_CODE (+ OVMF_VARS) u OVMF_BIOS, como qemu_uefi_test.sh. Sin
# firmware esta prueba FALLA con un mensaje claro; el Makefile hace el SKIP.
#
# Uso: tests/qemu_uefi_blk_test.sh [directorio-ESP]
# Necesita: qemu-system-x86_64, socat y OVMF/EDK2.
set -u
ESP=${1:-build/uefi/esp}
[ -f "$ESP/EFI/BOOT/BOOTX64.EFI" ] || { echo "FAIL: no hay $ESP/EFI/BOOT/BOOTX64.EFI (make uefi-image)"; exit 1; }
[ -f "$ESP/kernel.bin" ] || { echo "FAIL: no hay $ESP/kernel.bin (make uefi-image)"; exit 1; }
if [ -z "${OVMF_CODE:-}" ] && [ -z "${OVMF_BIOS:-}" ]; then
    echo "FAIL: no hay firmware UEFI. Instala OVMF/EDK2 y pasa OVMF_CODE=... (y OVMF_VARS=...)"
    echo "      o OVMF_BIOS=... (ver docs/hr02-uefi-ahci.md). Esta prueba no corrió."
    exit 1
fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); SERIAL=$TMP/serial.log; MON=$TMP/mon.sock
SATA=$TMP/sata.img
SECTORS=2048
QPID=""
BOOTS=0
OUT=""
dd if=/dev/zero of="$SATA" bs=512 count=$SECTORS status=none
# OVMF sin pflash de variables escribe NvVars en la ESP (vvfat rw), con su orden
# de arranque; una copia evita dejar ese estado en build/uefi/esp, que rompe
# qemu_uefi_test.sh (arranca por la ESP en el SATA).
cp -R "$ESP" "$TMP/esp"
ESP=$TMP/esp

stop_qemu() {
    if [ -n "${QPID:-}" ] && kill -0 "$QPID" 2>/dev/null; then
        echo quit | "$SOCAT" - UNIX-CONNECT:"$MON" >/dev/null 2>&1 || true
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
    echo "--- serial (últimas 60 líneas) ---"
    tr -d '\r' < "$SERIAL" 2>/dev/null | tail -60 || true
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

prompts() { grep -c "lapageria> " "$SERIAL" 2>/dev/null || true; }

# start_qemu [con|sin]: con = un disco SATA de datos en el AHCI de q35; sin = ninguno.
start_qemu() {
    BOOTS=$((BOOTS + 1))
    : > "$SERIAL"
    rm -f "$MON"
    local extra=()
    if [ "$1" = con ]; then
        # Controlador AHCI explícito (como qemu_ahci_fs_test.sh), no el ICH9
        # integrado: no depende de cómo el firmware deje ese puerto.
        extra=(-device ahci,id=ahci -drive "id=sata0,file=$SATA,format=raw,if=none" -device ide-hd,drive=sata0,bus=ahci.0)
    fi
    qemu-system-x86_64 -machine q35 -m 256 "${fw[@]}" ${QEMU_EXTRA:-} \
        -drive "id=esp,format=raw,file=fat:rw:$ESP,if=none" -device virtio-blk-pci,drive=esp,bootindex=0 \
        ${extra[@]+"${extra[@]}"} -net none \
        -display none -no-reboot -serial "file:$SERIAL" \
        -monitor unix:"$MON",server,nowait &
    QPID=$!
    sleep 0.5
    kill -0 "$QPID" 2>/dev/null || fail "qemu no arrancó"
    local i
    for ((i = 0; i < ${UEFI_WAIT:-1800}; i++)); do
        [ "$(prompts)" -ge 1 ] && return 0
        kill -0 "$QPID" 2>/dev/null || fail "qemu terminó antes del prompt"
        sleep 0.1
    done
    fail "no llegó el prompt del shell bajo UEFI"
}

keys() {
    local s=$1 i c k seq=""
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in
            " ") k=spc ;; "-") k=minus ;; "/") k=slash ;; ".") k=dot ;;
            "=") k=equal ;; *) k=$c ;;
        esac
        seq="${seq}sendkey $k"$'\n'
    done
    seq="${seq}sendkey ret"$'\n'
    printf '%s' "$seq" | "$SOCAT" -t 0.3 - UNIX-CONNECT:"$MON" >/dev/null
}

run() {
    local cmd=$1 cap=${2:-90} before off i
    before=$(prompts)
    off=$(wc -c < "$SERIAL" | tr -d ' ')
    keys "$cmd"
    for ((i = 0; i < cap * 20; i++)); do
        if [ "$(prompts)" -gt "$before" ]; then
            OUT=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
            return 0
        fi
        kill -0 "$QPID" 2>/dev/null || fail "qemu terminó durante: $cmd"
        sleep 0.05
    done
    OUT=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
    fail "sin prompt (tope ${cap}s) tras: $cmd"
}

has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
want() { has "$1" || fail "falta la línea '$1' tras el último comando ($(printf '%s' "$OUT" | tr '\n' '|'))"; }
lack() { has "$1" && fail "no debía salir '$1' ($(printf '%s' "$OUT" | tr '\n' '|'))"; return 0; }
ok() { run "$1" "${3:-90}"; want "$2"; }

# --- 1. Con disco SATA: disk y fs andan por AHCI --------------------------------
start_qemu con
tr -d '\r' < "$SERIAL" | grep -qx "uefi: ExitBootServices ok, jumping to kernel" || fail "no pasó por el cargador UEFI"
ok "blk" "blk dev=ahci sectors=$SECTORS"
echo "ok   bajo UEFI (q35, sin IDE) blk elige AHCI solo: sectors=$SECTORS"
run "disk" 120
want "ahci ok"
want "blk ok"
want "blk corrupt detected"
lack "ata ok"
echo "ok   disk bajo UEFI: ahci ok, blk ok, blk corrupt detected"
ok "fs format" "fs format ok"
ok "fs mkdir /a" "fs mkdir ok"
ok "fs write /a/f uefi-ahci" "fs write ok"
ok "fs cat /a/f" "fs live uefi-ahci"
run "fs scrub" 120
n=$(printf '%s\n' "$OUT" | sed -n 's/^fs scrub ok bloques=//p' | head -1)
[ -n "$n" ] && [ "$n" -gt 0 ] || fail "fs scrub ok bloques=N faltante bajo UEFI: $OUT"
echo "ok   fs format, mkdir, write, cat y scrub bajo UEFI sobre el SATA (scrub ok bloques=$n)"
stop_qemu
magic() { dd if="$1" bs=512 skip="$2" count=1 status=none | head -c 4; }
[ "$(magic "$SATA" 4)" = "AFS1" ] || fail "LBA 4 del SATA no empieza con AFS1"
[ "$(magic "$SATA" 5)" = "ABLK" ] || fail "LBA 5 del SATA no empieza con ABLK"
echo "ok   el anfitrión ve AFS1 en el LBA 4 y ABLK en el LBA 5 del archivo SATA"

# --- 2. Sin disco SATA: falla limpio -----------------------------------------------
start_qemu sin
run "blk" 30
want "blk dev=none"
want "blk fail 3"
run "disk" 30
want "ata fail 3"
run "fs ls" 30
want "fs fail 3"
ok "echo sigue-vivo" "sigue-vivo" 30
echo "ok   sin disco SATA: blk fail 3, ata fail 3, fs fail 3 y el shell sigue"
stop_qemu
echo "ok   qemu_uefi_blk_test"
