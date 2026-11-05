#!/usr/bin/env bash
# FS-04/3, etapa 7: cuota de CPU por zona (`zone cpu <nombre> <n>`).
#
# n son los ticks del PIT que la zona puede gastar en cada ventana de 20
# (0 = sin límite). Con la cuota gastada, la zona cede la CPU al otro proceso
# hasta que la ventana se renueva. Todo se cuenta en ticks, no en tiempo del
# anfitrión; los contadores de `zone cpu <nombre>` son:
#   tot   ticks cobrados a la zona
#   cont  ticks cobrados con otro proceso listo (los que disputó)
#   thr   veces que la cuota la sacó de la CPU
# Se corre `zone pair za zb par` con los dos procesos en modo 'h' (gastan
# CPU sin syscalls: 100 millones de vueltas y salen). Dos corridas:
#   1. control, sin cuotas: el reparto es por turnos, cont casi igual (±20%),
#      thr = 0 en las dos.
#   2. za con cuota 2 de 20, zb sin límite: cont(za) * 4 <= cont(zb) (lo
#      esperado es 2/18, un 11%), thr(za) >= 1, thr(zb) = 0, y los dos
#      procesos terminan (`zone pair ok`, sin fuga).
# Más los errores de `zone cpu`. Nada depende del reloj del anfitrión: la
# cuota se mide en ticks. QEMU_EXTRA="-icount shift=4" suma opciones a QEMU.
# La imagen de arranque se copia al directorio temporal. El disco de datos es
# una copia nueva.
# Uso: tests/qemu_cpu_test.sh [imagen] [opciones de QEMU, p. ej. "-icount shift=4"]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
EXTRA_ARGS=${2:-}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
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
    # QEMU_EXTRA: opciones de más, p. ej. QEMU_EXTRA="-icount shift=4".
    # shellcheck disable=SC2086
    qemu-system-x86_64 -cpu qemu64 ${QEMU_EXTRA:-} ${EXTRA_ARGS:-} -drive format=raw,file="$BOOT" \
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

# pair_run za zb: corre `zone pair`. Deja la salida en $w.
pair_run() {
    typewait "zone pair $1 $2 par" 600
    w=$(win "zone pair $1 $2 par")
    printf '%s\n' "$w" | grep -qx 'zone pair ok' || fail "zone pair $1 $2: $(printf '%s' "$w" | tr '\n' '|')"
    printf '%s\n' "$w" | grep -q 'zone leak\|user killed' && fail "zone pair $1 $2: leak o proceso muerto"
    return 0
}

# Pide `zone cpu za` y `zone cpu zb` y deja en $ca $cb $ta $tb $tota $totb
# los contadores cont, thr y tot, y en $qa la cuota de za.
read_cpu() {
    typewait "zone cpu za" 30
    typewait "zone cpu zb" 30
    ca=$(cpuf za cont); cb=$(cpuf zb cont)
    ta=$(cpuf za thr); tb=$(cpuf zb thr)
    tota=$(cpuf za tot); totb=$(cpuf zb tot)
    qa=$(cpuf za quota)
    for v in "$ca" "$cb" "$ta" "$tb" "$tota" "$totb" "$qa"; do
        [ -n "$v" ] || fail "zone cpu sin contadores: za=[$(win 'zone cpu za' | tr '\n' '|')] zb=[$(win 'zone cpu zb' | tr '\n' '|')]"
    done
}
cpuf() { win "zone cpu $1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }

start_qemu
for _ in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"

typewait "fs format" 50
typewait "zone par" 50
has "zone par plant ok" || fail "zone par"
typewait "zone create za 12" 30
typewait "zone create zb 12" 30
for z in za zb; do
    typewait "zone sched $z" 30
    typewait "fs write /zonas/$z/q h" 30
done

# Errores de zone cpu.
for c in "zone cpu za 21" "zone cpu za x" "zone cpu nada 3" "zone cpu global 3" "zone cpu nada" "zone cpu"; do
    typewait "$c" 30
    win "$c" | grep -qx 'zone fail 11' || fail "'$c' debía dar zone fail 11: $(win "$c" | tr '\n' '|')"
done
typewait "zone cpu za 5" 30
win "zone cpu za 5" | grep -qx 'zone cpu set za 5' || fail "zone cpu za 5: $(win 'zone cpu za 5' | tr '\n' '|')"
typewait "zone cpu za" 30
[ "$(cpuf za quota)" = "5/20" ] || fail "quota de za: $(cpuf za quota), esperaba 5/20"
echo "ok   zone cpu: n de 0 a 20 en una zona normal; 21, letras, zona inexistente, global y sin nombre dan zone fail 11"

# 1. Control: sin cuotas.
typewait "zone cpu za 0" 30
typewait "zone cpu zb 0" 30
pair_run za zb
read_cpu
[ "$qa" = "0/20" ] || fail "control: quota de za $qa"
[ "$ca" -ge 20 ] && [ "$cb" -ge 20 ] || fail "control: muy pocos ticks disputados (za=$ca zb=$cb); el programa no gasta CPU suficiente"
[ $((ca * 10)) -ge $((cb * 8)) ] && [ $((cb * 10)) -ge $((ca * 8)) ] || fail "control: reparto desparejo sin cuotas (cont za=$ca zb=$cb)"
[ "$ta" = 0 ] && [ "$tb" = 0 ] || fail "control: thr za=$ta zb=$tb, esperaba 0 y 0"
echo "ok   control sin cuotas: cont za=$ca zb=$cb (parejo), thr 0 y 0, los dos terminan"

# 2. za con cuota 2 de 20, zb sin límite.
typewait "zone cpu za 2" 30
typewait "zone cpu zb 0" 30
pair_run za zb
read_cpu
[ "$qa" = "2/20" ] || fail "quota de za: $qa, esperaba 2/20"
[ "$cb" -ge 40 ] || fail "cuota: muy pocos ticks disputados por zb ($cb); el programa no gasta CPU suficiente"
[ "$ca" -ge 1 ] || fail "cuota: za no corrió nada disputado (cont=$ca)"
[ $((ca * 4)) -le "$cb" ] || fail "cuota: za corrió demasiado (cont za=$ca zb=$cb; esperaba za*4 <= zb)"
[ "$ta" -ge 1 ] || fail "cuota: la cuota nunca sacó a za de la CPU (thr=$ta)"
[ "$tb" = 0 ] || fail "cuota: zb sin límite fue sacada de la CPU (thr=$tb)"
echo "ok   cuota 2/20 en za, zb sin límite: cont za=$ca zb=$cb (za*4 <= zb), tot za=$tota zb=$totb, thr za=$ta zb=$tb; los dos terminan sin fuga"

typewait "zone ls" 30
win "zone ls" | grep -q '^zone 1 za root=/zonas/za .* proc=0/2 pag=0 ' || fail "za quedó con procesos o páginas: $(win 'zone ls' | tr '\n' '|')"
typewait "echo vivo" 30
has "vivo" || fail "el shell no respondió"
echo "ok   zonas sin procesos ni páginas al terminar, shell vivo"
echo "PASS: qemu_cpu_test"
