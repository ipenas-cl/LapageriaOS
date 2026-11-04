#!/bin/sh
# Arma un ejecutable plano AXE1 y el fuente Copihue que lo embebe.
# Uso: scripts/mkaxe.sh hola.bin hola.axe exec_img.lap [funcion]
# Sin Python: printf, od y awk. La función por defecto es exec_fill.
set -eu
fn_name=exec_fill
if [ "$#" -eq 4 ]; then
    fn_name=$4
elif [ "$#" -ne 3 ]; then
    echo "usage: mkaxe.sh payload.bin salida.axe salida.lap [funcion]" >&2
    exit 1
fi
case $fn_name in
    [A-Za-z]*) ;;
    *) echo "mkaxe: nombre de funcion invalido" >&2; exit 1 ;;
esac
case $fn_name in
    *[!A-Za-z0-9_]*) echo "mkaxe: nombre de funcion invalido" >&2; exit 1 ;;
esac
bin=$1
axe=$2
lap=$3
size=$(wc -c < "$bin")
size=$((size))
if [ "$size" -lt 1 ] || [ "$size" -gt 4080 ]; then
    echo "mkaxe: payload de $size bytes; cabe entre 1 y 4080" >&2
    exit 1
fi
{
    # magic AXE1, tamaño u32, entrada u64 = 0x400000
    printf '\101\130\105\061'
    b0=$((size & 255))
    b1=$(((size >> 8) & 255))
    b2=$(((size >> 16) & 255))
    b3=$(((size >> 24) & 255))
    o0=$(printf '%03o' "$b0")
    o1=$(printf '%03o' "$b1")
    o2=$(printf '%03o' "$b2")
    o3=$(printf '%03o' "$b3")
    printf "\\${o0}\\${o1}\\${o2}\\${o3}"
    printf '\000\000\100\000\000\000\000\000'
    cat "$bin"
} > "$axe"
total=$(wc -c < "$axe")
total=$((total))
if [ "$total" -ne $((size + 16)) ]; then
    echo "mkaxe: el axe mide $total; esperaba $((size + 16))" >&2
    exit 1
fi
magic=$(od -An -tx1 -N4 "$axe" | tr -d ' \n')
if [ "$magic" != "41584531" ]; then
    echo "mkaxe: magic $magic, no es AXE1" >&2
    exit 1
fi
{
    echo "// Generado por scripts/mkaxe.sh. No editar."
    echo "fn ${fn_name}(p: *u8) -> i64 {"
    echo "    let q: *u32 = p as *u32;"
    # De a 4 bytes (little-endian) en una sola escritura: el compilador
    # emite unos 20 bytes de código por cada asignación, y a byte por byte las
    # imágenes de usuario sumaban unos 200 KiB de kernel.
    od -An -tu1 -v "$axe" | awk '
        BEGIN { n = 0 }
        {
            for (i = 1; i <= NF; i++) {
                b[n] = $i
                n++
            }
        }
        END {
            k = 0
            for (o = 0; o + 4 <= n; o += 4) {
                printf "    q[%d] = %.0f;\n", k, b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216
                k++
            }
            for (; o < n; o++) {
                printf "    p[%d] = %d;\n", o, b[o]
            }
        }
    '
    echo "    return $total;"
    echo "}"
} > "$lap"
words=$(grep -c ' q\[' "$lap" || true)
rest=$(grep -c ' p\[' "$lap" || true)
assigns=$((words * 4 + rest))
if [ "$assigns" -ne "$total" ]; then
    echo "mkaxe: quedaron $assigns bytes en el fuente; son $total" >&2
    exit 1
fi
echo "mkaxe: $axe ($total bytes, codigo $size, entrada 0x400000)"
