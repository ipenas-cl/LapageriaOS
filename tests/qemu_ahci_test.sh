#!/usr/bin/env bash
# HR-01: lectura por AHCI de un sector conocido, sin tocar el camino ATA.
#
# QEMU arranca por BIOS desde el IDE, igual que siempre, y además cuelga un
# controlador AHCI (-device ahci) con un disco SATA que es una copia de la
# imagen de arranque. `ahci 0` y `ahci 9` leen por DMA el sector 0 (etapa 1,
# termina en 55aa) y el sector 9 (primer sector del kernel) y dan su CRC-32.
# La prueba calcula ese CRC en el anfitrión (gzip) y lo compara. También
# comprueba que:
#   - `disk` (ATA + blk) sigue dando ata ok, blk ok, blk corrupt detected;
#   - un LBA fuera del disco da `ahci read fail 4`;
#   - sin controlador AHCI el kernel imprime `ahci none` y arranca igual.
#
# Uso: tests/qemu_ahci_test.sh [imagen]
# Necesita: qemu-system-x86_64, socat, gzip.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA_SRC=$(dirname "$IMAGE")/data.img
if [ ! -f "$IMAGE" ]; then echo "FAIL: no hay imagen $IMAGE"; exit 1; fi
if [ ! -f "$DATA_SRC" ]; then echo "FAIL: no data image $DATA_SRC"; exit 1; fi
SOCAT=$(command -v socat) || { echo "FAIL: falta socat"; exit 1; }
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial.log
DATA=$TMP/data.img; SATA=$TMP/sata.img
QPID=""
SECTORS=$(( $(wc -c < "$DATA_SRC") / 512 ))
dd if=/dev/zero of="$DATA" bs=512 count="$SECTORS" status=none
cp "$IMAGE" "$SATA"
SATA_SECTORS=$(( $(wc -c < "$SATA") / 512 ))

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
    tr -d '\r' < "$SERIAL" 2>/dev/null | tail -60 || true
    exit 1
}

# start_qemu [con|sin]: con = controlador AHCI y disco SATA; sin = solo IDE.
start_qemu() {
    : > "$SERIAL"
    rm -f "$MON"
    local extra=""
    if [ "$1" = con ]; then
        extra="-device ahci,id=ahci -drive id=sata0,file=$SATA,format=raw,if=none -device ide-hd,drive=sata0,bus=ahci.0"
    fi
    # shellcheck disable=SC2086
    qemu-system-x86_64 -cpu qemu64 ${QEMU_EXTRA:-} -drive format=raw,file="$IMAGE" \
        -drive file="$DATA",format=raw,if=ide,index=1 $extra \
        -display none -no-reboot \
        -serial file:"$SERIAL" -monitor unix:"$MON",server,nowait &
    QPID=$!
    sleep 0.5
    kill -0 "$QPID" 2>/dev/null || fail "qemu did not start"
    local i
    for i in $(seq 150); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
    grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"
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

# CRC-32 (ISO-HDLC) del sector $1 del disco SATA, en 0x%08x como put_hex.
host_crc() {
    local hex
    hex=$(dd if="$SATA" bs=512 skip="$1" count=1 status=none | gzip -1 -c | tail -c 8 | head -c 4 \
        | od -An -tx1 -v | tr -d ' \n')
    # gzip lo guarda little-endian.
    printf '0x%s%s%s%s' "${hex:6:2}" "${hex:4:2}" "${hex:2:2}" "${hex:0:2}"
}

# --- con controlador AHCI -------------------------------------------------
start_qemu con
typewait "ahci 0" 100
w=$(win "ahci 0")
printf '%s\n' "$w" | grep -q '^ahci found 0x00008086:0x00002922 abar=0x10100000 pi=0x' \
    || fail "ahci found line missing or wrong (QEMU ich9-ahci es 8086:2922)"
printf '%s\n' "$w" | grep -qx "ahci disk port=0 sectors=$SATA_SECTORS" \
    || fail "ahci disk line: se esperaba port=0 sectors=$SATA_SECTORS"
crc0=$(host_crc 0)
printf '%s\n' "$w" | grep -qx "ahci read lba=0 crc=$crc0 tail=0x000055aa" \
    || fail "ahci read lba=0: se esperaba crc=$crc0 tail=0x000055aa"
echo "ok   ahci sector 0 por DMA: crc=$crc0, termina en 55aa"

typewait "ahci 9" 100
crc9=$(host_crc 9)
win "ahci 9" | grep -q "^ahci read lba=9 crc=$crc9 tail=" || fail "ahci read lba=9: se esperaba crc=$crc9"
[ "$crc0" != "$crc9" ] || fail "los CRC de los sectores 0 y 9 no deberían coincidir"
echo "ok   ahci sector 9 (primer sector del kernel): crc=$crc9"

typewait "ahci $SATA_SECTORS" 100
win "ahci $SATA_SECTORS" | grep -qx "ahci read fail 4" || fail "LBA fuera del disco debía dar ahci read fail 4"
echo "ok   ahci LBA $SATA_SECTORS fuera del disco -> ahci read fail 4"

# El camino ATA sigue igual con el controlador presente.
typewait "disk" 200
has "ata ok" || fail "disk: falta ata ok"
has "blk ok" || fail "disk: falta blk ok"
has "blk corrupt detected" || fail "disk: falta blk corrupt detected"
echo "ok   disk (ATA PIO + blk) sigue verde con AHCI presente"
stop_qemu

# --- sin controlador AHCI --------------------------------------------------
start_qemu sin
typewait "ahci" 100
win "ahci" | grep -qx "ahci none" || fail "sin controlador debía imprimir ahci none"
typewait "disk" 200
has "ata ok" || fail "sin AHCI: falta ata ok"
echo "ok   sin AHCI: ahci none y el disco ATA funciona"
echo "ok   qemu_ahci_test"
