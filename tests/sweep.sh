#!/usr/bin/env bash
# sweep.sh <directorio de logs> <corridas por valor> <paralelas> <test> <shift>...
# Corre <test> con QEMU -icount shift=<n> para cada <n>. Con icount el tiempo
# virtual depende solo de las instrucciones ejecutadas: cada valor fija otro
# reparto del PIT frente al código, y cada uno es repetible. Sirve para
# exponer una carrera que con el reloj real sale una vez de cada tantas.
set -u
DIR=$1; N=$2; PAR=$3; TEST=$4; shift 4
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$DIR"
for s in "$@"; do
    echo "--- shift=$s"
    QEMU_EXTRA="-icount shift=$s" bash "$HERE/repeat.sh" "$DIR/sh$s" "$N" "$PAR" "$TEST" | tail -"$((N + 1))"
done
