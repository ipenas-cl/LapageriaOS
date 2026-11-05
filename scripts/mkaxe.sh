#!/bin/sh
# Arma un ejecutable plano (AXE1 o AXE2) y el fuente Copihue que lo embebe.
# Uso: scripts/mkaxe.sh [-d datos.bin] [-b bss] payload.bin salida.axe salida.lap [funcion]
#      scripts/mkaxe.sh -a entrada.axe salida.lap [funcion]
# Sin Python: printf, od, head y awk. La función por defecto es exec_fill.
#
# EX-05, -a: entrada.axe es un AXE2 que armó el compilador
# (`copihue --flat 0x400000 --axe2`, Copihue v0.44.1): cabecera, texto, datos y
# bss ya están hechos. mkaxe.sh no arma nada: comprueba la cabecera (magic,
# imagen = archivo - 32, texto, memoria, reservado en cero, entrada dentro del
# texto) y deja el .lap que lo embebe, con la misma comprobación de abajo. Es el
# camino de los programas con datos y bss; sin -a se arma a mano, como antes
# (AXE1, y AXE2 con un compilador sin --axe2).
#
# Sin opciones y con un payload de 1 a 4080 bytes sale un AXE1 (16 bytes de
# cabecera, una página de código), igual que siempre. Sale un AXE2 (32 bytes
# de cabecera, de 1 a 16 páginas; docs/exec.md) si el payload pasa de 4080
# bytes o si se pide -d o -b:
#   payload.bin  el texto (código). Queda al principio de la imagen, de solo
#                lectura y ejecutable; se rellena con ceros hasta la página.
#   -d datos.bin los datos iniciales (lectura y escritura, sin ejecución):
#                empiezan en la primera página después del texto.
#   -b bss       bytes en cero después de los datos (o del texto, si no hay
#                datos), sin archivo. Lectura y escritura, sin ejecución.
# La imagen entera (texto + relleno + datos + bss) no puede pasar de 64 KiB.
# El fuente .lap de un AXE2 pone el buffer en cero y solo escribe las
# palabras que no son cero: las páginas de datos casi vacías cuestan poco
# código en el kernel (unos 5 bytes por palabra no nula).
set -eu
usage() {
    echo "usage: mkaxe.sh [-d datos.bin] [-b bss] payload.bin salida.axe salida.lap [funcion]" >&2
    echo "       mkaxe.sh -a entrada.axe salida.lap [funcion]" >&2
    exit 1
}
dat=""
bss=""
from_cc=0
while getopts "ad:b:" opt; do
    case $opt in
        a) from_cc=1 ;;
        d) dat=$OPTARG ;;
        b) bss=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
if [ "$from_cc" -eq 1 ]; then
    # entrada.axe salida.lap [funcion]: se completa como si fueran 4 argumentos
    [ -z "$dat" ] && [ -z "$bss" ] || usage
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage
    set -- "$1" "$1" "$2" ${3:+"$3"}
fi
fn_name=exec_fill
if [ "$#" -eq 4 ]; then
    fn_name=$4
elif [ "$#" -ne 3 ]; then
    usage
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
if [ "$from_cc" -eq 0 ]; then
    size=$(wc -c < "$bin")
    size=$((size))
    dsz=0
    if [ -n "$dat" ]; then
        [ -f "$dat" ] || { echo "mkaxe: no hay archivo de datos $dat" >&2; exit 1; }
        dsz=$(wc -c < "$dat")
        dsz=$((dsz))
        if [ "$dsz" -lt 1 ]; then
            echo "mkaxe: el archivo de datos esta vacio (use -b para bss)" >&2
            exit 1
        fi
    fi
    bsz=0
    if [ -n "$bss" ]; then
        case $bss in
            *[!0-9]*|"") echo "mkaxe: bss invalido: $bss" >&2; exit 1 ;;
        esac
        bsz=$((bss))
    fi

    # octal de un byte, y u32 little-endian como cuatro escapes de printf
    oct() { printf '%03o' "$1"; }
    le32() {
        printf "\\$(oct $(($1 & 255)))\\$(oct $((($1 >> 8) & 255)))\\$(oct $((($1 >> 16) & 255)))\\$(oct $((($1 >> 24) & 255)))"
    }

    kind=1
    if [ "$size" -gt 4080 ] || [ -n "$dat" ] || [ -n "$bss" ]; then
        kind=2
    fi

    if [ "$kind" -eq 1 ]; then
        if [ "$size" -lt 1 ] || [ "$size" -gt 4080 ]; then
            echo "mkaxe: payload de $size bytes; cabe entre 1 y 4080" >&2
            exit 1
        fi
        {
            # magic AXE1, tamaño u32, entrada u64 = 0x400000
            printf '\101\130\105\061'
            le32 "$size"
            printf '\000\000\100\000\000\000\000\000'
            cat "$bin"
        } > "$axe"
        hdr=16
        img=$size
        magic_want=41584531
    else
        if [ "$size" -lt 1 ] || [ "$size" -gt 65536 ]; then
            echo "mkaxe: texto de $size bytes; cabe entre 1 y 65536" >&2
            exit 1
        fi
        tpad=$(((size + 4095) / 4096 * 4096))
        # bytes de imagen en el archivo, y tamaño en memoria (con la bss)
        if [ "$dsz" -gt 0 ]; then
            img=$((tpad + dsz))
            mem=$((tpad + dsz + bsz))
        elif [ "$bsz" -gt 0 ]; then
            # la bss no puede compartir página con el texto (solo lectura)
            img=$size
            mem=$((tpad + bsz))
        else
            img=$size
            mem=$size
        fi
        pages=$(((mem + 4095) / 4096))
        if [ "$img" -gt 65536 ] || [ "$mem" -gt 65536 ] || [ "$pages" -lt 1 ] || [ "$pages" -gt 16 ]; then
            echo "mkaxe: imagen de $img bytes, memoria de $mem ($pages paginas); el maximo es 65536 (16 paginas)" >&2
            exit 1
        fi
        {
            # magic AXE2, bytes de imagen, entrada u64 = 0x400000, texto,
            # tamaño en memoria, 8 bytes reservados en cero
            printf '\101\130\105\062'
            le32 "$img"
            printf '\000\000\100\000\000\000\000\000'
            le32 "$size"
            le32 "$mem"
            printf '\000\000\000\000\000\000\000\000'
            cat "$bin"
            if [ "$dsz" -gt 0 ]; then
                pad=$((tpad - size))
                if [ "$pad" -gt 0 ]; then
                    head -c "$pad" /dev/zero
                fi
                cat "$dat"
            fi
        } > "$axe"
        hdr=32
        magic_want=41584532
    fi
else
    # EX-05: AXE2 del compilador. Se lee la cabecera tal como salió.
    [ -f "$axe" ] || { echo "mkaxe: no hay archivo $axe" >&2; exit 1; }
    kind=2
    hdr=32
    magic_want=41584532
    total=$(wc -c < "$axe")
    total=$((total))
    [ "$total" -gt 32 ] || { echo "mkaxe: $axe mide $total; no tiene cabecera AXE2 e imagen" >&2; exit 1; }
    u32() {
        set -- $(od -An -tu1 -v -j "$2" -N4 "$1")
        echo $(($1 + $2 * 256 + $3 * 65536 + $4 * 16777216))
    }
    magic=$(od -An -tx1 -N4 "$axe" | tr -d ' \n')
    [ "$magic" = "$magic_want" ] || { echo "mkaxe: magic $magic, esperaba $magic_want" >&2; exit 1; }
    img=$(u32 "$axe" 4)
    entry=$(u32 "$axe" 8)
    entry_hi=$(u32 "$axe" 12)
    size=$(u32 "$axe" 16)
    mem=$(u32 "$axe" 20)
    rsv=$(( $(u32 "$axe" 24) + $(u32 "$axe" 28) ))
    [ "$entry_hi" -eq 0 ] && [ "$rsv" -eq 0 ] || { echo "mkaxe: $axe: entrada alta o reservado distintos de cero" >&2; exit 1; }
    [ "$img" -ge 1 ] && [ "$img" -le 65536 ] && [ "$total" -eq $((img + 32)) ] || { echo "mkaxe: $axe: imagen de $img bytes con archivo de $total" >&2; exit 1; }
    [ "$size" -ge 1 ] && [ "$size" -le "$img" ] || { echo "mkaxe: $axe: texto de $size con imagen de $img" >&2; exit 1; }
    [ "$mem" -ge "$img" ] && [ "$mem" -le 65536 ] || { echo "mkaxe: $axe: memoria de $mem con imagen de $img" >&2; exit 1; }
    # La entrada es la dirección virtual de _start, absoluta (0x400000 + el
    # desplazamiento): tiene que caer en el texto.
    [ "$entry" -ge 4194304 ] && [ "$entry" -lt $((4194304 + size)) ] || { echo "mkaxe: $axe: entrada $entry fuera del texto" >&2; exit 1; }
    pages=$(((mem + 4095) / 4096))
fi
total=$(wc -c < "$axe")
total=$((total))
if [ "$total" -ne $((img + hdr)) ]; then
    echo "mkaxe: el axe mide $total; esperaba $((img + hdr))" >&2
    exit 1
fi
magic=$(od -An -tx1 -N4 "$axe" | tr -d ' \n')
if [ "$magic" != "$magic_want" ]; then
    echo "mkaxe: magic $magic, esperaba $magic_want" >&2
    exit 1
fi
{
    echo "// Generado por scripts/mkaxe.sh. No editar."
    echo "fn ${fn_name}(p: *u8) -> i64 {"
    if [ "$kind" -eq 2 ]; then
        # El que llama no garantiza un buffer en cero: se limpia entero y
        # después solo se escriben las palabras no nulas.
        echo "    let z: i64 = 0;"
        echo "    while (z < $total) {"
        echo "        p[z] = 0;"
        echo "        z = z + 1;"
        echo "    }"
    fi
    echo "    let q: *u32 = p as *u32;"
    # De a 4 bytes (little-endian) en una sola escritura: el compilador
    # emite unos 20 bytes de código por cada asignación, y a byte por byte las
    # imágenes de usuario sumaban unos 200 KiB de kernel.
    od -An -tu1 -v "$axe" | awk -v skip="$([ "$kind" -eq 2 ] && echo 1 || echo 0)" '
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
                v = b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216
                if (!(skip && v == 0)) {
                    printf "    q[%d] = %.0f;\n", k, v
                }
                k++
            }
            for (; o < n; o++) {
                if (!(skip && b[o] == 0)) {
                    printf "    p[%d] = %d;\n", o, b[o]
                }
            }
        }
    '
    echo "    return $total;"
    echo "}"
} > "$lap"
# Se vuelve a armar el archivo desde el fuente (las palabras no escritas
# valen cero) y se compara byte por byte con el .axe.
want=$(od -An -tu1 -v "$axe" | tr -s ' \n' '  ' | sed 's/^ //; s/ $//')
got=$(awk -v total="$total" '
    / q\[[0-9]+\] = [0-9]+;$/ {
        s = $0; sub(/^.*q\[/, "", s); k = s + 0
        sub(/^[0-9]+\] = /, "", s); v = s + 0
        for (j = 0; j < 4; j++) { b[k * 4 + j] = v % 256; v = int(v / 256) }
    }
    / p\[[0-9]+\] = [0-9]+;$/ {
        s = $0; sub(/^.*p\[/, "", s); o = s + 0
        sub(/^[0-9]+\] = /, "", s); b[o] = s + 0
    }
    END {
        out = ""
        for (i = 0; i < total; i++) {
            out = out (i ? " " : "") (i in b ? b[i] : 0)
        }
        print out
    }
' "$lap")
if [ "$got" != "$want" ]; then
    echo "mkaxe: el fuente $lap no reproduce el axe" >&2
    exit 1
fi
if [ "$kind" -eq 1 ]; then
    echo "mkaxe: $axe ($total bytes, codigo $size, entrada 0x400000)"
else
    nz=$(grep -c ' [qp]\[' "$lap" || true)
    echo "mkaxe: $axe (AXE2, $total bytes, texto $size, imagen $img, memoria $mem, $pages paginas, entrada $(printf '0x%x' "${entry:-4194304}"), $nz escrituras)"
fi
