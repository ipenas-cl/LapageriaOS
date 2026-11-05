#!/bin/sh
# EX-08: comprueba en el anfitrión si Copihue (el del pin) emite el store de
# `f(x)[0] = v` (pedido de alta prioridad de docs/PEDIDOS_COPIHUE.md). No falla
# si se descarta: lo informa, porque es un pedido abierto, no una regresión.
# Uso: tests/copihue_gaps_test.sh /ruta/copihue
set -u
CC=${1:?usage: copihue_gaps_test.sh copihue}
D=$(dirname "$0")/copihue
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if ! "$CC" --flat 0x400000 -S -o "$TMP/s.asm" "$D/storecall.lap" > "$TMP/out" 2>&1; then
    echo "gap f(x)[0]=v: el compilador lo rechaza (error): $(tr '\n' ' ' < "$TMP/out")"
    exit 0
fi
if [ -s "$TMP/out" ]; then
    echo "gap f(x)[0]=v: salida del compilador: $(tr '\n' ' ' < "$TMP/out")"
fi
# el cuerpo de poke: desde su etiqueta hasta el ret
awk '/^poke:/ {on=1} on {print} on && /^ *ret/ {exit}' "$TMP/s.asm" > "$TMP/poke.asm"
echo "--- asm de poke ---"
cat "$TMP/poke.asm"
echo "-------------------"
if grep -Eq 'mov +(byte|word|dword|qword)? *\[|mov +\[' "$TMP/poke.asm"; then
    echo "gap f(x)[0]=v: poke emite un store"
else
    echo "gap f(x)[0]=v: ABIERTO, poke no emite ningun store (se descarta sin aviso)"
fi
