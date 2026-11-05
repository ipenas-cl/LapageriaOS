#!/usr/bin/env bash
# repeat.sh <prefijo> <corridas> <paralelas> <test> [imagen] [sin-icount]
# Corre <test> N veces con QEMU -icount shift=7 (o sin icount con el sexto
# argumento "sin-icount"), de a <paralelas> a la vez.
# Deja <prefijo>_<i>.log y un resumen por salida estándar.
set -u
PFX=$1; N=$2; PAR=$3; TEST=$4; IMG=${5:-/Users/admin/lapageriaos-work/src/build/lapageriaos.img}
export QEMU_EXTRA="${QEMU_EXTRA--icount shift=7}"
# Sexto argumento "sin-icount": sin opciones de QEMU (TCG normal, reloj del anfitrión).
if [ "${6:-}" = "sin-icount" ]; then QEMU_EXTRA=""; fi
i=1
while [ "$i" -le "$N" ]; do
    ( "$TEST" "$IMG" > "${PFX}_$i.log" 2>&1; echo "exit=$?" >> "${PFX}_$i.log" ) &
    if [ $((i % PAR)) -eq 0 ]; then wait; fi
    i=$((i + 1))
done
wait
pass=0; failn=0
i=1
while [ "$i" -le "$N" ]; do
    if grep -qx 'exit=0' "${PFX}_$i.log"; then pass=$((pass + 1)); echo "corrida $i: OK"
    else failn=$((failn + 1)); echo "corrida $i: FALLA: $(grep -m1 '^FAIL' "${PFX}_$i.log")"; fi
    i=$((i + 1))
done
echo "total: $pass ok, $failn fallas de $N"
