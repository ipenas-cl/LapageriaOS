# Changelog

Lapageria rosea es el nombre científico del copihue; antes AtomicOS.

Las notas de las versiones Tempo (hasta v5.2.2) están en el historial de git,
en el commit `355f4ec7438239f0062988512a5c9f585da8cc57`. La etiqueta propuesta
para ese commit es `legacy-tempo`.

## 0.8

CP-01: el compilador fijado sube de v0.31.0 a v0.34.1 (commit
`330ec195b27c8cd66aa1cf5ee5113c767a1ea5ca`). No hubo cambios de código
en `src/`: `make` compila igual. `kernel.bin` mide 157775 bytes (309
sectores, igual que con v0.31.0) y `stage2.bin` pasa de 1789 a 1805
bytes (máximo 4096): v0.34.1 agrega `push`/`pop` de `edx` y `ebx` en
`bits 16`/`bits 32`. El banner del shell dice v0.34.1 (misma
longitud). El `Makefile` mide tamaños con `wc -c < archivo | tr -d ' '`
en vez de `stat -c %s`, para que corra en macOS y en Linux. El arranque
en QEMU no se probó con esta versión; queda para el CI. Lo que sigue
describe la imagen con v0.31.0.

Kernel en Copihue v0.31.0 (commit
`495bb4b54d3fba77ed83aa51c0d2362ea9ebd621`). `git ls-remote` devuelve
ese commit para el tag, para `HEAD` y para `refs/heads/main`. `git -C
build/copihue rev-parse HEAD` después del `make` también, y
`copihue --version` imprime `Copihue 0.31.0`. v0.31.0 rechaza un
entero más ancho en un campo, un elemento, un store, un argumento o
un `return` sin `as`. El lado derecho va entre paréntesis. Este árbol
agrega los 75 que lista el CHANGELOG de Copihue para estos archivos,
y uno más en `nx.lap`: `p[0] = (old) as u8`. `old` es el byte leído
de `.text` (`movzx` a `i64`); el `as` lo devuelve a `u8` y el store
es `mov byte`, sin otra máscara. No es una PTE. El bit 63 vive en
`i64` y en `u64`: `pte_nx_bit` hace `shl` de 63 y la hoja se escribe
con `mov qword`. Un directorio no lleva ese bit, porque `>>` es
aritmético y `(e >> 12) << 12` ensuciaría la dirección. Los 75 son
el store que ya recortaba v0.30.0: la celda VGA, el dígito, la
tecla, los bytes de la GDT y de la MAC, los campos `u32` del disco y
del CRC-32, los bytes del checksum, el `u16` del descriptor de envío
y el límite de la IDT (767, cabe en 16 bits). Un `as` de esos 75 no
agrega una máscara que el store de v0.30.0 no tuviera. `hola.bin` y
`zona.bin` no necesitaron `as` nuevo.

v0.30.0, incluido en este pin, recorta `u8`/`u16`/`u32` después de cada
operador y `volatile` forma parte del tipo del puntero. Un
`(byte & 255) << 8` quedaba en 0: `ata_id_word`, la MAC del e1000, el
ethertype, el largo y el fragmento IP, el id y la secuencia ICMP, el
opcode ARP y el byte impar de `net_csum` ensanchan ese byte con
`as i64` antes del desplazamiento. El CRC-32 y el checksum par siguen
en un acumulador sin tipo (`i64`). `parse_int` resta `'0'` solo en un
dígito; el `movzx` no cambia 0..9. `fs_commit` suma 1 a un campo
`u32`: el valor que vuelve al campo es el del store recortado de
antes. `e_rd` enmascara 32 bits. Las páginas se calculan en `i64`.
No hubo un error de `*volatile` asignado a un puntero sin `volatile`.
El caso mínimo del `<<` y la lista de conversiones implícitas
puntero/entero están en `docs/PEDIDOS_COPIHUE.md`.

Bit NX y W^X, traído de la rama sobre Copihue v0.29.4. Con `-cpu
qemu64`, CPUID `0x80000001` EDX bit 20 está puesto y el kernel prende
EFER.NXE (MSR `0xC0000080`, bit 11) y CR0.WP. La página de 2 MiB de
PD[0] pasa a 512 páginas de 4 KiB: `.text` (`0x10000`..`0x33000`, 35
páginas) queda ejecutable y sin escritura; datos, `.bss`, pilas, heap
y el MMIO llevan el bit 63. `.data` y `.bss` comparten la página
`0x34000`. En esa rama, el comando `nx` en QEMU 8.2.2 imprimió fetch
`err=0x00000011` `cr2=0x00033000`, escritura `err=0x00000003`
`cr2=0x00010000`, usuario `err=0x00000015` en `0x401000` y `0x500000`
con `nx ok sched` en medio, y `nx ok audit wx=0 leaves=513 code=35
nx=478 huge=0`. `make qemu-test` de esa imagen terminó en 0 e
imprimió `ok   nx fetch=0x00000011 write=0x00000003 user=0x00000015
audit wx=0 leaves=513 code=35 nx=478`. El humo de 10 s con `-cpu
qemu64` salió 124 y mostró `nx efer on` y `nx wp on`. No hay `asm()`
nuevo. Copihue ya tenía `wrmsr`, `cpuid` y el desplazamiento de 63
bits. El detalle está en `docs/nx.md`. El planificador pone
`released_ok` en 0 al entrar a `sched`, porque `nx` también libera
sus dos procesos. Esta imagen junta la red e1000, el nombre
LapageriaOS, las trazas y las zonas ligeras sobre el kernel sin
`asm()`. El planificador guarda el marco del shell con `save_context`
y vuelve con `restore_context`. El PIT y el `#PF` leen el marco de la
CPU por un puntero. El directorio, el superbloque, el metadato del
bloque y la cabecera AXE1 son structs; el disco no cambia. `EthHdr`,
`ArpPkt`, `IpPkt`, `IcmpEcho`, `TrEv` y `ZoneStr` también:
`net_layout`, `trace_layout` y `zone_layout` comprueban `sizeof` y
`offsetof`. Los campos de más de un byte de la trama van en dos
`u8`, en orden de red, así que la trama no cambia. `fs_remove` usa
`FsEnt` y `FsSlot`; el slot del directorio sigue midiendo 64. No
queda `asm()` en el kernel ni en el arranque. `clear_df` es `cld()`
antes de `lodsb` y de `rep_stosd`. `pushfd` / `popfd` queda en
`check_long_mode` (bit ID) y en `trace_save_if` (en 64 bits emite
`pushfq`). `get_e820` escribe el token de INT 15h en `ebx`. En
v0.29.2 un `+` fuera de la condición dejaba el sumando ahí (`di = di
+ 24` dejaba 24) y sin la copia QEMU imprimía `e820 n=1`. v0.29.4
hace `push ebx` / `pop ebx` alrededor de ese `+`. Con `ebx` directo,
QEMU 8.2.2 imprimió `e820 n=7` y `pmm free=32480`. Un store de
dirección no simple y `lgdt` / `lidt` / `invlpg` sin etiqueta todavía
dejan `ebx` modificado; `get_e820` no los usa entre el `int 0x15` y
el `if (ebx == 0)`. El caso está en `docs/PEDIDOS_COPIHUE.md`.

El arranque es `src/bootloader/boot.lap` (512 bytes, firma `55 aa`;
el último byte distinto de cero antes de la firma está en el offset
168) y `src/bootloader/stage2.lap` (en `0x8200`, 1789 bytes). La
etapa 2 pide los sectores que ocupa `kernel.bin`, de a 128 por INT
13h. En esta compilación `kernel.bin` mide 157775 bytes: 309
sectores, LBA 9..317, paquete `10 00 35 01 00 00 00 10 09 00 00 00
00 00 00 00`. `make` suma 22188 bytes de `.bss` y escribe fin de
imagen `0x3befb`. `__bss_end` es `0xFFFFFFFF8003BEFC` (físico
`0x3BEFC`). `stage2.bin` mide 1789 bytes. El pin v0.31.0 sin NX
medía 136835 bytes, 268 sectores, LBA 9..276, paquete `10 00 0c 01
00 00 00 10 09 00 00 00 00 00 00 00`, `.bss` 22060 y fin `0x36CAF`,
con la etapa 2 de 1682. La rama NX sobre v0.29.4 medía 149053 bytes,
292 sectores y `__bss_end` `0x39cac`, y `stage2.bin` en 1678. La
imagen NX de v0.31.0 todavía enlazada en `0x10000` medía los mismos
149053 bytes, 292 sectores, paquete `10 00 24 01 …`, `.bss` 22124,
fin `0x39ca9` y `stage2.bin` en 1682. Los 75 `as` no agregan
instrucciones. El `as u8` de `nx.lap` tampoco.

El kernel queda enlazado en `0xFFFFFFFF80010000`
(`copihue --flat` de v0.31.0). NASM `-f bin` no rellena hasta esa
dirección: el archivo empieza en `_start`. La etapa 2 arma la
identidad baja y la ventana `0xFFFFFFFF80000000` (PML4[511] =
`0x4003`, PDPT[510] = `0x5003`, PD en `0x5000`), pone RSP en
`0xFFFFFFFF80090000` y salta con `jmp rax` (`FF E0`). `nx_init`
parte las dos páginas de 2 MiB. `.text` (`0x10000`..`0x35000`, 37
páginas) queda ejecutable y sin escritura en las dos tablas; el
resto lleva el bit 63. `hh_retire` borra de la tabla baja las
páginas `0x10000`..`0x3C000`. VGA, E820, las tablas y las pilas de
`0x60000` para arriba siguen en identidad. GDT, IDT y TSS viven en
la `.bss`, así que después de eso solo se alcanzan por la ventana
alta. El PDPT compartido de cada proceso apunta su slot 510 a la PD
`0x5000`, sin bit de usuario. El comando `hh` comprueba RIP, RSP, el
`#PF` de `0x10000` y el de anillo 3 sobre `0xFFFFFFFF80010000`. La
auditoría sigue en `wx=0`: `leaves=981 code=37 nx=944`. El comando
`user` ve `err=0x4` en `0x10000`, porque esa página ya no está. El
detalle está en `docs/higher-half.md`. No hubo pedido nuevo a
Copihue: `--flat` con esa dirección basta.

El archivo puede pasar de `0x20000`; imagen y `.bss` tienen que
terminar antes de `0x58000` (la pila de `0x60000` crece hacia abajo).
`make` rechaza un kernel de más de 512 sectores. El disquete tiene
2880 sectores y después del LBA 8 quedan 2871, así que el tope que
aprieta es esa pila, no los 1.44 MB. 512 sectores caben: el kernel
máximo terminaría en el LBA 520 y sobrarían 2359. Con esta `.bss`, ese
tope llegaría a `0x5566c`, todavía antes de `0x58000`. Cada proceso tiene
su PML4 y el PIT hace round-robin. La imagen la construyen `make all`
y la comprueba `make qemu-test`. El árbol de trabajo ya no incluye el
lenguaje Tempo ni sus salidas generadas.

En v0.28.1 un `while` y un `if` saltan por los flags, y un store de
constante no pasa por `rax`. `src/user/zona.lap` pide la cuota con
`r = syscall(8)` y `if (r == 0 - 1)`. `r` está en la pila. El
ensamblado está en `docs/PEDIDOS_COPIHUE.md`.

En QEMU 8.2.2, `make qemu-test` del pin v0.31.0 sin NX terminó en 0. El
script imprimió ticks 100 → 200 en 935 ms,
ticks 200 → 417, `keyboard IRQ count=151`, `cr3=0x1000 pml4=0x2023
pdpt=0x3023`, `e820 n=7`, `pmm free=32480 base=0x0000000000100000
end=0x0000000007fe0000`, `gdt ok`, `pmm ok, high page 0x00201000`,
letras `babababababa`, `round-robin timer=29 yield=4`, `exit freed
7+6 pages, pmm back to 32473`, `trace counters ok`, `ata ok, blk ok,
blk corrupt detected`, `trace syscall ok`, `trace off ok`, `exec
desde disco, missing, bad magic, bad size, corrupt`, `zone fs,
denied, syscall, quota mem 32473, escape`, `net arp, ping, drop`,
`trace overflow ok`, `ud2 -> #UD`, y en el segundo arranque `fs
persist v2, snap v1, corrupt detected`. `gdt load` y después `gdt ok`
salen también en el humo de ese pin: `lgdt(&gdtr)` corre en QEMU. El
PIT, la IRQ1, el `#PF` y el `#UD` salen con la IDT cargada por
`lidt`. El round-robin, el retorno de `user` y la zona usan
`save_context` y `restore_context`. Ese humo de 10 s, sin `-cpu
qemu64` y sin disco de datos, salió 124. La serie mostró `e820 n=7`,
las siete entradas, `pmm free=32480`, `gdt load`, `gdt ok`, `timer:
ticks=100`, `timer: ticks=200` y `lapageria>`. No se probó `reboot`,
`clear`, el teclado a mano, TCP, UDP, AHCI, NVMe, el bit NX ni un
kernel en la mitad alta. El borde `gen == 0xFFFFFFFF` de `fs_commit`
no se ejecutó.

En la rama NX sobre Copihue v0.29.4, con `-cpu qemu64`, el script
imprimió ticks 100 → 200 en 1037 ms, ticks 200 → 418, `keyboard IRQ
count=151`, `cr3=0x1000 pml4=0x2023 pdpt=0x3023`, `e820 n=7`, `pmm
free=32480 base=0x0000000000100000 end=0x0000000007fe0000`, `ok   nx
fetch=0x00000011 write=0x00000003 user=0x00000015 audit wx=0
leaves=513 code=35 nx=478`, `pmm ok, high page 0x00201000`, letras
`baabaabababb`, `round-robin timer=28 yield=4`, `exit freed 7+6
pages, pmm back to 32472`, `trace counters ok`, `ata ok, blk ok, blk
corrupt detected`, `trace syscall ok`, `trace off ok`, `exec desde
disco, missing, bad magic, bad size, corrupt`, `zone fs, denied,
syscall, quota mem 32472, escape`, `net arp, ping, drop`, `trace
overflow ok`, `ud2 -> #UD`, y en el segundo arranque `fs persist v2,
snap v1, corrupt detected`. El humo de 10 s con `-cpu qemu64`, sin
disco de datos, salió 124. La serie mostró `e820 n=7`, las siete
entradas, `pmm free=32480`, `nx efer on`, `nx wp on` y `lapageria>`.
No se probó `reboot`, `clear`, el teclado a mano, TCP, UDP, AHCI,
NVMe ni un kernel en la mitad alta.

En la imagen anterior (v0.31.0 y NX, kernel en `0x10000`), tres
`make qemu-test` seguidos en QEMU 8.2.2 con `-cpu qemu64` terminaron
en 0. La línea NX fue la misma las tres veces: `ok   nx
fetch=0x00000011 write=0x00000003 user=0x00000015 audit wx=0
leaves=513 code=35 nx=478`. También coincidieron `keyboard IRQ
count=151`, `cr3=0x1000 pml4=0x2023 pdpt=0x3023`, `e820 n=7`, `pmm
free=32480`, `exit freed 7+6 pages, pmm back to 32472` y `zone quota
mem 32472`. Lo que cambió entre corridas: ticks 100 → 200 en 935 ms,
934 ms y 946 ms; ticks 200 → 416, 418 y 419; letras `abbaababbaab`,
`babababababa` y `abababababba`; `round-robin timer=38`, `27` y
`29`, las tres con `yield=4`. El humo de esa imagen salió 124 y
mostró `nx efer on` y `nx wp on`, sin `hh on`.

En esta imagen, tres `make COPIHUE=/tmp/copihue qemu-test` seguidos
en QEMU 8.2.2 con `-cpu qemu64` terminaron en 0. Las dos líneas
estables fueron `ok   nx fetch=0x00000011 write=0x00000003
user=0x00000015 audit wx=0 leaves=981 code=37 nx=944` y `ok   hh rip
rsp low=#PF user wx=0 leaves=981 code=37 nx=944`. También
coincidieron `keyboard IRQ count=151`, `cr3=0x1000 pml4=0x2023
pdpt=0x3023`, `e820 n=7`, `pmm free=32480 base=0x0000000000100000
end=0x0000000007fe0000`, `gdt ok`, `pmm ok, high page 0x00201000`,
`exit freed 7+6 pages, pmm back to 32471`, `trace counters ok`,
`ata ok, blk ok, blk corrupt detected`, `trace syscall ok`, `trace
off ok`, `exec desde disco, missing, bad magic, bad size, corrupt`,
`zone fs, denied, syscall, quota mem 32471, escape`, `net arp, ping,
drop`, `trace overflow ok`, `ud2 -> #UD` y, en el segundo arranque,
`fs persist v2, snap v1, corrupt detected`. Lo que cambió entre
corridas: ticks 100 → 200 en 935 ms, 938 ms y 1035 ms; ticks 200 →
415, 419 y 418; letras `babababababa`, `abbababababa` y
`babababababa`; `round-robin timer=25`, `33` y `27`, las tres con
`yield=4`. El humo de 10 s (`timeout 10 qemu-system-x86_64 -cpu
qemu64 -drive format=raw,file=build/lapageriaos.img -display none
-no-reboot -serial file:…`, sin disco de datos) salió 124. La serie
mostró `e820 n=7`, las siete entradas (la usable de 1 MB termina en
`0x7fe0000`), `pmm free=32480`, `gdt load`, `gdt ok`, `nx efer on`,
`nx wp on`, `hh on text=0xffffffff80010000`, `timer: ticks=100`,
`timer: ticks=200` y `lapageria>`. Esa corrida no escribe comandos.
No se probó `reboot`, `clear`, el teclado a mano, TCP, UDP, AHCI ni
NVMe. El borde `gen == 0xFFFFFFFF` de `fs_commit` no se ejecutó. El
`make` de esta sesión usó un `copihue` ya compilado de ese commit;
no clonó `build/copihue`.

El esclavo IDE (`build/data.img`, QEMU index=1) tiene driver ATA PIO
LBA28 y bloques de 512 B con CRC-32 en un sector de metadatos. `disk`
escribe un patrón, lo relee y comprueba que un byte pisado con el
driver (sin pasar por `blk`) hace fallar la lectura. El layout está en
`docs/disco.md`.

Encima de esos bloques hay un sistema de archivos copy-on-write, con
directorio plano, snapshots y rollback (`docs/fs.md`). `make qemu-test`
formatea, escribe, saca un snapshot, reabre el mismo `data.img` y
comprueba que un bloque pisado no se entrega como dato.

`exec` carga un ejecutable plano de 16 bytes de cabecera (`AXE1`,
tamaño, entrada) desde ese disco a un PML4 nuevo (`docs/exec.md`).
`scripts/mkaxe.sh` arma la imagen; `exec plant` la escribe con
`fs_write`. Un magic malo, un tamaño de más o un bloque con el CRC
roto no arrancan el proceso.

Hay zonas ligeras (`docs/zonas.md`): la zona 0 es la global y una
zona nueva niega syscalls, nombres fuera de su prefijo y páginas o
procesos sobre su tope. `zone exec` mete un programa del disco en esa
zona. Al salir, los marcos vuelven al asignador.

`net` habla con el e1000 de QEMU (82540EM) por PCI: ARP de `10.0.2.15`
contra la puerta `10.0.2.2`, IPv4 con checksum e ICMP echo. No hay
TCP ni UDP, y el chip no queda prendido en el arranque. El layout y
la prueba están en `docs/red.md`. Una trama cuyo largo IP no cabe en
el buffer se descarta.

`trace` deja once sondas estáticas y un anillo fijo de 32 eventos
(`docs/trace.md`). Apagada, la sonda es un chequeo. `trace dump`
muestra los últimos eventos; si el anillo se llena, pisa lo viejo y
cuenta los perdidos. No se agregó `asm()`.
