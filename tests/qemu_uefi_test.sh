#!/usr/bin/env bash
# HR-01: el stub UEFI arranca en QEMU con OVMF y escribe su línea por COM1.
#
# La ESP es un directorio (fat:rw:, sin mkfs) con EFI/BOOT/BOOTX64.EFI, que
# OVMF arranca por la ruta de respaldo. El stub imprime
# "LapageriaOS UEFI stub ok" por COM1 y por ConOut y apaga la máquina con
# ResetSystem, así que QEMU termina solo.
#
# Firmware (hay que dar uno de los dos; el Makefile busca rutas conocidas):
#   OVMF_CODE=/ruta/OVMF_CODE.fd [OVMF_VARS=/ruta/OVMF_VARS.fd]   (dos pflash)
#   OVMF_BIOS=/ruta/OVMF.fd                                       (-bios)
# Sin firmware la prueba FALLA con un mensaje claro: no se da por buena.
#
# Uso: tests/qemu_uefi_test.sh [directorio-ESP]
# Necesita: qemu-system-x86_64 y OVMF/EDK2.
set -u
ESP=${1:-build/uefi/esp}
EFI=$ESP/EFI/BOOT/BOOTX64.EFI
[ -f "$EFI" ] || { echo "FAIL: no hay $EFI (make uefi-image)"; exit 1; }
if [ -z "${OVMF_CODE:-}" ] && [ -z "${OVMF_BIOS:-}" ]; then
    echo "FAIL: no hay firmware UEFI. Instala OVMF/EDK2 y pasa OVMF_CODE=... (y OVMF_VARS=...)"
    echo "      o OVMF_BIOS=... (ver docs/hr01-uefi-ahci.md). Esta prueba no corrió."
    exit 1
fi
TMP=$(mktemp -d); SERIAL=$TMP/serial.log
QPID=""
trap '[ -n "$QPID" ] && kill "$QPID" 2>/dev/null; rm -rf "$TMP"' EXIT

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

qemu-system-x86_64 -machine q35 -m 256 "${fw[@]}" \
    -drive "format=raw,file=fat:rw:$ESP" -net none \
    -display none -no-reboot -serial "file:$SERIAL" &
QPID=$!

# El stub apaga la máquina; si en 60 s no terminó, algo no arrancó.
for _ in $(seq 600); do
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$QPID" 2>/dev/null; then
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
    echo "FAIL: QEMU no terminó en 60 s (el stub no llegó al ResetSystem)"
    echo "--- serial ---"; tr -d '\r' < "$SERIAL" | tail -20
    exit 1
fi
wait "$QPID" 2>/dev/null; QPID=""
if tr -d '\r' < "$SERIAL" | grep -q 'LapageriaOS UEFI stub ok'; then
    echo "ok   UEFI: el stub de Copihue arrancó con OVMF y escribió por COM1"
    echo "ok   qemu_uefi_test"
    exit 0
fi
echo "FAIL: no apareció 'LapageriaOS UEFI stub ok' en COM1"
echo "--- serial ---"; tr -d '\r' < "$SERIAL" | tail -20
exit 1
