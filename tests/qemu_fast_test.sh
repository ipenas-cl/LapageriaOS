#!/usr/bin/env bash
# EX-04: retransmisión rápida de TCP con pérdida real, en su propio QEMU.
#
# El invitado envía (tcpsnd, src/user/tcpsnd.lap: 32768 bytes en trozos de 256
# a un socat del host por hostfwd) y el TCP del invitado se come el segmento
# con datos número 20 que manda (`tcp fault txdrop 20 1`). El host (slirp) recibe
# los que siguen fuera de orden y contesta con un ACK repetido por cada uno;
# al tercero el invitado tiene que reenviar el hueco sin esperar al timer.
#
# Qué se exige (nada de esto es un umbral que se pueda aflojar):
#   - los 32768 bytes llegan al host en orden y completos (patrón (i*7+3)&255,
#     y la misma suma que contó el invitado);
#   - `tcp stat`: fast +1, rtos +0 (ningún vencimiento del timer), retx +1,
#     fdrop +1 (el segmento perdido);
#   - trazas: un solo evento `tcp-retx` y con b=0 (tc_nre sin tocar: un
#     vencimiento del timer lo sube antes de reenviar);
#   - la captura (si hay tcpdump): >= 3 ACK repetidos del host con el mismo
#     número de ack, y el segmento con ese número de secuencia sale después
#     del tercero.
#
# Sirve con QEMU_EXTRA="-icount shift=7" y sin icount (tests/repeat.sh).
# Uso: tests/qemu_fast_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
BOOT=$TMP/boot.img
PCAP=$TMP/net.pcap
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
trap 'stop_qemu; if [ -n "${TCP_PCAP:-}" ] && [ -f "$PCAP" ]; then cp "$PCAP" "$TCP_PCAP"; fi; rm -rf "$TMP"' EXIT

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
        rm -f "$MON" "$PCAP"
        # shellcheck disable=SC2086
        qemu-system-x86_64 -cpu qemu64 ${QEMU_EXTRA:-} -drive format=raw,file="$BOOT" \
            -drive file="$DATA",format=raw,if=ide,index=1 \
            -display none -no-reboot \
            -nic none -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$HPORT-:7005" \
            -device e1000,netdev=n0 -object filter-dump,id=f0,netdev=n0,file="$PCAP" \
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
waitline() {
    local want=$1 i
    for i in $(seq "$2"); do
        if tr -d '\r' < "$SERIAL" | grep -qx "$want"; then return 0; fi
        sleep 0.1
    done
    fail "no line '$want'"
}
waitpre() {
    local want=$1 i l
    for i in $(seq "$2"); do
        l=$(tr -d '\r' < "$SERIAL" | grep "^$want" | tail -1)
        if [ -n "$l" ]; then printf '%s\n' "$l"; return 0; fi
        sleep 0.1
    done
    fail "no line starting '$want'"
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
typewait "tcp stat" 30
fast0=$(tcp_field fast); rtos0=$(tcp_field rtos); retx0=$(tcp_field retx); fdrop0=$(tcp_field fdrop)
for v in "$fast0" "$rtos0" "$retx0" "$fdrop0"; do
    case "$v" in ''|*[!0-9]*) fail "tcp stat inicial sin contadores: fast=$fast0 rtos=$rtos0 retx=$retx0 fdrop=$fdrop0" ;; esac
done
[ "$fast0" = 0 ] && [ "$rtos0" = 0 ] && [ "$retx0" = 0 ] || fail "contadores no empiezan en 0: fast=$fast0 rtos=$rtos0 retx=$retx0"

typewait "trace clear" 30
typewait "trace on tcp-retx" 30
typewait "tcp fault txdrop 20 1" 30
has "tcp fault ok" || fail "tcp fault no quedó armado"
typeline "exec tcpsnd"
waitline "tcp listen" 150
"$SOCAT" -u -t30 TCP:127.0.0.1:"$HPORT" - > "$TMP/snd.out" 2> "$TMP/snd.err"
size=$(wc -c < "$TMP/snd.out" | tr -d ' ')
[ "$size" = 32768 ] || fail "el host recibió $size bytes, esperaba 32768 $(cat "$TMP/snd.err")"
# Patrón (i*7+3)&255, byte a byte.
od -An -v -tu1 "$TMP/snd.out" | awk 'BEGIN {n = 0; bad = 0} {for (i = 1; i <= NF; i++) {if ($i != (n * 7 + 3) % 256) bad++; n++}} END {exit (bad == 0 && n == 32768) ? 0 : 1}' || fail "los bytes que llegaron al host no siguen el patrón (perdidos, repetidos o fuera de orden)"
hsum=$(bytesum "$TMP/snd.out")
line=$(waitpre "tcp snd n=" 150)
[ "$line" = "tcp snd n=32768 sum=$hsum" ] || fail "el invitado contó [$line], el host [n=32768 sum=$hsum]"
echo "ok   32768 bytes del invitado al host, en orden y completos (patrón y suma $hsum iguales en los dos lados) con un segmento perdido"

# Que la conexión termine sola (FIN de los dos lados) antes de leer contadores.
for _ in $(seq 100); do
    typewait "tcp stat" 30
    [ "$(tcp_field used)" = 0 ] && break
    sleep 0.5
done
fast1=$(tcp_field fast); rtos1=$(tcp_field rtos); retx1=$(tcp_field retx); fdrop1=$(tcp_field fdrop)
[ "$((fdrop1 - fdrop0))" = 1 ] || fail "fdrop $fdrop0 -> $fdrop1, esperaba +1 (el segmento 20 perdido)"
[ "$((fast1 - fast0))" = 1 ] || fail "fast $fast0 -> $fast1, esperaba +1: no hubo retransmisión rápida (rtos $rtos0 -> $rtos1, retx $retx0 -> $retx1)"
[ "$((rtos1 - rtos0))" = 0 ] || fail "rtos $rtos0 -> $rtos1: venció el timer; la recuperación no fue solo por ACK repetidos"
[ "$((retx1 - retx0))" = 1 ] || fail "retx $retx0 -> $retx1, esperaba +1 (una sola retransmisión)"
echo "ok   contadores: fast +1, rtos +0, retx +1, fdrop +1 (tcp stat: $(tr -d '\r' < "$SERIAL" | grep '^tcp rx ' | tail -1))"

# Trazas: un solo tcp-retx y con b=0.
typewait "trace dump" 50
tr -d '\r' < "$SERIAL" | awk '/^lapageria> trace dump$/ {f = 1; next} f && /^t / {print} /^trace end/ {f = 0}' > "$TMP/trace.txt"
nre=$(grep -c ' tcp-retx ' "$TMP/trace.txt" || true)
[ "$nre" = 1 ] || fail "trazas: $nre eventos tcp-retx, esperaba 1: $(cat "$TMP/trace.txt")"
grep ' tcp-retx ' "$TMP/trace.txt" | grep -Eq ' b 0 ' || fail "trazas: el tcp-retx tiene b distinto de 0 (fue un vencimiento del timer): $(grep ' tcp-retx ' "$TMP/trace.txt")"
echo "ok   trazas: un solo tcp-retx con b=0 (tc_nre sin tocar: no fue timeout): $(grep ' tcp-retx ' "$TMP/trace.txt")"

# La captura: tres ACK repetidos del host y después el segmento reenviado.
if command -v tcpdump >/dev/null 2>&1; then
    sleep 0.5
    tcpdump -nn -tt -S -r "$PCAP" 'tcp port 7005' 2>/dev/null > "$TMP/pcap.txt" || true
    # Guest 10.0.2.15.7005 -> host: segmentos con datos (length > 0) y su seq.
    # Host -> guest: ACK puros (length 0) y su ack.
    awk '
    / 10\.0\.2\.15\.7005 > / && /length [1-9]/ {
        s = $0; sub(/.* seq /, "", s); sub(/:.*/, "", s); sub(/,.*/, "", s)
        d++; print "D", NR, s
    }
    / > 10\.0\.2\.15\.7005: / && /length 0/ && /ack / {
        a = $0; sub(/.* ack /, "", a); sub(/,.*/, "", a)
        print "A", NR, a
    }' "$TMP/pcap.txt" > "$TMP/seq.txt"
    # Un ack que se repite: >= 4 veces el mismo valor (1 + 3 repetidos).
    dupack=$(awk '$1 == "A" {c[$3]++} END {for (k in c) if (c[k] >= 4) print k}' "$TMP/seq.txt" | sort -n | head -1)
    [ -n "$dupack" ] || fail "la captura no tiene un ack repetido 3 veces ($(grep -c '^A' "$TMP/seq.txt") ACK del host)"
    third=$(awk -v k="$dupack" '$1 == "A" && $3 == k {n++; if (n == 4) {print $2; exit}}' "$TMP/seq.txt")
    resend=$(awk -v k="$dupack" '$1 == "D" && $3 == k {print $2}' "$TMP/seq.txt" | head -1)
    [ -n "$resend" ] || fail "la captura no tiene el segmento con seq $dupack (el hueco nunca se reenvió)"
    [ "$resend" -gt "$third" ] || fail "el segmento seq $dupack salió (línea $resend) antes del tercer ACK repetido (línea $third)"
    echo "ok   captura: ack $dupack repetido 3 veces por el host (+ el original) y el segmento seq $dupack reenviado después del tercero"
else
    echo "nota sin tcpdump: no se revisó la captura (los contadores y las trazas sí)"
fi

typewait "echo vivo" 30
has "vivo" || fail "el shell no respondió"
echo "ok   retransmisión rápida con pérdida real (3 ACK repetidos, sin timeout), shell vivo"
