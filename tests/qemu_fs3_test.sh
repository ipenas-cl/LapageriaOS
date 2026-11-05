#!/usr/bin/env bash
# FS-03: `fs migrate` (v1 -> v2), `fs snap rm` y `fs rm -r`.
#
# A. Migración. El disco v1 lo arma scripts/mkv1.c (C, sin Python ni kernel):
#    escenario `std` (dos snapshots, un archivo que solo vive en un snapshot,
#    uno vacío, uno de 8 bloques, 7 archivos vivos) y `full` (8 snapshots, 9
#    raíces). Con el disco v1: `fs ls`, `fs write` y `fs scrub` dicen
#    `fs old version` y no tocan nada; `fs migrate` lo pasa a v2 y entonces
#    los archivos están intactos (texto, 600 bytes, 4 KiB con CRC calculado
#    por mkv1), los snapshots se leen igual, `fs scrub` da ok con la cantidad
#    de bloques que sale de contar a mano, las dos copias del superbloque
#    quedan en versión 2, sobrevive a un reinicio, un segundo `fs migrate` no
#    hace nada y el fs v2 sigue escribiendo. Los discos que v2 no puede
#    migrar (nombre `x/y`, bloque con CRC malo) se rechazan sin tocar los
#    superbloques: siguen siendo v1.
# B. `fs snap rm`: con tres snapshots que comparten bloques entre sí y con la
#    raíz viva, borrar uno libera exactamente los bloques que solo él usaba
#    (2, 44 y 44, contados a mano); lo compartido sigue leyéndose (se escribe
#    un archivo grande encima para pisar lo que se hubiera liberado de más y
#    se relee con rollback); al final el scrub da lo mismo que un disco de
#    control con el mismo contenido y sin snapshots (ni fugas ni faltantes).
# C. `fs rm -r`: un árbol con subcarpetas, archivos de 64 y 72 KiB (bloque
#    indirecto) y un directorio de dos bloques; el scrub vuelve a la cuenta
#    de antes de crearlo; con un snapshot encima no libera nada de lo que el
#    snapshot usa, y al borrar el snapshot se libera todo.
# D. (opcional, segundo argumento o V1_KERNEL_IMG=ruta/a/lapageriaos.img de un kernel anterior a
#    FS-02) el disco v1 lo escribe el kernel viejo de verdad y el kernel nuevo
#    lo migra; además el viejo lee un disco hecho por mkv1 (valida el formato
#    que genera mkv1).
#
# Sin `sleep` como sincronización: cada comando espera su prompt en COM1, con
# un tope en segundos. Los únicos `sleep` son la pausa de 50 ms entre lecturas
# del archivo serie dentro de esas esperas. La imagen de arranque y el disco
# de datos son copias en un directorio temporal: se pueden correr varias a la
# vez. QEMU_EXTRA="-icount shift=7" suma opciones a QEMU.
# Uso: tests/qemu_fs3_test.sh [imagen [imagen-del-kernel-v1]]
# Necesita: qemu-system-x86_64, socat, cc.
set -u
IMAGE=${1:-build/lapageriaos.img}
V1_KERNEL_IMG=${2:-${V1_KERNEL_IMG:-}}
HERE=$(cd "$(dirname "$0")" && pwd)
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
CC=$(command -v cc) || { echo "FAIL: falta cc"; exit 1; }
[ -f "$IMAGE" ] || { echo "FAIL: no hay imagen $IMAGE"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial0.log
DATA=$TMP/data.img
BOOT=$TMP/boot.img
QPID=""
BOOTS=0
OUT=""
cp "$IMAGE" "$BOOT"
CUR_BOOT=$BOOT
"$CC" -O1 -Wall -o "$TMP/mkv1" "$HERE/../scripts/mkv1.c" || { echo "FAIL: no compila scripts/mkv1.c"; exit 1; }
dd if=/dev/zero of="$DATA" bs=512 count=2048 status=none

stop_qemu() {
    if [ -n "${QPID:-}" ] && kill -0 "$QPID" 2>/dev/null; then
        echo quit | "$SOCAT" - UNIX-CONNECT:"$MON" >/dev/null 2>&1 || true
        local i
        for i in $(seq 100); do
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
    echo "--- serial (últimas 70 líneas) ---"
    tr -d '\r' < "$SERIAL" 2>/dev/null | tail -70 || true
    exit 1
}

prompts() { grep -c "lapageria> " "$SERIAL" 2>/dev/null || true; }

# start_qemu [imagen de arranque]: arranca con el mismo data.img.
start_qemu() {
    stop_qemu
    BOOTS=$((BOOTS + 1))
    SERIAL=$TMP/serial$BOOTS.log
    : > "$SERIAL"
    rm -f "$MON"
    local img=${1:-$BOOT}
    # shellcheck disable=SC2086
    qemu-system-x86_64 -cpu qemu64 ${QEMU_EXTRA:-} -drive format=raw,file="$img" \
        -drive file="$DATA",format=raw,if=ide,index=1 \
        -display none -no-reboot \
        -serial file:"$SERIAL" -monitor unix:"$MON",server,nowait &
    QPID=$!
    local i
    for i in $(seq 100); do
        [ -S "$MON" ] && break
        kill -0 "$QPID" 2>/dev/null || fail "qemu terminó al arrancar"
        sleep 0.05
    done
    for i in $(seq 1200); do
        [ "$(prompts)" -ge 1 ] && return 0
        kill -0 "$QPID" 2>/dev/null || fail "qemu terminó antes del prompt"
        sleep 0.05
    done
    fail "no apareció el prompt del shell"
}

# Teclea una línea con sendkey, todo por una sola conexión al monitor.
keys() {
    local s=$1 i c k seq=""
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in
            " ") k=spc ;; "-") k=minus ;; "/") k=slash ;; ".") k=dot ;;
            "=") k=equal ;; *) k=$c ;;
        esac
        seq="${seq}sendkey $k"$'\n'
    done
    seq="${seq}sendkey ret"$'\n'
    printf '%s' "$seq" | "$SOCAT" -t 0.3 - UNIX-CONNECT:"$MON" >/dev/null
}

# run "comando" [tope en segundos]: teclea, espera el prompt siguiente y deja
# en $OUT lo que salió por COM1 mientras tanto.
run() {
    local cmd=$1 cap=${2:-120} before off i
    before=$(prompts)
    off=$(wc -c < "$SERIAL" | tr -d ' ')
    keys "$cmd"
    for ((i = 0; i < cap * 20; i++)); do
        if [ "$(prompts)" -gt "$before" ]; then
            OUT=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
            return 0
        fi
        kill -0 "$QPID" 2>/dev/null || fail "qemu terminó durante: $cmd"
        sleep 0.05
    done
    OUT=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
    fail "sin prompt (tope ${cap}s) tras: $cmd"
}

has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
want() { has "$1" || fail "falta la línea '$1' tras el último comando ($(printf '%s' "$OUT" | tr '\n' '|'))"; }
lack() { has "$1" && fail "no debía salir '$1' ($(printf '%s' "$OUT" | tr '\n' '|'))"; return 0; }
pick() { printf '%s\n' "$OUT" | grep -m1 -- "^$1"; }
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }
ok() { run "$1" "${3:-120}"; want "$2"; }
expect_cat() { run "fs cat $1"; want "fs live $2"; }
# Lista de entradas del último `fs ls`, en una línea.
ents() { printf '%s\n' "$OUT" | grep -E '^fs (file|dir) ' | sed 's/^fs //; s/ /:/' | tr '\n' ' ' | sed 's/ $//'; }

# Cantidad de bloques que verifica `fs scrub` (falla si no sale ok).
nblocks() {
    run "fs scrub"
    local s
    s=$(pick "fs scrub ok bloques=") || fail "fs scrub no dio ok: $(printf '%s' "$OUT" | tr '\n' '|')"
    field "$s" bloques
}
# nblocks y comparar con el valor esperado.
scrub_is() {
    local n
    n=$(nblocks)
    [ "$n" = "$1" ] || fail "$2: fs scrub ok bloques=$n, esperaba $1"
}
# Archivo grande con patrón: escribe y deja el CRC en $LASTCRC.
LASTCRC=""
bigw() {
    run "fs bigw $1 $2 $3"
    local l
    l=$(pick "fs big w size=") || fail "fs bigw $1: $OUT"
    LASTCRC=$(field "$l" crc)
}
bigr_ok() {
    run "fs bigr $1 $2"
    pick "fs big r size=[0-9]* crc=0x[0-9A-Fa-f]* ok$" > /dev/null || fail "fs bigr $1 $2: $(printf '%s' "$OUT" | tr '\n' '|')"
}
# Los superbloques 2 y 3 (sector de datos de los bloques 2 y 3), a hex.
sb_hex() { dd if="$DATA" bs=512 skip="$1" count=1 status=none | od -An -tx1 -N 12 -v | tr -d ' \n'; }
sb_ver() { dd if="$DATA" bs=512 skip="$1" count=1 status=none | od -An -tx1 -j 4 -N 1 -v | tr -d ' \n'; }
# Hash de los 4 sectores de los bloques 2 y 3 (datos y metadatos).
sb_sum() { dd if="$DATA" bs=512 skip=4 count=4 status=none | cksum; }
# Número a partir de un 0x... (put_hex no rellena con ceros).
hexval() { echo $(( $1 )); }

# =============================================================== A. migración
"$TMP/mkv1" "$DATA" std > "$TMP/manifest" || fail "mkv1 std"
bigcrc=$(sed -n 's/^crc big .* \(0x[0-9a-f]*\)$/\1/p' "$TMP/manifest")
[ -n "$bigcrc" ] || fail "mkv1 no dio el CRC de big"
[ "$(sb_ver 4)" = 01 ] && [ "$(sb_ver 6)" = 01 ] || fail "mkv1: los superbloques no son v1"
start_qemu
run "fs ls"; want "fs old version"
run "fs write /x y"; want "fs old version"
run "fs scrub"; want "fs old version"
run "fs snap s1 a"; want "fs old version"
[ "$(sb_ver 4)" = 01 ] && [ "$(sb_ver 6)" = 01 ] || fail "un comando v1 tocó el superbloque"
echo "ok   disco v1 (mkv1 std): ls/write/scrub/snap dicen fs old version y no tocan el disco"

run "fs migrate"
want "fs migrate ok snaps=2 files=10"
n=$(nblocks)
# 2 superbloques + 3 raíces x (inodo + 1 bloque de directorio) + 10 inodos de
# archivo distintos + 18 bloques de datos (a:1+1+1, keep 1, m 2, big 8, f1 1,
# m2 2, g 1) = 2 + 6 + 10 + 18.
[ "$n" = 36 ] || fail "tras migrar: fs scrub ok bloques=$n, esperaba 36"
[ "$(sb_ver 4)" = 02 ] && [ "$(sb_ver 6)" = 02 ] || fail "tras migrar los dos superbloques tienen que ser v2 (bloque 2: $(sb_ver 4), bloque 3: $(sb_ver 6))"
run "fs ls"
[ "$(ents)" = "file:a file:keep file:m file:big file:f1 file:m2 file:g" ] || fail "fs ls tras migrar: $(ents)"
expect_cat a "v1-a-tres"
expect_cat keep "se queda"
expect_cat f1 "uno"
expect_cat g "ge"
run "fs check"; want "fs blocks ok"
run "fs bigr big 3"
l=$(pick "fs big r size=4096 crc=") || fail "fs bigr big: $OUT"
[ "$(hexval "$(field "$l" crc)")" = "$(hexval "$bigcrc")" ] || fail "CRC de big: kernel $(field "$l" crc), mkv1 $bigcrc"
printf '%s\n' "$l" | grep -q ' ok$' || fail "fs bigr big no dio ok: $l"
run "fs snap s1 a"; want "fs snap v1-a-uno"
run "fs snap s1 e"; want "fs empty"
run "fs snap s1 keep"; want "fs snap se queda"
run "fs snap s2 a"; want "fs snap v1-a-dos"
run "fs snap s2 f1"; want "fs snap uno"
run "fs snap s1 f1"; want "fs fail 7"
run "fs snap s2 e"; want "fs fail 7"
run "fs snap s2 g"; want "fs fail 7"
echo "ok   migrar std: files=10 snaps=2, scrub ok bloques=36 (contado a mano), superbloques v2, vivo y snapshots intactos, CRC de big igual al de mkv1"

# Un segundo migrate no hace nada; el fs v2 sigue funcionando.
run "fs migrate"; want "fs migrate not needed"
scrub_is 36 "tras el segundo migrate"
ok "fs mkdir /d" "fs mkdir ok"
ok "fs write /d/x nuevo" "fs write ok"
expect_cat /d/x "nuevo"
nblocks > /dev/null
# Reinicio con el mismo disco.
start_qemu
expect_cat /d/x "nuevo"
expect_cat a "v1-a-tres"
run "fs snap s1 a"; want "fs snap v1-a-uno"
nblocks > /dev/null
# Rollback a un snapshot migrado y vuelta a mirar.
ok "fs rollback s1" "fs rollback ok"
expect_cat a "v1-a-uno"
run "fs ls"
[ "$(ents)" = "file:a file:e file:keep file:m file:big" ] || fail "fs ls tras rollback a s1: $(ents)"
run "fs bigr big 3"
pick "fs big r size=4096 crc=.* ok$" > /dev/null || fail "big tras rollback: $OUT"
nblocks > /dev/null
echo "ok   migrado: segundo migrate sin efecto, fs v2 escribe, sobrevive al reinicio, rollback a un snapshot migrado"

# ---- full: 9 raíces
stop_qemu
dd if=/dev/zero of="$DATA" bs=512 count=2048 status=none
"$TMP/mkv1" "$DATA" full > /dev/null || fail "mkv1 full"
start_qemu
run "fs migrate"
want "fs migrate ok snaps=8 files=15"
# 2 + 9 raíces x 2 + 15 inodos + 15 bloques de datos
scrub_is 50 "migrar full"
for i in 1 2 3 4 5 6 7 8; do
    run "fs snap s$i a"; want "fs snap gen$i"
done
run "fs snap s6 f6"; want "fs snap gen6"
run "fs snap s3 f4"; want "fs fail 7"
expect_cat a "vivo"
echo "ok   migrar full: 8 snapshots + vivo (9 raíces), files=15, scrub ok bloques=50, cada snapshot conserva su versión"

# ---- discos que v2 no acepta: se rechazan sin tocar el disco
for sc in badname badcrc; do
    stop_qemu
    dd if=/dev/zero of="$DATA" bs=512 count=2048 status=none
    "$TMP/mkv1" "$DATA" $sc > /dev/null || fail "mkv1 $sc"
    before=$(sb_sum)
    start_qemu
    if [ $sc = badname ]; then want_code="fs fail 11"; else want_code="fs fail 5"; fi
    run "fs migrate"; want "$want_code"
    run "fs ls"; want "fs old version"
    [ "$(sb_sum)" = "$before" ] || fail "$sc: fs migrate fallido cambió los superbloques"
    [ "$(sb_ver 4)" = 01 ] && [ "$(sb_ver 6)" = 01 ] || fail "$sc: el disco dejó de ser v1"
done
echo "ok   migrar rechaza un nombre que v2 no acepta (fs fail 11) y un bloque con CRC malo (fs fail 5); el disco sigue siendo v1 y los superbloques no cambiaron"

# Disco sin formato.
stop_qemu
dd if=/dev/zero of="$DATA" bs=512 count=2048 status=none
start_qemu
run "fs migrate"; want "fs fail 8"
echo "ok   migrar en un disco sin formato: fs fail 8"

# =============================================================== B. fs snap rm
ok "fs format" "fs format ok"
scrub_is 3 "disco recién formateado"
ok "fs mkdir /d" "fs mkdir ok"
bigw /d/inner 4 5
bigw /shared 20 1
bigw /cow 20 2
ok "fs snap s1" "fs snap ok"
bigw /cow 20 3
ok "fs snap s2" "fs snap ok"
bigw /extra 8 4
ok "fs snap s3" "fs snap ok"
ok "fs rm /shared" "fs rm ok"
# vivo 72 (raíz 2, d 11, cow3 42, extra 17) + s3 44 (raíz 2 y shared 42) + s2 2
# (su raíz) + s1 44 (raíz 2 y cow2 42) + 2 superbloques
scrub_is 164 "antes de borrar snapshots"
run "fs snap rm"; want "fs fail 7"
run "fs snap rm nada"; want "fs fail 7"
ok "fs snap rm s2" "fs snap rm ok"
scrub_is 162 "tras fs snap rm s2 (solo su raíz, 2 bloques)"
run "fs snap rm s2"; want "fs fail 7"
ok "fs snap rm s1" "fs snap rm ok"
scrub_is 118 "tras fs snap rm s1 (raíz y cow2, 44 bloques; shared sigue en s3)"
# Un archivo grande encima: si se hubiera liberado de más algo que usa s3 o la
# raíz viva, se pisaría con esto.
bigw /fill 30 7
scrub_is 180 "con /fill (62 bloques)"
ok "fs rollback s3" "fs rollback ok"
scrub_is 116 "rollback a s3 (fill y raíces sueltas liberados)"
bigr_ok /shared 1
bigr_ok /cow 3
bigr_ok /extra 4
bigr_ok /d/inner 5
run "fs ls"
[ "$(ents)" = "dir:d file:shared file:cow file:extra" ] || fail "fs ls tras rollback a s3: $(ents)"
ok "fs snap rm s3" "fs snap rm ok"
scrub_is 116 "borrar s3, que comparte la raíz con el vivo, no libera nada"
bigr_ok /shared 1
bigr_ok /cow 3
bigr_ok /extra 4
bigr_ok /d/inner 5
run "fs snap s3 /extra"; want "fs fail 7"
run "fs snap rm s3"; want "fs fail 7"
# Control: el mismo contenido vivo en un disco sin snapshots.
ok "fs format" "fs format ok"
ok "fs mkdir /d" "fs mkdir ok"
bigw /d/inner 4 5
bigw /shared 20 1
bigw /cow 20 3
bigw /extra 8 4
scrub_is 116 "disco de control (mismo contenido, sin snapshots)"
echo "ok   snap rm: liberó 2, 44 y 44 bloques (los que solo usaba cada uno), lo compartido sigue leyéndose, scrub igual al de control (116), sin fugas"

# Ocho snapshots, borrar uno del medio y reusar el lugar.
for i in 1 2 3 4 5 6 7 8; do ok "fs snap q$i" "fs snap ok"; done
ok "fs snap q9" "fs fail 6"
ok "fs snap rm q4" "fs snap rm ok"
ok "fs snap q9" "fs snap ok"
ok "fs snap rm q1" "fs snap rm ok"
ok "fs snap rm q9" "fs snap rm ok"
for i in 2 3 5 6 7 8; do ok "fs snap rm q$i" "fs snap rm ok"; done
run "fs snap q2 /extra"; want "fs fail 7"
scrub_is 116 "tras crear y borrar 9 snapshots"
echo "ok   snap rm: 8 snapshots, borrar uno del medio libera su lugar (el noveno entra), todos se pueden borrar, scrub 116"

# =============================================================== C. fs rm -r
ok "fs format" "fs format ok"
ok "fs write /keep guardado" "fs write ok"
n0=$(nblocks)
[ "$n0" = 6 ] || fail "base de rm -r: bloques=$n0, esperaba 6 (2 + raíz 2 + keep 2)"
build_tree() {
    ok "fs mkdir /t" "fs mkdir ok"
    ok "fs mkdir /t/a" "fs mkdir ok"
    ok "fs mkdir /t/a/b" "fs mkdir ok"
    ok "fs mkdir /t/c" "fs mkdir ok"
    ok "fs mkdir /t/m" "fs mkdir ok"
    ok "fs write /t/x equis" "fs write ok"
    bigw /t/a/y 64 2
    bigw /t/a/b/z 72 5
    ok "fs write /t/c/w doble" "fs write ok"
    local i
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17; do
        ok "fs write /t/m/f$i d$i" "fs write ok"
    done
}
build_tree
# dirs: t 2, a 2, b 2, c 2, m 3 (17 entradas = 2 bloques); archivos: x 2,
# y 130 (128+indirecto+inodo), z 146 (144+indirecto+inodo), w 2, 17 x 2
n1=$(nblocks)
[ "$n1" = 331 ] || fail "árbol armado: bloques=$n1, esperaba 6 + 325 = 331"
ok "fs rm /t" "fs fail 14"
ok "fs rm -r /t" "fs rm -r ok"
run "fs ls /"
[ "$(ents)" = "file:keep" ] || fail "tras rm -r /t: $(ents)"
run "fs cat /t/x"; want "fs fail 7"
run "fs ls /t"; want "fs fail 7"
expect_cat /keep "guardado"
scrub_is 6 "tras rm -r de todo el árbol (vuelve a la cuenta de antes)"
echo "ok   rm -r: árbol de 325 bloques (subcarpetas, 64 y 72 KiB, directorio de 2 bloques) borrado, scrub vuelve a 6, sin fugas"

# rm -r de un archivo suelto y errores.
ok "fs write /solo uno" "fs write ok"
ok "fs rm -r /solo" "fs rm -r ok"
ok "fs rm -r /solo" "fs fail 7"
ok "fs rm -r /nada/x" "fs fail 7"
ok "fs rm -r /" "fs rm -r refused: raiz del sistema"
ok "fs rm -r" "fs rm -r refused: raiz del sistema"
scrub_is 6 "tras rm -r de un archivo"

# Con un snapshot encima: nada de lo que usa se libera, y al borrarlo sí.
build_tree
ok "fs snap sn" "fs snap ok"
ok "fs rm -r /t" "fs rm -r ok"
# 2 superbloques + raíz nueva 2 + keep 2 + raíz vieja del snapshot 2 + árbol 325
scrub_is 333 "con el árbol sostenido por el snapshot"
ok "fs rollback sn" "fs rollback ok"
scrub_is 331 "rollback al snapshot: la raíz nueva queda suelta y se libera"
bigr_ok /t/a/y 2
bigr_ok /t/a/b/z 5
expect_cat /t/c/w "doble"
expect_cat /t/m/f17 "d17"
expect_cat /t/x "equis"
ok "fs rm -r /t" "fs rm -r ok"
scrub_is 333 "segundo rm -r con el snapshot todavía"
ok "fs snap rm sn" "fs snap rm ok"
scrub_is 6 "tras borrar el árbol y el snapshot"
echo "ok   rm -r con snapshot: lo que el snapshot usa sigue (rollback lo trae intacto, 64 y 72 KiB con su patrón), y al borrar el snapshot se libera todo (scrub 6)"

# FS-05/2: `fs rm` sin -r también se niega a borrar "/", /zonas y
# /zonas/<nombre>, aunque estén vacías, y no toca el disco.
ok "zone create zq 12" "zone created 1"
n_zq=$(nblocks)
ok "fs rm /" "fs rm refused: raiz del sistema"
ok "fs rm /zonas" "fs rm refused: raiz de zona"
ok "fs rm /zonas/" "fs rm refused: raiz de zona"
ok "fs rm /zonas/zq" "fs rm refused: raiz de zona"
ok "fs rm /zonas/zq/" "fs rm refused: raiz de zona"
[ "$(nblocks)" = "$n_zq" ] || fail "fs rm negado cambió el disco (bloques $n_zq -> $(nblocks))"
run "fs ls /zonas"; printf '%s\n' "$OUT" | grep -q 'zq' || fail "tras fs rm /zonas/zq la zona ya no está: $OUT"
ok "fs write /zonas/zq/a uno" "fs write ok"
ok "fs rm /zonas/zq/a" "fs rm ok"
ok "fs rm /zonas/zq/a" "fs fail 7"
echo "ok   fs rm sin -r: negado en /, /zonas, /zonas/ y /zonas/zq (con o sin / final), disco intacto; dentro de la zona sigue borrando archivos"

run "version"
printf '%s\n' "$OUT" | grep -q 'LapageriaOS' || fail "el shell no sigue vivo"

# =============================================================== D. kernel v1 real (opcional)
if [ -n "${V1_KERNEL_IMG:-}" ]; then
    [ -f "$V1_KERNEL_IMG" ] || fail "V1_KERNEL_IMG no existe: $V1_KERNEL_IMG"
    OLD=$TMP/old.img
    cp "$V1_KERNEL_IMG" "$OLD"
    # D1. mkv1 contra el kernel viejo: valida el formato que genera mkv1.
    stop_qemu
    dd if=/dev/zero of="$DATA" bs=512 count=2048 status=none
    "$TMP/mkv1" "$DATA" std > /dev/null || fail "mkv1 std"
    start_qemu "$OLD"
    expect_cat a "v1-a-tres"
    expect_cat keep "se queda"
    run "fs check"; want "fs blocks ok"
    run "fs snap s1 a"; want "fs snap v1-a-uno"
    run "fs snap s2 a"; want "fs snap v1-a-dos"
    run "fs snap s1 e"; want "fs empty"
    echo "ok   D1 el kernel v1 real lee el disco de mkv1 (a, keep, m, snapshots s1 y s2)"
    # D2. el kernel viejo escribe el disco; el nuevo lo migra.
    stop_qemu
    dd if=/dev/zero of="$DATA" bs=512 count=2048 status=none
    start_qemu "$OLD"
    ok "fs format" "fs format ok"
    ok "fs write a uno" "fs write ok"
    ok "fs blocks" "fs blocks ok"
    ok "fs snap s1" "fs snap ok"
    ok "fs write a dos" "fs write ok"
    ok "fs create c" "fs create ok"
    ok "fs write b bebe" "fs write ok"
    ok "fs snap s2" "fs snap ok"
    ok "fs rm c" "fs rm ok"
    [ "$(sb_ver 4)" = 01 ] && [ "$(sb_ver 6)" = 01 ] || fail "el kernel viejo no dejó un disco v1"
    start_qemu
    run "fs ls"; want "fs old version"
    run "fs migrate"; want "fs migrate ok snaps=2 files=5"
    nblocks > /dev/null
    run "fs ls"
    [ "$(ents)" = "file:a file:m file:b" ] || fail "D2 fs ls: $(ents)"
    expect_cat a "dos"
    expect_cat b "bebe"
    run "fs check"; want "fs blocks ok"
    run "fs snap s1 a"; want "fs snap uno"
    run "fs snap s2 c"; want "fs empty"
    run "fs snap s1 b"; want "fs fail 7"
    echo "ok   D2 disco v1 escrito por el kernel viejo: migrado, íntegro y scrub ok"
fi

echo "ok   fs3: migración, snap rm y rm -r"
