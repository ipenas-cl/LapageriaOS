#!/usr/bin/env bash
# RD-01: red por interrupciones y UDP, en su propio QEMU.
#
# Arranca la imagen con una red de usuario que reenvía un puerto UDP del
# host (hostfwd) al 7777 del invitado, y habla con ella desde socat:
#
#   net            ARP y ping atendidos por irq_net (`net irq ok`)
#   udp test       recepción, descartes, cola, envío y punteros (sin red)
#   net up         el chip queda prendido, con IRQ
#   exec udpeco    socket UDP desde anillo 3: punteros malos dan -14
#                  (`udp ptr denied`), llega un datagrama de socat y se
#                  devuelve idéntico (`udp echo ok`); socat lo lee de vuelta
#   zone exec n    una zona sin red recibe `udp denied` y `niega` sube
#   zone net m     una zona a la que se le dio red hace el mismo eco
#   exec2 a b      dos procesos con sockets a la vez (udpeco y udpdos)
#   exec udpwait   recv con plazo, despertar por llegada, ráfaga de 64
#   ICMP           port-unreachable a un puerto cerrado, visto en el pcap
#
# El disco de datos es una copia nueva en el directorio temporal.
# UDP_PCAP=ruta guarda la captura de la red de usuario (pcap).
# Uso: tests/qemu_udp_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
PCAP=$TMP/net.pcap
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
trap 'stop_qemu; if [ -n "${UDP_PCAP:-}" ] && [ -f "$PCAP" ]; then cp "$PCAP" "$UDP_PCAP"; fi; rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*"
    echo "--- serial ---"
    tr -d '\r' < "$SERIAL" 2>/dev/null || true
    exit 1
}

# El puerto del host sale de $RANDOM; si está ocupado QEMU no arranca y
# se prueba otro.
start_qemu() {
    local try
    for try in 1 2 3 4 5 6; do
        HPORT=$((20000 + RANDOM % 30000))
        : > "$SERIAL"
        rm -f "$MON"
        qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$IMAGE" \
            -drive file="$DATA",format=raw,if=ide,index=1 \
            -display none -no-reboot \
            -nic none -netdev user,id=n0,hostfwd=udp:127.0.0.1:"$HPORT"-:7777,hostfwd=udp:127.0.0.1:$((HPORT + 1))-:7781,hostfwd=udp:127.0.0.1:$((HPORT + 2))-:7782,hostfwd=udp:127.0.0.1:$((HPORT + 3))-:7790,hostfwd=udp:127.0.0.1:$((HPORT + 4))-:7999 \
            -device e1000,netdev=n0 -object filter-dump,id=f0,netdev=n0,file="$PCAP" \
            -serial file:"$SERIAL" -monitor unix:"$MON",server,nowait &
        QPID=$!
        sleep 0.5
        if kill -0 "$QPID" 2>/dev/null; then return 0; fi
        wait "$QPID" 2>/dev/null || true
        QPID=""
    done
    fail "qemu did not start (hostfwd or disk)"
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
# Escribe el comando y espera el prompt siguiente (decimas de segundo).
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
# Espera una línea exacta en la serie, a partir de la posición `$2` de líneas.
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

# Manda $1 al puerto del host ($2, por defecto HPORT) y lee lo que vuelva
# (2 s). Imprime la respuesta.
udp_ask() {
    printf '%s' "$1" | socat -t2 - UDP:127.0.0.1:"${2:-$HPORT}" 2>/dev/null
}
# Campo de la última línea `udp stat`: udp_field nosock, full, rx, unr, ...
udp_field() {
    tr -d '\r' < "$SERIAL" | grep '^udp rx ' | tail -1 | tr ' ' '\n' | grep -A1 -x "$1" | tail -1
}
net_field() {
    tr -d '\r' < "$SERIAL" | grep '^net ring ' | tail -1 | tr ' ' '\n' | grep -A1 -x "$1" | tail -1
}

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"
out=$(echo "info network" | socat - UNIX-CONNECT:"$MON" 2>/dev/null || true)
printf '%s\n' "$out" | grep -q "hostfwd\|type=user" || fail "qemu has no user netdev"

# 1. ARP y ping atendidos por la interrupción.
typewait "net" 150
has "net arp ok" || fail "net arp"
has "net ping ok" || fail "net ping"
has "net irq ok" || fail "net irq (la interrupción no atendió las tramas)"
has "net drop ok" || fail "net drop"
echo "ok   net por IRQ: arp, ping y descarte sin sondeo"

# 2. UDP sin red: recepción, descartes, cola, envío, punteros.
typewait "udp test" 50
has "udp test ok" || fail "udp test"
echo "ok   udp test: checksum a mano 0x5C2D, 0 sin checksum, descartes, cola, envío, punteros del kernel"

# 3. Eco desde anillo 3.
typewait "fs format" 50
typewait "udp plant" 50
has "udp plant ok" || fail "udp plant"
typewait "net up" 150
has "net up ok" || fail "net up"
typeline "exec udpeco"
waitline "udp listen" 100
# Sin esperar: el programa ya está en el lazo de recv.
reply=$(udp_ask "hola copihue")
[ "$reply" = "hola copihue" ] || fail "eco: socat recibió [$reply]"
waitline "udp echo ok" 50
has "udp ptr denied" || fail "los punteros malos no dieron -14"
for _ in $(seq 50); do [ "$(prompts)" -ge 5 ] && break; sleep 0.1; done
echo "ok   eco UDP: socat -> hostfwd -> e1000 (IRQ) -> socket de anillo 3 -> e1000 -> socat, punteros malos denegados"
typewait "net stat" 30
isr=$(tr -d '\r' < "$SERIAL" | sed -n 's/^net on 1 irq [0-9]* irqs [0-9]* isr \([0-9]*\) poll [0-9]*$/\1/p' | tail -1)
poll=$(tr -d '\r' < "$SERIAL" | sed -n 's/^net on 1 irq [0-9]* irqs [0-9]* isr [0-9]* poll \([0-9]*\)$/\1/p' | tail -1)
[ -n "${isr:-}" ] && [ "$isr" -ge 2 ] || fail "net stat isr=[${isr:-}]"
[ "${poll:-1}" = 0 ] || fail "net stat poll=[${poll:-}]: hubo recepción por sondeo"
echo "ok   recepción solo por interrupción (isr=$isr poll=$poll)"

# Un datagrama a un puerto sin socket se descarta y el kernel sigue vivo.
nosock_of() {
    tr -d '\r' < "$SERIAL" | sed -n 's/^udp rx [0-9]* bad [0-9]* nosock \([0-9]*\) full.*$/\1/p' | tail -1
}
typewait "udp stat" 30
nos0=$(nosock_of)
[ -n "${nos0:-}" ] || fail "udp stat sin datos"
# bash manda exactamente un datagrama (socat manda además uno vacío al
# ver el fin de la entrada).
printf '%s' "nadie" > /dev/udp/127.0.0.1/"$HPORT"
sleep 0.5
typewait "udp stat" 30
nos1=$(nosock_of)
[ "${nos1:-x}" = "$((nos0 + 1))" ] || fail "udp stat nosock $nos0 -> ${nos1:-}, quería +1"
echo "ok   datagrama a puerto sin socket descartado (nosock $nos0 -> $nos1)"

# 4. Zonas: sin permiso de red, negación; con permiso, eco.
typewait "zone create n 12" 50
typewait "zone create m 12" 50
typewait "zone exec n udpeco" 150
waitline "udp denied" 50
has "zone exec ok" || fail "zone exec n no terminó"
typewait "zone ls" 50
niega=$(tr -d '\r' < "$SERIAL" | grep '^zone [0-9]* n root=' | tail -1)
echo "$niega" | grep -q "niega=[1-9]" || fail "zone ls: n sin niega ($niega)"
[ "$(count 'udp ptr denied')" = 1 ] || fail "la zona sin red llegó a las pruebas de punteros"
echo "ok   zona sin red: udp denied y niega>0"

typewait "zone net m" 30
has "zone net ok" || fail "zone net"
typeline "zone exec m udpeco"
waitline "udp listen" 100
for _ in $(seq 100); do [ "$(count 'udp listen')" -ge 2 ] && break; sleep 0.1; done
[ "$(count 'udp listen')" -ge 2 ] || fail "la zona m no abrió el puerto"
reply=$(udp_ask "desde zona")
[ "$reply" = "desde zona" ] || fail "eco en zona: socat recibió [$reply]"
for _ in $(seq 100); do [ "$(count 'zone exec ok')" -ge 2 ] && break; sleep 0.1; done
[ "$(count 'zone exec ok')" -ge 2 ] || fail "zone exec m no terminó"
[ "$(count 'udp ptr denied')" = 2 ] || fail "zona con red: punteros malos"
echo "ok   zona con red (zone net): eco UDP, punteros malos denegados"

# El socket se cerró con el proceso: el puerto vuelve a estar libre.
typeline "exec udpeco"
for _ in $(seq 100); do [ "$(count 'udp listen')" -ge 3 ] && break; sleep 0.1; done
[ "$(count 'udp listen')" -ge 3 ] || fail "el puerto 7777 no se liberó al morir el proceso"
reply=$(udp_ask "otra vez")
[ "$reply" = "otra vez" ] || fail "eco tras reabrir: socat recibió [$reply]"
for _ in $(seq 100); do [ "$(count 'exec ok')" -ge 2 ] && break; sleep 0.1; done
[ "$(count 'exec ok')" -ge 2 ] || fail "exec udpeco no terminó la segunda vez"
echo "ok   el puerto se libera al terminar el proceso"

# 5. RD-01 parte 2. Dos procesos con sockets distintos a la vez: udpeco
# (7777) y udpdos (7781 y 7782, dos sockets en un proceso). Los tres
# datagramas salen juntos; cada proceso duerme en recv y lo despierta el suyo.
typewait "udp stat" 30
blk0=$(udp_field blk); woke0=$(udp_field woke)
typeline "exec2 udpeco udpdos"
for _ in $(seq 100); do [ "$(count 'udp listen')" -ge 4 ] && has "udp dos listen" && break; sleep 0.1; done
[ "$(count 'udp listen')" -ge 4 ] || fail "exec2: udpeco no abrió su socket"
has "udp dos listen" || fail "exec2: udpdos no abrió sus sockets"
udp_ask "uno" "$HPORT" > "$TMP/r1" & p1=$!
udp_ask "dos" "$((HPORT + 1))" > "$TMP/r2" & p2=$!
udp_ask "tres" "$((HPORT + 2))" > "$TMP/r3" & p3=$!
wait "$p1" "$p2" "$p3"
[ "$(cat "$TMP/r1")" = "uno" ] || fail "exec2: eco de udpeco [$(cat "$TMP/r1")]"
[ "$(cat "$TMP/r2")" = "dos" ] || fail "exec2: eco del socket 0 de udpdos [$(cat "$TMP/r2")]"
[ "$(cat "$TMP/r3")" = "tres" ] || fail "exec2: eco del socket 1 de udpdos [$(cat "$TMP/r3")]"
waitline "exec2 ok" 100
has "udp dos echo ok" || fail "exec2: udpdos no terminó el eco"
[ "$(count 'udp echo ok')" -ge 4 ] || fail "exec2: udpeco no terminó el eco"
for _ in $(seq 50); do [ "$(prompts)" -ge 8 ] && break; sleep 0.1; done
typewait "udp stat" 30
blk1=$(udp_field blk); woke1=$(udp_field woke)
[ "$((blk1 - blk0))" -ge 2 ] || fail "exec2: blk $blk0 -> $blk1 (esperaba >= 2 recv dormidos)"
[ "$((woke1 - woke0))" -ge 1 ] || fail "exec2: woke $woke0 -> $woke1 (ningún despertar por llegada)"
echo "ok   dos procesos a la vez (exec2): 3 ecos, 3 sockets, dormidos $((blk1 - blk0)), despertados por llegada $((woke1 - woke0))"

# recv bloqueante con plazo, despertar por llegada y ráfaga de 64.
tmo0=$(udp_field tmo); full0=$(udp_field full); rx0=$(udp_field rx); bad0=$(udp_field bad)
typeline "exec udpwait"
waitline "udp timeout ok" 100
echo "ok   recv con plazo: -110 a los 50 ticks, el proceso durmió"
waitline "udp sleep" 50
printf '%s' "despierta" > /dev/udp/127.0.0.1/$((HPORT + 3))
waitline "udp wake ok" 50
echo "ok   recv dormido: lo despertó el datagrama (antes del plazo de 600 ticks)"
waitline "udp burst go" 50
for i in $(seq 0 63); do
    printf "\\$(printf '%03o' $((33 + i)))x" > /dev/udp/127.0.0.1/$((HPORT + 3))
done
waitline "udp burst n=64" 150
waitline "udp burst ok" 100
for _ in $(seq 100); do [ "$(count 'exec ok')" -ge 3 ] && break; sleep 0.1; done
[ "$(count 'exec ok')" -ge 3 ] || fail "udpwait no terminó"
typewait "udp stat" 30
tmo1=$(udp_field tmo); full1=$(udp_field full); rx1=$(udp_field rx); bad1=$(udp_field bad)
[ "$((rx1 - rx0))" = 65 ] || fail "ráfaga: rx $rx0 -> $rx1, quería +65 (64 más el de despertar)"
[ "$((full1 - full0))" = 0 ] || fail "ráfaga: full $full0 -> $full1 (colas llenas)"
[ "$((bad1 - bad0))" = 0 ] || fail "ráfaga: bad $bad0 -> $bad1"
[ "$((tmo1 - tmo0))" -ge 3 ] || fail "tmo $tmo0 -> $tmo1 (esperaba >= 3 plazos vencidos)"
typewait "net stat" 30
rxo=$(net_field rxo); mpc=$(net_field mpc)
[ -n "${rxo:-}" ] && [ -n "${mpc:-}" ] || fail "net stat sin rxo/mpc"
[ "$mpc" = 0 ] || fail "ráfaga: el chip perdió $mpc tramas (mpc)"
echo "ok   ráfaga de 64 datagramas: 64 entregados en orden, full +0, mpc $mpc, rxo $rxo"

# ICMP port-unreachable: un datagrama al 7999 del invitado (sin socket).
# El host lo ve en la captura de la red: ICMP tipo 3 código 3 del 10.0.2.15
# al 10.0.2.2 con el puerto 7999 (0x1F3F) en el UDP original.
typewait "udp stat" 30
unr0=$(udp_field unr); nos0=$(udp_field nosock)
printf '%s' "cerrado" > /dev/udp/127.0.0.1/$((HPORT + 4))
sleep 0.5
typewait "udp stat" 30
unr1=$(udp_field unr); nos1=$(udp_field nosock)
[ "$((nos1 - nos0))" = 1 ] || fail "unreachable: nosock $nos0 -> $nos1"
[ "$((unr1 - unr0))" = 1 ] || fail "unreachable: unr $unr0 -> $unr1, el invitado no envió el ICMP"
sleep 0.3
hex=$(od -An -v -tx1 "$PCAP" | tr -d ' \n')
printf '%s' "$hex" | grep -Eq '0a00020f0a0002020303[0-9a-f]{4}00000000[0-9a-f]{40}[0-9a-f]{4}1f3f' \
    || fail "la captura no tiene el ICMP port-unreachable al puerto 7999"
if command -v tcpdump >/dev/null 2>&1; then
    dump=$(tcpdump -nn -vv -r "$PCAP" icmp 2>/dev/null || true)
    printf '%s\n' "$dump" | grep -q "10.0.2.15 > 10.0.2.2: ICMP 10.0.2.15 udp port 7999 unreachable" \
        || fail "tcpdump no ve el unreachable: $dump"
    if printf '%s\n' "$dump" | grep -qi "bad cksum\|bad udp cksum\|incorrect"; then
        fail "tcpdump marca un checksum malo: $dump"
    fi
    echo "ok   port-unreachable visto desde el host (tcpdump): 10.0.2.15 udp port 7999 unreachable, checksums bien"
else
    echo "ok   port-unreachable visto desde el host (bytes de la captura; sin tcpdump no se revisó el checksum)"
fi

# Ráfaga que llena el anillo de recepción. `net hold` apaga las interrupciones
# del chip 150 ticks; en ese tiempo el host manda 40 datagramas a un puerto
# sin socket (más que los 31 descriptores útiles). No se puede perder ninguno
# sin que se vea: nosock + mpc tiene que dar 40, y unr + unrdrop también.
sleep 1.2
typewait "udp stat" 30
nos0=$(udp_field nosock); unr0=$(udp_field unr); drp0=$(udp_field unrdrop)
typeline "net hold 150"
waitline "net hold go" 30
for i in $(seq 1 40); do
    printf 'rafaga%s' "$i" > /dev/udp/127.0.0.1/$((HPORT + 4))
done
for _ in $(seq 100); do tr -d '\r' < "$SERIAL" | grep -q '^net hold ring ' && break; sleep 0.1; done
holdl=$(tr -d '\r' < "$SERIAL" | grep '^net hold ring ' | tail -1)
[ -n "$holdl" ] || fail "net hold no terminó"
ring=$(printf '%s\n' "$holdl" | sed -n 's/^net hold ring \([0-9]*\) drained .*$/\1/p')
drained=$(printf '%s\n' "$holdl" | sed -n 's/^net hold ring [0-9]* drained \([0-9]*\) mpc .*$/\1/p')
hmpc=$(printf '%s\n' "$holdl" | sed -n 's/^.* mpc \([0-9]*\)$/\1/p')
[ "${ring:-0}" -ge 31 ] || fail "net hold: el anillo no se llenó ($holdl)"
sleep 0.5
typewait "udp stat" 30
nos1=$(udp_field nosock); unr1=$(udp_field unr); drp1=$(udp_field unrdrop)
[ "$((nos1 - nos0 + hmpc))" = 40 ] || fail "net hold: nosock +$((nos1 - nos0)) y mpc $hmpc, no suman 40 ($holdl)"
[ "$((unr1 - unr0 + drp1 - drp0))" = "$((nos1 - nos0))" ] || fail "net hold: unr+unrdrop no cierra con nosock"
echo "ok   anillo lleno ($ring descriptores listos de 31): $((nos1 - nos0)) de 40 atendidas, mpc $hmpc, ICMP $((unr1 - unr0)) enviados y $((drp1 - drp0)) por el tope"
typewait "net down" 30
has "net down ok" || fail "net down"
typewait "echo vivo" 20
has "vivo" || fail "el shell no respondió"
echo "ok   net down, shell vivo"
