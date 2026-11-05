#!/bin/sh
# EX-05: compara la salida de `copihue --flat 0x400000 --axe2 --sizes` con lo
# que el programa espera. Uso: scripts/chksizes.sh archivo.sizes clave=valor ...
# Las claves son las de --sizes: text, data, bss, text_bytes, image, memsize,
# entry. Cada una tiene que aparecer en el archivo, una por línea, con ese valor.
set -eu
[ "$#" -ge 2 ] || { echo "usage: chksizes.sh archivo.sizes clave=valor ..." >&2; exit 1; }
f=$1
shift
rc=0
for kv in "$@"; do
    if ! grep -qx "$kv" "$f"; then
        echo "chksizes: $f: esperaba $kv, hay: $(tr '\n' ' ' < "$f")" >&2
        rc=1
    fi
done
exit $rc
