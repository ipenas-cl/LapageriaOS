#!/usr/bin/env bash
# SG-02: la etapa 2 tiene que cargar un kernel del tamaño máximo del
# layout (2048 sectores = 1 MiB), no solo los ~470 sectores de hoy.
# Se arma una imagen aparte con build/kernel.bin seguido de bytes
# aleatorios hasta 2048 sectores, con la etapa 2 recompilada para pedir
# 2048. El kernel arranca igual (lo que está después de su .bss no lo
# toca). Con el monitor de QEMU se vuelca la memoria física
# 0x4B0000..0x500000 (la parte alta del archivo, 5 trozos de 64 KiB
# después de la copia por INT 15h AH=87h) y se compara con los bytes del
# archivo. Si un trozo no se copió, o cayó en otra dirección, difiere.
# Uso: tests/stage2_big_test.sh [dir_build]
# Necesita: qemu-system-x86_64, socat, y build/copihue/copihue (o COPIHUE=).
set -u
B=${1:-build}
COP=${COPIHUE:-$B/copihue/copihue}
SECT=2048
OFF=$((0xB0000))
LEN=$((SECT * 512 - OFF))
TMP=$(mktemp -d)
QPID=""
cleanup() {
    if [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; then
        echo quit | socat - UNIX-CONNECT:"$TMP/mon.sock" >/dev/null 2>&1 || true
        sleep 0.3
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL (stage2 big): $*"; [ -f "$TMP/mon.out" ] && { echo "--- monitor ---"; tr -d "\r" < "$TMP/mon.out" | tail -8; }; [ -f "$TMP/serial.log" ] && tr -d '\r' < "$TMP/serial.log" | tail -20; exit 1; }

for f in "$B/kernel.bin" "$B/boot.bin" "$B/stage2.lap" "$COP"; do
    [ -e "$f" ] || fail "falta $f"
done
ksize=$(wc -c < "$B/kernel.bin" | tr -d ' ')
# La .bss (hasta 256 KiB; hoy unos 247 KiB) sigue al archivo y el kernel la limpia: lo que se
# compara empieza más allá.
[ $((ksize + 262144)) -lt "$OFF" ] || fail "kernel.bin ($ksize bytes) llega a la zona que se compara"
total=$((SECT * 512))
dd if=/dev/urandom of="$TMP/pad.bin" bs=512 count=$SECT status=none
cat "$B/kernel.bin" "$TMP/pad.bin" > "$TMP/big0.bin"
# Se corta en el tamaño exacto.
head -c "$total" "$TMP/big0.bin" > "$TMP/big.bin"
[ "$(wc -c < "$TMP/big.bin" | tr -d ' ')" -eq "$total" ] || fail "big.bin no mide $total bytes"

sed 's|^    dw [0-9]*; // KERNEL_SECTORS$|    dw '"$SECT"'; // KERNEL_SECTORS|' "$B/stage2.lap" > "$TMP/stage2.lap"
grep -q "^    dw $SECT; // KERNEL_SECTORS$" "$TMP/stage2.lap" || fail "no se pudo fijar KERNEL_SECTORS=$SECT"
"$COP" --flat 0x8200 -o "$TMP/stage2.bin" "$TMP/stage2.lap" >/dev/null 2>&1 || fail "no compila stage2"
[ "$(wc -c < "$TMP/stage2.bin" | tr -d ' ')" -le 4096 ] || fail "stage2 pasa de 8 sectores"

dd if=/dev/zero of="$TMP/big.img" bs=512 count=2880 status=none
dd if="$B/boot.bin" of="$TMP/big.img" conv=notrunc status=none
dd if="$TMP/stage2.bin" of="$TMP/big.img" bs=512 seek=1 conv=notrunc status=none
dd if="$TMP/big.bin" of="$TMP/big.img" bs=512 seek=9 conv=notrunc status=none

: > "$TMP/serial.log"
qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$TMP/big.img" \
    -display none -no-reboot -serial file:"$TMP/serial.log" \
    -monitor unix:"$TMP/mon.sock",server,nowait &
QPID=$!
ok=0
for i in $(seq 200); do
    if tr -d '\r' < "$TMP/serial.log" | grep -q '^lapageria> '; then ok=1; break; fi
    kill -0 "$QPID" 2>/dev/null || fail "qemu terminó antes del prompt"
    sleep 0.1
done
[ "$ok" -eq 1 ] || fail "el kernel de $SECT sectores no llegó al prompt"
tr -d '\r' < "$TMP/serial.log" | grep -q 'Disk error' && fail "la etapa 2 informó error de disco"
tr -d '\r' < "$TMP/serial.log" | grep -qx 'hh on text=0xffffffff80400000' || fail "falta 'hh on text=0xffffffff80400000'"
(echo "pmemsave $((0x400000 + OFF)) $LEN \"$TMP/dump.bin\""; sleep 2) | socat - UNIX-CONNECT:"$TMP/mon.sock" >"$TMP/mon.out" 2>&1
for i in $(seq 50); do
    [ "$(wc -c < "$TMP/dump.bin" 2>/dev/null | tr -d ' ')" = "$LEN" ] && break
    sleep 0.1
done
[ "$(wc -c < "$TMP/dump.bin" 2>/dev/null | tr -d ' ')" = "$LEN" ] || fail "pmemsave no escribió $LEN bytes"
dd if="$TMP/big.bin" of="$TMP/want.bin" bs=$OFF skip=1 status=none
cmp -s "$TMP/want.bin" "$TMP/dump.bin" || fail "la memoria en 0x$(printf '%x' $((0x400000 + OFF))) no coincide con el archivo: algún trozo de 64 KiB no se copió bien"
echo "ok   stage2 big: $SECT sectores (1 MiB) cargados a 0x400000, arranca y los últimos $LEN bytes coinciden"
