#!/usr/bin/env bash
# EX-05: pérdida de varios segmentos dentro de una misma ráfaga de TCP, con
# tráfico real de QEMU, en su propio QEMU.
#
# Igual que tests/qemu_fast_test.sh, el invitado envía (tcpsnd: 32768 bytes en
# 128 trozos de 256 a un socat del host por hostfwd) y su propio TCP se come
# segmentos con datos (`tcp fault txdrop K C [G]`). Cinco corridas seguidas en
# la misma máquina, cada una con `exec tcpsnd` nuevo:
#
#   base   sin pérdida: mide cuántos segmentos con datos salen (`tcp fault
#          left`) y exige fast +0, rtos +0, retx +0, fdrop +0.
#   par    `txdrop 20 2`: dos segmentos seguidos. Quedan ~14 en vuelo detrás
#          del hueco: 3 ACK repetidos y retransmisión rápida sin esperar al
#          timer. Un reenvío manda hasta un MSS (1460 bytes, unos 5 trozos de
#          256) de datos contiguos, así que uno solo cubre los dos huecos.
#   sep    `txdrop 20 1 4`: el 20 y el 24, separados por 3 segmentos que llegan
#          (a menos de un MSS). Con ACK rápidos (-icount) el 24 sale ya en
#          recuperación y hay una segunda recuperación rápida: fast +1 o +2.
#   tanda  `txdrop 40 4`: cuatro seguidos (un reenvío).
#   lejos  `txdrop 20 1 10`: el 20 y otro diez emisiones después, a más de un
#          MSS. El segundo hueco es de un segmento que sale ya en recuperación:
#          hace falta otro reenvío (retx +2) y puede entrar otra vez en
#          recuperación rápida (fast +1 o +2), pero nunca por el timer.
#   cola   los dos últimos segmentos de la ráfaga: detrás del hueco no sale
#          nada con datos, así que no hay 3 ACK repetidos y la recuperación
#          TIENE que ser por el timer (fast +0, rtos >= 1). Es el caso en que
#          la retransmisión rápida no corresponde.
#
# Qué se exige en cada corrida (nada de esto es un umbral que se pueda aflojar,
# salvo que el caso diga otra cosa):
#   - los 32768 bytes llegan al host en orden y completos (patrón (i*7+3)&255,
#     y la misma suma que contó el invitado);
#   - `tcp stat`: fdrop = segmentos perdidos; en par, sep y tanda `fast +1`,
#     `rtos +0` y `retx` = segmentos perdidos (cada hueco se reenvía una vez);
#   - trazas: tantos `tcp-retx` como retx y todos con b=0 (ninguno es un
#     vencimiento del timer, que sube tc_nre antes de reenviar).
#
# Sirve con QEMU_EXTRA="-icount shift=7" y sin icount (tests/repeat.sh).
# Uso: tests/qemu_burst_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
BOOT=$TMP/boot.img
cp "$IMAGE" "$BOOT"
QPID=""
HPORT=0
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

# Puerto al azar; si está ocupado QEMU no arranca y se prueba otro.
start_qemu() {
    local try
    for try in 1 2 3 4 5 6; do
        HPORT=$((20000 + RANDOM % 20000))
        : > "$SERIAL"
        rm -f "$MON"
        # shellcheck disable=SC2086
        qemu-system-x86_64 -cpu qemu64 ${QEMU_EXTRA:-} -drive format=raw,file="$BOOT" \
            -drive file="$DATA",format=raw,if=ide,index=1 \
            -display none -no-reboot \
            -nic none -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$HPORT-:7005" \
            -device e1000,netdev=n0 \
            -serial file:"$SERIAL" -monitor unix:"$MON",server,nowait &
        QPID=$!
        sleep 0.5
        if kill -0 "$QPID" 2>/dev/null; then return 0; fi
        wait "$QPID" 2>/dev/null || true
        QPID=""
    done
    fail "qemu did not start (hostfwd o disco)"
}

mon() { echo "$1" | socat - UNIX-CONNECT:"$MON" >/dev/null; }
typeline() {
    local s=$1 i c k
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in " ") k=spc ;; "-") k=minus ;; *) k=$c ;; esac
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
    for i in $(seq "${2:-100}"); do
        n=$(prompts)
        if [ "${n:-0}" -gt "${before:-0}" ]; then return 0; fi
        sleep 0.1
    done
    fail "no prompt after: $1"
}
count() { tr -d '\r' < "$SERIAL" | grep -cx "$1" || true; }
waitcount() {
    local want=$1 n=$2 i
    for i in $(seq "$3"); do
        if [ "$(count "$want")" -ge "$n" ]; then return 0; fi
        sleep 0.1
    done
    fail "no $n lines '$want' (hay $(count "$want"))"
}
has() { tr -d '\r' < "$SERIAL" | grep -qx "$1"; }
tcp_field() {
    tr -d '\r' < "$SERIAL" | grep '^tcp rx ' | tail -1 | tr ' ' '\n' | grep -A1 -x "$1" | tail -1
}
bytesum() { od -An -v -tu1 "$1" | awk '{for (i = 1; i <= NF; i++) s += $i} END {print s + 0}'; }

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"

typewait "fs format" 50
typewait "tcp plant" 80
has "tcp plant ok" || fail "tcp plant"
typewait "net up" 150
has "net up ok" || fail "net up"
typewait "trace on tcp-retx" 30

runs=0
faults=0
# send_run: una corrida de tcpsnd (el host lee los 32768 bytes) y espera a que
# el invitado cierre su conexión. Deja los bytes del host en $TMP/snd.out.
send_run() {
    local size line hsum i
    runs=$((runs + 1))
    typeline "exec tcpsnd"
    waitcount "tcp listen" "$runs" 150
    "$SOCAT" -u -t30 TCP:127.0.0.1:"$HPORT" - > "$TMP/snd.out" 2> "$TMP/snd.err"
    size=$(wc -c < "$TMP/snd.out" | tr -d ' ')
    [ "$size" = 32768 ] || fail "[$CASE] el host recibió $size bytes, esperaba 32768 $(cat "$TMP/snd.err")"
    od -An -v -tu1 "$TMP/snd.out" | awk 'BEGIN {n = 0; bad = 0} {for (i = 1; i <= NF; i++) {if ($i != (n * 7 + 3) % 256) bad++; n++}} END {exit (bad == 0 && n == 32768) ? 0 : 1}' || fail "[$CASE] los bytes que llegaron al host no siguen el patrón (perdidos, repetidos o fuera de orden)"
    hsum=$(bytesum "$TMP/snd.out")
    for i in $(seq 150); do
        [ "$(count "tcp snd n=32768 sum=$hsum")" -ge "$runs" ] && break
        sleep 0.1
    done
    [ "$(count "tcp snd n=32768 sum=$hsum")" -ge "$runs" ] || fail "[$CASE] el invitado no contó n=32768 sum=$hsum"
    # Que la conexión termine sola (FIN de los dos lados) antes de leer contadores.
    for i in $(seq 100); do
        typewait "tcp stat" 30
        [ "$(tcp_field used)" = 0 ] && break
        sleep 0.5
    done
    [ "$(tcp_field used)" = 0 ] || fail "[$CASE] la conexión no se cerró (used $(tcp_field used))"
}

snap() {
    typewait "tcp stat" 30
    S_fast=$(tcp_field fast); S_rtos=$(tcp_field rtos); S_retx=$(tcp_field retx); S_fdrop=$(tcp_field fdrop)
    for v in "$S_fast" "$S_rtos" "$S_retx" "$S_fdrop"; do
        case "$v" in ''|*[!0-9]*) fail "[$CASE] tcp stat sin contadores: fast=$S_fast rtos=$S_rtos retx=$S_retx fdrop=$S_fdrop" ;; esac
    done
}

arm() {
    faults=$((faults + 1))
    typewait "$1" 30
    [ "$(count 'tcp fault ok')" -ge "$faults" ] || fail "[$CASE] tcp fault no quedó armado: $1"
}

# trace_retx: cuántos tcp-retx hay desde el último `trace clear` y cuántos con b != 0.
trace_retx() {
    typewait "trace dump" 50
    tr -d '\r' < "$SERIAL" | awk '/^lapageria> trace dump$/ {f = 1; delete l; n = 0; next} f && /^t / {l[n++] = $0} /^trace end/ {f = 0} END {for (i = 0; i < n; i++) print l[i]}' > "$TMP/trace.txt"
    T_n=$(grep -c ' tcp-retx ' "$TMP/trace.txt" || true)
    T_b=$(grep ' tcp-retx ' "$TMP/trace.txt" | grep -Evc ' b 0 ' || true)
}

# 0. Referencia sin pérdida: cuántos segmentos con datos salen.
CASE=base
snap; f0=$S_fast; r0=$S_rtos; x0=$S_retx; d0=$S_fdrop
typewait "trace clear" 30
arm "tcp fault txdrop 100000 1"
send_run
typewait "tcp fault left" 30
left=$(tr -d '\r' < "$SERIAL" | grep '^tcp fault left ' | tail -1 | awk '{print $7}')
case "$left" in ''|*[!0-9]*) fail "[base] tcp fault left sin número: $left" ;; esac
NSEG=$((100000 - left))
snap
[ "$((S_fast - f0))" = 0 ] && [ "$((S_rtos - r0))" = 0 ] && [ "$((S_retx - x0))" = 0 ] && [ "$((S_fdrop - d0))" = 0 ] || fail "[base] sin pérdida y con contadores en movimiento: fast +$((S_fast - f0)) rtos +$((S_rtos - r0)) retx +$((S_retx - x0)) fdrop +$((S_fdrop - d0))"
[ "$NSEG" -ge 100 ] && [ "$NSEG" -le 140 ] || fail "[base] salieron $NSEG segmentos con datos; esperaba entre 100 y 140 para 128 trozos de 256"
typewait "tcp fault off" 30
echo "ok   base: 32768 bytes sin pérdida, $NSEG segmentos con datos; fast +0 rtos +0 retx +0 fdrop +0"

# burst NOMBRE "comando" perdidos fast_esperado retx_esperado
burst() {
    CASE=$1
    local lost=$3 wfast=$4 minx=${5:-$3} maxx=${6:-$3} maxf=${7:-1}
    snap; f0=$S_fast; r0=$S_rtos; x0=$S_retx; d0=$S_fdrop
    typewait "trace clear" 30
    arm "$2"
    send_run
    snap
    local df=$((S_fast - f0)) dr=$((S_rtos - r0)) dx=$((S_retx - x0)) dd_=$((S_fdrop - d0))
    [ "$dd_" = "$lost" ] || fail "[$CASE] fdrop +$dd_, esperaba +$lost (fast +$df rtos +$dr retx +$dx)"
    trace_retx
    [ "$T_n" = "$dx" ] || fail "[$CASE] trazas: $T_n tcp-retx para retx +$dx: $(cat "$TMP/trace.txt")"
    if [ "$wfast" = 1 ]; then
        { [ "$df" -ge 1 ] && [ "$df" -le "$maxf" ]; } || fail "[$CASE] fast +$df, esperaba entre +1 y +$maxf: sin retransmisión rápida (rtos +$dr, retx +$dx, fdrop +$dd_)"
        [ "$dr" = 0 ] || fail "[$CASE] rtos +$dr: venció el timer; la recuperación no fue solo por ACK repetidos (fast +$df, retx +$dx)"
        { [ "$dx" -ge "$minx" ] && [ "$dx" -le "$maxx" ]; } || fail "[$CASE] retx +$dx, esperaba entre +$minx y +$maxx (fdrop +$dd_)"
        [ "$T_b" = 0 ] || fail "[$CASE] trazas: $T_b tcp-retx con b != 0 (vencimiento del timer): $(grep ' tcp-retx ' "$TMP/trace.txt")"
        echo "ok   $CASE: $lost segmentos perdidos en la ráfaga, 32768 bytes íntegros; fast +$df rtos +$dr retx +$dx fdrop +$dd_; $T_n tcp-retx, todos con b=0"
    else
        [ "$df" = 0 ] || fail "[$CASE] fast +$df en una cola perdida: detrás del hueco no sale nada, no puede haber 3 ACK repetidos"
        [ "$dr" -ge 1 ] || fail "[$CASE] rtos +$dr: la cola se recuperó sin timer (fast +$df, retx +$dx)"
        [ "$dx" -ge 1 ] || fail "[$CASE] retx +$dx, esperaba >= 1"
        echo "ok   $CASE: cola de la ráfaga perdida ($dd_ segmentos), 32768 bytes íntegros; recuperación por timer: fast +$df rtos +$dr retx +$dx fdrop +$dd_"
    fi
    typewait "tcp fault off" 30
}

# Un reenvío manda hasta un MSS de datos contiguos sin confirmar (1460 bytes, unos
# 5 trozos de 256): huecos a menos de un MSS uno del otro se cubren con un solo
# reenvío. Dos huecos a más de un MSS necesitan dos (el segundo por ACK parcial).
burst par    "tcp fault txdrop 20 2" 2 1 1 2
burst sep    "tcp fault txdrop 20 1 4" 2 1 1 2 2
burst tanda  "tcp fault txdrop 40 4" 4 1 1 4
burst lejos  "tcp fault txdrop 20 1 10" 2 1 2 2 2
burst cola   "tcp fault txdrop $((NSEG - 1)) 2" 2 0

typewait "echo vivo" 30
has "vivo" || fail "el shell no respondió"
echo "ok   pérdida de varios segmentos en una ráfaga (par, separados, tanda, cola), shell vivo"
