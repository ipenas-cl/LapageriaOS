#!/usr/bin/env bash
# FS-04/1: el disco ATA no da timeout con -icount shift=4.
#
# Una vez salió "exec fail 1" (ata.lap devuelve 1 = se agotó el tiempo) con
# QEMU -icount shift=4. Esta prueba corre N veces (6 por defecto) una prueba
# que lee y escribe el disco todo el rato (tests/qemu_iso_test.sh: exec de
# varios programas desde el disco, dos zonas) con `-icount shift=4`, varias
# a la vez, y falla si alguna corrida da FAIL o si en cualquier serie
# aparece "exec fail" / "fs fail".
# Uso: tests/qemu_ata_test.sh [imagen] [corridas] [paralelas]
set -u
IMAGE=${1:-build/lapageriaos.img}
N=${2:-6}
PAR=${3:-6}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$IMAGE" ] || { echo "FAIL: no hay imagen $IMAGE"; exit 1; }
LOGS=$(mktemp -d)
trap 'rm -rf "$LOGS"' EXIT

export QEMU_EXTRA="-icount shift=4"
i=1
while [ "$i" -le "$N" ]; do
    ( bash "$HERE/qemu_iso_test.sh" "$IMAGE" > "$LOGS/c$i.log" 2>&1; echo "exit=$?" >> "$LOGS/c$i.log" ) &
    if [ $((i % PAR)) -eq 0 ]; then wait; fi
    i=$((i + 1))
done
wait

bad=0
i=1
while [ "$i" -le "$N" ]; do
    if grep -qx 'exit=0' "$LOGS/c$i.log" && ! grep -q '^FAIL' "$LOGS/c$i.log"; then
        echo "ok   corrida $i (icount shift=4)"
    else
        bad=$((bad + 1))
        echo "FAIL: corrida $i con -icount shift=4"
        grep -m3 -E '^FAIL|exec fail|fs fail' "$LOGS/c$i.log"
        tail -25 "$LOGS/c$i.log"
    fi
    i=$((i + 1))
done
[ "$bad" -eq 0 ] || { echo "FAIL: $bad de $N corridas fallaron"; exit 1; }
echo "ok   $N corridas con -icount shift=4, en paralelo de a $PAR, sin FAIL"
