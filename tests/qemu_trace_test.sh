#!/usr/bin/env bash
# OB-01: trazas del kernel, en su propio QEMU.
#
# Todo se activa y se lee desde anillo 3 con el programa `traza` (syscalls
# 23 y 24) salvo donde hace falta que el propio programa no deje eventos:
# ahí se usa el comando `trace` del shell, que no es un proceso.
#
#   traza ls          20 sondas, todas apagadas al arrancar
#   traza ptr         punteros malos a las syscalls 23 y 24 dan -14, args malos -22
#   sys-enter/exit    exec hola: 13 entradas y 12 salidas exactas; cada sonda
#                     se prende y apaga sola
#   filtros           exec2 hola hola (pid 1 y 2): dump por pid, evento y zona
#   irq-kbd           teclear un comando deja ~2 IRQ por tecla (make y break)
#   pit + anillo      el anillo (64) da la vuelta: ticks consecutivos, lost > 0
#   UDP               udp-rx / udp-tx / irq-net == lo que cuenta `udp stat`
#   TCP               tcp-state / tcp-retx / tcp-rst == lo que cuenta `tcp stat`,
#                     con eco de 64 KiB, un segmento perdido y un RST
#   zonas             zone-deny (máscara, escape, ruta) con zona 1 y zone-switch
#   off               con todo apagado no se graba nada
#
# El disco de datos es una copia nueva. Uso: tests/qemu_trace_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
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

# UDP 7777 y TCP 7001 (eco) y 7999 (sin socket) del invitado, en puertos del
# host al azar; si están ocupados QEMU no arranca y se prueba otro.
start_qemu() {
    local try
    for try in 1 2 3 4 5 6; do
        HPORT=$((20000 + RANDOM % 30000))
        : > "$SERIAL"
        rm -f "$MON"
        qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$IMAGE" \
            -drive file="$DATA",format=raw,if=ide,index=1 \
            -display none -no-reboot \
            -nic none -netdev "user,id=n0,hostfwd=udp:127.0.0.1:$HPORT-:7777,hostfwd=tcp:127.0.0.1:$HPORT-:7001,hostfwd=tcp:127.0.0.1:$((HPORT + 1))-:7999" \
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
        case "$c" in " ") k=spc ;; "-") k=minus ;; "=") k=equal ;; *) k=$c ;; esac
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
has() { tr -d '\r' < "$SERIAL" | grep -qx "$1"; }
count() { tr -d '\r' < "$SERIAL" | grep -cx "$1" || true; }
waitcount() {
    local want=$1 n=$2 i
    for i in $(seq "$3"); do
        if [ "$(count "$want")" -ge "$n" ]; then return 0; fi
        sleep 0.1
    done
    fail "line '$want' x$n"
}
# Salida de la última corrida del comando $1 (hasta el prompt siguiente).
win() {
    tr -d '\r' < "$SERIAL" | awk -v c="lapageria> $1" '
        $0 == c { buf = ""; cap = 1; next }
        cap && /^lapageria> / { cap = 0 }
        cap { buf = buf $0 "\n" }
        END { printf "%s", buf }'
}
# Contador de la sonda $1 en la última salida de `trace count`.
pc() { win "trace count" | awk -v n="$1" '$1 == "probe" && $2 == n { print $3 }'; }
udp_field() { tr -d '\r' < "$SERIAL" | grep '^udp rx ' | tail -1 | tr ' ' '\n' | grep -A1 -x "$1" | tail -1; }
tcp_field() { tr -d '\r' < "$SERIAL" | grep '^tcp rx ' | tail -1 | tr ' ' '\n' | grep -A1 -x "$1" | tail -1; }
# Líneas `t ...` de la última corrida del comando $1.
evs() { win "$1" | grep '^t '; }
# Número de eventos que declara `trace end n K` en la última corrida de $1.
endn() { win "$1" | sed -n 's/^trace end n \([0-9]*\) lost [0-9]*$/\1/p'; }

NAMES="sys-enter sys-exit switch pf pit pg-alloc pg-free blk-read blk-write net-rx net-tx irq-kbd irq-net udp-rx udp-tx tcp-state tcp-retx tcp-rst zone-switch zone-deny"

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"

# Siete archivos caben: se plantan y se sueltan los que no se usan.
typewait "fs format" 50
typewait "exec plant" 80
typewait "fs rm malo" 30
typewait "fs rm gordo" 30
typewait "trace plant" 50
has "trace plant ok" || fail "trace plant"
typewait "udp plant" 80
typewait "fs rm udpdos" 30
typewait "fs rm udpwait" 30
typewait "tcp plant" 80
typewait "fs rm tcpcli" 30
typewait "fs rm tcpmulti" 30
typewait "fs rm tcphog" 30
typewait "zone plant" 50
has "zone plant ok" || fail "zone plant"

# 1. Las 20 sondas existen y arrancan apagadas.
typewait "traza ls" 100
got=$(win "traza ls" | awk '/^[0-9]+ / { printf "%s:%s:%s:%s ", $1, $2, $3, $4 }')
want=""
i=0
for n in $NAMES; do want="$want$i:$n:off:0 "; i=$((i + 1)); done
[ "$got" = "$want" ] || fail "traza ls: [$got], esperaba [$want]"
win "traza ls" | grep -qx "trace lost 0" || fail "traza ls sin 'trace lost 0'"
echo "ok   traza ls: 20 sondas (syscalls, IRQ, red, zonas), todas apagadas al arrancar"

# 2. Punteros y argumentos malos contra las syscalls 23 y 24.
typewait "traza ptr" 100
win "traza ptr" | grep -qx "ptr ok" || fail "traza ptr: $(win 'traza ptr' | tr '\n' '|')"
typewait "traza on nosuch" 30
win "traza on nosuch" | grep -qx "trace bad probe" || fail "traza on nosuch"
echo "ok   punteros del kernel, de código y cruzando el final dan -14; args malos -22; sonda inexistente rechazada"

# 3. Entrada/salida de syscalls: cada sonda se prende y se apaga sola.
typewait "traza on sys-enter" 100
win "traza on sys-enter" | grep -qx "trace on sys-enter" || fail "traza on sys-enter"
typewait "traza on sys-exit" 100
typewait "traza off sys-exit" 100
win "traza off sys-exit" | grep -qx "trace off sys-exit" || fail "traza off sys-exit"
typewait "traza ls" 100
st=$(win "traza ls" | awk '/^[0-9]+ / && $3 == "on" { printf "%s ", $2 }')
[ "$st" = "sys-enter " ] || fail "solo sys-enter debía estar prendida: [$st]"
typewait "traza on sys-exit" 100
typewait "trace clear" 30
typewait "exec hola" 100
typewait "trace count" 30
se=$(pc sys-enter); sx=$(pc sys-exit)
[ "$se" = 13 ] && [ "$sx" = 12 ] || fail "exec hola: sys-enter=$se sys-exit=$sx, esperaba 13 y 12"
echo "ok   sys-enter/sys-exit: exec hola deja 13 entradas y 12 salidas (la de exit no vuelve); cada sonda prende y apaga sola"

# 4. Filtros por evento, zona y pid con dos procesos (pid 1 y 2).
typewait "trace clear" 30
typewait "exec2 hola hola" 150
has "exec2 ok" || fail "exec2 hola hola"
typewait "trace off sys-enter" 30
typewait "trace off sys-exit" 30
typewait "traza dump pid=2 n=32" 100
n2=$(endn "traza dump pid=2 n=32")
[ "$n2" = 25 ] || fail "dump pid=2: $n2 eventos, esperaba 25"
[ "$(evs 'traza dump pid=2 n=32' | grep -vc ' pid 2 ')" = 0 ] || fail "dump pid=2 trajo otro pid"
typewait "traza dump pid=1 ev=sys-exit n=32" 100
n3=$(endn "traza dump pid=1 ev=sys-exit n=32")
[ "$n3" = 12 ] || fail "dump pid=1 ev=sys-exit: $n3, esperaba 12"
[ "$(evs 'traza dump pid=1 ev=sys-exit n=32' | grep -vc ' sys-exit pid 1 ')" = 0 ] || fail "dump pid=1 ev=sys-exit trajo otra cosa"
typewait "traza dump ev=sys-enter zone=0 n=32" 100
n4=$(endn "traza dump ev=sys-enter zone=0 n=32")
[ "$n4" = 26 ] || fail "dump ev=sys-enter zone=0: $n4, esperaba 26"
l=$(evs 'traza dump ev=sys-enter zone=0 n=32')
[ "$(printf '%s\n' "$l" | grep -c ' pid 1 ')" = 13 ] && [ "$(printf '%s\n' "$l" | grep -c ' pid 2 ')" = 13 ] || fail "13 entradas por pid"
[ "$(printf '%s\n' "$l" | grep -vc ' z 0$')" = 0 ] || fail "zone=0 trajo otra zona"
typewait "traza dump zone=1 n=32" 100
[ "$(endn 'traza dump zone=1 n=32')" = 0 ] || fail "dump zone=1 debía estar vacío"
typewait "traza dump n=3" 100
[ "$(endn 'traza dump n=3')" = 3 ] || fail "dump n=3"
echo "ok   filtros: pid=2 -> 25 eventos, pid=1 ev=sys-exit -> 12, ev=sys-enter zone=0 -> 26 (13 por pid), zone=1 -> 0, n=3 -> los 3 últimos"

# 5. IRQ del teclado: cada tecla es un make y un break.
typewait "trace off sys-enter" 30
typewait "trace on irq-kbd" 30
typewait "trace clear" 30
typewait "trace count" 30
typewait "trace off irq-kbd" 30
k=$(win "trace count" | awk '$1 == "probe" && $2 == "irq-kbd" { print $3 }')
[ -n "${k:-}" ] && [ "$k" -ge 22 ] && [ "$k" -le 26 ] || fail "irq-kbd=$k tras teclear 'trace count' (12 teclas, esperaba 22..26)"
typewait "traza dump ev=irq-kbd n=32" 100
l=$(evs 'traza dump ev=irq-kbd n=32')
printf '%s\n' "$l" | grep -q ' irq-kbd pid 0 a 37 b 0 z 0$' || fail "falta el make de 'k' (scancode 37)"
printf '%s\n' "$l" | grep -q ' irq-kbd pid 0 a 165 b 0 z 0$' || fail "falta el break de 'k' (scancode 165)"
echo "ok   irq-kbd: $k IRQ al teclear 'trace count' (11 teclas y ret, make y break), scancodes 37 y 165 de la 'k' de 'trace off irq-kbd'"

# 6. El anillo (64) da la vuelta: ticks consecutivos y lost > 0.
typewait "trace clear" 30
typewait "trace on pit" 30
lost=0
for _ in $(seq 40); do
    sleep 0.25
    typewait "trace count" 30
    lost=$(win "trace count" | sed -n 's/^trace count lost \([0-9]*\)$/\1/p')
    [ "${lost:-0}" -gt 0 ] && break
done
typewait "trace off pit" 30
[ "${lost:-0}" -gt 0 ] || fail "el anillo no dio la vuelta (lost=$lost)"
typewait "traza dump ev=pit n=32" 100
l=$(evs 'traza dump ev=pit n=32')
[ "$(printf '%s\n' "$l" | wc -l | tr -d ' ')" = 32 ] || fail "dump ev=pit n=32 no dio 32 eventos"
printf '%s\n' "$l" | awk '
    { t = $2; a = $7
      if (t != a) { print "t != a en " $0 > "/dev/stderr"; bad = 1 }
      if (NR > 1 && t != prev + 1) { print "salto de tick en " $0 > "/dev/stderr"; bad = 1 }
      prev = t }
    END { exit bad }' || fail "ticks no consecutivos tras dar la vuelta el anillo"
echo "ok   anillo de 64: dio la vuelta (lost $lost) y los últimos 32 pit son ticks consecutivos"

# 7. UDP: las sondas cuentan lo mismo que `udp stat`.
typewait "net up" 150
has "net up ok" || fail "net up"
typewait "traza on udp-rx" 100
typewait "traza on udp-tx" 100
typewait "traza on irq-net" 100
typewait "trace clear" 30
typewait "udp stat" 30
rx0=$(udp_field rx); tx0=$(udp_field tx)
for msg in "hola copihue" "gato" "perro"; do
    p0=$(prompts)
    nl=$(count 'udp listen')
    ne=$(count 'udp echo ok')
    typeline "exec udpeco"
    waitcount "udp listen" $((nl + 1)) 100
    reply=$(printf '%s' "$msg" | socat -t2 - UDP:127.0.0.1:"$HPORT" 2>/dev/null)
    [ "$reply" = "$msg" ] || fail "eco UDP: [$reply] en vez de [$msg]"
    waitcount "udp echo ok" $((ne + 1)) 50
    for _ in $(seq 100); do [ "$(prompts)" -gt "$p0" ] && break; sleep 0.1; done
    [ "$(prompts)" -gt "$p0" ] || fail "exec udpeco no volvió al shell"
done
typewait "udp stat" 30
rx1=$(udp_field rx); tx1=$(udp_field tx)
typewait "trace count" 30
trx=$(pc udp-rx); ttx=$(pc udp-tx); tirq=$(pc irq-net)
# socat puede mandar además un datagrama vacío al cerrar su entrada: las
# sondas tienen que coincidir con `udp stat`, sean 3 o más.
[ "$((rx1 - rx0))" -ge 3 ] && [ "$((tx1 - tx0))" -ge 3 ] || fail "udp stat: rx $rx0 -> $rx1, tx $tx0 -> $tx1, esperaba al menos +3 y +3"
[ "$trx" = "$((rx1 - rx0))" ] && [ "$ttx" = "$((tx1 - tx0))" ] || fail "udp-rx=$trx udp-tx=$ttx, udp stat dice +$((rx1 - rx0)) y +$((tx1 - tx0))"
[ "${tirq:-0}" -ge 3 ] || fail "irq-net=$tirq, esperaba al menos 3 (una por llegada; una IRQ puede traer varias tramas)"
typewait "traza dump ev=udp-rx n=16" 100
l=$(evs 'traza dump ev=udp-rx n=16')
got=$(printf '%s\n' "$l" | awk '{ if ($7 != 7777) bad = 1; if ($9 > 0) printf "%s ", $9 } END { if (bad) printf "BADPORT" }')
[ "$got" = "12 4 5 " ] || fail "udp-rx: puerto/largo [$got], esperaba largos 12 4 5 al 7777"
typewait "traza dump ev=udp-tx n=16" 100
l=$(evs 'traza dump ev=udp-tx n=16')
got=$(printf '%s\n' "$l" | awk '{ if ($9 > 0) printf "%s ", $9 }')
[ "$got" = "12 4 5 " ] || fail "udp-tx: largos [$got], esperaba 12 4 5"
[ "$(printf '%s\n' "$l" | grep -vc ' pid 1 ')" = 0 ] || fail "udp-tx debía ser del pid 1"
echo "ok   UDP: udp-rx $trx == udp stat +$((rx1 - rx0)), udp-tx $ttx == +$((tx1 - tx0)), irq-net $tirq; largos 12 4 5 al puerto 7777, envío desde el pid 1"
typewait "traza off udp-rx" 100
typewait "traza off udp-tx" 100
typewait "traza off irq-net" 100

# 8. TCP: estados, retransmisión y RST == `tcp stat`.
typewait "traza on tcp-state" 100
typewait "traza on tcp-retx" 100
typewait "traza on tcp-rst" 100
typewait "tcp stat" 30
est0=$(tcp_field est); retx0=$(tcp_field retx); rso0=$(tcp_field rstout); rsi0=$(tcp_field rstin)
typewait "trace clear" 30
typewait "tcp fault txdrop 9 1" 30
n_listen=$(count 'tcp listen')
typeline "exec tcpeco"
waitcount "tcp listen" $((n_listen + 1)) 150
head -c 65536 /dev/urandom > "$TMP/in.bin"
"$SOCAT" -t30 - TCP:127.0.0.1:"$HPORT" < "$TMP/in.bin" > "$TMP/out.bin" 2> "$TMP/socat1.err"
cmp "$TMP/in.bin" "$TMP/out.bin" || fail "eco TCP de 64 KiB distinto ($(wc -c < "$TMP/out.bin") bytes)"
reply=$(printf 'adios' | "$SOCAT" -t5 - TCP:127.0.0.1:"$HPORT" 2>/dev/null)
[ "$reply" = "adios" ] || fail "eco TCP, segunda conexión: [$reply]"
waitline "tcp srv done" 200
typewait "tcp fault off" 30
# Conexión a un puerto sin socket: el invitado contesta RST|ACK.
printf 'x' | "$SOCAT" -t1 - TCP:127.0.0.1:$((HPORT + 1)) > /dev/null 2>&1 || true
sleep 1
typewait "tcp stat" 30
est1=$(tcp_field est); retx1=$(tcp_field retx); rso1=$(tcp_field rstout); rsi1=$(tcp_field rstin)
typewait "trace count" 30
tst=$(pc tcp-state); trt=$(pc tcp-retx); trs=$(pc tcp-rst)
lost=$(win "trace count" | sed -n 's/^trace count lost \([0-9]*\)$/\1/p')
[ "$((retx1 - retx0))" -ge 1 ] || fail "tcp stat: no hubo retransmisión ($retx0 -> $retx1)"
[ "$trt" = "$((retx1 - retx0))" ] || fail "tcp-retx=$trt, tcp stat retx +$((retx1 - retx0))"
[ "$((rso1 - rso0))" -ge 1 ] || fail "tcp stat: rstout $rso0 -> $rso1"
[ "$trs" = "$((rso1 - rso0 + rsi1 - rsi0))" ] || fail "tcp-rst=$trs, tcp stat rstout +$((rso1 - rso0)) rstin +$((rsi1 - rsi0))"
[ "$((est1 - est0))" = 2 ] || fail "tcp stat: est $est0 -> $est1, esperaba +2"
[ "${lost:-1}" = 0 ] || fail "el anillo perdió eventos (lost=$lost): el recuento no es exacto"
typewait "traza dump ev=tcp-state n=32" 100
l=$(evs 'traza dump ev=tcp-state n=32')
nest=$(printf '%s\n' "$l" | awk '{ if ($9 % 256 == 4) n++ } END { print n + 0 }')
[ "$nest" = "$((est1 - est0))" ] || fail "tcp-state: $nest transiciones a ESTABLISHED, tcp stat est +$((est1 - est0))"
# SYN_RCVD (3) -> ESTABLISHED (4) = (3 << 8) | 4 = 772; el oyente pasa de 0 a LISTEN (1): b 1.
printf '%s\n' "$l" | grep -q ' b 772 z 0$' || fail "falta SYN_RCVD -> ESTABLISHED (b 772)"
printf '%s\n' "$l" | grep -q ' tcp-state pid [0-9]* a [0-9]* b 1 z 0$' || fail "falta la transición a LISTEN (b 1)"
typewait "traza dump ev=tcp-rst n=8" 100
l=$(evs 'traza dump ev=tcp-rst n=8')
printf '%s\n' "$l" | grep -q " tcp-rst pid [0-9]* a 0 b [0-9]* z 0\$" || fail "falta un RST enviado (a 0)"
echo "ok   TCP: tcp-state $tst (ESTABLISHED $nest == est +$((est1 - est0)), 772 y LISTEN vistos), tcp-retx $trt == retx +$((retx1 - retx0)), tcp-rst $trs == rstout +$((rso1 - rso0)) y rstin +$((rsi1 - rsi0)); lost 0"
typewait "traza off tcp-state" 100
typewait "traza off tcp-retx" 100
typewait "traza off tcp-rst" 100

# 9. Zonas: zone-deny (máscara, escape, ruta) y zone-switch.
typewait "fs rm hola" 30
typewait "zone create a za 12" 50
typewait "traza on zone-deny" 100
typewait "traza on zone-switch" 100
typewait "trace clear" 30
typewait "zone exec a ztest" 200
has "zone exec ok" || fail "zone exec a ztest"
typewait "trace count" 30
typewait "zone ls" 50
zl=$(tr -d '\r' < "$SERIAL" | grep '^zone 1 a pre=' | tail -1)
niega=$(printf '%s\n' "$zl" | sed -n 's/.* niega=\([0-9]*\) .*/\1/p')
fuga=$(printf '%s\n' "$zl" | sed -n 's/.* fuga=\([0-9]*\) .*/\1/p')
zd=$(pc zone-deny)
[ -n "${niega:-}" ] && [ "$niega" -ge 1 ] && [ "$fuga" -ge 1 ] || fail "zone ls: niega=[$niega] fuga=[$fuga] ($zl)"
[ "$zd" -gt "$((niega + fuga))" ] || fail "zone-deny=$zd, esperaba niega $niega + fuga $fuga + denegaciones de ruta (>0)"
typewait "traza dump ev=zone-deny n=32" 100
l=$(evs 'traza dump ev=zone-deny n=32')
[ "$(endn 'traza dump ev=zone-deny n=32')" = 32 ] || fail "dump zone-deny n=32"
[ "$(printf '%s\n' "$l" | grep -vc ' zone-deny pid 1 a -*[0-9]* b [0-9]* z 1$')" = 0 ] || fail "zone-deny: eventos que no son de la zona 1 / pid 1: $(printf "%s\n" "$l" | grep -v " zone-deny pid 1 a -*[0-9]* b [0-9]* z 1\$" | head -3)"
typewait "traza dump ev=zone-deny zone=0 n=32" 100
[ "$(endn 'traza dump ev=zone-deny zone=0 n=32')" = 0 ] || fail "zone-deny con zone=0 debía estar vacío"
echo "ok   zone-deny: $zd eventos (niega $niega + fuga $fuga + rutas $((zd - niega - fuga))), todos de la zona 1; zone=0 no ve ninguno"
typewait "trace clear" 30
typewait "traza zone 1" 100
win "traza zone 1" | grep -qx "traza zone 0 deny -1" || fail "traza zone 1: $(win 'traza zone 1' | tr '\n' '|')"
typewait "traza dump ev=zone-switch n=4" 100
l=$(evs 'traza dump ev=zone-switch n=4')
[ "$(printf '%s\n' "$l" | wc -l | tr -d ' ')" = 1 ] || fail "zone-switch: esperaba 1 evento: $l"
printf '%s\n' "$l" | grep -q ' zone-switch pid 1 a 0 b 1 z 1$' || fail "zone-switch: $l"
typewait "traza dump ev=zone-deny n=4" 100
evs 'traza dump ev=zone-deny n=4' | grep -q ' zone-deny pid 1 a 23 b 1 z 1$' || fail "zone-deny de la syscall 23 en la zona 1"
echo "ok   zone-switch: un proceso de la zona 0 pasa a la zona 1 (a 0 b 1) y su syscall 23 queda denegada por la máscara (zone-deny a 23 b 1)"

# 10. Con todo apagado no se graba nada, y las zonas niegan las syscalls 23 y 24.
typewait "traza off all" 100
typewait "trace clear" 30
typewait "exec udpeco" 100
sleep 0.5
typewait "trace count" 30
sum=$(win "trace count" | awk '$1 == "probe" { s += $3 } END { print s + 0 }')
[ "$sum" = 0 ] || fail "con todo apagado quedaron $sum eventos"
echo "ok   traza off all: con las 20 sondas apagadas no se grabó ningún evento"
typewait "net down" 100
typewait "echo vivo" 30
has "vivo" || fail "el shell no respondió"
echo "ok   net down, shell vivo"
