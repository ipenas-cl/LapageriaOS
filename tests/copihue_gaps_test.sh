#!/bin/sh
# EX-09: comprueba en el anfitrión el comportamiento de Copihue v0.44.4 ante
# asignaciones por llamada (pedido HR-01 punto 1 de docs/PEDIDOS_COPIHUE.md,
# CERRADO en v0.44.4). Desde EX-09 es una regresión: falla si
#   - `f(x)[0] = v` o `*f(x) = v` con `-> *volatile u32` no emiten un store
#     dword (antes se descartaba sin aviso), o
#   - `f(x) = v` (no-lvalue) compila, o el error no trae archivo y línea.
# Uso: tests/copihue_gaps_test.sh /ruta/copihue
set -u
CC=${1:?usage: copihue_gaps_test.sh copihue}
D=$(dirname "$0")/copihue
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

# 1) store volatile por llamada, al ancho del pointee (dword)
if ! "$CC" --flat 0x400000 -S -o "$TMP/s.asm" "$D/storevol.lap" > "$TMP/out" 2>&1; then
    echo "FALLA storevol: el compilador rechaza: $(tr '\n' ' ' < "$TMP/out")"
    exit 1
fi
for f in poke_idx poke_deref; do
    awk -v f="$f:" '$0 == f {on=1} on {print} on && /^ *ret/ {exit}' "$TMP/s.asm" > "$TMP/$f.asm"
    echo "--- asm de $f ---"
    cat "$TMP/$f.asm"
    echo "-------------------"
    if grep -Eq 'mov +dword +\[' "$TMP/$f.asm" && grep -q 'call mem' "$TMP/$f.asm"; then
        echo "ok   $f: llama a mem y emite un store dword"
    else
        echo "FALLA $f: no emite el store dword (se descarta)"
        fail=1
    fi
done

# 2) no-lvalue: error de compilación con archivo y línea (la asignación está en la 8)
if "$CC" --flat 0x400000 -S -o "$TMP/n.asm" "$D/nolvalue.lap" > "$TMP/nout" 2>&1; then
    echo "FALLA nolvalue: f(1) = 5 compiló sin error"
    fail=1
else
    echo "salida: $(tr '\n' ' ' < "$TMP/nout")"
    if grep -q 'nolvalue.lap:8' "$TMP/nout"; then
        echo "ok   nolvalue: error con archivo y línea"
    else
        echo "FALLA nolvalue: el error no trae nolvalue.lap:8"
        fail=1
    fi
fi
exit $fail
