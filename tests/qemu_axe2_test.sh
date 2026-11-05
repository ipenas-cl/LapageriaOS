#!/usr/bin/env bash
# EX-02: AXE2 armado por scripts/mkaxe.sh (texto, datos y bss) y ataques de
# anillo 3 contra un AXE2.
#
# `exec axe2plant` escribe en el disco `pag2`: lo que mkaxe.sh empacó de
# src/user/pag2.lap (1 página de texto) + build/pag2.dat (1 página de datos con
# marcadores) + 1 página de bss. Todo corre en anillo 3:
#
#   exec pag2        lee los marcadores de la segunda página (que vienen del
#                    archivo), la escribe entera y la lee de vuelta, comprueba
#                    la bss en cero, la escribe y usa la página de E/S en
#                    0x410000: `pag2 ok`. Al salir devuelve sus páginas.
#   zone exec        el mismo programa en una zona con cupo justo y en una sin
#                    cupo (`zone fail 6`, nada tomado).
#
# La salida de anillo 3 va por líneas enteras, así que `grep -x` no se rompe.
# Nada de la prueba depende del reloj: cada paso espera el prompt siguiente.
# El disco de datos y la imagen son copias nuevas en el directorio temporal;
# QEMU_EXTRA="-icount shift=7" suma opciones a QEMU.
# Uso: tests/qemu_axe2_test.sh [imagen]
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
typewait "exec axe2plant" 400
has "exec axe2 plant ok" || fail "exec axe2plant: $(since 'exec axe2plant')"
typewait "fs ls" 100
tr -d '\r' < "$SERIAL" | grep -q "pag2" || fail "fs ls no muestra pag2"
echo "ok   exec axe2plant: pag2 (AXE2 de mkaxe.sh: texto + datos + bss) en el disco"

# 1. El programa de 3 páginas corre en anillo 3 y usa su segunda página.
typewait "exec pag2" 600
out=$(since "exec pag2")
printf '%s\n' "$out" | grep -qx "pag2 ok" || fail "exec pag2: $out"
printf '%s\n' "$out" | grep -qx "exit pid=1 freed=9" || fail "exec pag2 no devolvió las 9 páginas: $out"
printf '%s\n' "$out" | grep -qx "exec ok" || fail "exec pag2 no terminó: $out"
printf '%s\n' "$out" | grep -q "user killed" && fail "exec pag2: lo mataron: $out"
echo "ok   exec pag2: AXE2 de mkaxe.sh, lee los marcadores del archivo, escribe su segunda página y la bss, E/S en 0x410000, freed=9"

# 2. Se recicla: otra vez, y el shell sigue vivo.
typewait "exec pag2" 600
[ "$(count 'pag2 ok')" -ge 2 ] || fail "exec pag2 otra vez: pag2 ok x$(count 'pag2 ok')"
typewait "echo vivo" 50
has "vivo" || fail "el shell no respondió"
echo "ok   las páginas se reciclan: exec pag2 otra vez, shell vivo"

# 3. Zonas: cupo justo (9) y cupo corto (8).
typewait "zone create p 9" 200
typewait "zone exec p pag2" 900
out=$(since "zone exec p pag2")
printf '%s\n' "$out" | grep -qx "pag2 ok" || fail "zone exec p pag2: $out"
printf '%s\n' "$out" | grep -qx "zone used 9" || fail "zone used: esperaba 9 páginas: $out"
printf '%s\n' "$out" | grep -qx "zone exec ok" || fail "zone exec p pag2 no terminó sin fugas: $out"
printf '%s\n' "$out" | grep -qx "zone leak" && fail "zone leak: $out"
typewait "zone create s 8" 200
typewait "zone exec s pag2" 600
out=$(since "zone exec s pag2")
printf '%s\n' "$out" | grep -qx "zone fail 6" || fail "zone s (8 páginas) debía dar zone fail 6: $out"
printf '%s\n' "$out" | grep -qx "pag2 ok" && fail "zone s corrió con 8 páginas: $out"
typewait "zone ls" 100
tr -d '\r' < "$SERIAL" | grep -E '^zone [0-9]+ s root=' | tail -1 | grep -q "pag=0 " || fail "zone s quedó con páginas tomadas: $(since 'zone ls')"
echo "ok   zona de 9 páginas: pag2 corre sin fugas; zona de 8: zone fail 6 y pag=0"
