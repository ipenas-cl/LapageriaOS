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

# 4. Cabeceras AXE2 malas. `exec hdrcheck` estropea una a una la cabecera de
# pag2 y pasa cada una por exec_hdr, que es lo que usan exec, exec2 y zone
# exec. El kernel solo imprime el resultado: lo esperado está aquí.
typewait "exec hdrcheck" 300
has "exec hdrcheck done" || fail "exec hdrcheck no terminó: $(since 'exec hdrcheck')"
hdr_want() {
    local name=$1 want=$2 got
    got=$(tr -d '\r' < "$SERIAL" | grep "^hdr $name " | tail -1 | sed "s/^hdr $name //")
    [ "$got" = "$want" ] || fail "hdr $name: esperaba [$want], salió [$got]"
}
hdr_want base "ok"
hdr_want textall "ok"
hdr_want mem16 "ok"
hdr_want memodd "ok"
for h in size0 size65537 sizemax sizelong memshort mem0 mem17 memmax text0 textlong textmax pad n31 n32 n15 short; do
    hdr_want "$h" "bad size"
done
for h in entlow entend entdata entio entkern enthigh entbit63; do
    hdr_want "$h" "bad entry"
done
hdr_want magic "bad magic"
nh=$(tr -d '\r' < "$SERIAL" | grep -c '^hdr ')
[ "$nh" = 28 ] || fail "hdrcheck: esperaba 28 líneas hdr, hay $nh"
echo "ok   cabeceras AXE2 malas: tamaños, páginas fuera de 1..16, texto > imagen, entradas fuera del texto, reservado, magic y archivo corto rechazados; los bordes válidos pasan ($nh casos)"

# 5. Ataques de anillo 3 contra un AXE2. Un programa (atk2, src/user/atk2.lap)
# hace un ataque por corrida; el modo está en el archivo `q` de la zona k. Cada
# ataque tiene que terminar con `user killed ...` (el kernel mata solo a ese
# proceso), sin `atk2 survived`, con `zone exec ok` (volvió al shell), sin
# `zone leak` y con el shell vivo para el ataque siguiente.
typewait "zone create k 12" 200
typewait "fs write /zonas/k/q a" 100
attack_n=0
# atk_run modo vec err addr [programa]: el #PF trae CR2 en addr; el #GP trae RIP.
atk_run() {
    local mode=$1 vec=$2 err=$3 addr=$4 prog=${5:-atk2} off win kill
    typewait "fs write /zonas/k/q $mode" 100
    off=$(wc -c < "$SERIAL" | tr -d ' ')
    typewait "zone exec k $prog" 300
    win=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
    printf '%s\n' "$win" | grep -qx "atk2 $mode" || fail "attack $mode did not start: $win"
    printf '%s\n' "$win" | grep -q 'atk2 survived' && fail "attack $mode SURVIVED: the kernel did not deny it"
    printf '%s\n' "$win" | grep -qx 'X' && fail "attack $mode read a value it should not have"
    kill=$(printf '%s\n' "$win" | grep '^user killed ' || true)
    [ "$(printf '%s\n' "$kill" | grep -c .)" = 1 ] || fail "attack $mode: want one 'user killed' line, got [$kill]"
    printf '%s\n' "$kill" | grep -Eq "^user killed pid=1 vec=$vec err=$err addr=$addr\$" || fail "attack $mode: wrong fault [$kill] (want vec=$vec err=$err addr=$addr)"
    printf '%s\n' "$win" | grep -qx 'zone exec ok' || fail "attack $mode: shell did not get control back"
    printf '%s\n' "$win" | grep -q 'zone leak' && fail "attack $mode leaked memory"
    printf '%s\n' "$win" | grep -q 'pf-cross' && fail "attack $mode went down the sched recovery path"
    printf '%s\n' "$win" | grep -q 'user leak' && fail "attack $mode ran a denied syscall"
    attack_n=$((attack_n + 1))
}
# Escribir en el texto (P, W, U: error 7), primer y último byte.
atk_run a 14 0x00000007 0x0000000000400000
atk_run b 14 0x00000007 0x0000000000400fff
# NX: datos, bss, E/S, pila y la página pedida con la syscall 8 tienen un ret
# (0xC3) en el destino; si se ejecutaran, el programa volvería y diría
# `atk2 survived`. Error 0x15 = P, U, fetch.
atk_run c 14 0x00000015 0x0000000000401000
atk_run d 14 0x00000015 0x0000000000402000
atk_run e 14 0x00000015 0x0000000000410000
atk_run f 14 0x00000015 0x0000000000411000
atk_run q 14 0x00000015 0x0000000000412000
# Fuera de sus páginas: justo después de la bss (leer: no presente, error 4;
# escribir: error 6), el hueco antes de la E/S, sobre la pila y bajo la imagen.
atk_run g 14 0x00000004 0x0000000000403000
atk_run h 14 0x00000006 0x0000000000403000
atk_run i 14 0x00000004 0x000000000040ffff
atk_run j 14 0x00000004 0x0000000000412000
atk_run k 14 0x00000004 0x00000000003fffff
# La pila se desborda hacia abajo: cruza la E/S (suya) y cae en el hueco.
atk_run s 14 0x00000006 '0x000000000040f[0-9a-f]{3}'
# Memoria del kernel y tablas, igual que el AXE1.
atk_run l 14 0x00000005 0xffffffff80400000
atk_run m 14 0x00000007 0xffff800000001000
atk_run n 14 0x00000005 0x0000000000001000
# Dirección no canónica: #GP (RIP) o #PF (CR2), según el QEMU; nada más.
atk_run o '(13|14)' '0x0000000[05]' '(0x00000000004[0-9a-f]{5}|0x8000000000000000)'
tr -d '\r' < "$SERIAL" | grep '^user killed ' | grep -Eq 'vec=13 err=0x00000000 addr=0x00000000004|vec=14 err=0x00000005 addr=0x8000000000000000$' || fail "attack o: unexpected fault combination"
# Dos páginas de texto: la segunda deja de ser de datos y es de solo lectura.
atk_run w 14 0x00000007 0x0000000000401000 atk2w
echo "ok   ring 3 vs un AXE2: $attack_n ataques (escribir texto, ejecutar datos/bss/E-S/pila/pág. pedida, leer y escribir fuera de sus páginas, desbordar la pila, kernel, no canónica, escribir texto de 2 páginas) mataron solo al proceso"

# Control: la misma escritura en la segunda página de atk2 (datos) no mata a nadie.
typewait "fs write /zonas/k/q w" 100
off=$(wc -c < "$SERIAL" | tr -d ' ')
typewait "zone exec k atk2" 300
win=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
printf '%s\n' "$win" | grep -qx 'atk2 w ok' || fail "control w: atk2 no pudo escribir su página de datos: $win"
printf '%s\n' "$win" | grep -q 'user killed' && fail "control w: mataron a atk2: $win"
printf '%s\n' "$win" | grep -qx 'zone exec ok' || fail "control w no terminó: $win"
echo "ok   control: escribir la segunda página de atk2 (datos) funciona; solo en atk2w, con texto de 2 páginas, la matan"

# Punteros de usuario malos en una syscall: se niegan con -14, nadie muere y el
# texto queda igual; los rangos válidos que cruzan de datos a bss funcionan.
# La syscall 23 (trace_ctl, op 5, escribe 16 bytes en el puntero) está fuera de
# la máscara de una zona nueva: `zone trace k` la agrega.
typewait "zone trace k" 100
has "zone trace ok" || fail "zone trace k: $(since 'zone trace k')"
typewait "fs write /zonas/k/q p" 100
off=$(wc -c < "$SERIAL" | tr -d ' ')
typewait "zone exec k atk2" 300
win=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
printf '%s\n' "$win" | grep -qx 'atk2 p' || fail "pointer attack did not start: $win"
printf '%s\n' "$win" | grep -qx 'atk2 ptr denied' || fail "syscall con punteros malos de un AXE2 no se negó todo: $win"
printf '%s\n' "$win" | grep -q 'atk2 survived' && fail "un puntero malo se aceptó: $win"
printf '%s\n' "$win" | grep -q 'user killed' && fail "pointer attack faulted: el kernel tocó una dirección mala?: $win"
printf '%s\n' "$win" | grep -qx 'zone exec ok' || fail "pointer attack no terminó: $win"
echo "ok   punteros malos (texto, hueco, fin de imagen, tope de pila, kernel, enormes) negados con -14 en un AXE2; los rangos válidos cruzan de página"

# Nada quedó tomado y todo sigue en pie.
typewait "zone ls" 100
zk=$(tr -d '\r' < "$SERIAL" | grep -E '^zone [0-9]+ k root=/zonas/k ' | tail -1)
[ -n "$zk" ] || fail "zone k missing after the attacks"
printf '%s\n' "$zk" | grep -q ' pag=0 ' || fail "zone k kept pages after being killed ($zk)"
printf '%s\n' "$zk" | grep -q 'proc=0/' || fail "zone k kept a process after being killed ($zk)"
typewait "exec pag2" 600
[ "$(count 'pag2 ok')" -ge 3 ] || fail "exec pag2 después de los ataques: pag2 ok x$(count 'pag2 ok')"
typewait "echo vivo2" 50
has "vivo2" || fail "el shell no respondió después de los ataques"
echo "ok   tras los ataques: zona k con pag=0 y sin procesos, exec pag2 sigue dando pag2 ok, shell vivo"
