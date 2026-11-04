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
# RD-03 (docs/red.md, «TCP endurecido» y «RD-03: más de ...»), entre el eco
# y tcpcli:
#   tcp test       además: cola fuera de orden, RTT/RTO, congestión,
#                  agotamiento de bloques y fallas inyectadas (5 líneas ok)
#   exec2 tcpmulti tcpmulti   4 ecos simultáneos de 64 KiB distintos (2+2)
#   tcp fault + exec tcpeco   pérdida (2 recibidos, 1 enviado) y reordenamiento
#                  de segmentos con datos, con eco íntegro; la falla la
#                  inyecta el TCP del invitado, no la red
#   exec tcphog    8 de 8 bloques ocupados; el siguiente SYN recibe RST|ACK
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
            -nic none -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$HPORT-:7001,hostfwd=tcp:127.0.0.1:$((HPORT + 1))-:7999,hostfwd=tcp:127.0.0.1:$((HPORT + 2))-:7002,hostfwd=tcp:127.0.0.1:$((HPORT + 3))-:7003,hostfwd=tcp:127.0.0.1:$((HPORT + 4))-:7004,guestfwd=tcp:10.0.2.100:7100-cmd:$SOCAT - TCP:127.0.0.1:$HPORT2" \
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
# Espera a que la línea exacta $1 aparezca al menos $2 veces (plazo $3 décimas).
waitcount() {
    local want=$1 n=$2 i
    for i in $(seq "$3"); do
        if [ "$(count "$want")" -ge "$n" ]; then return 0; fi
        sleep 0.1
    done
    fail "line '$want' x$n"
}
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
for part in ooo rtt cc full fault; do
    has "tcp test $part ok" || fail "tcp test $part: $(tr -d '\r' < "$SERIAL" | grep '^tcp test' | tail -3 | tr '\n' '|')"
done
echo "ok   tcp test (RD-03): cola fuera de orden (c), RTT/RTO RFC 6298, congestión RFC 5681 (arranque lento, evitación, timeout, retransmisión rápida), agotamiento de bloques (d), fallas inyectadas"

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
est_a=$est
# ISN: los dos SYN|ACK del 7001 en el pcap (puerto 0x1B59, offset 6, flags 0x12).
hex=$(od -An -v -tx1 "$PCAP" | tr -d ' \n')
isns=$(printf '%s' "$hex" | grep -Eo '1b59[0-9a-f]{4}[0-9a-f]{8}[0-9a-f]{8}601[0-9a-f]' | grep -Eo '^1b59[0-9a-f]{4}[0-9a-f]{8}' | cut -c9-16 | sort -u)
[ "$(printf '%s\n' "$isns" | grep -c .)" = 2 ] || fail "ISN: esperaba 2 SYN|ACK distintos en el pcap, vi [$isns]"
for s in $isns; do
    [ $((16#$s)) -gt 65535 ] || fail "ISN trivial: $s"
done
echo "ok   (a) contadores tras las dos conexiones: rx $rx_a tx $tx_a retx $retx_a dup $dup_a est $est"
echo "ok   números de secuencia iniciales aleatorios: $(printf '%s' "$isns" | tr '\n' ' ')(distintos, > 65535)"

# 2b. RD-03 (a): cuatro conexiones de eco simultáneas, 64 KiB distintos cada
# una, contra dos servidores de un solo hilo que corren a la vez (exec2).
for k in 1 2 3 4; do head -c 65536 /dev/urandom > "$TMP/m$k.in"; done
typeline "exec2 tcpmulti tcpmulti"
waitline "tcp multi listen 7001" 150
waitline "tcp multi listen 7002" 150
mpids=""
for k in 1 2 3 4; do
    mport=$HPORT
    [ "$k" -gt 2 ] && mport=$((HPORT + 2))
    "$SOCAT" -t20 - TCP:127.0.0.1:"$mport" < "$TMP/m$k.in" > "$TMP/m$k.out" 2> "$TMP/m$k.err" &
    mpids="$mpids $!"
done
for p in $mpids; do wait "$p" 2>/dev/null || true; done
for k in 1 2 3 4; do
    cmp "$TMP/m$k.in" "$TMP/m$k.out" || fail "eco simultáneo $k: salida de $(wc -c < "$TMP/m$k.out") bytes distinta de la entrada $(cat "$TMP/m$k.err")"
done
waitline "tcp multi done 7001" 400
waitline "tcp multi done 7002" 400
waitline "exec2 ok" 100
! has "tcp multi fail" 2>/dev/null || true
if tr -d '\r' < "$SERIAL" | grep -q '^tcp multi fail'; then fail "tcpmulti: $(tr -d '\r' < "$SERIAL" | grep '^tcp multi fail')"; fi
for pr in 7001:12 7002:34; do
    p=${pr%%:*}; ks=${pr##*:}
    want=$(for k in $(printf '%s' "$ks" | sed 's/./& /g'); do bytesum "$TMP/m$k.in"; done | sort -n | tr '\n' ' ')
    got=$(tr -d '\r' < "$SERIAL" | grep "^tcp multi $p n=65536 sum=" | sed 's/.*sum=//' | sort -n | tr '\n' ' ')
    [ "$want" = "$got" ] || fail "tcpmulti $p: el invitado contó [$got], el host [$want]"
done
sleep 1
typewait "tcp stat" 30
peak=$(tcp_field peak); ooo_m=$(tcp_field ooo)
[ "${peak:-0}" -ge 6 ] || fail "tcp stat: peak=$peak, 4 conexiones y 2 escuchadores piden >= 6 bloques a la vez"
echo "ok   (a) 4 conexiones de eco simultáneas de 64 KiB, dos servidores con exec2 (2+2): las 4 salidas son idénticas a su entrada (cmp); el invitado contó las mismas sumas de bytes; máximo de bloques ocupados a la vez: $peak"

# 2c. RD-03 (b): pérdida a mitad de ráfaga. El TCP del invitado pierde los
# segmentos con datos 6 y 7 que le llegan del host y el 9 que él mismo manda
# (`tcp fault`); el eco de 64 KiB tiene que volver íntegro.
typewait "tcp stat" 30
retx_l0=$(tcp_field retx); fdrop0=$(tcp_field fdrop); ooo_l0=$(tcp_field ooo); rtos_l0=$(tcp_field rtos); fast_l0=$(tcp_field fast)
typewait "tcp fault rxdrop 6 2" 30
typewait "tcp fault txdrop 9 1" 30
[ "$(count 'tcp fault ok')" = 2 ] || fail "tcp fault no quedó armado"
n_listen=$(count 'tcp listen')
typeline "exec tcpeco"
waitcount "tcp listen" $((n_listen + 1)) 150
head -c 65536 /dev/urandom > "$TMP/l.in"
"$SOCAT" -t30 - TCP:127.0.0.1:"$HPORT" < "$TMP/l.in" > "$TMP/l.out" 2> "$TMP/l.err"
cmp "$TMP/l.in" "$TMP/l.out" || fail "eco con pérdida: salida de $(wc -c < "$TMP/l.out") bytes distinta de la entrada $(cat "$TMP/l.err")"
reply=$(printf 'adios' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "adios" ] || fail "eco con pérdida, segunda conexión: [$reply]"
waitcount "tcp srv done" 2 200
lsum=$(bytesum "$TMP/l.in")
tr -d '\r' < "$SERIAL" | grep -q "^tcp eof n=65536 sum=$lsum\$" || fail "el invitado no contó n=65536 sum=$lsum tras la pérdida"
typewait "tcp stat" 30
retx_l1=$(tcp_field retx); fdrop1=$(tcp_field fdrop); ooo_l1=$(tcp_field ooo); rtos_l1=$(tcp_field rtos); fast_l1=$(tcp_field fast)
[ "$((fdrop1 - fdrop0))" = 3 ] || fail "fdrop $fdrop0 -> $fdrop1, esperaba +3 (2 al entrar, 1 al salir)"
[ "$((retx_l1 - retx_l0))" -ge 1 ] || fail "el invitado no retransmitió ($retx_l0 -> $retx_l1) tras perder su segmento"
echo "ok   (b) pérdida a mitad de ráfaga: 3 segmentos con datos perdidos en el TCP del invitado (2 recibidos y 1 enviado); eco de 64 KiB idéntico (cmp, suma $lsum); retransmisiones del invitado +$((retx_l1 - retx_l0)) (timeout +$((rtos_l1 - rtos_l0)), rápida +$((fast_l1 - fast_l0))); segmentos adelantados encolados +$((ooo_l1 - ooo_l0))"

# 2d. RD-03 (c): reordenamiento. El segmento con datos 5 se retiene y sale
# después del siguiente; el eco tiene que volver idéntico.
typewait "tcp fault off" 30
sw0=$(tcp_field fswap)
typewait "tcp stat" 30
sw0=$(tcp_field fswap); ooo_s0=$(tcp_field ooo)
typewait "tcp fault swap 5" 30
n_listen=$(count 'tcp listen')
typeline "exec tcpeco"
waitcount "tcp listen" $((n_listen + 1)) 150
head -c 65536 /dev/urandom > "$TMP/s.in"
"$SOCAT" -t30 - TCP:127.0.0.1:"$HPORT" < "$TMP/s.in" > "$TMP/s.out" 2> "$TMP/s.err"
cmp "$TMP/s.in" "$TMP/s.out" || fail "eco con reordenamiento: salida de $(wc -c < "$TMP/s.out") bytes distinta de la entrada $(cat "$TMP/s.err")"
reply=$(printf 'adios' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "adios" ] || fail "eco con reordenamiento, segunda conexión: [$reply]"
waitcount "tcp srv done" 3 200
typewait "tcp stat" 30
sw1=$(tcp_field fswap); ooo_s1=$(tcp_field ooo)
[ "$((sw1 - sw0))" = 1 ] || fail "fswap $sw0 -> $sw1, esperaba +1"
echo "ok   (c) reordenamiento: un segmento con datos retenido y entregado después del siguiente (fswap +1); eco de 64 KiB idéntico (cmp); segmentos adelantados encolados +$((ooo_s1 - ooo_s0))"

# 2e. RD-03 (d): agotar los bloques. tcphog abre tres escuchadores y no acepta
# nunca; cinco conexiones del host (3 al 7003, 2 al 7004) dejan hijos
# pendientes y ocupan los 8 bloques; la sexta recibe RST|ACK sin reservar nada.
typewait "tcp fault off" 30
typewait "tcp stat" 30
full0=$(tcp_field full); bk0=$(tcp_field bklog); rso_h0=$(tcp_field rstout)
typeline "exec tcphog"
waitline "tcp hog listen" 100
hpids=""
for hp in 3 3 3 4 4; do
    ( sleep 3 | "$SOCAT" -t0 - TCP:127.0.0.1:$((HPORT + hp)) > /dev/null 2>&1 ) &
    hpids="$hpids $!"
    sleep 0.15
done
sleep 0.5
( printf 'x' | "$SOCAT" -t1 - TCP:127.0.0.1:$((HPORT + 4)) > /dev/null 2>&1 ) || true
waitline "tcp hog done -110" 700
for p in $hpids; do wait "$p" 2>/dev/null || true; done
sleep 1
typewait "tcp stat" 30
full1=$(tcp_field full); peak=$(tcp_field peak); rso_h1=$(tcp_field rstout); used_h=$(tcp_field used)
[ "$peak" = 8 ] || fail "tcp stat: peak=$peak, esperaba 8 (todos los bloques)"
[ "$((full1 - full0))" -ge 1 ] || fail "tcp stat: full $full0 -> $full1, el SYN sin bloque no se rechazó"
[ "$((rso_h1 - rso_h0))" -ge 1 ] || fail "tcp stat: rstout $rso_h0 -> $rso_h1"
[ "$used_h" = 0 ] || fail "tcp stat: used=$used_h tras cerrar el acaparador"
hex=$(od -An -v -tx1 "$PCAP" | tr -d ' \n')
printf '%s' "$hex" | grep -Eq '1b5c[0-9a-f]{4}00000000[0-9a-f]{8}5014' || fail "la captura no tiene el RST|ACK desde el puerto 7004"
echo "ok   (d) agotamiento: peak 8 de 8 bloques; el SYN sin bloque recibió RST|ACK (full +$((full1 - full0)), visto en el pcap desde el puerto 7004); al cerrar, used 0 (bklog +$(( $(tcp_field bklog) - bk0 )))"

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
typewait "zone create n 12" 50
typewait "zone create m 12" 50
pd0=$(count 'tcp ptr denied')
zl0=$(count 'tcp listen')
typewait "zone exec n tcpeco" 150
waitline "tcp denied" 50
has "zone exec ok" || fail "zone exec n no terminó"
typewait "zone ls" 50
niega=$(tr -d '\r' < "$SERIAL" | grep '^zone [0-9]* n root=' | tail -1)
echo "$niega" | grep -q "niega=[1-9]" || fail "zone ls: n sin niega ($niega)"
[ "$(count 'tcp ptr denied')" = "$pd0" ] || fail "la zona sin red llegó a las pruebas de punteros"
echo "ok   (d) zona sin red: tcp denied y niega>0"
typewait "zone net m" 30
has "zone net ok" || fail "zone net"
typeline "zone exec m tcpeco"
for _ in $(seq 100); do [ "$(count 'tcp listen')" -ge $((zl0 + 1)) ] && break; sleep 0.1; done
[ "$(count 'tcp listen')" -ge $((zl0 + 1)) ] || fail "la zona m no abrió el puerto"
reply=$(printf 'en zona' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "en zona" ] || fail "eco en zona (1): [$reply]"
reply=$(printf 'otra' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "otra" ] || fail "eco en zona (2): [$reply]"
for _ in $(seq 100); do [ "$(count 'zone exec ok')" -ge 2 ] && break; sleep 0.1; done
[ "$(count 'zone exec ok')" -ge 2 ] || fail "zone exec m no terminó"
[ "$(count 'tcp ptr denied')" = $((pd0 + 1)) ] || fail "zona con red: punteros malos"
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
