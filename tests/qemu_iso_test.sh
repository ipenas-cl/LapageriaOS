#!/usr/bin/env bash
# OB-02, etapa 7: aislamiento entre procesos de zonas distintas.
#
# Un proceso de una zona no ve, no puede señalar ni tracear a un proceso de
# otra zona; la zona global sí. Se prueba con dos copias del programa `par`
# (zone pair), que dejan en el archivo r<pid> de su zona una cadena de '1'
# (bien) y '0' (mal) por cada intento:
#
#   c  zonas za y zb: proc_stat (25) y proc_kill (26) del otro dan -3 (igual
#      que un pid que no existe), trace_read (24) pidiendo la zona del otro
#      da -1, trace_ctl (23) de prender/apagar, vaciar, estado y contador
#      da -1; permitido: verse a sí mismo, leer su propia traza (solo trae
#      eventos de su zona, aunque en el anillo haya de la otra), trace_ctl
#      4 y 5. 7 intentos negados por proceso: 14 zone-deny con b 4.
#   s  la misma zona dos veces: se ven, el pid 1 lee la traza y mata al
#      pid 2 (kill pid=2 by pid=1); no hay ningún zone-deny.
#   g  la zona global contra za: ve, lee la traza de la otra zona y la
#      mata; no hay ningún zone-deny.
#
# En los tres, `zone pair ok`: no queda ni una página ni un cupo de zona
# (el proceso muerto devolvió lo suyo). El orden en que corren los dos no
# está fijado (el PIT también cambia de proceso): `par` cede la CPU para que
# el otro siga vivo mientras uno intenta algo, y la prueba no depende del
# orden. El disco de datos es una copia nueva.
# Uso: tests/qemu_iso_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img
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
    qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$IMAGE" \
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
pc() { win "trace count" | awk -v n="$1" '$1 == "probe" && $2 == n { print $3 }'; }
# Campo `name=valor` de la línea `zone pair sw ...` de la última corrida de $1.
sw() {
    win "$1" | awk -v k="$2" '/^zone pair sw / {
        for (i = 1; i <= NF; i++) { split($i, p, "="); if (p[1] == k) print p[2] } }'
}

# Contenido del archivo $1 (la línea `fs live <contenido>` de `fs cat`).
catf() {
    typewait "fs cat $1" 30
    win "fs cat $1" | sed -n 's/^fs live //p'
}

# pair_run za zb: corre `zone pair` con la traza vacía. Deja la salida en $w.
# El orden en que corren los dos (cesiones y PIT) no importa: el programa
# deja al otro vivo mientras intenta algo.
pair_run() {
    typewait "trace clear" 30
    typewait "zone pair $1 $2 par" 300
    w=$(win "zone pair $1 $2 par")
    printf '%s\n' "$w" | grep -qx 'zone pair ok' || fail "zone pair $1 $2: $(printf '%s' "$w" | tr '\n' '|')"
    printf '%s\n' "$w" | grep -q 'zone leak\|user killed' && fail "zone pair $1 $2: leak o proceso muerto"
    return 0
}

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
    typewait "zone trace $z" 30
done
has "zone trace ok" || fail "zone trace"
typewait "trace on zone-deny" 30

# 1. Dos zonas distintas: todo lo ajeno se niega, todo lo propio se permite.
typewait "fs write /zonas/za/q c" 30
typewait "fs write /zonas/zb/q c" 30
pair_run za zb
want=1111111111111
r1=$(catf /zonas/za/r1); r2=$(catf /zonas/zb/r2)
[ "$r1" = "$want" ] || fail "zona za (pid 1): resultado [$r1], esperaba [$want]"
[ "$r2" = "$want" ] || fail "zona zb (pid 2): resultado [$r2], esperaba [$want]"
printf '%s\n' "$w" | grep -q '^kill pid=' && fail "algún proceso mató a otro de otra zona"
typewait "trace count" 30
pd=$(pc zone-deny)
[ "$pd" = 14 ] || fail "zone-deny=$pd, esperaba 14 (7 por proceso)"
typewait "trace dump" 100
d=$(win "trace dump" | grep '^t [0-9]* zone-deny ')
[ -n "$d" ] || fail "no hay zone-deny en el anillo"
[ "$(printf '%s\n' "$d" | grep -vc ' b 4 z [12] c [0-9]*$')" = 0 ] || fail "zone-deny que no es b 4 de la zona 1 o 2: $(printf '%s\n' "$d" | grep -v ' b 4 z [12] c' | head -2)"
printf '%s\n' "$d" | grep -q ' zone-deny pid 1 a 25 b 4 z 1 ' || fail "falta el proc_stat negado del pid 1"
printf '%s\n' "$d" | grep -q ' zone-deny pid 2 a 26 b 4 z 2 ' || fail "falta el proc_kill negado del pid 2"
printf '%s\n' "$d" | grep -q ' zone-deny pid 1 a 24 b 4 z 1 ' || fail "falta el trace_read negado del pid 1"
printf '%s\n' "$d" | grep -q ' zone-deny pid 2 a 23 b 4 z 2 ' || fail "falta el trace_ctl negado del pid 2"
zs=$(printf '%s\n' "$d" | awk '{ z[$11] = 1 } END { n = 0; for (k in z) n++; print n }')
[ "$zs" -ge 2 ] || fail "el anillo solo tiene eventos de una zona: el filtro no tuvo nada que ocultar"
[ "$(printf '%s\n' "$d" | grep -c .)" = 14 ] || fail "el anillo no tiene los 14 zone-deny"
echo "ok   zonas za/zb: 13 intentos por proceso, todos como se esperaba (negados: 25, 26, 24 ajena, 23 x4; permitidos: propio, traza propia, 23 op 4 y 5); zone-deny=$pd con b 4; el anillo tenía eventos de las dos zonas"

# 2. La misma zona dos veces: se ven, uno lee la traza y mata al otro.
# Hace falta una sonda que deje eventos de la zona sin negar nada.
typewait "trace on sys-enter" 30
typewait "fs write /zonas/za/q s" 30
pair_run za za
printf '%s\n' "$w" | grep -qx 'kill pid=2 by pid=1' || fail "falta 'kill pid=2 by pid=1': $(printf '%s' "$w" | tr '\n' '|')"
r1=$(catf /zonas/za/r1); r2=$(catf /zonas/za/r2)
[ "$r1" = 111111 ] || fail "misma zona, pid 1: [$r1], esperaba [111111]"
[ "$r2" = 11 ] || fail "misma zona, pid 2: [$r2], esperaba [11]"
typewait "trace count" 30
pd=$(pc zone-deny)
[ "$pd" = 0 ] || fail "misma zona: zone-deny=$pd, esperaba 0 (todo permitido)"
echo "ok   misma zona: se ven (25), el pid 1 lee su traza y mata al pid 2 (kill pid=2 by pid=1), después ya no lo ve; sin zone-deny, sin fugas"

# 3. La zona global ve, traza y mata a la de za.
typewait "fs rm /zonas/zb/q" 30
typewait "fs rm /zonas/zb/r2" 30
typewait "fs rm /zonas/za/r2" 30
typewait "fs write /zonas/za/q w" 30
typewait "fs write g g" 30
pair_run global za
printf '%s\n' "$w" | grep -qx 'kill pid=2 by pid=1' || fail "global: falta 'kill pid=2 by pid=1': $(printf '%s' "$w" | tr '\n' '|')"
r1=$(catf r1)
[ "$r1" = 1111111 ] || fail "global (pid 1): [$r1], esperaba [1111111]"
typewait "trace count" 30
pd=$(pc zone-deny)
[ "$pd" = 0 ] || fail "global: zone-deny=$pd, esperaba 0"
echo "ok   zona global: ve a la zona za, lee solo sus eventos (z 1) y los de todas, lee un contador y la mata; sin zone-deny, sin fugas"

typewait "zone ls" 30
win "zone ls" | grep -q '^zone 1 za root=/zonas/za .* proc=0/2 pag=0 ' || fail "za quedó con procesos o páginas: $(win 'zone ls' | tr '\n' '|')"
win "zone ls" | grep -q '^zone 2 zb root=/zonas/zb .* proc=0/2 pag=0 ' || fail "zb quedó con procesos o páginas"
typewait "echo vivo" 30
has "vivo" || fail "el shell no respondió"
echo "ok   zonas sin procesos ni páginas al terminar, shell vivo"
