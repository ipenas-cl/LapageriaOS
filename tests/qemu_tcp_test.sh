#!/usr/bin/env bash
# RD-02: TCP, en su propio QEMU.
#
# La red de usuario reenvía dos puertos TCP del host al invitado (hostfwd:
# 7001 es el eco, 7999 no tiene socket) y un destino del invitado hacia el
# host (guestfwd 10.0.2.100:7100 -> un socat del host). Todo pasa por el
# e1000 y por irq_net; el pcap (filter-dump) deja ver lo que salió.
#
#   net            ARP y ping por interrupción (como la prueba de UDP)
#   tcp test       máquina de estados sin dispositivo: handshake, datos,
#                  retransmisión con timer, cierre, RST, TIME_WAIT, ventana
#   exec tcpeco    (a) servidor de eco en anillo 3: 64 KiB aleatorios desde
#                  socat vuelven idénticos (cmp y suma de bytes contada por
#                  el invitado); cierre FIN de los dos lados; una segunda
#                  conexión que cierra primero el invitado; ISN distintos y
#                  no triviales en el pcap
#   exec tcpcli    (b) el kernel conecta al host (guestfwd): se corta el
#                  enlace durante la pausa del cliente para perder envíos y
#                  forzar retransmisiones; 3000 bytes llegan intactos; el
#                  host responde y cierra; connect a un puerto cerrado da
#                  -111
#   (c)            conexión del host a un puerto sin socket: el invitado
#                  contesta RST|ACK (contador y pcap)
#   (d)            zona sin red: tcp denied y niega; con `zone net`, eco
#   (e)            al terminar todo: tcp stat sin sockets (used 0), y los
#                  procesos liberan las mismas páginas en cada corrida
#
# TCP_PCAP=ruta guarda la captura. Uso: tests/qemu_tcp_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
PCAP=$TMP/net.pcap
QPID=""
LPID=""
HPORT=0
HPORT2=0
SECTORS=$(( $(wc -c < "$DATA_SRC") / 512 ))
dd if=/dev/zero of="$DATA" bs=512 count="$SECTORS" status=none

stop_qemu() {
    if [ -n "${LPID:-}" ] && kill -0 "$LPID" 2>/dev/null; then
        kill "$LPID" 2>/dev/null || true
        wait "$LPID" 2>/dev/null || true
        LPID=""
    fi
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
    tr -d '\r' < "$SERIAL" 2>/dev/null || true
    exit 1
}

# Puertos al azar; si están ocupados QEMU no arranca y se prueba otro par.
start_qemu() {
    local try
    for try in 1 2 3 4 5 6; do
        HPORT=$((20000 + RANDOM % 20000))
        HPORT2=$((HPORT + 100))
        : > "$SERIAL"
        rm -f "$MON"
        qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$IMAGE" \
            -drive file="$DATA",format=raw,if=ide,index=1 \
            -display none -no-reboot \
            -nic none -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$HPORT-:7001,hostfwd=tcp:127.0.0.1:$((HPORT + 1))-:7999,guestfwd=tcp:10.0.2.100:7100-cmd:$SOCAT - TCP:127.0.0.1:$HPORT2" \
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
    for i in $(seq "$2"); do
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
# Espera una línea que empiece con $1 y la imprime.
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
count() { tr -d '\r' < "$SERIAL" | grep -cx "$1" || true; }
tcp_field() {
    tr -d '\r' < "$SERIAL" | grep '^tcp rx ' | tail -1 | tr ' ' '\n' | grep -A1 -x "$1" | tail -1
}
bytesum() { od -An -v -tu1 "$1" | awk '{for (i = 1; i <= NF; i++) s += $i} END {print s + 0}'; }

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"
out=$(echo "info network" | socat - UNIX-CONNECT:"$MON" 2>/dev/null || true)
printf '%s\n' "$out" | grep -q "hostfwd\|type=user" || fail "qemu has no user netdev"

# 1. La red por interrupción y la máquina de estados sin dispositivo.
typewait "net" 150
has "net irq ok" || fail "net irq"
typewait "tcp test" 100
has "tcp test ok" || fail "tcp test: $(tr -d '\r' < "$SERIAL" | grep '^tcp test' | tail -1)"
echo "ok   tcp test: handshake, datos, ACK, retransmisión con timer, FIN/TIME_WAIT, RST, ventana"

typewait "fs format" 50
typewait "tcp plant" 80
has "tcp plant ok" || fail "tcp plant"
typewait "net up" 150
has "net up ok" || fail "net up"
typewait "tcp stat" 30
n0=$(tcp_field used)
[ "${n0:-x}" = 0 ] || fail "tcp stat inicial: used=[${n0:-}]"

# 2. (a) Servidor de eco en anillo 3.
head -c 65536 /dev/urandom > "$TMP/in.bin"
typeline "exec tcpeco"
waitline "tcp listen" 100
has "tcp ptr denied" || fail "los punteros malos no dieron -14"
"$SOCAT" -t10 - TCP:127.0.0.1:"$HPORT" < "$TMP/in.bin" > "$TMP/out.bin" 2>"$TMP/socat1.err"
cmp "$TMP/in.bin" "$TMP/out.bin" || fail "eco de 64 KiB: la salida difiere ($(wc -c < "$TMP/out.bin") bytes) $(cat "$TMP/socat1.err")"
line=$(waitpre "tcp eof n=" 100)
hsum=$(bytesum "$TMP/in.bin")
[ "$line" = "tcp eof n=65536 sum=$hsum" ] || fail "el invitado contó [$line], el host [n=65536 sum=$hsum]"
waitline "tcp echo1 ok" 100
echo "ok   (a) eco TCP de 64 KiB: socat -> hostfwd -> e1000 -> anillo 3 -> e1000 -> socat, idéntico (cmp); suma de bytes $hsum igual en host e invitado; FIN del cliente y cierre del servidor"
reply=$(printf 'adios' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "adios" ] || fail "segunda conexión: socat recibió [$reply]"
waitline "tcp echo2 ok" 100
waitline "tcp srv done" 100
echo "ok   (a) segunda conexión: eco y cierre iniciado por el invitado (socat ve el FIN)"
sleep 1
typewait "tcp stat" 30
est=$(tcp_field est); retx_a=$(tcp_field retx); dup_a=$(tcp_field dup); rx_a=$(tcp_field rx); tx_a=$(tcp_field tx)
[ "$est" = 2 ] || fail "tcp stat: est=$est, esperaba 2"
# ISN: los dos SYN|ACK del 7001 en el pcap (puerto 0x1B59, offset 6, flags 0x12).
hex=$(od -An -v -tx1 "$PCAP" | tr -d ' \n')
isns=$(printf '%s' "$hex" | grep -Eo '1b59[0-9a-f]{4}[0-9a-f]{8}[0-9a-f]{8}601[0-9a-f]' | grep -Eo '^1b59[0-9a-f]{4}[0-9a-f]{8}' | cut -c9-16 | sort -u)
[ "$(printf '%s\n' "$isns" | grep -c .)" = 2 ] || fail "ISN: esperaba 2 SYN|ACK distintos en el pcap, vi [$isns]"
for s in $isns; do
    [ $((16#$s)) -gt 65535 ] || fail "ISN trivial: $s"
done
echo "ok   (a) contadores tras las dos conexiones: rx $rx_a tx $tx_a retx $retx_a dup $dup_a est $est"
echo "ok   números de secuencia iniciales aleatorios: $(printf '%s' "$isns" | tr '\n' ' ')(distintos, > 65535)"

# 3. (b) El kernel conecta al host.
"$SOCAT" TCP-LISTEN:"$HPORT2",bind=127.0.0.1,reuseaddr SYSTEM:"head -c 3000 > $TMP/got.bin; printf respuesta" 2>"$TMP/socat2.err" &
LPID=$!
sleep 0.5
rx0=$(tcp_field rx); retx0=$(tcp_field retx); rst0=$(tcp_field rstin)
typeline "exec tcpcli"
waitline "tcp conn ok" 100
waitline "tcp pause" 50
# Enlace caído durante la pausa de 1,5 s del cliente: sus envíos se pierden.
mon "set_link n0 off"
sleep 2.4
mon "set_link n0 on"
sent=$(waitpre "tcp sent n=3000 sum=" 100)
waitline "tcp got ok" 300
waitline "tcp cli ok" 100
waitline "tcp refused ok" 300
wait "$LPID" 2>/dev/null || true
LPID=""
gsize=$(wc -c < "$TMP/got.bin" | tr -d ' ')
[ "$gsize" = 3000 ] || fail "el host recibió $gsize bytes, esperaba 3000"
gsum=$(bytesum "$TMP/got.bin")
[ "$sent" = "tcp sent n=3000 sum=$gsum" ] || fail "el invitado envió [$sent], el host recibió suma $gsum"
for _ in $(seq 100); do [ "$(count 'exec ok')" -ge 2 ] && break; sleep 0.1; done
typewait "tcp stat" 30
retx1=$(tcp_field retx); rst1=$(tcp_field rstin)
[ "$((retx1 - retx0))" -ge 1 ] || fail "retransmisión: retx $retx0 -> $retx1, el enlace caído no la provocó"
[ "$((rst1 - rst0))" -ge 1 ] || fail "rstin $rst0 -> $rst1: no llegó el RST del puerto cerrado del host"
echo "ok   (b) el kernel conecta (guestfwd), envía 3000 bytes con el enlace caído (retx +$((retx1 - retx0))), el host los recibe intactos (suma $gsum), responde y cierra; connect a puerto cerrado dio -111 (rstin +$((rst1 - rst0)))"

# 4. (c) Conexión del host a un puerto sin socket: RST|ACK.
rso0=$(tcp_field rstout)
"$SOCAT" -t1 - TCP:127.0.0.1:$((HPORT + 1)) < /dev/null > /dev/null 2>&1
sleep 0.5
typewait "tcp stat" 30
rso1=$(tcp_field rstout)
[ "$((rso1 - rso0))" -ge 1 ] || fail "RST: rstout $rso0 -> $rso1"
sleep 0.3
hex=$(od -An -v -tx1 "$PCAP" | tr -d ' \n')
# Puerto origen 7999 (0x1F3F), seq 0, offset 5, flags 0x14 (RST|ACK).
printf '%s' "$hex" | grep -Eq '1f3f[0-9a-f]{4}00000000[0-9a-f]{8}5014' || fail "la captura no tiene el RST|ACK desde el puerto 7999"
if command -v tcpdump >/dev/null 2>&1; then
    dump=$(tcpdump -nn -vv -r "$PCAP" 'tcp port 7999' 2>/dev/null || true)
    printf '%s\n' "$dump" | grep -q "10.0.2.15.7999 > .*Flags \[R\.\]" || fail "tcpdump no ve el RST: $dump"
    if printf '%s\n' "$dump" | grep -qi "bad cksum\|incorrect"; then fail "tcpdump marca un checksum malo: $dump"; fi
    echo "ok   (c) RST a puerto cerrado visto en el pcap (tcpdump: Flags [R.], checksums bien); rstout +$((rso1 - rso0))"
else
    echo "ok   (c) RST a puerto cerrado visto en el pcap (bytes; sin tcpdump no se revisó el checksum); rstout +$((rso1 - rso0))"
fi

# 5. (d) Zonas.
typewait "zone create n zn 12" 50
typewait "zone create m zm 12" 50
typewait "zone exec n tcpeco" 150
waitline "tcp denied" 50
has "zone exec ok" || fail "zone exec n no terminó"
typewait "zone ls" 50
niega=$(tr -d '\r' < "$SERIAL" | grep '^zone [0-9]* n pre=' | tail -1)
echo "$niega" | grep -q "niega=[1-9]" || fail "zone ls: n sin niega ($niega)"
[ "$(count 'tcp ptr denied')" = 1 ] || fail "la zona sin red llegó a las pruebas de punteros"
echo "ok   (d) zona sin red: tcp denied y niega>0"
typewait "zone net m" 30
has "zone net ok" || fail "zone net"
typeline "zone exec m tcpeco"
for _ in $(seq 100); do [ "$(count 'tcp listen')" -ge 2 ] && break; sleep 0.1; done
[ "$(count 'tcp listen')" -ge 2 ] || fail "la zona m no abrió el puerto"
reply=$(printf 'en zona' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "en zona" ] || fail "eco en zona (1): [$reply]"
reply=$(printf 'otra' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "otra" ] || fail "eco en zona (2): [$reply]"
for _ in $(seq 100); do [ "$(count 'zone exec ok')" -ge 2 ] && break; sleep 0.1; done
[ "$(count 'zone exec ok')" -ge 2 ] || fail "zone exec m no terminó"
[ "$(count 'tcp ptr denied')" = 2 ] || fail "zona con red: punteros malos"
echo "ok   (d) zona con red (zone net): eco TCP, punteros malos denegados"

# 6. (e) Sin fugas: sockets y páginas.
for _ in $(seq 60); do
    typewait "tcp stat" 30
    [ "$(tcp_field used)" = 0 ] && break
    sleep 0.5
done
used=$(tcp_field used); lst=$(tcp_field lst); tw=$(tcp_field tw); giveup=$(tcp_field giveup); bad=$(tcp_field bad)
[ "$used" = 0 ] && [ "$lst" = 0 ] && [ "$tw" = 0 ] || fail "tcp stat: used=$used lst=$lst tw=$tw tras cerrar todo"
[ "$bad" = 0 ] || fail "tcp stat: bad=$bad segmentos malos"
[ "$giveup" = 0 ] || fail "tcp stat: giveup=$giveup conexiones abandonadas"
freed=$(tr -d '\r' < "$SERIAL" | grep '^exit pid=' | sed 's/.*freed=//' | sort -u)
echo "ok   (e) cierre limpio: used 0, lst 0, tw 0, bad 0, giveup 0; páginas liberadas por proceso: $(printf '%s' "$freed" | tr '\n' ' ')"
echo "     tcp stat final: $(tr -d "\r" < "$SERIAL" | grep "^tcp rx " | tail -1)"
typewait "net down" 30
has "net down ok" || fail "net down"
typewait "tcp stat" 30
[ "$(tcp_field used)" = 0 ] || fail "tras net down quedan sockets"
typewait "echo vivo" 20
has "vivo" || fail "el shell no respondió"
echo "ok   net down, shell vivo"
