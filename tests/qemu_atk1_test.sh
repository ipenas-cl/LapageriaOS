#!/usr/bin/env bash
# EX-03: ataques de anillo 3 contra un AXE1 (SG-01 parte 2 y SG-02), los mismos
# que corre tests/qemu_shell_test.sh, pero solos y con QEMU_EXTRA, para
# repetirlos con `-icount shift=7` y sin icount (tests/repeat.sh). La prueba
# grande del shell mezcla comprobaciones de tiempo del PIT y no sirve con
# icount.
#
# Un solo programa (`zatk`, src/user/ataque.lap) hace un ataque por corrida; el
# modo está en el archivo `q` de la zona k. Cada ataque tiene que terminar con
# `user killed ...` (el kernel mata solo a ese proceso), sin `atk survived`, con
# `zone exec ok` (volvió al shell), sin `zone leak`, y el shell tiene que
# seguir vivo para el ataque siguiente. Al final: punteros del kernel como
# argumento de syscalls (todos negados) y un AXE1 con la entrada en el kernel
# (`exec bad entry`).
#
# Nada depende del reloj: cada paso espera el prompt siguiente. El disco de
# datos y la imagen son copias nuevas en el directorio temporal;
# QEMU_EXTRA="-icount shift=7" suma opciones a QEMU.
# Uso: tests/qemu_atk1_test.sh [imagen]
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

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"

typewait "fs format" 100
typewait "zone atk" 300
has "zone atk plant ok" || fail "zone atk no escribió zatk"
typewait "zone create k 12" 200
typewait "fs write /zonas/k/q 1" 100
attack_n=0
# atk_run modo vec err addr: el #PF trae CR2 en addr; el #GP trae RIP.
atk_run() {
    local mode=$1 vec=$2 err=$3 addr=$4 off win kill
    typewait "fs write /zonas/k/q $mode" 100
    off=$(wc -c < "$SERIAL" | tr -d ' ')
    typewait "zone exec k zatk" 300
    win=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
    printf '%s\n' "$win" | grep -qx "atk $mode" || fail "attack $mode did not start: $win"
    printf '%s\n' "$win" | grep -q 'atk survived' && fail "attack $mode SURVIVED: the kernel did not deny it"
    printf '%s\n' "$win" | grep -q 'X' && fail "attack $mode read a value it should not have"
    kill=$(printf '%s\n' "$win" | grep '^user killed ' || true)
    [ "$(printf '%s\n' "$kill" | grep -c .)" = 1 ] || fail "attack $mode: want one 'user killed' line, got [$kill]"
    printf '%s\n' "$kill" | grep -Eq "^user killed pid=1 vec=$vec err=$err addr=$addr\$" || fail "attack $mode: wrong fault [$kill] (want vec=$vec err=$err addr=$addr)"
    printf '%s\n' "$win" | grep -qx 'zone exec ok' || fail "attack $mode: shell did not get control back"
    printf '%s\n' "$win" | grep -q 'zone leak' && fail "attack $mode leaked memory"
    printf '%s\n' "$win" | grep -q 'pf-cross' && fail "attack $mode went down the sched recovery path"
    printf '%s\n' "$win" | grep -q 'user leak' && fail "attack $mode ran a denied syscall"
    attack_n=$((attack_n + 1))
}
K=0xffffffff80400000
H=0xffff800000001000
# Mitad alta del kernel: leer y escribir. P|U sin escritura es 0x5; con
# escritura, 0x7.
atk_run 1 14 0x00000005 $K
atk_run 2 14 0x00000007 $K
atk_run 3 14 0x00000005 $H
atk_run 4 14 0x00000007 $H
atk_run 5 14 0x00000005 0x0000000000001000
# NX: pila y página pedida con la syscall 8 (error 0x15 = P, U, fetch); el
# texto del kernel tampoco se ejecuta desde anillo 3.
atk_run 6 14 0x00000015 0x0000000000401800
atk_run 7 14 0x00000015 0x0000000000402000
atk_run 9 14 0x00000015 $K
# Su propio código es de solo lectura (P, W, U).
atk_run 8 14 0x00000007 0x0000000000400000
# Dirección no canónica: #GP con addr = RIP, o #PF con CR2 = la dirección según
# el QEMU; nada más.
atk_run a '(13|14)' '0x0000000[05]' '(0x00000000004[0-9a-f]{5}|0x8000000000000000)'
tr -d '\r' < "$SERIAL" | grep '^user killed ' | grep -Eq 'vec=13 err=0x00000000 addr=0x00000000004|vec=14 err=0x00000005 addr=0x8000000000000000$' || fail "attack a: unexpected fault combination"
# Página de usuario que no existe (no presente, U).
atk_run b 14 0x00000004 0x0000000000500000
# SG-02: excepciones de CPU de anillo 3 que no son #PF ni #GP de memoria. El
# addr de `user killed` es el RIP de la instrucción que falla; se exige que
# esté dentro del programa y que los bytes de build/ataque.bin en ese RIP sean
# la instrucción esperada.
ATK_BIN=$(dirname "$IMAGE")/ataque.bin
[ -f "$ATK_BIN" ] || fail "no $ATK_BIN to check the faulting instruction"
exc_bytes() {
    local rip=$1 n=$2 off
    off=$((rip - 0x400000))
    [ "$off" -ge 0 ] && [ "$off" -lt "$(wc -c < "$ATK_BIN")" ] || { echo "fuera"; return; }
    od -An -tx1 -v -j "$off" -N "$n" "$ATK_BIN" | tr -d ' \n'
}
# exc_run modo vec err regex_de_bytes_en_rip
exc_run() {
    local mode=$1 vec=$2 err=$3 want=$4 rip got
    atk_run "$mode" "$vec" "$err" '0x00000000004[0-9a-f]{5}'
    rip=$(tr -d '\r' < "$SERIAL" | grep '^user killed ' | tail -1 | sed 's/.* addr=//')
    got=$(exc_bytes "$((rip))" 3)
    printf '%s\n' "$got" | grep -Eq "^$want" || fail "attack $mode: bytes at RIP $rip are [$got], want $want"
}
exc_run u 6 0x00000000 '0f0b'
exc_run z 0 0x00000000 '(48)?f7'
exc_run r 0 0x00000000 '(48)?f7'
exc_run m 0 0x00000000 '(48)?f7'
exc_run i 13 0x0000001a 'cd03'
typewait "zone ls" 100
zk=$(tr -d '\r' < "$SERIAL" | grep -E '^zone [0-9]+ k root=/zonas/k ' | tail -1)
[ -n "$zk" ] || fail "zone k missing after the attacks"
printf '%s\n' "$zk" | grep -q ' pag=0 ' || fail "zone k kept pages after being killed ($zk)"
printf '%s\n' "$zk" | grep -q 'proc=0/' || fail "zone k kept a process after being killed ($zk)"
typewait "echo vivo2" 50
has "vivo2" || fail "shell did not answer after the attacks"
echo "ok   ring 3 vs AXE1: $attack_n ataques (leer/escribir kernel, ejecutar kernel, ejecutar pila y página NX, escribir su código, no canónica, sin mapa, #UD, #DE x3, int 3) mataron solo al proceso"

# Punteros del kernel como argumento de syscalls: se niegan y nada se filtra.
typewait "fs write /zonas/k/q d" 100
off=$(wc -c < "$SERIAL" | tr -d ' ')
typewait "zone exec k zatk" 300
win=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
printf '%s\n' "$win" | grep -qx 'atk d' || fail "pointer attack did not start: $win"
printf '%s\n' "$win" | grep -qx 'zone ptr denied' || fail "kernel pointers as syscall arguments were not all denied: $win"
printf '%s\n' "$win" | grep -q 'atk survived' && fail "a kernel pointer argument was accepted"
printf '%s\n' "$win" | grep -q 'user killed' && fail "pointer attack faulted: the kernel touched a bad address?"
printf '%s\n' "$win" | grep -qx 'zone exec ok' || fail "pointer attack did not finish"
typewait "fs cat /zonas/k/q" 100
tr -d '\r' < "$SERIAL" | awk '$0=="lapageria> fs cat /zonas/k/q" {f=1; next} f && /^fs live / {print; exit}' | grep -qx 'fs live d' || fail "pointer attack changed the file"
typewait "exec kentry" 100
typewait "zone exec k kentry" 100
tr -d '\r' < "$SERIAL" | awk '
/^lapageria> exec kentry$/ { f=1; next }
f && /^exec bad entry$/ && !a { a=1; next }
f && /^lapageria> zone exec k kentry$/ { g=1; next }
g && /^exec bad entry$/ { b=1 }
/run begin/ && f { r=1 }
END { exit !(a && b && !r) }
' || fail "AXE1 with entry in the kernel was not rejected, or it ran"
echo "ok   punteros del kernel como argumento negados; AXE1 con entrada en el kernel rechazado (exec bad entry)"
