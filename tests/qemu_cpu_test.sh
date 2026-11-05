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
# Se corre `zone pair za zb parcpu` con los procesos en modo `k<d>` de parcpu.lap:
# gastan CPU sin ceder hasta que el kernel ha cobrado 10*d ticks a su zona
# (syscall 28) y salen. El gasto se pide en ticks, no en vueltas, así que la
# prueba da lo mismo en un anfitrión rápido, lento o con -icount. Tres corridas:
#   1. control, sin cuotas: el reparto es por turnos, cont casi igual (±20%),
#      thr = 0 en las dos.
#   2. za con cuota 2 de 20, zb sin límite: cont(za) * 4 <= cont(zb) (lo
#      esperado es 2/18, un 11%), thr(za) >= 1, thr(zb) = 0, y los dos
#      procesos terminan (`zone pair ok`, sin fuga).
#   3. tope duro (FS-05/1): za sola (zb sale enseguida) con cuota 5 de 20:
#      tot <= 5 * ventanas transcurridas e idle >= 2 * solo. Sin tarea ociosa
#      idle sería 0.
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

# Contenido del archivo $1 (la línea `fs live <contenido>` de `fs cat`).
catf() {
    typewait "fs cat $1" 30
    win "fs cat $1" | sed -n 's/^fs live //p'
}

# pair_run za zb [solo1]: corre `zone pair za zb parcpu`. Deja la salida en $w.
# parcpu deja '0' en /zonas/<z>/r<pid> si agotó su tope de lecturas con el
# contador sin llegar (el test lo dice en vez de esperar el plazo); si llegó no
# escribe nada. Con solo1 no se mira el resultado de la copia 2.
pair_run() {
    typewait "fs rm /zonas/$1/r1" 30
    typewait "fs rm /zonas/$2/r2" 30
    typewait "zone pair $1 $2 parcpu" 600
    w=$(win "zone pair $1 $2 parcpu")
    printf '%s\n' "$w" | grep -qx 'zone pair ok' || fail "zone pair $1 $2: $(printf '%s' "$w" | tr '\n' '|')"
    printf '%s\n' "$w" | grep -q 'zone leak\|user killed' && fail "zone pair $1 $2: leak o proceso muerto"
    local r1 r2
    r1=$(catf "/zonas/$1/r1")
    [ "$r1" != 0 ] || fail "zone pair $1 $2: parcpu pid 1 agotó su tope de lecturas: el contador de ticks no avanza"
    if [ "${3:-}" != solo1 ]; then
        r2=$(catf "/zonas/$2/r2")
        [ "$r2" != 0 ] || fail "zone pair $1 $2: parcpu pid 2 agotó su tope de lecturas: el contador de ticks no avanza"
    fi
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
typewait "zone parcpu" 50
has "zone parcpu plant ok" || fail "zone parcpu"
typewait "zone create za 12" 30
typewait "zone create zb 12" 30
for z in za zb; do
    typewait "zone sched $z" 30
    typewait "fs write /zonas/$z/q k4" 30
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

# 2. za con cuota 2 de 20, zb sin límite. zb gasta 60 ticks (unos 67 de reloj,
# 18 de cada 20) y za 10 (5 ventanas, 100 ticks de reloj), así que za sigue viva mientras zb corre
# y los 60 ticks de zb son disputados, sea cual sea la velocidad del anfitrión.
typewait "fs write /zonas/za/q k1" 30
typewait "fs write /zonas/zb/q k6" 30
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

# 3. Tope duro (FS-05/1): za sola con cuota 5 de 20. zb solo cede 6 veces y
# sale; za gasta CPU (modo k4 de parcpu) y queda sola. Sin tarea
# ociosa seguiría corriendo todo el tiempo; con ella, en cada ventana de 20
# ticks gasta como mucho 5 y el resto es idle. Se mide en ticks del PIT:
#   solo  ticks cobrados a za sin otro proceso listo
#   idle  ticks que za esperó con la cuota agotada (nadie corría)
# Cota: tot <= cuota * ventanas, con ventanas = ceil((tot de za + idle + tot de
# zb) / 20), o sea, todos los ticks transcurridos de la corrida.
typewait "fs write /zonas/za/q k4" 30
typewait "fs write /zonas/zb/q y" 30
typewait "zone cpu za 5" 30
typewait "zone cpu zb 0" 30
pair_run za zb solo1
typewait "zone cpu za" 30
typewait "zone cpu zb" 30
totb=$(cpuf zb tot); tot=$(cpuf za tot); solo=$(cpuf za solo); idle=$(cpuf za idle); thr=$(cpuf za thr)
for v in "$totb" "$tot" "$solo" "$idle" "$thr"; do
    [ -n "$v" ] || fail "tope duro: zone cpu sin contadores: $(win 'zone cpu za' | tr '\n' '|')"
done
[ "$solo" -ge 20 ] || fail "tope duro: za corrió muy poco sola (solo=$solo, tot=$tot)"
[ "$idle" -ge 1 ] || fail "tope duro: za nunca esperó ociosa (idle=$idle): la cuota no frenó a una zona sola"
windows=$(( (tot + idle + ${totb:-0} + 19) / 20 ))
[ "$tot" -le $((5 * windows)) ] || fail "tope duro: za gastó $tot ticks en $windows ventanas (cuota 5/ventana = $((5 * windows)))"
[ "$idle" -ge $((solo * 2)) ] || fail "tope duro: idle=$idle contra solo=$solo; esperaba idle >= 2*solo con cuota 5/20"
echo "ok   tope duro 5/20 con za sola: tot=$tot solo=$solo idle=$idle en $windows ventanas (tot <= 5*ventanas), thr=$thr; termina sin fuga"

# zone ls (OB-03) muestra la cuota y el uso de cada zona: lo mismo que `zone cpu`.
typewait "zone ls" 30
win "zone ls" | grep -qx "zone 1 za root=/zonas/za .* cpu=5/20 tot=$tot" || fail "zone ls sin cpu=5/20 tot=$tot para za: $(win 'zone ls' | tr '\n' '|')"
win "zone ls" | grep -qx "zone 2 zb root=/zonas/zb .* cpu=0/20 tot=$totb" || fail "zone ls sin cpu=0/20 tot=$totb para zb: $(win 'zone ls' | tr '\n' '|')"
win "zone ls" | grep -qx "zone 0 global root=/ .* cpu=0/20 tot=[0-9]*" || fail "zone ls sin cpu de la global: $(win 'zone ls' | tr '\n' '|')"
echo "ok   zone ls: cuota y uso de CPU por zona (za cpu=5/20 tot=$tot, zb cpu=0/20 tot=$totb), iguales a zone cpu"

# 4. Tope de lecturas (OB-03): el modo n9 pide 90 ticks pero lee el contador
# solo 1000 veces (unos ms), así que no llega y debe salir solo, dejando '0' en
# r1, mucho antes del plazo de 60 s.
typewait "fs write /zonas/za/q n9" 30
typewait "zone cpu za 0" 30
typewait "fs rm /zonas/za/r1" 30
typewait "zone pair za zb parcpu" 600
win "zone pair za zb parcpu" | grep -qx 'zone pair ok' || fail "tope de lecturas: zone pair: $(win 'zone pair za zb parcpu' | tr '\n' '|')"
r1=$(catf /zonas/za/r1)
[ "$r1" = 0 ] || fail "tope de lecturas: r1=[$r1], esperaba [0] (salida por tope)"
echo "ok   tope de lecturas: n9 sale solo por tope y deja 0 en r1, sin esperar el plazo"

typewait "zone ls" 30
win "zone ls" | grep -q '^zone 1 za root=/zonas/za .* proc=0/2 pag=0 ' || fail "za quedó con procesos o páginas: $(win 'zone ls' | tr '\n' '|')"
typewait "echo vivo" 30
has "vivo" || fail "el shell no respondió"
echo "ok   zonas sin procesos ni páginas al terminar, shell vivo"
echo "PASS: qemu_cpu_test"
