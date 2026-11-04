#!/usr/bin/env bash
# OB-02: la zona activa cambia en cada cambio de contexto (switch_to).
#
# `zone pair za zb par` corre dos copias del programa `par` a la vez, la
# copia 1 (pid 1) en la zona za y la 2 (pid 2) en la zb. En modo `y` cada
# copia cede la CPU 6 veces con la syscall 4 (yield): los dos procesos se
# alternan. La prueba es determinista en lo que importa:
#
#   - con zonas distintas, cada cambio de contexto cambia la zona activa:
#     el contador del kernel (chg) es igual al de cambios (n);
#   - n = yield + timer + 1 (la salida del primero con el otro vivo
#     también cambia de contexto, sin pasar por switch_to);
#   - la prueba NO depende del tiempo: el PIT puede caer en cualquier punto
#     de la corrida (en un runner lento cae varias veces) y eso solo reparte
#     los cambios entre yield y timer. Se comprueban los invariantes que
#     valen con cualquier número de ticks, contando los switch_to reales
#     (sonda switch) y no un número fijo de cesiones;
#   - las sondas `switch` y `zone-switch` lo registran: una zone-switch
#     por cambio, a == zona que sale, b == zona que entra, la zona de
#     salida de cada una es la de entrada de la anterior, el pid 1 siempre
#     sale de su zona y el 2 de la suya, y cada `switch` va seguido de su
#     zone-switch con el mismo pid;
#   - con la misma zona dos veces hay cambios pero ninguno cambia la zona
#     y no queda ninguna zone-switch;
#   - la zona global (0) contra una zona normal también se registra (a 0).
#
# El disco de datos es una copia nueva. Uso: tests/qemu_zswitch_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
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
    # QEMU_EXTRA: opciones de más, p. ej. QEMU_EXTRA="-icount shift=7" (TCG lento).
    # shellcheck disable=SC2086
    qemu-system-x86_64 -cpu qemu64 ${QEMU_EXTRA:-} -drive format=raw,file="$IMAGE" \
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
        case "$c" in " ") k=spc ;; "-") k=minus ;; "/") k=slash ;; ".") k=dot ;; "=") k=equal ;; *) k=$c ;; esac
        mon "sendkey $k"
    done
    mon "sendkey ret"
    sleep 0.3
}
prompts() { grep -c "lapageria> " "$SERIAL" 2>/dev/null || true; }
typewait() {
    local before n i
    before=$(prompts)
    typeline "$1"
    for i in $(seq "$2"); do
        n=$(prompts)
        if [ "${n:-0}" -gt "${before:-0}" ]; then return 0; fi
        sleep 0.1
    done
    fail "no prompt after: $1"
}
has() { tr -d '\r' < "$SERIAL" | grep -qx "$1"; }
# Salida de la última corrida del comando $1 (hasta el prompt siguiente).
win() {
    tr -d '\r' < "$SERIAL" | awk -v c="lapageria> $1" '
        $0 == c { buf = ""; cap = 1; next }
        cap && /^lapageria> / { cap = 0 }
        cap { buf = buf $0 "\n" }
        END { printf "%s", buf }'
}
pc() { win "trace count" | awk -v n="$1" '$1 == "probe" && $2 == n { print $3 }'; }
# Campo `name=valor` de la línea `zone pair sw ...` de la última corrida de $1.
sw() {
    win "$1" | awk -v k="$2" '/^zone pair sw / {
        for (i = 1; i <= NF; i++) { split($i, p, "="); if (p[1] == k) print p[2] } }'
}

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"

typewait "fs format" 50
typewait "zone par" 50
has "zone par plant ok" || fail "zone par"
typewait "zone create za 12" 30
typewait "zone create zb 12" 30
typewait "zone sched za" 30
typewait "zone sched zb" 30
has "zone sched ok" || fail "zone sched"
typewait "fs write /zonas/za/q y" 30
typewait "fs write /zonas/zb/q y" 30
typewait "trace on switch" 30
typewait "trace on zone-switch" 30

# pair_run za zb: una sola corrida; los invariantes no dependen de dónde cae el PIT.
pair_run() {
    local a=$1 b=$2 w
    typewait "trace clear" 30
    typewait "zone pair $a $b par" 150
    w=$(win "zone pair $a $b par")
    printf '%s\n' "$w" | grep -qx 'zone pair ok' || fail "zone pair $a $b: $(printf '%s' "$w" | tr '\n' '|')"
    printf '%s\n' "$w" | grep -q 'zone leak\|user killed' && fail "zone pair $a $b: leak o proceso muerto"
    return 0
}

# 1. Dos zonas distintas: cada cambio de contexto cambia la zona activa.
pair_run za zb
n=$(sw "zone pair za zb par" n); chg=$(sw "zone pair za zb par" chg)
y=$(sw "zone pair za zb par" yield); t=$(sw "zone pair za zb par" timer)
[ "$y" -ge 1 ] || fail "ninguna cesión (yield=$y)"
[ "$n" = $((y + t + 1)) ] || fail "n=$n, esperaba yield+timer+1 = $((y + t + 1))"
[ "$chg" = "$n" ] || fail "la zona activa no cambió en cada cambio de contexto: n=$n chg=$chg"
typewait "trace count" 30
ps=$(pc switch); pz=$(pc zone-switch)
[ "$ps" = $((y + t)) ] || fail "sonda switch=$ps, esperaba yield+timer = $((y + t))"
[ "$pz" = "$n" ] || fail "sonda zone-switch=$pz, esperaba $n"
echo "ok   zonas za/zb: yield=$y timer=$t, n=$n cambios de contexto, chg=$chg (todos cambian la zona); sondas switch=$ps zone-switch=$pz"

# 2. Las trazas registran cada cambio, en orden.
typewait "trace dump" 100
tr -d '\r' < "$SERIAL" | awk -v want_sw="$ps" -v want_zs="$pz" '
function bad(msg) { print msg > "/dev/stderr"; exit 1 }
$0 == "trace begin" { cap = 1; n = 0; next }
cap && /^trace end n / { cap = 0; total = n; next }
cap && /^t / { ev[n] = $3; pid[n] = $5; a[n] = $7; b[n] = $9; z[n] = $11; c[n] = $13; n++; next }
END {
    if (total == 0) bad("sin eventos")
    zs = 0; sw = 0; prevb = ""; lastc = 0
    for (i = 0; i < total; i++) {
        if (c[i] + 0 < lastc) bad("c baja en el evento " i)
        lastc = c[i] + 0
        if (ev[i] == "switch") {
            sw++
            if (i + 1 >= total || ev[i + 1] != "zone-switch") bad("switch " i " sin zone-switch")
            if (pid[i + 1] != pid[i]) bad("pid del zone-switch distinto del switch en " i)
        } else if (ev[i] == "zone-switch") {
            zs++
            if (a[i] == b[i]) bad("zone-switch sin cambio de zona en " i)
            if (z[i] != a[i]) bad("z != a en zone-switch " i)
            if (prevb != "" && a[i] != prevb) bad("la zona de salida " a[i] " no es la de entrada anterior " prevb)
            prevb = b[i]
            if (zs == 1 && !(a[i] == 1 && b[i] == 2 && pid[i] == 1)) bad("el primero tenía que ser pid 1, zona 1 -> 2")
            if (a[i] != pid[i]) bad("el pid " pid[i] " sale de la zona " a[i] " en " i)
            if (i == 0 || ev[i - 1] != "switch") last_alone = i
        } else bad("evento inesperado " ev[i])
    }
    if (sw != want_sw) bad("switch=" sw ", esperaba " want_sw)
    if (zs != want_zs) bad("zone-switch=" zs ", esperaba " want_zs)
    if (last_alone != total - 1) bad("la salida (zone-switch sin switch) tenía que ser la última")
    printf "%d switch, %d zone-switch, la salida al final\n", sw, zs
}' > "$TMP/ring.out" 2> "$TMP/ring.err" || fail "anillo: $(cat "$TMP/ring.err")"
echo "ok   trazas: $(cat "$TMP/ring.out"); cadena de zonas continua, cada switch con su zone-switch del mismo pid, c no baja"

# 3. La misma zona dos veces: hay cambios de contexto, ninguno cambia la zona.
pair_run za za
n=$(sw "zone pair za za par" n); chg=$(sw "zone pair za za par" chg)
y=$(sw "zone pair za za par" yield); t=$(sw "zone pair za za par" timer)
[ "$n" = $((y + t + 1)) ] && [ "$chg" = 0 ] || fail "za za: n=$n chg=$chg yield=$y timer=$t, esperaba n=yield+timer+1 y chg=0"
typewait "trace count" 30
pz=$(pc zone-switch); ps=$(pc switch)
[ "$ps" = $((y + t)) ] && [ "$pz" = 0 ] || fail "za za: switch=$ps zone-switch=$pz, esperaba $((y + t)) y 0"
echo "ok   misma zona: n=$n cambios de contexto (yield=$y timer=$t), chg=0 y ninguna zone-switch (switch=$ps)"

# 4. La zona global contra una zona: el pid 1 (zona 0) sale con a 0 y el
# pid 2 (zona 2) con b 0.
pair_run global zb
n=$(sw "zone pair global zb par" n); chg=$(sw "zone pair global zb par" chg)
y=$(sw "zone pair global zb par" yield); t=$(sw "zone pair global zb par" timer)
[ "$n" = $((y + t + 1)) ] && [ "$chg" = "$n" ] || fail "global zb: n=$n chg=$chg yield=$y timer=$t, esperaba n=yield+timer+1 y chg=n"
# Quién sale primero depende del reloj: la última zone-switch es la salida
# de uno de los dos (pid 1 de la zona 0, o pid 2 de la zona 2).
typewait "trace dump 1" 60
l=$(win "trace dump 1" | grep '^t ')
printf '%s\n' "$l" | grep -qE ' zone-switch pid (1 a 0 b 2 z 0|2 a 2 b 0 z 2) c [0-9]*$' || fail "global zb: la última zone-switch (una salida) tenía que ser pid 1 a 0 b 2 o pid 2 a 2 b 0: $l"
typewait "trace dump" 100
win "trace dump" | grep -qE ' zone-switch pid 1 a 0 b 2 z 0 c [0-9]*$' || fail "global zb: falta una salida de la zona 0 a la 2 (pid 1, a 0 b 2)"
win "trace dump" | grep -qE ' zone-switch pid 2 a 2 b 0 z 2 c [0-9]*$' || fail "global zb: falta la vuelta del pid 2 a la zona 0 (a 2 b 0)"
echo "ok   global/zb: $n de $n cambios cambian la zona (0 -> 2 ... 2 -> 0; yield=$y timer=$t), registrados con a 0 y b 0"

typewait "zone ls" 30
win "zone ls" | grep -q '^zone 1 za root=/zonas/za .* proc=0/2 pag=0 ' || fail "zona za quedó con procesos o páginas: $(win 'zone ls' | tr '\n' '|')"
win "zone ls" | grep -q '^zone 2 zb root=/zonas/zb .* proc=0/2 pag=0 ' || fail "zona zb quedó con procesos o páginas"
typewait "echo vivo" 30
has "vivo" || fail "el shell no respondió"
echo "ok   zonas sin procesos ni páginas al terminar, shell vivo"
