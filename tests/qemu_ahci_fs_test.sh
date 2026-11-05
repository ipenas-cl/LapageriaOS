#!/usr/bin/env bash
# HR-03: `disk` y `fs` sobre el disco SATA, por la capa de bloque (blk.lap).
#
# QEMU arranca por BIOS desde el IDE, como siempre, con un disco de datos IDE
# (esclavo) y además un controlador AHCI con un disco SATA de datos, los dos en
# cero y de 2048 sectores. Se comprueba:
#   1. Elección del backend: `blk` solo elige ATA (el camino BIOS no cambia
#      aunque haya un SATA); `blk ahci` fuerza AHCI; `blk` ya no cambia.
#   2. `disk` con el backend AHCI: `ahci ok`, `blk ok`, `blk corrupt detected`
#      (y no `ata ok`).
#   3. `fs format`, `mkdir`, `write`, `cat` y `scrub` sobre el SATA.
#   4. Con QEMU parado, el anfitrión lee del archivo SATA el superbloque del fs
#      (bloque 2 = LBA 4: magic AFS1; LBA 5: metadatos ABLK) y comprueba que el
#      disco IDE de datos sigue en cero: nada se escribió por ATA.
#   5. Otro arranque, mismo SATA: el archivo persiste por AHCI; `fs corrupt` y
#      `fs cat` dan `fs corrupt detected` (el CRC de blk también vale en AHCI).
#   6. Sin controlador AHCI: `blk ahci` falla limpio (`blk fail 3`), el shell
#      sigue y `blk`/`disk` usan el ATA.
#
# Uso: tests/qemu_ahci_fs_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat, od.
set -u
IMAGE=${1:-build/lapageriaos.img}
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
[ -f "$IMAGE" ] || { echo "FAIL: no hay imagen $IMAGE"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial0.log
IDE=$TMP/ide.img; SATA=$TMP/sata.img
QPID=""
BOOTS=0
OUT=""
SECTORS=2048
dd if=/dev/zero of="$IDE" bs=512 count=$SECTORS status=none
dd if=/dev/zero of="$SATA" bs=512 count=$SECTORS status=none
dd if=/dev/zero of="$TMP/zero.img" bs=512 count=$SECTORS status=none

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

# start_qemu [con|sin]: con = controlador AHCI y disco SATA; sin = solo IDE.
start_qemu() {
    BOOTS=$((BOOTS + 1))
    SERIAL=$TMP/serial$BOOTS.log
    : > "$SERIAL"
    rm -f "$MON"
    local extra=""
    if [ "$1" = con ]; then
        extra="-device ahci,id=ahci -drive id=sata0,file=$SATA,format=raw,if=none -device ide-hd,drive=sata0,bus=ahci.0"
    fi
    # shellcheck disable=SC2086
    qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$IMAGE" \
        -drive file="$IDE",format=raw,if=ide,index=1 $extra \
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

has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
want() { has "$1" || fail "falta la línea '$1' tras el último comando ($(printf '%s' "$OUT" | tr '\n' '|'))"; }
lack() { has "$1" && fail "no debía salir '$1' ($(printf '%s' "$OUT" | tr '\n' '|'))"; return 0; }
ok() { run "$1" "${3:-90}"; want "$2"; }

# --- 1-4. Elección del backend, disk y fs sobre el SATA -----------------------
start_qemu con
ok "blk" "blk dev=ata sectors=$SECTORS"
echo "ok   blk sin argumento: ATA (el camino BIOS no cambia con un SATA presente), sectors=$SECTORS"
ok "blk ahci" "blk dev=ahci sectors=$SECTORS"
ok "blk" "blk dev=ahci sectors=$SECTORS"
echo "ok   blk ahci fuerza el backend AHCI y blk lo conserva: sectors=$SECTORS"

run "disk" 120
want "ahci ok"
want "blk ok"
want "blk corrupt detected"
lack "ata ok"
echo "ok   disk sobre AHCI: ahci ok, blk ok, blk corrupt detected (sin ata ok)"

ok "fs format" "fs format ok"
ok "fs mkdir /a" "fs mkdir ok"
ok "fs write /a/f ahci-hola" "fs write ok"
ok "fs cat /a/f" "fs live ahci-hola"
run "fs scrub" 120
n=$(printf '%s\n' "$OUT" | sed -n 's/^fs scrub ok bloques=//p' | head -1)
[ -n "$n" ] && [ "$n" -gt 0 ] || fail "fs scrub ok bloques=N faltante sobre AHCI: $OUT"
echo "ok   fs format, mkdir, write, cat y scrub sobre el disco SATA (scrub ok bloques=$n)"
stop_qemu

magic() { dd if="$1" bs=512 skip="$2" count=1 status=none | head -c 4; }
[ "$(magic "$SATA" 4)" = "AFS1" ] || fail "LBA 4 del SATA no empieza con AFS1 (superbloque del fs)"
[ "$(magic "$SATA" 5)" = "ABLK" ] || fail "LBA 5 del SATA no empieza con ABLK (metadatos de blk)"
cmp -s "$IDE" "$TMP/zero.img" || fail "el disco IDE de datos cambió: algo salió por ATA"
echo "ok   el anfitrión ve AFS1 en el LBA 4 y ABLK en el LBA 5 del SATA; el IDE de datos sigue en cero"

# --- 5. Otro arranque: persistencia y CRC por AHCI -----------------------------
start_qemu con
ok "fs ls" "fs fail 8"
ok "blk" "blk dev=ata sectors=$SECTORS"
echo "ok   sin elegir AHCI, fs usa el IDE (en cero: fs fail 8); el SATA no se toca solo"
ok "blk ahci" "blk dev=ahci sectors=$SECTORS"
ok "fs cat /a/f" "fs live ahci-hola"
echo "ok   el archivo persiste en el SATA tras reiniciar: fs live ahci-hola"
ok "fs corrupt /a/f" "fs corrupt armed"
ok "fs cat /a/f" "fs corrupt detected"
echo "ok   fs corrupt por AHCI y fs cat da fs corrupt detected (CRC de blk sobre SATA)"
stop_qemu

# --- 6. Sin controlador AHCI: falla limpio -------------------------------------
start_qemu sin
run "blk ahci" 30
want "blk dev=none"
want "blk fail 3"
echo "ok   sin controlador: blk ahci -> blk fail 3, el shell sigue"
ok "blk" "blk dev=ata sectors=$SECTORS"
run "disk" 120
want "ata ok"
want "blk corrupt detected"
echo "ok   sin AHCI: blk y disk usan el ATA"
stop_qemu
echo "ok   qemu_ahci_fs_test"
