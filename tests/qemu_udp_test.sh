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
            -nic none -netdev user,id=n0,hostfwd=udp:127.0.0.1:"$HPORT"-:7777 \
            -device e1000,netdev=n0 ${UDP_PCAP:+-object filter-dump,id=f0,netdev=n0,file=$UDP_PCAP} \
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

# Manda $1 al puerto del host y lee lo que vuelva (2 s). Imprime la respuesta.
udp_ask() {
    printf '%s' "$1" | socat -t2 - UDP:127.0.0.1:"$HPORT" 2>/dev/null
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
typewait "zone create n zn 12" 50
typewait "zone create m zm 12" 50
typewait "zone exec n udpeco" 150
waitline "udp denied" 50
has "zone exec ok" || fail "zone exec n no terminó"
typewait "zone ls" 50
niega=$(tr -d '\r' < "$SERIAL" | grep '^zone [0-9]* n pre=' | tail -1)
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
typewait "net down" 30
has "net down ok" || fail "net down"
typewait "echo vivo" 20
has "vivo" || fail "el shell no respondió"
echo "ok   net down, shell vivo"
