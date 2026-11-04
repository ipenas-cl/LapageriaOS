#!/usr/bin/env bash
# FS-02: directorios, archivos grandes, scrub y raíz propia por zona.
#
# Cubre, en este orden:
#   1. disco sin formato: `fs fail 8`, el shell sigue vivo.
#   2. formato, `fs scrub ok` en un disco sano.
#   3. mkdir anidado de tres niveles, un archivo profundo, nombres malos,
#      rm de un directorio con y sin contenido.
#   4. archivo de 64 KiB (bloque indirecto): el checksum que sale al escribir
#      es el mismo que sale al leer.
#   5. 30 archivos en un directorio (más de un bloque).
#   6. snapshot + cambio profundo + rollback; un snapshot sostiene los
#      bloques de un archivo borrado (scrub ok, y el rollback lo trae igual).
#   7. QEMU se cierra y se abre de nuevo con el mismo data.img: todo sigue
#      y el scrub da la misma cantidad de bloques.
#   8. un sector de datos y un sector de inodo pisados desde afuera: scrub
#      dice `fs scrub bad bloque=N` con esos números.
#   9. `fs leak` (bloque usado que nadie apunta) y `fs unmark` (bloque en uso
#      marcado libre).
#  10. un disco versión 1: `fs old version`, sin caerse; después `fs format`.
#  11. zonas con raíz propia: escribe y lee en su raíz, `..`, `/zonas/otra/x`
#      y rutas absolutas se niegan (-1, suben `niega`), el disco queda igual.
#  12. `zone destroy`: con un proceso vivo de la zona (`zone busy`), sin él
#      (`zone destroyed`), y los archivos de la zona quedan.
#
# Sin `sleep` como sincronización: cada comando espera su prompt en COM1, con
# un tope generoso en segundos. Los únicos `sleep` son la pausa de 50 ms entre
# lecturas del archivo serie dentro de esas esperas.
# El disco de datos es una copia nueva (2048 sectores) en un directorio temporal.
# Uso: tests/qemu_fs2_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat, gzip (solo para armar el disco v1).
set -u
IMAGE=${1:-build/lapageriaos.img}
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
[ -f "$IMAGE" ] || { echo "FAIL: no hay imagen $IMAGE"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial0.log
DATA=$TMP/data.img
QPID=""
BOOTS=0
OUT=""
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

start_qemu() {
    BOOTS=$((BOOTS + 1))
    SERIAL=$TMP/serial$BOOTS.log
    : > "$SERIAL"
    rm -f "$MON"
    qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$IMAGE" \
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
    local cmd=$1 cap=${2:-90} before off i
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

# La línea exacta está en la salida del último run.
has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
want() { has "$1" || fail "falta la línea '$1' tras el último comando ($(printf '%s' "$OUT" | tr '\n' '|'))"; }
lack() { has "$1" && fail "no debía salir '$1' ($(printf '%s' "$OUT" | tr '\n' '|'))"; return 0; }
# Alguna línea empieza con el prefijo; imprime la primera.
pick() { printf '%s\n' "$OUT" | grep -m1 -- "^$1"; }
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }
# run + want de la respuesta esperada
ok() { run "$1" "${3:-90}"; want "$2"; }
# Contenido de un archivo corto: `fs cat` imprime `fs live <texto>`.
expect_cat() { run "fs cat $1"; want "fs live $2"; }
count_lines() { printf "%s\n" "$OUT" | grep -c -- "^$1" || true; }
count_ent() { printf "%s\n" "$OUT" | grep -cE "^fs (file|dir) " || true; }

# ---------------------------------------------------------------- 1. disco en blanco
start_qemu
run "fs ls"
want "fs fail 8"
run "fs scrub"
want "fs fail 8"
run "version"
printf '%s\n' "$OUT" | grep -q 'LapageriaOS' || fail "el shell no sigue vivo tras fs fail 8"
echo "ok   disco sin formato: fs fail 8, el shell sigue"

# ---------------------------------------------------------------- 2. formato y scrub
ok "fs format" "fs format ok"
run "fs scrub"
s0=$(pick "fs scrub ok bloques=") || fail "scrub de un disco recién formateado: $OUT"
n0=$(field "$s0" bloques)
[ "$n0" = 3 ] || fail "disco recién formateado: se esperaban 3 bloques (2 superbloques + raíz), salió $n0"
run "fs ls"
lack "fs file a"
echo "ok   fs format, scrub ok bloques=$n0 en disco vacío"

# ---------------------------------------------------------------- 3. directorios anidados
ok "fs mkdir /a" "fs mkdir ok"
ok "fs mkdir /a/b" "fs mkdir ok"
ok "fs mkdir /a/b/c" "fs mkdir ok"
ok "fs write /a/b/c/f deep1" "fs write ok"
expect_cat "/a/b/c/f" "deep1"
expect_cat "a/b/c/f" "deep1"
run "fs ls /a/b"
want "fs dir c"
run "fs ls /a/b/c"
want "fs file f"
run "fs ls /"
want "fs dir a"
lack "fs file f"
run "fs stat /a/b/c/f"
pick "fs stat file size=5 blocks=1 ino=[0-9][0-9]* first=[0-9][0-9]*$" > /dev/null || fail "fs stat del archivo profundo: $OUT"
# errores
ok "fs mkdir /a/b" "fs fail 11"
ok "fs mkdir /nada/x" "fs fail 7"
ok "fs mkdir /a/../x" "fs fail 11"
ok "fs mkdir /a//x" "fs fail 11"
ok "fs mkdir /a/b/c/f/x" "fs fail 13"
ok "fs mkdir /a/0123456789abcdef" "fs fail 11"
ok "fs write /a/b hola" "fs fail 13"
ok "fs cat /a/b" "fs fail 13"
ok "fs ls /a/b/c/f" "fs fail 13"
ok "fs rm /a/b/c" "fs fail 14"
ok "fs rm /a/zz" "fs fail 7"
run "fs ls /a/b/c"
want "fs file f"
ok "fs mkdir /a/b/c/x" "fs mkdir ok"
ok "fs rm /a/b/c/x" "fs rm ok"
run "fs scrub"
pick "fs scrub ok bloques=" > /dev/null || fail "scrub tras los directorios: $OUT"
echo "ok   mkdir anidado de 3 niveles, archivo profundo, errores 7/11/13/14, rm"

# ---------------------------------------------------------------- 4. 64 KiB
run "fs bigw /a/big 64 0" 120
w=$(pick "fs big w size=65536 crc=") || fail "fs bigw: $OUT"
crc_w=$(field "$w" crc)
run "fs bigr /a/big 0" 120
r=$(pick "fs big r size=65536 crc=") || fail "fs bigr: $OUT"
crc_r=$(field "$r" crc)
[ -n "$crc_w" ] && [ "$crc_w" = "$crc_r" ] || fail "checksum de 64 KiB distinto: escrito $crc_w, leído $crc_r"
printf '%s\n' "$r" | grep -q ' ok$' || fail "el patrón de 64 KiB no coincide: $r"
run "fs bigr /a/big 1" 120
pick "fs big r size=65536 crc=" | grep -q ' bad$' || fail "bigr con otra semilla debía dar bad: $OUT"
run "fs stat /a/big"
pick "fs stat file size=65536 blocks=128 ino=[0-9][0-9]* first=[0-9][0-9]*$" > /dev/null || fail "fs stat del archivo de 64 KiB: $OUT"
first_big=$(field "$(pick 'fs stat [fd]')" first)
ok "fs bigw /a/toobig 73 0" "fs fail 9"
run "fs bigw /a/max 72 0" 120
pick "fs big w size=73728 crc=" > /dev/null || fail "72 KiB: $OUT"
run "fs bigr /a/max 0" 120
pick "fs big r size=73728 crc=.* ok$" > /dev/null || fail "72 KiB leído: $OUT"
ok "fs rm /a/max" "fs rm ok"
echo "ok   archivo de 64 KiB: escrito y leído con checksum $crc_w; 72 KiB (tope) ok; 73 KiB fail 9"

# ---------------------------------------------------------------- 5. 30 archivos en un directorio
ok "fs mkdir /d" "fs mkdir ok"
for i in $(seq 1 30); do
    n=$(printf '%02d' "$i")
    ok "fs write /d/f$n v$n" "fs write ok"
done
run "fs ls /d"
[ "$(count_lines 'fs file f')" = 30 ] || fail "se esperaban 30 archivos en /d, salieron $(count_lines 'fs file f')"
expect_cat "/d/f17" "v17"
expect_cat "/d/f30" "v30"
ok "fs rm /d/f05" "fs rm ok"
ok "fs write /d/f05 v05" "fs write ok"
run "fs ls /d"
[ "$(count_lines 'fs file f')" = 30 ] || fail "tras rm y write de f05 no quedan 30 en /d"
run "fs stat /d"
printf '%s\n' "$OUT" | grep -q '^fs stat dir size=960 blocks=2 ' || fail "/d debía ocupar 2 bloques (960 bytes): $OUT"
run "fs scrub"
pick "fs scrub ok bloques=" > /dev/null || fail "scrub tras 30 archivos: $OUT"
echo "ok   30 archivos en un directorio de 2 bloques, ls, rm y reescritura"

# ---------------------------------------------------------------- 6. snapshot, cambio profundo, rollback
ok "fs snap s1" "fs snap ok"
ok "fs write /a/b/c/f deep2" "fs write ok"
expect_cat "/a/b/c/f" "deep2"
run "fs snap s1 /a/b/c/f"
want "fs snap deep1"
run "fs scrub"
pick "fs scrub ok bloques=" > /dev/null || fail "scrub con snapshot: $OUT"
ok "fs rollback s1" "fs rollback ok"
expect_cat "/a/b/c/f" "deep1"
run "fs scrub"
pick "fs scrub ok bloques=" > /dev/null || fail "scrub tras rollback: $OUT"
# Un snapshot sostiene el archivo grande aunque se borre.
ok "fs snap s2" "fs snap ok"
ok "fs rm /a/big" "fs rm ok"
run "fs scrub"
pick "fs scrub ok bloques=" > /dev/null || fail "scrub tras borrar un archivo que sostiene s2 (un bloque de s2 quedó libre?): $OUT"
lack "fs scrub bad bloque=$first_big"
run "fs bigw /a/other 64 1" 120
pick "fs big w size=65536 crc=" > /dev/null || fail "segundo archivo de 64 KiB: $OUT"
run "fs stat /a/other"
first_other=$(field "$(pick 'fs stat [fd]')" first)
[ "$first_other" != "$first_big" ] || fail "el archivo nuevo reusó el primer bloque que sostiene s2 ($first_big)"
ok "fs rollback s2" "fs rollback ok"
run "fs bigr /a/big 0" 120
r2=$(pick "fs big r size=65536 crc=") || fail "bigr tras rollback a s2: $OUT"
[ "$(field "$r2" crc)" = "$crc_w" ] || fail "tras rollback a s2 el checksum cambió: $(field "$r2" crc) vs $crc_w"
printf '%s\n' "$r2" | grep -q ' ok$' || fail "contenido de /a/big tras el rollback no coincide"
ok "fs cat /a/other" "fs fail 7"
run "fs scrub"
s1=$(pick "fs scrub ok bloques=") || fail "scrub tras rollback a s2: $OUT"
n1=$(field "$s1" bloques)
echo "ok   snapshot + cambio profundo + rollback; s2 sostiene el archivo borrado (scrub bloques=$n1)"

# ---------------------------------------------------------------- 7. reinicio con el mismo data.img
stop_qemu
start_qemu
expect_cat "/a/b/c/f" "deep1"
run "fs bigr /a/big 0" 120
r3=$(pick "fs big r size=65536 crc=") || fail "bigr tras el reinicio: $OUT"
[ "$(field "$r3" crc)" = "$crc_w" ] || fail "tras reiniciar QEMU el checksum de 64 KiB cambió"
printf '%s\n' "$r3" | grep -q ' ok$' || fail "contenido de /a/big tras reiniciar no coincide"
run "fs ls /d"
[ "$(count_lines 'fs file f')" = 30 ] || fail "tras reiniciar no quedan 30 archivos en /d"
run "fs snap s1 /a/b/c/f"
want "fs snap deep1"
run "fs snap s2 /d/f17"
want "fs snap v17"
run "fs scrub"
s2=$(pick "fs scrub ok bloques=") || fail "scrub tras reiniciar: $OUT"
[ "$(field "$s2" bloques)" = "$n1" ] || fail "scrub tras reiniciar: $(field "$s2" bloques) bloques, antes $n1"
echo "ok   reinicio con el mismo data.img: árbol, 64 KiB, 30 archivos, snapshots y scrub ok bloques=$n1"

# ---------------------------------------------------------------- 8. sectores pisados desde afuera
run "fs stat /a/big"
first_big=$(field "$(pick 'fs stat [fd]')" first)
run "fs stat /a/b/c/f"
ino_f=$(field "$(pick 'fs stat [fd]')" ino)
stop_qemu
flip() {
    local lba=$1 off cur new
    off=$((lba * 512 + 100))
    cur=$(dd if="$DATA" bs=1 skip="$off" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
    new=$(( (cur + 1) & 255 ))
    printf "\\$(printf '%03o' "$new")" | dd of="$DATA" bs=1 seek="$off" conv=notrunc status=none
}
flip $((first_big * 2))
flip $((ino_f * 2))
start_qemu
run "fs scrub" 120
want "fs scrub bad bloque=$first_big"
want "fs scrub bad bloque=$ino_f"
printf '%s\n' "$OUT" | grep -q '^fs scrub fail problemas=' || fail "scrub no cerró con fail: $OUT"
printf '%s\n' "$OUT" | grep -q '^fs scrub ok' && fail "scrub dijo ok con dos bloques pisados"
run "fs bigr /a/big 0" 120
want "fs fail 5"
run "fs cat /a/b/c/f"
want "fs corrupt detected"
echo "ok   sector de datos ($first_big) e inodo ($ino_f) pisados: scrub los nombra y lecturas fallan"

# ---------------------------------------------------------------- 9. leak y bloque libre en uso
ok "fs format" "fs format ok"
run "fs leak"
lk=$(pick "fs leak ") || fail "fs leak: $OUT"
lk=${lk#fs leak }
run "fs scrub"
want "fs scrub leak $lk"
printf '%s\n' "$OUT" | grep -q '^fs scrub fail problemas=1 ' || fail "scrub con un leak: $OUT"
ok "fs format" "fs format ok"
ok "fs unmark 4" "fs unmark ok"
run "fs scrub"
want "fs scrub bad bloque=4"
ok "fs format" "fs format ok"
run "fs scrub"
pick "fs scrub ok bloques=3$" > /dev/null || fail "scrub tras formatear de nuevo: $OUT"
echo "ok   scrub: leak $lk detectado, bloque 4 usado y marcado libre detectado"

# ---------------------------------------------------------------- 10. disco versión 1
stop_qemu
dd if=/dev/zero of="$DATA" bs=512 count=2048 status=none
sect=$TMP/sect
dd if=/dev/zero of="$sect" bs=512 count=1 status=none
printf 'AFS1\001\000\000\000\001\000\000\000' | dd of="$sect" bs=1 conv=notrunc status=none
crc4=$(gzip -c < "$sect" | tail -c 8 | head -c 4 | od -An -tx1 | tr -d ' \n')
meta=$TMP/meta
dd if=/dev/zero of="$meta" bs=512 count=1 status=none
printf 'ABLK\002\000\000\000' | dd of="$meta" bs=1 conv=notrunc status=none
printf "\\x${crc4:0:2}\\x${crc4:2:2}\\x${crc4:4:2}\\x${crc4:6:2}" | dd of="$meta" bs=1 seek=8 conv=notrunc status=none
dd if="$sect" of="$DATA" bs=512 seek=4 conv=notrunc status=none
dd if="$meta" of="$DATA" bs=512 seek=5 conv=notrunc status=none
start_qemu
run "fs ls"
want "fs old version"
run "fs write /x y"
want "fs old version"
run "fs scrub"
want "fs old version"
run "version"
printf '%s\n' "$OUT" | grep -q 'LapageriaOS' || fail "el shell no sigue vivo tras fs old version"
ok "fs format" "fs format ok"
ok "fs mkdir /v2" "fs mkdir ok"
run "fs ls /"
want "fs dir v2"
echo "ok   disco versión 1: fs old version (sin caerse); fs format lo deja en versión 2"

# ---------------------------------------------------------------- 11. zonas con raíz propia
ok "fs write /c secreto" "fs write ok"
ok "zone plant" "zone plant ok"
# La primera corrida de un proceso toma dos páginas compartidas que se quedan
# (shared_init): `zone exec` las contaría como fuga. Un `exec` previo las toma.
ok "exec plant" "exec plant ok"
ok "exec hola" "exec ok" 120
ok "zone create a 12" "zone created 1"
ok "zone create b 12" "zone created 2"
run "fs ls /zonas"
want "fs dir a"
want "fs dir b"
ok "fs mkdir /zonas/a/d" "fs mkdir ok"
ok "zone create a 5" "zone fail 11"
ok "zone create a za 5" "zone fail 11"
ok "zone create c 0" "zone fail 11"
ok "zone create c 5000" "zone fail 11"
ok "zone create c/x 5" "zone fail 11"
run "zone ls"
printf '%s\n' "$OUT" | grep -q '^zone 0 global root=/ ' || fail "zone ls sin la global: $OUT"
printf '%s\n' "$OUT" | grep -q '^zone 1 a root=/zonas/a cap=12 proc=0/2 ' || fail "zone ls sin a: $OUT"
printf '%s\n' "$OUT" | grep -q '^zone 2 b root=/zonas/b cap=12 proc=0/2 ' || fail "zone ls sin b: $OUT"
run "fs ls /"
root_before=$(printf '%s\n' "$OUT" | grep -E '^fs (file|dir) ' | sort | tr '\n' ' ')
run "zone exec a ztest" 120
for l in "zone fs ok" "zone fs denied" "zone fs denied create" "zone syscall denied" \
         "zone syscall flood denied" "zone quota ok" "zone quota hold" \
         "zone escape denied" "zone exec ok"; do
    want "$l"
done
lack "zone leak"
printf '%s\n' "$OUT" | grep -q 'user killed' && fail "la zona murió: $OUT"
run "zone ls"
za=$(pick "zone 1 a ") || fail "zone 1 desapareció"
# 64 syscalls fuera de la máscara + 26 de 13 rutas negadas (dos syscalls cada una)
# + 1 de "../c". 5 intentos de escape. Cupo de 12 páginas alcanzado, no pasado.
for kv in niega=91 fuga=5 max=12 pag=0; do
    printf '%s\n' "$za" | grep -q " $kv" || fail "contador $kv de la zona a: $za"
done
printf '%s\n' "$za" | grep -q ' proc=0/2 ' || fail "la zona a retuvo un proceso: $za"
zb=$(pick "zone 2 b ") || fail "zone 2 desapareció"
printf '%s\n' "$zb" | grep -q ' pag=0 niega=0 fuga=0 max=0$' || fail "la zona b se tocó: $zb"
expect_cat "/zonas/a/n" "Z"
expect_cat "/zonas/a/d/n" "Y"
run "fs cat /zonas/b/n"
want "fs fail 7"
run "fs ls /zonas/a"
want "fs file n"
want "fs dir d"
[ "$(count_ent)" = 2 ] || fail "la raíz de a tiene archivos de más: $OUT"
run "fs ls /zonas/b"
[ "$(count_ent)" = 0 ] || fail "la raíz de b tiene archivos: $OUT"
run "fs ls /"
root_after=$(printf '%s\n' "$OUT" | grep -E '^fs (file|dir) ' | sort | tr '\n' ' ')
[ "$root_before" = "$root_after" ] || fail "la raíz global cambió tras el ataque: antes [$root_before] después [$root_after]"
expect_cat "/c" "secreto"
run "fs cat /x"
want "fs fail 7"
run "fs scrub"
pick "fs scrub ok bloques=" > /dev/null || fail "scrub tras la zona: $OUT"
echo "ok   zona: escribe y lee en su raíz (n, d/n); .., ../c, /x, /zonas/zb/x, a/../b, x//y negados (niega=91), raíz global intacta"

# ---------------------------------------------------------------- 12. zone destroy
ok "zone par" "zone par plant ok"
ok "zone create dz 12" "zone created 3"
ok "zone sched dz" "zone sched ok"
ok "fs write /zonas/dz/q w" "fs write ok"
ok "fs write /g d" "fs write ok"
run "zone pair global dz par" 120
want "zone busy"
want "zone destroyed 3"
want "zone pair ok"
lack "zone leak"
expect_cat "/r1" "11111"
run "zone ls"
printf '%s\n' "$OUT" | grep -q '^zone 3 ' && fail "dz sigue en zone ls tras destroy: $OUT"
ok "zone destroy dz" "zone fail 11"
ok "zone destroy global" "zone fail 11"
ok "zone destroy nadie" "zone fail 11"
expect_cat "/zonas/dz/q" "w"
ok "zone create dz 7" "zone created 3"
ok "zone create e 3" "zone created 4"
ok "zone destroy dz" "zone destroyed 3"
ok "zone destroy e" "zone destroyed 4"
run "zone ls"
printf '%s\n' "$OUT" | grep -q '^zone [34] ' && fail "quedaron zonas destruidas: $OUT"
printf '%s\n' "$OUT" | grep -q '^zone 1 a ' || fail "zone destroy se llevó la zona a: $OUT"
ok "zone create f 3" "zone created 3"
run "fs scrub"
pick "fs scrub ok bloques=" > /dev/null || fail "scrub tras zone destroy: $OUT"
echo "ok   zone destroy: busy con un proceso vivo (syscall 27 desde la global), destroyed sin él, ranura reutilizada, archivos quedan"

stop_qemu
echo "PASS: qemu_fs2_test"
