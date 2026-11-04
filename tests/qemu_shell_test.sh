#!/usr/bin/env bash
# Boot LapageriaOS in QEMU, type shell commands with the monitor's sendkey and
# check the replies on the serial console (the kernel mirrors VGA to COM1).
# Also checks that the PIT counter advances by 100 ticks in about one second,
# that a later `ticks` read is larger, that IRQ1 delivered keystrokes, and
# that a deliberate #UD prints its exception line, that read_cr3 matches
# the bootloader page table, and that a read of unmapped 0x200000 prints
# that address from CR2 and then the loaded byte 0x00000000.
# Also checks the E820 map, alloc/free, a mapped page at or above 2MB,
# and a ring-3 program that syscalls "user ok" and then #PF on a kernel read.
# Also checks the data disk (IDE slave, build/data.img): ata ok, blk ok,
# and blk corrupt detected, in that order, after the `disk` command.
# Then the copy-on-write filesystem: format, snapshot, rollback and a
# two-block file. QEMU is quit and started again on the same data.img
# to check that the files and the snapshot are still there. A corrupted
# data sector must print `fs corrupt detected` and the snapshot must
# still read the old bytes. A missing line fails the script.
# Then exec: a flat program planted on the data disk prints `desde disco`
# (not the built-in user/sched strings). A missing name, a bad magic and
# an oversized header return to the prompt. After `fs corrupt`, exec
# rejects the file on checksum and does not run it.
# Then zones: a program in zone A writes and reads under its prefix
# (`zone fs ok`), is denied a zone-0 file and zone B's prefix
# (`zone fs denied`), a syscall outside the mask (`zone syscall denied`),
# a page past its quota (`zone quota ok`, global free memory returns),
# and a zone change (`zone escape denied`). A missing line fails the script.
# Then net: user-mode e1000. The kernel ARPs 10.0.2.2 (`net arp ok`),
# pings that gateway (`net ping ok`) and drops a frame whose IP length
# does not fit the buffer (`net drop ok`). If this QEMU has no user
# netdev, the script fails immediately instead of waiting.
# Then NX: `nx` checks EFER.NXE, a data fetch #PF with the instruction
# bit, a write to kernel code #PF, a user process that dies executing
# its stack and another that dies executing data while the scheduler
# continues, and an audit with zero W+X leaves. QEMU is started with
# -cpu qemu64 so CPUID leaf 0x80000001 EDX bit 20 is set.
# Then trace: sched's #PF and context-switch counters, `exec hola`
# syscalls in order, a disabled probe that records nothing, and a PIT
# flood that counts lost events and leaves the shell alive. The script
# prints `trace counters ok`, `trace syscall ok`, `trace off ok` and
# `trace overflow ok`, and fails if any of those checks miss.
# Usage: tests/qemu_shell_test.sh [image] [--screenshot out.png]
# Needs: qemu-system-x86_64, socat; ffmpeg only for --screenshot.
set -u
IMAGE=${1:-build/lapageriaos.img}
DATA=$(dirname "$IMAGE")/data.img
SHOT=""; [ "${2:-}" = "--screenshot" ] && SHOT=$3
if [ ! -f "$DATA" ]; then echo "FAIL: no data image $DATA"; exit 1; fi
TMP=$(mktemp -d); MON=$TMP/mon.sock; SERIAL=$TMP/serial1.log
QPID=""
# El primer drive es la imagen de arranque (IDE maestro). El segundo es
# el disco de datos, esclavo del canal primario. No cambiar el orden.
start_qemu() {
    SERIAL="$1"
    : > "$SERIAL"
    rm -f "$MON"
    # -nic none evita la NIC por defecto. La única es este e1000.
    # qemu64 expone NX (CPUID 0x80000001 EDX bit 20). El Makefile usa el mismo -cpu.
    qemu-system-x86_64 -cpu qemu64 -drive format=raw,file="$IMAGE" \
        -drive file="$DATA",format=raw,if=ide,index=1 \
        -display none -no-reboot \
        -nic none -netdev user,id=n0 -device e1000,netdev=n0 \
        -serial file:"$SERIAL" -monitor unix:"$MON",server,nowait &
    QPID=$!
    sleep 0.3
    if ! kill -0 "$QPID" 2>/dev/null; then
        fail "qemu exited at startup (user netdev or disk)"
    fi
}
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
# Espera el prompt que el shell imprime al terminar el comando.
typefs() {
    local before
    before=$(grep -c "lapageria> " "$SERIAL" 2>/dev/null || true)
    typeline "$1"
    local i n
    for i in $(seq 40); do
        n=$(grep -c "lapageria> " "$SERIAL" 2>/dev/null || true)
        if [ "${n:-0}" -gt "${before:-0}" ]; then return 0; fi
        sleep 0.1
    done
    fail "no prompt after: $1"
}
typewait() {
    local before n i
    before=$(grep -c "lapageria> " "$SERIAL" 2>/dev/null || true)
    typeline "$1"
    for i in $(seq "$2"); do
        n=$(grep -c "lapageria> " "$SERIAL" 2>/dev/null || true)
        if [ "${n:-0}" -gt "${before:-0}" ]; then return 0; fi
        sleep 0.1
    done
    fail "no prompt after: $1"
}
require_net() {
    local out
    out=$(echo "info network" | socat - UNIX-CONNECT:"$MON" 2>/dev/null || true)
    if printf '%s\n' "$out" | grep -q "type=user" && printf '%s\n' "$out" | grep -q "e1000"; then
        return 0
    fi
    echo "--- info network ---"
    printf '%s\n' "$out"
    fail "qemu has no user netdev with e1000; not waiting on ping"
}
fail() {
    echo "FAIL: $*"
    echo "--- serial ---"
    tr -d '\r' < "$SERIAL" 2>/dev/null || true
    if [ -f "$TMP/serial1.log" ] && [ "$SERIAL" != "$TMP/serial1.log" ]; then
        echo "--- serial phase 1 ---"
        tr -d '\r' < "$TMP/serial1.log" 2>/dev/null || true
    fi
    exit 1
}

start_qemu "$TMP/serial1.log"

# The kernel prints ticks once the counter reaches 100, then again after 100
# more interrupts. Stamp each line so the gap can be compared to 1 second.
t1=0
for _ in $(seq 200); do
    if grep -q "timer: ticks=" "$SERIAL" 2>/dev/null; then t1=$(date +%s%N); break; fi
    sleep 0.1
done
[ "$t1" != 0 ] || fail "no PIT sample on serial"
t2=0
for _ in $(seq 80); do
    n=$(grep -c "timer: ticks=" "$SERIAL" || true)
    if [ "${n:-0}" -ge 2 ]; then t2=$(date +%s%N); break; fi
    sleep 0.1
done
[ "$t2" != 0 ] || fail "PIT did not publish a second sample"
sleep 0.1
samples=$(tr -d '\r' < "$SERIAL" | sed -n 's/^timer: ticks=\([0-9][0-9]*\)$/\1/p')
first=$(printf '%s\n' "$samples" | sed -n '1p')
second=$(printf '%s\n' "$samples" | sed -n '2p')
[ -n "$first" ] && [ -n "$second" ] || fail "could not parse timer samples"
[ "$first" -ge 100 ] || fail "first ticks=$first, want >= 100"
[ "$second" -ge $((first + 100)) ] || fail "second ticks=$second, first=$first, want second >= first+100"
dt_ms=$(( (t2 - t1) / 1000000 ))
echo "ok   ticks $first -> $second in ${dt_ms} ms"
# 100 ticks at 100 Hz is 1 s. The legacy 18.2 Hz PIT would take ~5.5 s.
if [ "$dt_ms" -lt 400 ] || [ "$dt_ms" -gt 4000 ]; then
    fail "100 ticks took ${dt_ms} ms, want 400..4000 (PIT not ~100 Hz)"
fi

for _ in $(seq 100); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt"

CASES=("echo hello from copihue|hello from copihue" "add 40 2|42" "mul 6 -7|-42"
       "version|Copihue" "help|echo <text>" "nosuchcmd|unknown command")
for c in "${CASES[@]}"; do typeline "${c%%|*}"; done
typeline ticks
typeline irqs
typeline cr3
typeline pf
sleep 1
if [ -n "$SHOT" ]; then
    mon "screendump $TMP/s.ppm"; sleep 1
    ffmpeg -loglevel error -y -i "$TMP/s.ppm" "$SHOT" && echo "screenshot: $SHOT"
fi

fails=0
for c in "${CASES[@]}"; do
    cmd=${c%%|*}; want=${c#*|}
    # the reply must appear after the echoed command line
    if awk -v c="lapageria> $cmd" -v w="$want" 'f && index($0, w) {ok=1; exit} index($0, c) {f=1} END {exit !ok}' "$SERIAL"; then
        echo "ok   '$cmd' -> '$want'"
    else
        echo "FAIL '$cmd' -> '$want'"; fails=$((fails + 1))
    fi
done
[ $fails -eq 0 ] || fail "shell cases"

shell_ticks=$(tr -d '\r' < "$SERIAL" | sed -n 's/^ticks \([0-9][0-9]*\)$/\1/p' | tail -1)
[ -n "${shell_ticks:-}" ] || fail "no ticks command reply"
[ "$shell_ticks" -gt "$second" ] || fail "ticks command=$shell_ticks, not greater than boot sample $second"
echo "ok   ticks still growing ($second -> $shell_ticks)"

kbd=$(tr -d '\r' < "$SERIAL" | sed -n 's/^kbd_irqs \([0-9][0-9]*\)$/\1/p' | tail -1)
[ -n "${kbd:-}" ] || fail "no irqs command reply"
[ "$kbd" -ge 8 ] || fail "kbd_irqs=$kbd, want >= 8 (keyboard IRQ not delivering keys)"
echo "ok   keyboard IRQ count=$kbd"

clean=$(tr -d '\r' < "$SERIAL")
# stage2.lap writes CR3=0x1000, PML4[0]=0x2003, PDPT[0]=0x3003.
# The CPU sets the accessed bit (bit 5) on the entries it walks, so they
# read back as 0x2023 and 0x3023. CR3 itself stays 0x1000.
printf '%s\n' "$clean" | grep -qx "cr3=0x00001000" || fail "read_cr3 is not the bootloader PML4 at 0x1000"
printf '%s\n' "$clean" | grep -qx "pml4=0x00002023" || fail "PML4[0] is not 0x2003 with the accessed bit"
printf '%s\n' "$clean" | grep -qx "pdpt=0x00003023" || fail "PDPT[0] is not 0x3003 with the accessed bit"
echo "ok   cr3=0x1000 pml4=0x2023 pdpt=0x3023"

if printf '%s\n' "$clean" | grep -qx "exception: vector 14 #PF page fault err=0x00000000 cr2=0x00200000"; then
    echo "ok   pf -> cr2=0x200000"
else
    fail "page fault did not report cr2=0x200000"
fi
# `mul 6 -7` runs before `pf`. Both blocks bind `b`. The fault allocates
# a frame and zeros it, so the resumed line is `pf resumed 0x00000000`.
# Before block scope, the second `b` printed the mul operand -7 as 0xfffffff9.
mul_at=$(printf '%s\n' "$clean" | grep -n "^-42$" | head -1 | cut -d: -f1)
pf_line=$(printf '%s\n' "$clean" | grep -n "^pf resumed " | head -1)
pf_at=$(printf '%s\n' "$pf_line" | cut -d: -f1)
pf_byte=$(printf '%s\n' "$pf_line" | sed -n 's/^[0-9]*:pf resumed //p')
[ -n "$mul_at" ] && [ -n "$pf_at" ] && [ "$pf_at" -gt "$mul_at" ] || fail "pf did not run after mul 6 -7"
[ "$pf_byte" = "0x00000000" ] || fail "pf resumed printed '$pf_byte', want the byte 0 at 0x200000 (not 0xfffffff9)"
echo "ok   pf resumed 0x00000000 after mul 6 -7"

# E820 and the page allocator. The exact entry count depends on the
# firmware; QEMU's default 128MB map has usable RAM above 1MB, which is
# more than the 256-page identity window.
en=$(tr -d '\r' < "$SERIAL" | sed -n 's/^e820 n=\([0-9][0-9]*\)$/\1/p' | head -1)
[ -n "${en:-}" ] || fail "no e820 count"
[ "$en" -ge 1 ] || fail "e820 n=$en"
echo "ok   e820 n=$en"
pfree=$(tr -d '\r' < "$SERIAL" | sed -n 's/^pmm free=\([0-9][0-9]*\) base=\(0x[0-9a-f]*\) end=\(0x[0-9a-f]*\)$/\1/p' | head -1)
pbase=$(tr -d '\r' < "$SERIAL" | sed -n 's/^pmm free=\([0-9][0-9]*\) base=\(0x[0-9a-f]*\) end=\(0x[0-9a-f]*\)$/\2/p' | head -1)
pend=$(tr -d '\r' < "$SERIAL" | sed -n 's/^pmm free=\([0-9][0-9]*\) base=\(0x[0-9a-f]*\) end=\(0x[0-9a-f]*\)$/\3/p' | head -1)
[ -n "${pfree:-}" ] && [ -n "${pbase:-}" ] && [ -n "${pend:-}" ] || fail "no pmm free line"
[ "$pfree" -gt 256 ] || fail "pmm free=$pfree, want > 256 (E820 did not add RAM above 1MB)"
[ "$pbase" = "0x0000000000100000" ] || fail "pmm base=$pbase, want 0x0000000000100000"
[ $((pend)) -gt $((0x200000)) ] || fail "pmm end=$pend, want above 2MB"
echo "ok   pmm free=$pfree base=$pbase end=$pend"
tr -d '\r' < "$SERIAL" | grep -qx "gdt load" || fail "gdt was not loaded"
tr -d '\r' < "$SERIAL" | grep -qx "gdt ok" || fail "ltr/syscall setup did not finish"
echo "ok   gdt ok"

# Bit NX. `pf` ya dejó la página 0x200000 (NX). El comando tiene que
# volver al prompt e imprimir solo líneas `nx ok`.
typefs "nx"
clean=$(tr -d '\r' < "$SERIAL")
if printf '%s\n' "$clean" | grep -q '^nx fail'; then
    fail "nx reported a failure"
fi
printf '%s\n' "$clean" | grep -qx "nx efer on" || fail "boot did not enable EFER.NXE"
printf '%s\n' "$clean" | grep -qx "nx wp on" || fail "boot did not set CR0.WP"
map=$(printf '%s\n' "$clean" | sed -n 's/^nx map text \(0x[0-9a-f]*\) \(0x[0-9a-f]*\) data \(0x[0-9a-f]*\) \(0x[0-9a-f]*\) bss \(0x[0-9a-f]*\) \(0x[0-9a-f]*\)$/\1 \2 \3 \4 \5 \6/p' | head -1)
[ -n "${map:-}" ] || fail "no nx map line"
set -- $map
text_lo=$(($1)); text_hi=$(($2)); data_lo=$(($3)); data_hi=$(($4)); bss_lo=$(($5)); bss_hi=$(($6))
[ $((text_lo & 4095)) -eq 0 ] && [ $((text_hi & 4095)) -eq 0 ] || fail "nx text is not page aligned"
[ "$text_hi" -gt "$text_lo" ] && [ "$text_hi" -le "$data_lo" ] || fail "nx text overlaps data"
[ "$data_hi" -le "$bss_lo" ] && [ "$bss_hi" -gt "$bss_lo" ] || fail "nx data/bss range is wrong"
# put_hex imprime 32 bits. 0xFFFFFFFF80010000 sale como 0x80010000.
[ "$text_lo" -ge $((0x80000000)) ] && [ "$text_lo" -lt $((0x80200000)) ] || fail "nx text is not in the higher half"
phys_text=$((text_lo - 0x80000000))
phys_bss=$((bss_hi - 0x80000000))
[ "$phys_text" -eq $((0x10000)) ] || fail "nx text is not physical 0x10000"
[ "$phys_bss" -gt "$phys_text" ] && [ "$phys_bss" -le $((0x200000)) ] || fail "nx bss extends past 2MB"
fetch=$(printf '%s\n' "$clean" | sed -n 's/^nx ok fetch err=\(0x[0-9a-f]*\) cr2=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
write=$(printf '%s\n' "$clean" | sed -n 's/^nx ok write err=\(0x[0-9a-f]*\) cr2=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
ustack=$(printf '%s\n' "$clean" | sed -n 's/^nx ok user stack err=\(0x[0-9a-f]*\) cr2=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
udata=$(printf '%s\n' "$clean" | sed -n 's/^nx ok user data err=\(0x[0-9a-f]*\) cr2=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
audit=$(printf '%s\n' "$clean" | sed -n 's/^nx ok audit wx=\([0-9][0-9]*\) leaves=\([0-9][0-9]*\) code=\([0-9][0-9]*\) nx=\([0-9][0-9]*\) huge=\([0-9][0-9]*\)$/\1 \2 \3 \4 \5/p' | head -1)
[ -n "${fetch:-}" ] && [ -n "${write:-}" ] && [ -n "${ustack:-}" ] && [ -n "${udata:-}" ] && [ -n "${audit:-}" ] || fail "nx ok lines missing"
set -- $fetch; fe=$(($1)); fc=$(($2))
set -- $write; we=$(($1)); wc=$(($2))
set -- $ustack; ue=$(($1)); uc=$(($2))
set -- $udata; de=$(($1)); dc=$(($2))
set -- $audit; awx=$1; aleaves=$2; acode=$3; anx=$4; ahuge=$5
[ $((fe & 1)) -ne 0 ] && [ $((fe & 16)) -ne 0 ] && [ $((fe & 14)) -eq 0 ] || fail "fetch err is not a present instruction fetch"
[ $((fc & 4095)) -eq 0 ] && [ "$fc" -ge "$text_hi" ] && [ "$fc" -lt "$bss_hi" ] || fail "fetch cr2 is not a data or bss page"
[ $((we & 3)) -eq 3 ] && [ $((we & 28)) -eq 0 ] || fail "write err is not a present data write"
[ "$wc" -eq "$text_lo" ] || fail "write cr2 is not the start of .text"
[ $((ue & 21)) -eq 21 ] && [ $((ue & 10)) -eq 0 ] || fail "user stack err is not a present user instruction fetch"
[ "$uc" -eq $((0x401000)) ] || fail "user stack cr2 is not 0x401000"
[ $((de & 21)) -eq 21 ] && [ $((de & 10)) -eq 0 ] || fail "user data err is not a present user instruction fetch"
[ "$dc" -eq $((0x500000)) ] || fail "user data cr2 is not 0x500000"
[ "$awx" -eq 0 ] && [ "$ahuge" -eq 0 ] || fail "nx audit has W+X or a huge page"
[ "$acode" -ge 1 ] && [ "$anx" -ge 1 ] && [ "$aleaves" -ge 512 ] || fail "nx audit counts are empty"
[ "$aleaves" -eq $((acode + anx)) ] || fail "nx audit leaves are not code+nx"
fex=$(printf '0x%08x' "$fe"); fcx=$(printf '0x%08x' "$fc")
wex=$(printf '0x%08x' "$we"); wcx=$(printf '0x%08x' "$wc")
uex=$(printf '0x%08x' "$ue"); ucx=$(printf '0x%08x' "$uc")
dex=$(printf '0x%08x' "$de"); dcx=$(printf '0x%08x' "$dc")
printf '%s\n' "$clean" | grep -qx "exception: vector 14 #PF page fault err=${fex} cr2=${fcx}" || fail "fetch exception line does not match nx ok fetch"
printf '%s\n' "$clean" | grep -qx "exception: vector 14 #PF page fault err=${wex} cr2=${wcx}" || fail "write exception line does not match nx ok write"
printf '%s\n' "$clean" | grep -qx "exception: vector 14 #PF page fault err=${uex} cr2=${ucx}" || fail "user stack exception line does not match"
printf '%s\n' "$clean" | grep -qx "exception: vector 14 #PF page fault err=${dex} cr2=${dcx}" || fail "user data exception line does not match"
if ! printf '%s\n' "$clean" | awk '
    /^nx map text / { if (!a) a=NR }
    /^nx ok efer$/ { if (a && !b) b=NR }
    /^nx ok wp$/ { if (b && !c) c=NR }
    /^nx ok fetch err=/ { if (c && !d) d=NR }
    /^nx ok write err=/ { if (d && !e) e=NR }
    /^nx ok sched$/ { if (e && !f) f=NR }
    /^nx ok user stack err=/ { if (f && !g) g=NR }
    /^nx ok user data err=/ { if (g && !h) h=NR }
    /^nx ok audit / { if (h && !i) i=NR }
    END { exit !(a && b && c && d && e && f && g && h && i && a<b && b<c && c<d && d<e && e<f && f<g && g<h && h<i) }
'; then
    fail "nx ok lines were out of order"
fi
echo "ok   nx fetch=${fex} write=${wex} user=${uex} audit wx=0 leaves=${aleaves} code=${acode} nx=${anx}"

# Mitad alta. `pf` y `nx` ya corrieron. La identidad del kernel está
# retirada desde el arranque. El segundo proceso imprime `hh ok sched`
# y después muere al escribir; el shell vuelve.
typefs "hh"
clean=$(tr -d '\r' < "$SERIAL")
if printf '%s\n' "$clean" | grep -q '^hh fail'; then
    fail "hh reported a failure"
fi
hhcpu=$(printf '%s\n' "$clean" | sed -n 's/^hh rip=\(0x[0-9a-f]*\) rsp=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
[ -n "${hhcpu:-}" ] || fail "no hh rip/rsp line"
set -- $hhcpu
hh_rip=$(($1)); hh_rsp=$(($2))
hh_lo=$((0xFFFFFFFF80000000))
hh_hi=$((0xFFFFFFFF80200000))
[ "$hh_rip" -ge "$hh_lo" ] && [ "$hh_rip" -lt "$hh_hi" ] || fail "rip is not in the higher half"
[ "$hh_rsp" -ge "$hh_lo" ] && [ "$hh_rsp" -lt "$hh_hi" ] || fail "rsp is not in the higher half"
printf '%s\n' "$clean" | grep -qx "hh ok cpu" || fail "hh cpu check missing"
printf '%s\n' "$clean" | grep -qx "exception: vector 14 #PF page fault err=0x00000000 cr2=0x00010000" || fail "retired low kernel address did not #PF"
printf '%s\n' "$clean" | grep -qx "hh ok low err=0x00000000 cr2=0x00010000" || fail "hh low probe mismatch"
printf '%s\n' "$clean" | grep -qx "hh ok sched" || fail "scheduler did not continue after the user kernel read"
hh_rd=$(printf '%s\n' "$clean" | sed -n 's/^hh ok read err=\(0x[0-9a-f]*\) cr2=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
hh_wr=$(printf '%s\n' "$clean" | sed -n 's/^hh ok write err=\(0x[0-9a-f]*\) cr2=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
[ -n "${hh_rd:-}" ] && [ -n "${hh_wr:-}" ] || fail "hh user fault lines missing"
set -- $hh_rd; hh_re=$(($1)); hh_rc=$(($2))
set -- $hh_wr; hh_we=$(($1)); hh_wc=$(($2))
[ $((hh_re & 5)) -eq 5 ] && [ $((hh_re & 18)) -eq 0 ] || fail "user kernel read err is not a present user read"
[ $((hh_we & 7)) -eq 7 ] && [ $((hh_we & 16)) -eq 0 ] || fail "user kernel write err is not a present user write"
[ "$hh_rc" -eq $((0xFFFFFFFF80010000)) ] && [ "$hh_wc" -eq $((0xFFFFFFFF80010000)) ] || fail "user kernel cr2 is not the higher-half text"
hha=$(printf '%s\n' "$clean" | sed -n 's/^hh ok audit wx=\([0-9][0-9]*\) leaves=\([0-9][0-9]*\) code=\([0-9][0-9]*\) nx=\([0-9][0-9]*\) huge=\([0-9][0-9]*\)$/\1 \2 \3 \4 \5/p' | head -1)
[ -n "${hha:-}" ] || fail "hh audit line missing"
set -- $hha; hhwx=$1; hhleaves=$2; hhcode=$3; hhnx=$4; hhhuge=$5
[ "$hhwx" -eq 0 ] && [ "$hhhuge" -eq 0 ] || fail "hh audit has W+X or a huge page"
[ "$hhcode" -ge 1 ] && [ "$hhnx" -ge 1 ] && [ "$hhleaves" -eq $((hhcode + hhnx)) ] || fail "hh audit leaves are not code+nx"
if ! printf '%s\n' "$clean" | awk '
    /^hh ok cpu$/ { if (!a) a=NR }
    /^hh ok low err=/ { if (a && !b) b=NR }
    /^hh ok sched$/ { if (b && !c) c=NR }
    /^hh ok read err=/ { if (c && !d) d=NR }
    /^hh ok write err=/ { if (d && !e) e=NR }
    /^hh ok audit / { if (e && !f) f=NR }
    END { exit !(a && b && c && d && e && f && a<b && b<c && c<d && d<e && e<f) }
'; then
    fail "hh lines were out of order"
fi
echo "ok   hh rip rsp low=#PF user wx=0 leaves=${hhleaves} code=${hhcode} nx=${hhnx}"

typeline pmm
sleep 0.4
typeline user
sleep 0.4
clean=$(tr -d '\r' < "$SERIAL")
printf '%s\n' "$clean" | grep -qx "pmm ok" || fail "pmm alloc/free test did not pass"
high=$(printf '%s\n' "$clean" | sed -n 's/^pmm high ok \(0x[0-9a-f]*\)$/\1/p' | head -1)
[ -n "${high:-}" ] || fail "no pmm high ok line"
[ $((high)) -ge $((0x200000)) ] || fail "pmm high page $high is below 2MB"
echo "ok   pmm ok, high page $high"
printf '%s\n' "$clean" | grep -qx "user ok" || fail "ring 3 syscall did not print user ok"
printf '%s\n' "$clean" | grep -qx "exception: vector 14 #PF page fault err=0x00000004 cr2=0x00010000" || fail "ring 3 kernel read did not #PF"
printf '%s\n' "$clean" | grep -qx "user blocked" || fail "user #PF was not reported"
printf '%s\n' "$clean" | grep -qx "user returned" || fail "shell did not resume after user #PF"
printf '%s\n' "$clean" | grep -qx "user leak" && fail "ring 3 read of kernel memory succeeded"
if ! printf '%s\n' "$clean" | awk '
    /^user ok$/ { if (!a) a=NR }
    /^exception: vector 14 #PF page fault err=0x00000004 cr2=0x00010000$/ { if (a && !b) b=NR }
    /^user blocked$/ { if (b && !c) c=NR }
    /^user returned$/ { if (c && !d) d=NR }
    END { exit !(a && b && c && d && a<b && b<c && c<d) }
'; then
    fail "user ok / #PF / user blocked / user returned were out of order"
fi
echo "ok   user syscall, #PF on kernel read, returned to shell"

# Two address spaces and the PIT round-robin. `sched` returns to the
# prompt; the spins are user-mode, so this waits longer than a shell command.
# pf y switch quedan prendidas para cotejar los contadores al volver.
typefs "trace clear"
typefs "trace on pf"
typefs "trace on switch"
typeline sched
sched_ok=0
for _ in $(seq 200); do
    if tr -d '\r' < "$SERIAL" | grep -qx "sched ok"; then
        sched_ok=1
        break
    fi
    if tr -d '\r' < "$SERIAL" | grep -qx "sched fail"; then break; fi
    sleep 0.25
done
[ "$sched_ok" = 1 ] || fail "sched did not finish"
clean=$(tr -d '\r' < "$SERIAL")

pml4=$(printf '%s\n' "$clean" | sed -n 's/^pml4 a=\(0x[0-9a-f]*\) b=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
half=$(printf '%s\n' "$clean" | sed -n 's/^half a=\(0x[0-9a-f]*\) b=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
span=$(printf '%s\n' "$clean" | sed -n 's/^span a=\(0x[0-9a-f]*\) b=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
low=$(printf '%s\n' "$clean" | sed -n 's/^low a=\(0x[0-9a-f]*\) b=\(0x[0-9a-f]*\)$/\1 \2/p' | head -1)
cr3a=$(printf '%s\n' "$clean" | sed -n 's/^cr3 a=\(0x[0-9a-f]*\)$/\1/p' | head -1)
cr3b=$(printf '%s\n' "$clean" | sed -n 's/^cr3 b=\(0x[0-9a-f]*\)$/\1/p' | head -1)
[ -n "$pml4" ] && [ -n "$half" ] && [ -n "$span" ] && [ -n "$low" ] || fail "missing page-table lines"
set -- $pml4; pa=$1; pb=$2
set -- $half; ha=$1; hb=$2
set -- $span; sa=$1; sb=$2
set -- $low; la=$1; lb=$2
[ "$pa" != "$pb" ] || fail "processes share one PML4 ($pa)"
[ "$pa" != "0x00001000" ] && [ "$pb" != "0x00001000" ] || fail "process PML4 is the bootloader table"
[ "$cr3a" = "$pa" ] || fail "write_cr3(A) read back $cr3a, PML4 is $pa"
[ "$cr3b" = "$pb" ] || fail "write_cr3(B) read back $cr3b, PML4 is $pb"
# PML4[256] y PML4[511] apuntan al mismo PDPT. El kernel corre por
# la 511, así que el CPU deja ahí el bit de acceso (bit 5). La 256 no
# se camina y ese bit sigue en 0. La página es la misma.
[ $((ha & ~0x20)) -eq $((hb & ~0x20)) ] && [ $((ha & ~0x20)) -eq $((sa & ~0x20)) ] && [ $((ha & ~0x20)) -eq $((sb & ~0x20)) ] || fail "kernel half is not one shared entry (half $ha $hb span $sa $sb)"
[ "$ha" != "0x00000000" ] || fail "kernel half entry is empty"
[ "$la" != "$lb" ] || fail "lower-half PML4[0] is not per process"
alias_n=$(printf '%s\n' "$clean" | grep -cx "alias ok")
[ "$alias_n" = 2 ] || fail "alias ok count=$alias_n, want 2 (shared kernel half not readable)"
echo "ok   per-process PML4, shared kernel half, write_cr3"

printf '%s\n' "$clean" | grep -qx "pf-cross R pid=2 cr2=0x00500000 err=0x00000004" || fail "process B read of A's page did not #PF"
printf '%s\n' "$clean" | grep -qx "pf-cross W pid=2 cr2=0x00500000 err=0x00000006" || fail "process B write of A's page did not #PF"
echo "ok   cross-process read and write #PF"

printf '%s\n' "$clean" | grep -qx "getpid 1" || fail "getpid 1 missing"
printf '%s\n' "$clean" | grep -qx "getpid 2" || fail "getpid 2 missing"
region=$(printf '%s\n' "$clean" | awk 'f&&/run end/{exit} /run begin/{f=1;next} f{print}')
printf '%s\n' "$region" | grep -q "M" || fail "process A did not print M from its private page"
ab=$(printf '%s\n' "$region" | awk 'BEGIN{s=""} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="a"||c=="b") s=s c}} END{print s}')
case "$ab" in
    *a*b*a*|*b*a*b*) ;;
    *) fail "user letters not interleaved (got '$ab')" ;;
esac
echo "ok   A/B interleaved ($ab)"

sw=$(printf '%s\n' "$clean" | sed -n 's/^switch timer=\([0-9][0-9]*\) yield=\([0-9][0-9]*\)$/\1 \2/p' | head -1)
[ -n "$sw" ] || fail "no switch line"
set -- $sw; st=$1; sy=$2
[ "$st" -ge 1 ] || fail "timer switches=$st, want >= 1"
[ "$sy" -ge 1 ] || fail "yield switches=$sy, want >= 1"
echo "ok   round-robin timer=$st yield=$sy"

ex1=$(printf '%s\n' "$clean" | sed -n 's/^exit pid=1 freed=\([0-9][0-9]*\)$/\1/p' | head -1)
ex2=$(printf '%s\n' "$clean" | sed -n 's/^exit pid=2 freed=\([0-9][0-9]*\)$/\1/p' | head -1)
rel=$(printf '%s\n' "$clean" | sed -n 's/^sched released=\([0-9][0-9]*\)$/\1/p' | head -1)
bb=$(printf '%s\n' "$clean" | sed -n 's/^sched base=\([0-9][0-9]*\) back=\([0-9][0-9]*\)$/\1 \2/p' | head -1)
[ -n "$ex1" ] && [ -n "$ex2" ] && [ -n "$rel" ] && [ -n "$bb" ] || fail "missing exit accounting"
set -- $bb; base=$1; back=$2
[ "$ex1" -ge 1 ] && [ "$ex2" -ge 1 ] || fail "exit freed pid1=$ex1 pid2=$ex2"
[ "$rel" -eq $((ex1 + ex2)) ] || fail "released=$rel, want pid1+pid2=$((ex1 + ex2))"
[ "$back" -eq "$base" ] || fail "pmm free back=$back, base=$base (exit did not return every page)"
printf '%s\n' "$clean" | grep -qx "half kept" || fail "shared kernel half was freed"
printf '%s\n' "$clean" | grep -qx "pml4 free" || fail "process PML4 pages were not freed"
echo "ok   exit freed $ex1+$ex2 pages, pmm back to $base"

printf '%s\n' "$clean" | grep -qx "user leak" && fail "ring 3 read of kernel memory succeeded"
echo "ok   sched ok"

typefs "trace count"
pf_ev=$(tr -d '\r' < "$SERIAL" | awk '
    $0=="trace on switch" { go=1; n=0; next }
    go && /^trace count lost / { exit }
    go && /^exception: vector 14 / { n++ }
    go && /^pf-cross / { n++ }
    END { print n+0 }
')
pf_ct=$(tr -d '\r' < "$SERIAL" | sed -n 's/^probe pf \([0-9][0-9]*\)$/\1/p' | tail -1)
sw_ct=$(tr -d '\r' < "$SERIAL" | sed -n 's/^probe switch \([0-9][0-9]*\)$/\1/p' | tail -1)
[ -n "${pf_ct:-}" ] && [ -n "${sw_ct:-}" ] || fail "trace count did not print pf/switch"
[ "$pf_ev" -ge 2 ] || fail "pf events in sched window=$pf_ev, want >= 2"
[ "$pf_ct" -eq "$pf_ev" ] || fail "pf counter=$pf_ct, printed events=$pf_ev"
[ "$sw_ct" -eq $((st + sy)) ] || fail "switch counter=$sw_ct, timer+yield=$((st + sy))"
typefs "trace off pf"
typefs "trace off switch"
echo "trace counters ok"

# `ud2` deja la CPU en hlt. El disco tiene que correr antes.
typeline disk
disk_ok=0
for _ in $(seq 50); do
    if tr -d '\r' < "$SERIAL" | grep -qx "blk corrupt detected"; then
        disk_ok=1
        break
    fi
    if tr -d '\r' < "$SERIAL" | grep -qE '^(ata fail|ata mismatch|blk fail|blk mismatch|blk crc|blk corrupt miss)'; then
        break
    fi
    sleep 0.2
done
[ "$disk_ok" = 1 ] || fail "disk test did not print blk corrupt detected"
clean=$(tr -d '\r' < "$SERIAL")
if ! printf '%s\n' "$clean" | awk '
    /^lapageria> disk$/ { if (!s) s=NR }
    /^ata ok$/ { if (s && !a) a=NR }
    /^blk ok$/ { if (a && !b) b=NR }
    /^blk corrupt detected$/ { if (b && !c) c=NR }
    END { exit !(s && a && b && c && s<a && a<b && b<c) }
'; then
    fail "ata ok / blk ok / blk corrupt detected missing or out of order"
fi
echo "ok   ata ok, blk ok, blk corrupt detected"

# Copy-on-write. `disk` ya pisó el bloque 0 y el LBA 2; el fs parte en el 2.
typefs "fs format"
typefs "fs create c"
typefs "fs cat c"
typefs "fs write a v1"
typefs "fs snap s1"
typefs "fs write a v2"
typefs "fs cat a"
typefs "fs snap s1 a"
typefs "fs ls"
typefs "fs write b b1"
typefs "fs snap s1 b"
typefs "fs snap s2"
typefs "fs write b b2"
typefs "fs rollback s2"
typefs "fs cat b"
typefs "fs blocks"
tr -d '\r' < "$SERIAL" | awk '
{
    if (i==0 && $0=="fs format ok") i=1
    else if (i==1 && $0=="fs create ok") i=2
    else if (i==2 && $0=="fs empty") i=3
    else if (i==3 && $0=="fs write ok") i=4
    else if (i==4 && $0=="fs snap ok") i=5
    else if (i==5 && $0=="fs write ok") i=6
    else if (i==6 && $0=="fs live v2") i=7
    else if (i==7 && $0=="fs snap v1") i=8
    else if (i==8 && $0=="fs file c") i=9
    else if (i==9 && $0=="fs file a") i=10
    else if (i==10 && $0=="fs write ok") i=11
    else if (i==11 && $0=="fs fail 7") i=12
    else if (i==12 && $0=="fs snap ok") i=13
    else if (i==13 && $0=="fs write ok") i=14
    else if (i==14 && $0=="fs rollback ok") i=15
    else if (i==15 && $0=="fs live b1") i=16
    else if (i==16 && $0=="fs blocks ok") i=17
}
END {
    if (i != 17) {
        print "fs phase 1 stuck at " i > "/dev/stderr"
        exit 1
    }
}
' || fail "fs story missing a line"
echo "ok   fs format, snap v1, live v2, rollback, two blocks"

# El directorio ya tiene c, a, b y m (tope 7). plant escribe hola, malo
# y gordo. exec lee con fs_read: no salta a la copia del kernel.
typefs "exec plant"
typefs "exec hola"
typefs "trace clear"
typefs "trace on sys-enter"
typefs "trace on sys-exit"
typefs "exec hola"
typefs "trace dump 40"
tr -d '\r' < "$SERIAL" | awk '
function bad(msg) { print msg > "/dev/stderr"; exit 1 }
$0=="trace begin" { n=0; cap=1; next }
cap && /^t / { ev[n++] = $0; next }
cap && /^trace end n / {
    endline = $0
    cnt = n
    for (i = 0; i < n; i++) last[i] = ev[i]
    cap = 0
}
END {
    if (endline != "trace end n 25 lost 0") bad("syscall dump end: [" endline "]")
    if (cnt != 25) bad("syscall dump count " cnt)
    split("100 101 115 100 101 32 100 105 115 99 111 10", ch, " ")
    prev = -1
    for (i = 0; i < 12; i++) {
        split(last[i * 2], f, " ")
        split(last[i * 2 + 1], g, " ")
        if (f[3] != "sys-enter" || f[5] != "1" || f[7] != "1" || f[9] != ch[i + 1])
            bad("enter " i ": " last[i * 2])
        if (g[3] != "sys-exit" || g[5] != "1" || g[7] != "1" || g[9] != "0")
            bad("exit " i ": " last[i * 2 + 1])
        if (f[2] + 0 < prev) bad("tick back " last[i * 2])
        prev = f[2] + 0
        if (g[2] + 0 < prev) bad("tick back " last[i * 2 + 1])
        prev = g[2] + 0
    }
    split(last[24], h, " ")
    if (h[3] != "sys-enter" || h[5] != "1" || h[7] != "5") bad("exit syscall: " last[24])
    if (h[2] + 0 < prev) bad("tick back " last[24])
}
' || fail "trace syscall dump mismatch"
echo "trace syscall ok"
typefs "trace off sys-enter"
typefs "trace off sys-exit"
typefs "trace clear"
typefs "exec hola"
typefs "trace dump"
tr -d '\r' < "$SERIAL" | awk '
function bad(msg) { print msg > "/dev/stderr"; exit 1 }
$0=="trace begin" { n=0; cap=1; next }
cap && /^t / { ev[n++] = $0; next }
cap && /^trace end n / {
    endline = $0
    cnt = n
    cap = 0
}
END {
    if (endline != "trace end n 0 lost 0") bad("off dump end: [" endline "]")
    if (cnt != 0) bad("off dump recorded " cnt)
}
' || fail "disabled probes recorded events"
typefs "trace count"
se=$(tr -d '\r' < "$SERIAL" | sed -n 's/^probe sys-enter \([0-9][0-9]*\)$/\1/p' | tail -1)
sx=$(tr -d '\r' < "$SERIAL" | sed -n 's/^probe sys-exit \([0-9][0-9]*\)$/\1/p' | tail -1)
[ "$se" = "0" ] && [ "$sx" = "0" ] || fail "disabled syscall counters sys-enter=$se sys-exit=$sx"
echo "trace off ok"
typefs "exec noesta"
typefs "exec malo"
typefs "exec gordo"
typefs "fs corrupt hola"
typefs "exec hola"
tr -d '\r' < "$SERIAL" | awk '
{
    if (i==0 && $0=="exec plant ok") i=1
    else if (i==1 && $0=="desde disco") i=2
    else if (i==2 && $0=="exec ok") i=3
    else if (i==3 && $0=="exec fail 7") i=4
    else if (i==4 && $0=="exec bad magic") i=5
    else if (i==5 && $0=="exec bad size") i=6
    else if (i==6 && $0=="fs corrupt armed") i=7
    else if (i==7 && $0=="exec corrupt") i=8
    else if (i==8 && $0=="desde disco") {
        print "exec ran the corrupt file" > "/dev/stderr"
        exit 1
    }
}
END {
    if (i != 8) {
        print "exec stuck at " i > "/dev/stderr"
        exit 1
    }
}
' || fail "exec story missing a line"
echo "ok   exec desde disco, missing, bad magic, bad size, corrupt"

# El directorio cabe 7. exec plant lo llenó. Se sueltan malo y gordo
# para plantar ztest y dejar un cupo al archivo de la zona.
typefs "fs rm malo"
typefs "fs rm gordo"
typefs "fs rm hola"
typefs "zone plant"
typefs "zone create a za 12"
typefs "zone create b zb 12"
# SG-01: crear zonas que pisan el espacio de otra o con tope absurdo tiene
# que fallar con `zone fail 11` y no crear nada: mismo prefijo, prefijo
# que es cabeza del de a, prefijo que lo extiende, tope 0, tope sobre
# 4096, tope negativo y nombre repetido.
typefs "zone create c za 5"
typefs "zone create d z 5"
typefs "zone create e zab 5"
typefs "zone create f zf 0"
typefs "zone create g zg 5000"
typefs "zone create h zh -5"
typefs "zone create a zq 5"
typefs "zone ls"
# Directorio antes del ataque: tiene que quedar igual salvo `zan`.
typefs "fs ls"
typewait "zone exec a ztest" 200
typefs "zone ls"
typefs "fs cat zan"
typefs "fs cat n"
typefs "fs cat c"
typefs "fs cat zbx"
typefs "fs cat x"
typefs "fs ls"
# SG-01: tope de 1 página. armar el proceso no cabe: `zone fail 6`, sin
# páginas ni procesos retenidos. `zone exec t nosuch` solo imprime
# `zone mem` y vuelve: sirve de sonda de memoria libre entre intentos.
typefs "zone create t zt 1"
typefs "zone exec t nosuch"
typefs "zone exec t ztest"
typefs "zone exec t nosuch"
typefs "zone exec t ztest"
typefs "zone exec t nosuch"
typefs "zone ls"
tr -d '\r' < "$SERIAL" | awk '
{
    if (i==0 && $0=="fs rm ok") i=1
    else if (i==1 && $0=="fs rm ok") i=2
    else if (i==2 && $0=="fs rm ok") i=3
    else if (i==3 && $0=="zone plant ok") i=4
    else if (i==4 && $0=="zone created 1") i=5
    else if (i==5 && $0=="zone created 2") i=6
    else if (i==6 && $0=="zone fs ok") i=7
    else if (i==7 && $0=="zone fs denied") i=8
    else if (i==8 && $0=="zone fs denied create") i=9
    else if (i==9 && $0=="zone syscall denied") i=10
    else if (i==10 && $0=="zone syscall flood denied") i=11
    else if (i==11 && $0=="zone quota ok") i=12
    else if (i==12 && $0=="zone quota hold") i=13
    else if (i==13 && $0=="zone escape denied") i=14
    else if (i==14 && $0=="zone exec ok") i=15
    else if (i==15 && $0=="fs live Z") i=16
    else if (i==16 && $0=="fs fail 7") i=17
    else if (i==17 && $0=="fs empty") i=18
}
END {
    if (i != 18) {
        print "zone story stuck at " i > "/dev/stderr"
        exit 1
    }
}
' || fail "zone story missing a line"
clean=$(tr -d '\r' < "$SERIAL")
# Ninguna syscall negada tuvo efecto: dentro de la ventana de la zona no
# salen las líneas de las syscalls 2, 3, 10 y 11, ni la X de rdi=88.
win=$(printf '%s\n' "$clean" | awk '/^lapageria> zone exec a ztest$/ {f=1; next} f && /^zone exec ok$/ {exit} f {print}')
[ -n "$win" ] || fail "no zone window to inspect"
printf '%s\n' "$win" | grep -q 'user leak' && fail "denied syscall 2 ran inside the zone"
printf '%s\n' "$win" | grep -q 'getpid' && fail "denied syscall 3 ran inside the zone"
printf '%s\n' "$win" | grep -q 'nx ok sched' && fail "denied syscall 10 ran inside the zone"
printf '%s\n' "$win" | grep -q 'hh ok sched' && fail "denied syscall 11 ran inside the zone"
printf '%s\n' "$win" | grep -q 'X' && fail "a syscall with rdi=88 printed X (nr truncated?)"
# Las creaciones inválidas: siete `zone fail 11`, ninguna zona de más.
f11=$(printf '%s\n' "$clean" | grep -cx 'zone fail 11')
[ "$f11" = 7 ] || fail "want 7 'zone fail 11' (bad zone creates), got $f11"
# Dos zonas válidas (a, b) más la zona t de 1 página creada después: 3.
[ "$(printf '%s\n' "$clean" | grep -c '^zone created ')" = 3 ] || fail "a bad zone create was accepted"
f6=$(printf '%s\n' "$clean" | grep -cx 'zone fail 6')
[ "$f6" = 2 ] || fail "want 2 'zone fail 6' (1-page zone), got $f6"
printf '%s\n' "$clean" | grep -q '^zone fail' && {
    other=$(printf '%s\n' "$clean" | grep '^zone fail' | grep -vx 'zone fail 11' | grep -vx 'zone fail 6' || true)
    [ -z "$other" ] || fail "unexpected zone failure: $other"
}
# Memoria: a antes, a después, y las seis líneas de la zona de 1 página
# (sondas y `zone fail 6`) valen lo mismo. Nada se filtró.
mems=$(printf '%s\n' "$clean" | sed -n 's/^zone mem \([0-9][0-9]*\)$/\1/p')
nm=$(printf '%s\n' "$mems" | grep -c .)
[ "$nm" = 7 ] || fail "want 7 zone mem lines, got $nm"
m1=$(printf '%s\n' "$mems" | sed -n '1p')
m2=$(printf '%s\n' "$mems" | sed -n '2p')
[ "$m1" = "$m2" ] || fail "zone mem $m1 -> $m2, free memory did not return"
[ "$(printf '%s\n' "$mems" | sort -u | wc -l | tr -d ' ')" = 1 ] || fail "free memory changed across the 1-page zone attempts: $(printf '%s ' $mems)"
printf '%s\n' "$clean" | awk -v a="$m1" '
$0 == ("zone mem " a) { if (!s) { s=1; next } if (s==1) { s=2 } }
s==1 && $0=="zone quota ok" { q=1 }
END { exit !(s==2 && q) }
' || fail "zone quota ok was not between the two zone mem lines"
# Contadores del kernel. a: 64 negadas, 5 intentos de escape, el tope se
# alcanzó (max=12) y nunca se pasó. b no se tocó. t: una página, soltada.
z1=$(printf '%s\n' "$clean" | grep '^zone 1 ' | tail -1)
printf '%s\n' "$z1" | grep -q 'pre=za ' || fail "zone 1 lost prefix za ($z1)"
printf '%s\n' "$z1" | grep -q ' pag=0 ' || fail "zone 1 pages not released ($z1)"
printf '%s\n' "$z1" | grep -q 'proc=0/' || fail "zone 1 process leaked ($z1)"
printf '%s\n' "$z1" | grep -q ' niega=64 ' || fail "denied syscalls: want niega=64 ($z1)"
printf '%s\n' "$z1" | grep -q ' fuga=5 ' || fail "zone escapes: want fuga=5 ($z1)"
printf '%s\n' "$z1" | grep -q ' max=12$' || fail "zone 1 quota 12 not reached exactly, or passed ($z1)"
z2=$(printf '%s\n' "$clean" | grep '^zone 2 b pre=zb ' | tail -1)
[ -n "$z2" ] || fail "zone B missing after exec"
printf '%s\n' "$z2" | grep -q ' pag=0 niega=0 fuga=0 max=0$' || fail "zone B was touched by zone A ($z2)"
z3=$(printf '%s\n' "$clean" | grep '^zone 3 t pre=zt ' | tail -1)
[ -n "$z3" ] || fail "zone t missing"
printf '%s\n' "$z3" | grep -q ' pag=0 ' || fail "zone t kept pages ($z3)"
printf '%s\n' "$z3" | grep -q 'proc=0/' || fail "zone t kept a process ($z3)"
printf '%s\n' "$z3" | grep -q ' max=1$' || fail "zone t passed its 1-page quota ($z3)"
# Disco: los intentos fuera del prefijo no dejaron archivos. Entre los dos
# `fs ls` solo aparece `zan`; zbx y x no existen; c sigue vacío.
ls1=$(printf '%s\n' "$clean" | awk '/^lapageria> fs ls$/ {k++; next} k && /^fs file / {c[k]=c[k] " " $3} END {print c[k-1]}')
ls2=$(printf '%s\n' "$clean" | awk '/^lapageria> fs ls$/ {k++; next} k && /^fs file / {c[k]=c[k] " " $3} END {print c[k]}')
[ -n "$ls1" ] && [ -n "$ls2" ] || fail "could not read fs ls before and after the zone attack"
want2=$(printf '%s\n' $ls1 zan | sort | tr '\n' ' ')
got2=$(printf '%s\n' $ls2 | sort | tr '\n' ' ')
[ "$want2" = "$got2" ] || fail "directory changed: before [$ls1 ] after [$ls2 ]"
n_fail7=$(printf '%s\n' "$clean" | awk '/^lapageria> fs cat zbx$/ {f=1; next} f && /^lapageria> / {exit} f && $0=="fs fail 7" {c++} END {print c+0}')
n_fail7x=$(printf '%s\n' "$clean" | awk '/^lapageria> fs cat x$/ {f=1; next} f && /^lapageria> / {exit} f && $0=="fs fail 7" {c++} END {print c+0}')
[ "$n_fail7" = 1 ] && [ "$n_fail7x" = 1 ] || fail "zbx or x exists on disk"
printf '%s\n' "$clean" | grep -qx 'zone leak' && fail "zone leak"
echo "ok   zone fs, denied, syscall, quota mem $m1, escape"
echo "ok   zone attacks: fs create denied, 64 syscalls denied, 5 escapes, quota held (max=12), 1-page zone, disk intact"

# SG-01 parte 2: anillo 3 contra la memoria del kernel y contra sus propias
# páginas NX / de solo lectura (d), y punteros del kernel como argumento (e).
# Un solo programa (`zatk`, src/user/ataque.lap) hace un ataque por corrida;
# el modo está en el archivo `zkq` de la zona k. Cada ataque tiene que
# terminar con `user killed ...` (el kernel mata solo a ese proceso), sin
# `atk survived`, con `zone exec ok` (volvió al shell), sin `zone leak`, y
# el shell tiene que seguir vivo para el ataque siguiente. El directorio
# cabe 7: se sueltan ztest y zan, que ya cumplieron.
typefs "fs rm ztest"
typefs "fs rm zan"
typefs "zone atk"
typefs "zone create k zk 12"
typefs "fs write zkq 1"
typefs "fs ls"
attack_n=0
# atk_run modo vec err addr: el #PF trae CR2 en addr; el #GP trae RIP.
atk_run() {
    local mode=$1 vec=$2 err=$3 addr=$4 off win kill
    typefs "fs write zkq $mode"
    off=$(wc -c < "$SERIAL" | tr -d ' ')
    typewait "zone exec k zatk" 100
    win=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
    printf '%s\n' "$win" | grep -qx "atk $mode" || fail "attack $mode did not start"
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
K=0xffffffff80010000
H=0xffff800000001000
# Mitad alta del kernel: leer y escribir. P|U sin escritura es 0x5; con
# escritura, 0x7. La página es de supervisor: el bit de usuario del error
# dice que vino de anillo 3.
atk_run 1 14 0x00000005 $K
atk_run 2 14 0x00000007 $K
atk_run 3 14 0x00000005 $H
atk_run 4 14 0x00000007 $H
atk_run 5 14 0x00000005 0x0000000000001000
# NX: pila y página pedida con la syscall 8 (error 0x15 = P, U, fetch);
# el texto del kernel tampoco se ejecuta desde anillo 3.
atk_run 6 14 0x00000015 0x0000000000401800
atk_run 7 14 0x00000015 0x0000000000402000
atk_run 9 14 0x00000015 $K
# Su propio código es de solo lectura (P, W, U).
atk_run 8 14 0x00000007 0x0000000000400000
# Dirección no canónica: QEMU 11.1 (y el hardware) dan #GP con addr = RIP
# del programa; el QEMU de Ubuntu en CI la entrega como #PF con CR2 = la
# dirección. Las dos niegan el acceso y matan solo al proceso: se acepta
# cualquiera de las dos, pero nada más.
atk_run a '(13|14)' '0x0000000[05]' '(0x00000000004[0-9a-f]{5}|0x8000000000000000)'
tr -d '\r' < "$SERIAL" | grep '^user killed ' | grep -Eq 'vec=13 err=0x00000000 addr=0x00000000004|vec=14 err=0x00000005 addr=0x8000000000000000$' || fail "attack a: unexpected fault combination"
# Página de usuario que no existe (no presente, U).
atk_run b 14 0x00000004 0x0000000000500000
# SG-02: excepciones de CPU de anillo 3 que no son #PF ni #GP de memoria.
# El addr de `user killed` es el RIP de la instrucción que falla (trap de
# fallo: apunta a ella). Se exige que esté dentro del programa y que los
# bytes de build/ataque.bin en ese RIP sean la instrucción esperada: así
# el vector no puede venir de otro lado. El vector y el error son exactos:
# #UD de ud2 (6, sin código de error), #DE de idiv (0, sin código) e
# `int 3`, que no da #BP: la puerta 3 de la IDT es DPL 0 (0x8E) y INT n
# con CPL 3 > DPL da #GP con error = 3*8+2 = 0x1a.
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
exc_run i 13 0x0000001a 'cd03'
typefs "zone ls"
zk=$(tr -d '\r' < "$SERIAL" | grep '^zone 4 k pre=zk ' | tail -1)
[ -n "$zk" ] || fail "zone k missing after the attacks"
printf '%s\n' "$zk" | grep -q ' pag=0 ' || fail "zone k kept pages after being killed ($zk)"
printf '%s\n' "$zk" | grep -q 'proc=0/' || fail "zone k kept a process after being killed ($zk)"
typefs "echo vivo2"
tr -d '\r' < "$SERIAL" | grep -qx "vivo2" || fail "shell did not answer after the attacks"
echo "ok   ring 3 vs kernel memory: $attack_n attacks (read/write kernel, exec kernel, exec NX stack and page, write own code, non-canonical, unmapped) each killed only the process"

# (e) Ninguna syscall recibe hoy un puntero de usuario: el nombre y los datos
# son direcciones fijas del propio proceso (0x401800, 0x401C00). Lo que sí se
# puede es mandar punteros del kernel como largo (syscalls 6 y 7) y en rsi y
# rdx, y apuntar la entrada del AXE1 al kernel (el kernel lee esa cabecera
# del disco). Todo se niega y nada se filtra.
typefs "fs write zkq d"
off=$(wc -c < "$SERIAL" | tr -d ' ')
typewait "zone exec k zatk" 100
win=$(tail -c +$((off + 1)) "$SERIAL" | tr -d '\r')
printf '%s\n' "$win" | grep -qx 'atk d' || fail "pointer attack did not start"
printf '%s\n' "$win" | grep -qx 'zone ptr denied' || fail "kernel pointers as syscall arguments were not all denied"
printf '%s\n' "$win" | grep -q 'atk survived' && fail "a kernel pointer argument was accepted"
printf '%s\n' "$win" | grep -q 'user killed' && fail "pointer attack faulted: the kernel touched a bad address?"
printf '%s\n' "$win" | grep -qx 'zone exec ok' || fail "pointer attack did not finish"
typefs "fs cat zkq"
tr -d '\r' < "$SERIAL" | awk '/^lapageria> fs cat zkq$/ {f=1; next} f && /^fs live / {print; exit}' | grep -qx 'fs live d' || fail "pointer attack changed the file"
typefs "exec kentry"
typefs "zone exec k kentry"
tr -d '\r' < "$SERIAL" | awk '
/^lapageria> exec kentry$/ { f=1; next }
f && /^exec bad entry$/ && !a { a=1; next }
f && /^lapageria> zone exec k kentry$/ { g=1; next }
g && /^exec bad entry$/ { b=1 }
/run begin/ && f { r=1 }
END { exit !(a && b && !r) }
' || fail "AXE1 with entry in the kernel was not rejected, or it ran"
echo "ok   kernel pointers as syscall arguments denied; AXE1 entry in kernel rejected (exec bad entry)"
typefs "fs rm zkq"
typefs "fs rm zatk"
typefs "fs rm kentry"

require_net
typewait "net" 120
tr -d '\r' < "$SERIAL" | awk '
{
    if (i==0 && $0=="net arp ok") i=1
    else if (i==1 && $0=="net ping ok") i=2
    else if (i==2 && $0=="net drop ok") i=3
}
END {
    if (i != 3) {
        print "net stuck at " i > "/dev/stderr"
        exit 1
    }
}
' || fail "net story missing a line"
echo "ok   net arp, ping, drop"

typefs "trace clear"
typefs "trace on pit"
overflow=0
for _ in $(seq 20); do
    sleep 0.25
    typefs "trace count"
    lost=$(tr -d '\r' < "$SERIAL" | sed -n 's/^trace count lost \([0-9][0-9]*\)$/\1/p' | tail -1)
    pit=$(tr -d '\r' < "$SERIAL" | sed -n 's/^probe pit \([0-9][0-9]*\)$/\1/p' | tail -1)
    if [ -n "${lost:-}" ] && [ -n "${pit:-}" ] && [ "$lost" -gt 0 ] && [ "$pit" -gt 32 ]; then
        overflow=1
        break
    fi
done
[ "$overflow" = 1 ] || fail "pit probe did not overflow the ring (lost=${lost:-} pit=${pit:-})"
typefs "trace off pit"
typefs "trace dump 1"
tr -d '\r' < "$SERIAL" | awk '
function bad(msg) { print msg > "/dev/stderr"; exit 1 }
$0=="trace begin" { n=0; cap=1; next }
cap && /^t / { ev[n++] = $0; next }
cap && /^trace end n / { endline=$0; cnt=n; if (n>0) ev0=ev[0]; cap=0 }
END {
    if (cnt != 1) bad("overflow dump count " cnt " [" endline "]")
    if (endline !~ /^trace end n 1 lost [1-9][0-9]*$/) bad("overflow dump end: [" endline "]")
    if (ev0 !~ /^t [0-9]+ pit pid [0-9]+ a [0-9]+ b 0$/) bad("overflow event: " ev0)
}
' || fail "ring not readable after overflow"
typefs "echo vivo"
tr -d '\r' < "$SERIAL" | grep -qx "vivo" || fail "shell did not answer after the ring overflow"
echo "trace overflow ok"

typeline ud2
sleep 0.5
if tr -d '\r' < "$SERIAL" | grep -q "exception: vector 6 #UD invalid opcode"; then
    echo "ok   ud2 -> #UD"
else
    fail "no #UD exception message"
fi

# Mismo data.img, otro arranque. `quit` del monitor cierra el disco.
stop_qemu
sync
start_qemu "$TMP/serial2.log"
for _ in $(seq 100); do grep -q "lapageria> " "$SERIAL" 2>/dev/null && break; sleep 0.2; done
grep -q "lapageria> " "$SERIAL" || fail "no shell prompt on second boot"
typefs "fs cat a"
typefs "fs snap s1 a"
typefs "fs cat b"
typefs "fs cat c"
typefs "fs snap s1 b"
typefs "fs check"
typefs "fs corrupt a"
typefs "fs cat a"
typefs "fs snap s1 a"
tr -d '\r' < "$SERIAL" | awk '
{
    if (i==0 && $0=="fs live v2") i=1
    else if (i==1 && $0=="fs snap v1") i=2
    else if (i==2 && $0=="fs live b1") i=3
    else if (i==3 && $0=="fs empty") i=4
    else if (i==4 && $0=="fs fail 7") i=5
    else if (i==5 && $0=="fs blocks ok") i=6
    else if (i==6 && $0=="fs corrupt armed") i=7
    else if (i==7 && $0 ~ /^fs live/) {
        print "fs corrupt returned live data" > "/dev/stderr"
        exit 1
    }
    else if (i==7 && $0=="fs corrupt detected") i=8
    else if (i==8 && $0=="fs snap v1") i=9
}
END {
    if (i != 9) {
        print "fs phase 2 stuck at " i > "/dev/stderr"
        exit 1
    }
}
' || fail "fs persist or corrupt check failed"
echo "ok   fs persist v2, snap v1, corrupt detected"
