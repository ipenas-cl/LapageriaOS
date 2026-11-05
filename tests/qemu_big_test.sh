#!/usr/bin/env bash
# EX-01: programas de modo usuario de más de una página (AXE2).
#
# `exec bigplant` escribe en el disco `grande`: un AXE2 con 3 páginas de
# imagen (código, y dos con un patrón que el programa conoce) más una de bss.
# Todo corre en anillo 3:
#
#   exec grande      lee las páginas 2 y 3, comprueba la de bss en cero, escribe
#                    en la segunda, en el final de la tercera y en la de bss, las
#                    lee de vuelta, y usa la syscall 6/7 con el nombre y los datos
#                    en la página de E/S nueva (0x410800 / 0x410C00): `big ok`.
#                    Al salir devuelve las 10 páginas (`freed=10`).
#   exec grandew     el mismo archivo con 2 páginas de texto: la escritura en la
#                    segunda cae en una página de solo lectura y el kernel mata
#                    al proceso (#PF de escritura, err 7). No hay `big ok`.
#   exec gbad1..4    cabeceras malas (memoria > 64 KiB, texto 0, entrada fuera del
#                    texto, tamaño más largo que el archivo): el shell sigue.
#   exec2 grande hola  un AXE2 y un AXE1 a la vez (cada uno con su ranura).
#   zone exec g grande en una zona con cupo suficiente y sin fugas; en una zona
#                    de 8 páginas, `zone fail 6` sin quedar nada tomado.
#
# La salida de anillo 3 va por líneas enteras, así que `grep -x` no se rompe
# si dos procesos imprimen a la vez. Nada de la prueba depende del reloj: cada
# paso espera el prompt siguiente o una línea de la serie.
# El disco de datos y la imagen son copias nuevas en el directorio temporal
# (varias corridas a la vez); QEMU_EXTRA="-icount shift=7" suma opciones a QEMU.
# Uso: tests/qemu_big_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
BOOT=$TMP/boot.img
cp "$IMAGE" "$BOOT"
QPID=""
SECTORS=$(( $(wc -c < "$DATA_SRC") / 512 ))
dd if=/dev/zero of="$DATA" bs=512 count="$SECTORS" status=none

stop_qemu() {
    if [ -n "${QPID:-}" ] && kill -0 "$QPID" 2>/dev/null; then
        echo quit | socat - UNIX-CONNECT:"$MON" >/dev/null 2>&1 || true
        local i
        for i in $(seq 50); do
            if ! kill -0 "$QPID" 2>/dev/null; then
                wait "$QPID" 2>/dev/null || true
                QPID=""
                return 0
            fi
            sleep 0.1
        done
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
        QPID=""
    fi
}
trap 'stop_qemu; rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*"
    echo "--- serial ---"
    tr -d '\r' < "$SERIAL" 2>/dev/null | tail -80 || true
    exit 1
}

start_qemu() {
    : > "$SERIAL"
    rm -f "$MON"
    # shellcheck disable=SC2086
    qemu-system-x86_64 -cpu qemu64 ${QEMU_EXTRA:-} -drive format=raw,file="$BOOT" \
        -drive file="$DATA",format=raw,if=ide,index=1 \
        -display none -no-reboot \
        -serial file:"$SERIAL" -monitor unix:"$MON",server,nowait &
    QPID=$!
    sleep 0.5
    kill -0 "$QPID" 2>/dev/null || fail "qemu did not start"
}

mon() { echo "$1" | socat - UNIX-CONNECT:"$MON" >/dev/null; }
typeline() {
    local s=$1 i c k
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in " ") k=spc ;; "-") k=minus ;; "/") k=slash ;; *) k=$c ;; esac
        mon "sendkey $k"
    done
    mon "sendkey ret"
    sleep 0.3
}
prompts() { grep -c "lapageria> " "$SERIAL" 2>/dev/null || true; }
# Escribe el comando y espera el prompt siguiente (décimas de segundo).
typewait() {
    local before n i
    before=$(prompts)
    typeline "$1"
    for i in $(seq "${2:-300}"); do
        n=$(prompts)
        if [ "${n:-0}" -gt "${before:-0}" ]; then return 0; fi
        sleep 0.1
    done
    fail "no prompt after: $1"
}
has() { tr -d '\r' < "$SERIAL" | grep -qx "$1"; }
count() { tr -d '\r' < "$SERIAL" | grep -cx "$1" || true; }
# Lo que salió desde el último comando `$1` (la última aparición).
since() { tr -d '\r' < "$SERIAL" | awk -v c="lapageria> $1" '$0 == c { buf = "" ; next } { buf = buf $0 "\n" } END { printf "%s", buf }'; }

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"

typewait "fs format" 100
typewait "exec bigplant" 300
has "exec big plant ok" || fail "exec bigplant: $(since 'exec bigplant')"
typewait "fs ls" 100
tr -d '\r' < "$SERIAL" | grep -q "grande" || fail "fs ls no muestra grande"
echo "ok   exec bigplant: grande, grandew y 4 cabeceras malas en el disco"

# 1. El programa de 4 páginas corre en anillo 3, lee y escribe sus páginas.
typewait "exec grande" 600
out=$(since "exec grande")
printf '%s\n' "$out" | grep -qx "big ok" || fail "exec grande: $out"
printf '%s\n' "$out" | grep -qx "exit pid=1 freed=10" || fail "exec grande no devolvió las 10 páginas: $out"
printf '%s\n' "$out" | grep -qx "exec ok" || fail "exec grande no terminó: $out"
printf '%s\n' "$out" | grep -q "user killed" && fail "exec grande: lo mataron: $out"
echo "ok   exec grande: imagen de 3 páginas + bss en anillo 3, lee y escribe la segunda, E/S en 0x410800, freed=10"
typewait "fs cat gdat" 100
since "fs cat gdat" | grep -qx "fs live big" || fail "gdat: $(since 'fs cat gdat')"
echo "ok   la syscall 6 con la página de E/S nueva dejó gdat = big"

# 2. Texto de 2 páginas: la segunda es de solo lectura.
typewait "exec grandew" 600
out=$(since "exec grandew")
printf '%s\n' "$out" | grep -q "user killed pid=1 vec=14 err=0x00000007 addr=0x0000000000401000" \
    || printf '%s\n' "$out" | grep -q "user killed pid=1 vec=14 err=0x7 addr=0x401000" \
    || fail "exec grandew: esperaba #PF de escritura en 0x401000: $out"
printf '%s\n' "$out" | grep -qx "big ok" && fail "exec grandew llegó a big ok: $out"
printf '%s\n' "$out" | grep -qx "exec ok" || fail "exec grandew: el shell no volvió: $out"
echo "ok   exec grandew: escribir en una página de texto mata solo al proceso (#PF de escritura)"

# 3. Cabeceras malas.
typewait "exec gbad1" 300
since "exec gbad1" | grep -qx "exec bad size" || fail "gbad1 (memoria > 64 KiB): $(since 'exec gbad1')"
typewait "exec gbad2" 300
since "exec gbad2" | grep -qx "exec bad size" || fail "gbad2 (texto 0): $(since 'exec gbad2')"
typewait "exec gbad3" 300
since "exec gbad3" | grep -qx "exec bad entry" || fail "gbad3 (entrada en datos): $(since 'exec gbad3')"
typewait "exec gbad4" 300
since "exec gbad4" | grep -qx "exec bad size" || fail "gbad4 (archivo corto): $(since 'exec gbad4')"
echo "ok   cabeceras AXE2 malas: bad size x3, bad entry; el shell sigue"

# 4. Un AXE2 y un AXE1 a la vez.
typewait "exec plant" 300
typewait "exec2 grande hola" 900
out=$(since "exec2 grande hola")
printf '%s\n' "$out" | grep -qx "big ok" || fail "exec2: grande no dijo big ok: $out"
printf '%s\n' "$out" | grep -qx "desde disco" || fail "exec2: hola no dijo desde disco: $out"
printf '%s\n' "$out" | grep -qx "exit pid=1 freed=10" || fail "exec2: pid 1 (grande) no devolvió 10: $out"
printf '%s\n' "$out" | grep -qx "exit pid=2 freed=6" || fail "exec2: pid 2 (hola) no devolvió 6: $out"
printf '%s\n' "$out" | grep -qx "exec2 ok" || fail "exec2 no terminó: $out"
echo "ok   exec2 grande hola: AXE2 y AXE1 a la vez, 10 y 6 páginas devueltas"

# 5. Zonas: cupo y fugas.
typewait "zone create g 16" 200
typewait "zone exec g grande" 900
out=$(since "zone exec g grande")
printf '%s\n' "$out" | grep -qx "big ok" || fail "zone exec g grande: $out"
printf '%s\n' "$out" | grep -qx "zone used 10" || fail "zone used: esperaba 10 páginas: $out"
printf '%s\n' "$out" | grep -qx "zone exec ok" || fail "zone exec g grande no terminó sin fugas: $out"
printf '%s\n' "$out" | grep -qx "zone leak" && fail "zone leak: $out"
typewait "fs cat /zonas/g/gdat" 100
since "fs cat /zonas/g/gdat" | grep -qx "fs live big" || fail "gdat de la zona: $(since 'fs cat /zonas/g/gdat')"
echo "ok   zone exec g grande: cupo 16, sin fugas, el archivo cae en la raíz de la zona"
typewait "zone create s 8" 200
typewait "zone exec s grande" 600
out=$(since "zone exec s grande")
printf '%s\n' "$out" | grep -qx "zone fail 6" || fail "zone s (8 páginas) debía dar zone fail 6: $out"
printf '%s\n' "$out" | grep -qx "big ok" && fail "zone s corrió con 8 páginas: $out"
typewait "zone ls" 100
tr -d '\r' < "$SERIAL" | grep -E '^zone [0-9]+ s root=' | tail -1 | grep -q "pag=0 " || fail "zone s quedó con páginas tomadas: $(since 'zone ls')"
echo "ok   zona de 8 páginas: zone fail 6 y pag=0 (nada tomado)"

# 6. Todo sigue en pie.
typewait "exec grande" 600
[ "$(count 'big ok')" -ge 4 ] || fail "exec grande otra vez: big ok x$(count 'big ok')"
typewait "echo vivo" 50
has "vivo" || fail "el shell no respondió"
echo "ok   las páginas se reciclan: exec grande otra vez, shell vivo"
