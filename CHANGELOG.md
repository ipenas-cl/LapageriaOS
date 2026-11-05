# Changelog

Lapageria rosea es el nombre científico del copihue; antes AtomicOS.

Las notas de las versiones Tempo (hasta v5.2.2) están en el historial de git,
en el commit `355f4ec7438239f0062988512a5c9f585da8cc57`. La etiqueta propuesta
para ese commit es `legacy-tempo`.

## 0.8

EX-03, página de guarda de la pila y estabilidad de los ataques.
(1) La pila de un AXE2 iba pegada a la página de E/S (`0x410000`): un desborde
pisaba el nombre y los datos de las syscalls 6, 7 y 27 y moría recién bajo la E/S,
en `0x40fxxx`. Ahora `0x411000` queda sin mapa, la pila pasa a `0x412000` (tope
`0x413000`) y las páginas de la syscall 8 empiezan en `0x413000`; `uptr_range_ok`
trata la E/S y la pila como regiones separadas (un rango que cruza la guarda da
`-14`). `atk2` suma los modos `t`, `u`, `r` (leer, escribir y ejecutar la
guarda), `v` y `x` (`rsp` dentro de la guarda y bajo la E/S, en el hueco, y un
`push`) e `y` (marco local de 8 KiB). `tests/qemu_axe2_test.sh` pasa de 18 a 23
ataques, exige que el desborde por recursión caiga en `0x411xxx` y que con
`exec2 atk2 pag2` (en los dos órdenes) muera solo `atk2` mientras `pag2` dice
`pag2 ok`, devuelve 9 páginas y el shell responde. Límite conocido: un marco
local de más de 4096 bytes salta la guarda (`atk2 y` sobrevive; la prueba lo
informa y no lo exige) porque el compilador no sondea la pila; pedido en
`docs/PEDIDOS_COPIHUE.md`. (2) Baterías de ataques repetidas: los 16 ataques de
AXE1 salen de `qemu_shell_test.sh` (que mezcla comprobaciones del PIT y no
admite icount) a `tests/qemu_atk1_test.sh`, con `QEMU_EXTRA`. `make
qemu-stab-test` corre 6 veces cada batería, 3 a la vez, con `-icount shift=7` y
sin icount: AXE2 6/6 y 6/6, AXE1 6/6 y 6/6, ninguna falla. Lo único que falló
fue la batería AXE1 sola, en su primera corrida: `zone leak` en el primer
ataque. No era una fuga: `shared_init` toma 2 páginas bajas la primera vez que
se arma un proceso y `zone_run` medía `before` antes, así que el primer `zone
exec` tras el arranque dijo `zone leak` siempre (la prueba grande lo escondía con
un `exec` previo). `zone_run` llama ahora a `shared_init` antes de medir.
`tests/repeat.sh` sale con error si alguna corrida falla y ya no lleva una ruta
absoluta. Kernel: 941 sectores (antes 933).

EX-02, `mkaxe.sh` empaca AXE2 y ataques de anillo 3 contra un AXE2.
(1) `scripts/mkaxe.sh [-d datos.bin] [-b bss] payload.bin salida.axe salida.lap
[funcion]`: sin opciones y con un payload de hasta 4080 bytes sale el mismo AXE1
de siempre (los `.lap` de `hola`, `ataque`, `grande` y `traza` se regeneraron y
son idénticos byte a byte); con `-d`, `-b` o un payload mayor sale un AXE2 de 1 a
16 páginas: texto relleno con ceros hasta la página, datos desde la página
siguiente, bss detrás de los datos (o en la página siguiente al texto si no hay
datos) sin ocupar archivo. El `.lap` de un AXE2 limpia el buffer y solo escribe
las palabras no nulas, y `mkaxe.sh` vuelve a armar el archivo desde el `.lap` y lo
compara con el `.axe`. `tests/mkaxe_test.sh` (`make mkaxe-test`, sin QEMU) revisa
las cabeceras byte por byte, el relleno, la bss y los rechazos. `src/user/pag2.lap`
es el primer AXE2 de verdad (1 página de texto, 1 de datos con marcadores armada
en el Makefile con `printf` y `dd`, 1 de bss): `exec pag2` imprime `pag2 ok` tras
leer los marcadores del archivo y escribir su segunda página. (2) `src/user/atk2.lap`
hace 18 ataques de anillo 3 contra un AXE2, uno por corrida, y los 18 matan solo
al proceso sin fugas: escribir el texto (primer y último byte), ejecutar datos,
bss, página de E/S, pila y página de la syscall 8 (con un `ret` de destino, para
que sobrevivir se note), leer y escribir fuera de sus páginas, desbordar la pila,
kernel, tablas, no canónica, y escribir la segunda página de `atk2w` (texto de 2
páginas). Control: la misma escritura en `atk2` (datos) no mata a nadie. Trece
punteros malos contra la syscall 23 op 5 dan `-14` y el texto queda igual; cinco
rangos válidos que cruzan de página funcionan. (3) La validación de cabecera salió
de `exec_prepare` a `exec_hdr` (mismos mensajes) y ahora exige los 8 bytes
reservados de un AXE2 en cero. `exec hdrcheck` estropea la cabecera de `pag2` en 28
casos y los pasa por `exec_hdr`. `tests/qemu_axe2_test.sh` (`make
qemu-axe2-test`, también en `make qemu-test`). Los 16 ataques de AXE1 de
`tests/qemu_shell_test.sh` no se tocaron. Sigue pedido a Copihue: datos y bss en
`--flat`, y alinear una función a una página (`docs/PEDIDOS_COPIHUE.md`, EX-02).

EX-01, programas de modo usuario de varias páginas y `qemu_udp_test` estable.
(1) `exec2: udpdos no abrió sus sockets` (PR 45, primera corrida) era una
carrera: la syscall 1 escribe un carácter y el PIT puede cortar a un proceso a
mitad de línea, así que con `exec2` salía `udp dos listenudp ptr denied` y la
marca de la prueba dejaba de ser una línea. Se reprodujo en `main` con
`-icount shift=7`, 6 a la vez: en 12 corridas, una dio la misma línea y otra
`woke 0 -> 0` (la prueba suponía que el despertar por llegada ocurría siempre);
en otras 6, una dio `no line 'udp listen'`. Ahora la salida de los programas del disco va
por líneas enteras (`usermode.lap`: búfer por proceso, vaciado en el `\n` con
interrupciones apagadas y antes de cualquier mensaje del kernel sobre el
proceso; las demos de `sched` siguen carácter a carácter porque su prueba usa
la mezcla de letras). `udp_recv` imprime `udp block <puerto>` al dormir y la
prueba manda cada datagrama al ver esa línea (sin interrupciones entre la
marca y el sueño, así que `blk` y `woke` ya no dependen de quién llegó
primero); el único que cuenta `woke` es el que durmió primero y se le manda
primero. `tests/qemu_udp_test.sh` copia la imagen (corridas en paralelo) y
acepta `QEMU_EXTRA`. Con shift=7 aparecía además `exec fail 1` / `exec fail 8`
en `udp plant` (timeout ATA: 5 s virtuales son 39 millones de instrucciones);
el tope pasa a 60 s del contador del PIT. (2) AXE2: `exec` carga programas de 1
a 16 páginas (cabecera de 32 bytes con bytes de texto y tamaño en memoria; texto
de solo lectura y ejecutable, datos y bss de lectura y escritura sin ejecución).
La página de E/S pasa a `0x410000`, sola; la pila a `0x411000` y las páginas de
la syscall 8 a `0x412000`. Los AXE1 siguen como estaban (`0x401000`, `0x402000`).
Los búferes de las syscalls 6, 7 y 27 se buscan con `uio_base()` y los rangos
de UDP, TCP y trazas se validan por regiones (`uptr_range_ok`). Un proceso
puede tomar hasta 32 páginas (eran 16). Programa de prueba `src/user/grande.lap`
y `tests/qemu_big_test.sh` (`make qemu-big-test`, también en `make qemu-test`).
Pedidos nuevos al lenguaje en `docs/PEDIDOS_COPIHUE.md` (EX-01). Detalle en
`docs/exec.md`.

OB-03, espacio en `par`, `zone ls` con CPU y cierre de la etapa 7.
`par.bin` estaba en 4078 de los 4080 bytes que admite `mkaxe.sh`. El modo de
CPU por zona (`k<d>`) pasa a un programa propio, `src/user/parcpu.lap`
(`zone parcpu` lo escribe como `parcpu`; Makefile, `kernel.lap` y `.gitignore`
lo registran), y `par.bin` baja a 3919 bytes (`parcpu.bin`: 665). No se subió el
tope: el código de usuario es una página de 4 KiB y sus búferes están en
direcciones fijas (`docs/PEDIDOS_COPIHUE.md`). `parcpu` ya no depende solo del
plazo de 60 s: lee el contador a lo sumo 2000000 veces y, si no llega, sale
solo y deja `0` en `r<pid>`; el modo `n9` (1000 lecturas) ejerce esa salida y
`tests/qemu_cpu_test.sh` la comprueba y exige que ningún `parcpu` haya salido
por tope. `zone ls` agrega `cpu=<cuota>/20 tot=<ticks>` al final de cada línea
(las pruebas que anclaban `max=N$` ahora buscan `max=N cpu=`). `docs/zonas.md`
gana «Administración de zonas» (todos los comandos `zone` y una receta) y el
README anota lo que falta de la etapa 7.

FS-05b, prueba de CPU independiente de la velocidad (PR 44). La prueba pedía
67 millones de vueltas fijas y esperaba de ahí ticks disputados; en el runner
de CI una zona tuvo 30 y falló. Ahora el programa gasta CPU hasta que el kernel
le ha cobrado N ticks a su zona (modo `k<d>`, syscall 28 `cpu_ticks`, en la
máscara de `zone sched`). Las cotas no cambian; `tests/repeat.sh` acepta
`sin-icount`.

FS-05, límite de CPU estricto por zona, `fs rm` protegido y disco por tiempo
real (PR 44). (1) Una zona con la cuota agotada y sin otro proceso listo ya no
sigue corriendo: pasa a una tarea ociosa (`idle_loop`, `hlt` sobre pila propia)
hasta que la ventana de 20 ticks se renueva; `zone cpu` muestra `idle=` y
`solo=`. (2) `fs rm` sin `-r` también pasa por la guarda: `/`, `/zonas` y
`/zonas/<nombre>` se rechazan sin tocar el disco. (3) El ATA espera por tiempo
real, leyendo el contador del canal 0 del PIT (cada 16 sondeos, rendición a los
5 s), sin ticks, `hlt` ni interrupciones; `tests/qemu_ata_test.sh` con
`-icount shift=4`.

FS-04. (1) El `exec fail 1` con `-icount shift=4` era un timeout ATA: las
esperas del estado (BSY, DRQ, fin de escritura) acababan a las 200000
lecturas de `inb`, que miden instrucciones, mientras QEMU completa la E/S en
tiempo del anfitrión; con varias QEMU a la vez el tope se agotaba antes que
el disco. Ahora se espera por ticks del PIT con `hlt` (5 s). Prueba
`tests/qemu_ata_test.sh`. (2) `fs rm -r` rechaza `/`, `/zonas`,
`/zonas/<nombre>` y rutas con `.`, `..` o componentes vacíos; nuevo
`zone rm <nombre> <ruta>` (borrado dentro de la raíz de la zona). (3) Cuota
de CPU por zona: `zone cpu <nombre> <n>` (n ticks por ventana de 20), con
contadores y `tests/qemu_cpu_test.sh`.

FS-03, estabilidad de pruebas, migración y borrado (`docs/fs.md`).
`tests/qemu_iso_test.sh` ya no es una carrera: el modo `s` de `par` mataba al
pid 2 tras una sola cesión dando por hecho que ya había escrito `r2`; si el PIT
lo cortaba antes, salía `misma zona, pid 2: [], esperaba [11]` (reproducido
con `-icount shift=1`). Ahora el pid 1 espera la marca `r2` por polling con
cesión. `fs migrate` pasa un disco versión 1 a versión 2 en el sitio, sin
perder archivos ni snapshots (reusa los bloques de datos y publica al final;
hasta ahí el disco sigue siendo v1). `fs snap rm <nombre>` borra un snapshot
y libera lo que solo él usaba (`rm` queda reservado como nombre). `fs rm -r
<ruta>` borra una carpeta con todo lo de abajo. Prueba
`tests/qemu_fs3_test.sh` (`make qemu-fs3-test`, también en `make qemu-test`),
con discos v1 de `scripts/mkv1.c` (C) y, opcional, un kernel v1 real.

FS-02, sistema de archivos con directorios, archivos grandes, scrub y raíz
propia por zona (`docs/fs.md`, `docs/zonas.md`, `docs/disco.md`).
Superbloque versión 2: árbol de directorios (rutas con `/`, `fs mkdir`,
`fs ls ruta`, `fs rm` de archivo y de directorio vacío), inodos con 16
bloques directos y uno indirecto (archivos de hasta 72 KiB) y directorios de
varios bloques (hasta 64 entradas). Un disco versión 1 se rechaza con
`fs old version` y no se migra. Lo que queda sin dueño lo libera un barrido
de alcanzabilidad desde la raíz y desde cada snapshot; `fs scrub` verifica el
CRC de todo lo alcanzable y cruza con el bitmap (`fs scrub ok bloques=N`,
`bad bloque=N`, `leak N`). Cada zona ve `/zonas/<nombre>` como `/`: `zone
create nombre paginas` lo crea, el mecanismo de prefijo se eliminó y `..` o una
ruta absoluta se niegan con -1 y suben `niega`. `zone destroy nombre` y la
syscall 27 (solo zona 0): `zone busy` con procesos vivos, `zone destroyed N`
si no; los archivos quedan. Prueba `tests/qemu_fs2_test.sh` (`make
qemu-fs2-test`, también en `make qemu-test`). Cambian dos formatos de salida
que las pruebas viejas ya siguen: `zone ls` muestra `root=` en vez de `pre=` y
`niega` de la zona de prueba pasa de 64 a 91.

Copihue sube de v0.42.4 a v0.42.5 (commit
`ea898c6c2be6f1a1686cf06c5050c31e726ef177`). Se usa lo nuevo donde había
contorno: `irq_save()` / `irq_restore(f)` en las secciones críticas con
`cli()` / `sti()` (`ata`, `net`, `tcp`, `nx`, `hh`, `usermode`, `sched`,
`exec`, `zone`) y en `trace_save_if` / `trace_restore_if`;
`cx = n * 256;` en `stage2.lap`; `0 - *(… as *u8)` directo en `ataque.lap`;
`div_raw` / `rem_raw` en dos ataques nuevos, `r` y `m` (#DE por divisor cero;
`z` sigue con `INT64_MIN / -1`). Detalle en `docs/PEDIDOS_COPIHUE.md`.

El ISN de TCP (y el puerto efímero) se mezcla con `rdtsc()` en lugar del
contador del PIT y el segundero del CMOS; la MAC y los ticks siguen. No es
criptográfico.

OB-02, etapa 7, aislamiento entre zonas: un proceso de una zona no ve, no
señala ni traza a los de otra. Syscalls nuevas 25 `proc_stat` y 26
`proc_kill` (`zone sched` las da junto con `yield`); `trace_read` (24) fuera de
la zona global filtra siempre por la propia zona y niega pedir otra (`-1`);
`trace_ctl` (23) solo contesta las operaciones 4 y 5 (`zone trace` da 23 y
24). Un pid de otra zona da `-3`, igual que uno que no existe, y deja
`zone-deny` con `b` = 4. Prueba `tests/qemu_iso_test.sh` (`make
qemu-iso-test`, en `make qemu-test`): 14 intentos negados, los permitidos,
la misma zona y la global. `par` crece (3265 bytes): el kernel pasa de 722 a
770 sectores y `tests/stage2_big_test.sh` compara desde `0x4A0000` (antes
`0x490000`; la `.bss` llega a `0x487745`).

OB-02, cambio de zona en `switch_to`: `zone sched` (da `yield` a una zona),
`zone par` y `zone pair za zb programa` (dos copias del programa `par` a la
vez, una por zona), con los contadores `zsw_n` / `zsw_chg` y
`zone_note_switch`, que también registra la salida de un proceso con el otro
vivo. Prueba determinista `tests/qemu_zswitch_test.sh` (`make
qemu-zswitch-test`, en `make qemu-test`): 12 cesiones, 13 cambios de
contexto, todos cambian la zona y cada uno deja su `zone-switch`; misma zona
no deja ninguno; global contra zona sí.

Trazas con `rdtsc()`: cada registro del anillo guarda además la marca de
ciclos (`TrEv` pasa de 48 a 56 bytes). `trace dump` y `traza dump` agregan
` c <tsc>` al final de cada línea y la syscall 24 devuelve 7 `i64` por
registro (hasta 32, 1792 bytes). `traza.lap` compacta `do_ptr` con dos
ayudas (`c23`, `c24`) para caber en 4080 bytes (3926). Prueba en
`tests/qemu_trace_test.sh`: la marca es positiva y crece en 32 `pit` seguidos.

Copihue sube de v0.34.1 a v0.42.4 (commit
`795252ce322f12d1b14274f5b9bec7cb3a6ac2c9`). Sin cambios de código salvo
`src/user/ataque.lap`: los ataques 3 y 4 ya no necesitan la dirección en un
`*u8` local, porque v0.42.4 emite bien la dirección absoluta de 64 bits.
Los errores nuevos del compilador no se dispararon en ningún archivo.

OB-01: observabilidad (`trace.lap`, `docs/trace.md`). **Sondas:** de 11 a 20
(se suman `irq-kbd`, `irq-net`, `udp-rx`, `udp-tx`, `tcp-state`, `tcp-retx`,
`tcp-rst`, `zone-switch`, `zone-deny`), cada una prendida o apagada por
separado. **Anillo:** 64 registros (eran 32) de 48 bytes, con zona;
`trace dump` agrega ` z <zona>` al final de cada línea. **Syscalls:** 23
`trace_ctl` (prender, apagar, leer contador, vaciar, nombre) y 24
`trace_read` (hasta 32 registros con filtro de sonda, zona y pid), con los
punteros validados como UDP y TCP; las zonas las niegan. **Programa:**
`traza` (`trace plant`, luego `traza ls|count|on|off|dump|clear|ptr|zone`).
**Prueba:** `tests/qemu_trace_test.sh`, también en `make qemu-test` y como
`make qemu-trace-test`. El kernel pasa de 649 a 714 sectores; la prueba de la
etapa 2 grande compara desde `0x490000` (la `.bss` llega a `0x480283`).

RD-03: TCP endurecido (`tcp.lap`). **Bloques:** 8 TCB (eran 6, 64 KiB de
`.bss`); sin bloque libre se recicla el TIME_WAIT más viejo y, si no hay, el
SYN recibe RST\|ACK sin reservar nada (`full`); `listen`/`connect` dan `-24`
limpio; cola de 3 hijos llena descarta el SYN (`bklog`). **Cola fuera de
orden:** 4 bloques por conexión, los bytes van al anillo de recepción en su
posición final y se funden al llegar el hueco; ACK repetido por cada segmento
adelantado. **RTT/RTO (RFC 6298):** SRTT/RTTVAR por conexión, Karn, RTO de 3 s
tras retransmitir el SYN; RTO inicial 50, mínimo 20 y máximo 400 ticks (tres
desviaciones documentadas). **Congestión (RFC 5681/6582):** ventana inicial de
2 segmentos, arranque lento, evitación, timeout (`ssthresh`, `cwnd = 1`),
retransmisión rápida con 3 ACK repetidos, recuperación con ACK parciales;
`tc_max` separa lo más alto enviado de `tc_nxt`, que retrocede en un timeout.
**`tcp fault`:** `rxdrop`, `txdrop`, `swap` y `off` pierden o reordenan
segmentos con datos dentro del TCP del invitado (no en la red). **Programas:**
`tcpmulti` (eco de 2 conexiones a la vez por proceso, `exec2 tcpmulti
tcpmulti`) y `tcphog` (llena los bloques con hijos pendientes). **`tcp stat`**
suma `ooo oodrop fast rtos full bklog recyc rtts rtt rto cwmax fdrop peak
fswap`. **Pruebas** (`make qemu-test`): `tcp test` agrega cola fuera de orden,
RTT con valores exactos, congestión, agotamiento y fallas inyectadas; en QEMU,
4 ecos simultáneos de 64 KiB idénticos (2 servidores con `exec2`), eco íntegro
con pérdida (2 recibidos, 1 enviado) y con un segmento reordenado, y 8 de 8
bloques ocupados con RST\|ACK al siguiente SYN y `used 0` después. **No
probado:** la retransmisión rápida con tráfico real (en QEMU el invitado se
recuperó por timeout), pérdida de un solo segmento en la red (la inyecta el
TCP del invitado), `exec2` dentro de una zona. Kernel: 331 992 bytes, 649
sectores (544 antes; unos 29 KB son las dos imágenes de usuario nuevas, el resto TCP y sus pruebas), `.bss`
termina en `0x47726C` (tope de `stage2_big_test`: `0x480000`).

RD-02: TCP mínimo (`tcp.lap`). **Protocolo:** handshake de 3 vías activo y
pasivo, ISN aleatorio (xorshift mezclado con el PIT, el CMOS y la MAC; no
criptográfico), ventana de recepción de 4096 anunciada en cada segmento,
ACK por segmento, solo en orden (lo demás se descarta con ACK), retransmisión
con timer desde el PIT (RTO 50 ticks duplicado hasta 400, go-back-N, 8
intentos), cierre FIN en ambos sentidos con TIME_WAIT de 200 ticks, y RST
para puertos sin socket y al cerrar con datos sin leer. Seis TCB con 4 KiB
de envío y 4 KiB de recepción. Sin congestión, RTT, SACK ni cola fuera de
orden. **Syscalls 17..22** `listen/accept/connect/send/recv/close` con plazo
en ticks (duermen como el `recv` de UDP), la misma validación de punteros
(`uptr_range_ok`, ahora compartida con UDP) y la misma negación por zona;
`zone net` agrega 12..22. **Programas:** `tcpeco` (eco en el 7001) y
`tcpcli` (conecta al host), sin globales (la página de código es de solo
lectura). **Pruebas** (`tests/qemu_tcp_test.sh`, dentro de `make qemu-test`;
`make qemu-tcp-test` solo ella): `tcp test` sin dispositivo; eco de 64 KiB
aleatorios con socat por `hostfwd` (`cmp` idéntico y suma de bytes igual en
host e invitado); segunda conexión que cierra primero el invitado; ISN
distintos en el pcap; el kernel conecta a un socat del host por `guestfwd`
con el enlace cortado (`set_link`) para forzar retransmisiones; `connect` a
un puerto cerrado da `-111`; RST a puerto cerrado visto en el pcap; zona sin
red negada y con `zone net` el eco; al final 0 TCB ocupados y las mismas
páginas liberadas por proceso. **Tamaño:** `scripts/mkaxe.sh` ahora escribe
las imágenes de usuario de a 4 bytes en vez de un byte por asignación
(el compilador generaba ≈ 20 bytes de kernel por byte de imagen): el kernel baja de
351 250 a 278 189 bytes aun con TCP, y `stage2_big_test` sigue verde. No hizo
falta subir las ranuras de proceso (siguen siendo dos). Detalle y límites
en `docs/red.md`.

RD-01 (parte 2): UDP completo. **recv bloqueante:** `recv(fd, buf, max,
src, plazo)` duerme al proceso (estado 4) hasta que llega un datagrama a
su socket (`udp_rx` lo pasa a listo) o vence el plazo (`udp_tick` en el
PIT, `-110`). Para dormir se reescribe el marco de retorno y la
instrucción `syscall` se ejecuta de nuevo al despertar; si no hay otro
proceso listo se duerme dentro de la syscall con `sti; hlt`. `yield`
conserva `rbp`. **Varios sockets y procesos:** tabla de 8 sockets con cola
de hasta 64 sobre un pool de 96 slots, hasta 4 fd por proceso (`bind` devuelve el fd; las syscalls 13..15
toman el fd primero; `sys_user` pasa a 5 argumentos), y `exec2 a b` corre
dos programas a la vez. **ICMP port-unreachable** para puertos sin socket
(tope de 20 por 100 ticks). **Anillo de recepción** de 8 a 32 descriptores
y drenaje completo por interrupción; contadores `rxo` y `mpc` en `net
stat`, y `net hold N` para llenarlo a propósito. Programas nuevos
`udpdos` y `udpwait`; `udpeco` pasa a la ABI nueva. **Pruebas** (en
`tests/qemu_udp_test.sh`): dos procesos con tres sockets haciendo eco a la
vez, plazo de 50 ticks, despertar por llegada, ráfaga de 64 en orden con
conteo exacto, port-unreachable visto en el pcap, y anillo lleno con
`nosock + mpc == 40`. **Hallazgo:** con el anillo lleno QEMU pierde
tramas (8 de 40 en la corrida de esta parte): se cuentan en `mpc`, no se
evitan; la ráfaga de 64 con interrupciones armadas no perdió ninguna.
Quedan fuera: `select`, espera infinita, más de dos procesos, `exec2` en
una zona.

RD-01 (parte 1): red por interrupciones y UDP. **(1) IRQ.** El e1000 deja
de sondearse: la línea PCI (`0x3C`; fue la IRQ 11 en QEMU 11.1.3) se abre
en el PIC, `IMS = 0xD4`, y `irq_net` (`net.lap`) lee `ICR`, vacía el anillo
y manda EOI; ARP e ICMP siguen igual pero atendidos ahí. `net_tx` gira
sobre DD en vez de `hlt` (dentro de la interrupción IF está en 0).
`net` imprime `net irq ok` solo si el ARP reply y el echo reply los
atendió la interrupción (`isr >= 2`, `poll == 0`). Hallazgo de la prueba:
el BAR (`0x10000000`) no está en el PML4 privado de un proceso, así que
tocar el chip desde la interrupción o una syscall daba `#PF`
(`cr2=0x100000c0`); `net_cr3_in` / `net_cr3_out` usan CR3 `0x1000` mientras
se toca el chip. Comandos nuevos: `net up`, `net down`, `net stat`. **(2)
UDP** (`udp.lap`): tabla de 4 puertos, cola de 4 datagramas de 512 bytes
por puerto, checksum con pseudo-cabecera (0 aceptado como «sin checksum»),
y syscalls 12 `bind`, 13 `send`, 14 `recv`, 15 `close`, 16 `ticks`. Los
punteros de usuario se validan enteros contra las páginas del proceso
antes de tocarlos; kernel, MMIO, código (para escribir) y fuera de rango
dan -14. Las syscalls no están en la máscara de una zona nueva (-1 y
`niega`); `zone net nombre` las agrega. `src/user/udpeco.lap` es el eco de
anillo 3 (`udp plant`). **Pruebas:** `tests/qemu_udp_test.sh` (parte de
`make qemu-test`; `make qemu-udp-test` solo ella): hostfwd UDP y socat
mandan un datagrama y leen el mismo de vuelta; punteros malos reales dan
-14; zona sin red recibe `udp denied`; zona con `zone net` hace el eco;
el puerto se libera al morir el proceso; `udp test` cubre el checksum a
mano (`0x5C2D`), descartes, cola llena y punteros del kernel sin
dispositivo. **Sin probar:** hardware real (solo QEMU, e1000 82540EM),
IRQ por IOAPIC (el kernel usa el PIC), línea compartida, ráfagas que
llenen el anillo de 8, dos procesos con socket a la vez, y MAC de destino
distinta de la puerta.

SG-02: robustez del kernel antes de la red. **(1) Excepciones de anillo 3.**
Todo vector de CPU salvo `#PF` pasa por `user_exc` (`idt.lap`): de anillo 3
(`CS & 3 == 3`) mata solo al proceso por `user_kill`, igual que `#GP` y
`#PF` (`user killed pid= vec= err= addr=`, página y cupo de zona devueltos,
sigue el otro proceso o el shell); sin planificador (`user`, rama no probada) informa y
vuelve al shell; de anillo 0 sigue siendo `cpu_fault` (diagnóstico y
`hlt`). NMI, `#DF` y `#MC` siguen fatales. Antes cualquier `#UD`, `#DE`,
`#SS`... de un programa de usuario detenía toda la máquina (por lectura del código de entonces, no se midió). Pruebas
nuevas en `tests/qemu_shell_test.sh` con `ataque.lap` (modos `u`, `z`,
`i`): `ud2` da `vec=6 err=0`, `INT64_MIN / -1` da `vec=0 err=0` (Copihue
define `x / 0` como 0, así que no hay otro `#DE` posible: anotado en
`docs/PEDIDOS_COPIHUE.md`) e `int 3` da `#GP err=0x1a` (la puerta 3 es
DPL 0, no llega a `#BP`). La prueba exige vector y error exactos y que los
bytes de `build/ataque.bin` en el RIP sean la instrucción esperada; cada
caso termina con `zone exec ok`, sin `zone leak`, la zona con `pag=0`
`proc=0/` y el shell vivo. El `#UD` de anillo 0 (`ud2` del shell) sigue
imprimiendo su línea y deteniendo. **Sin probar:** `#DB`, `#BP` (opcode
CC), `#OF`, `#BR`, `#NM`, `#TS`, `#NP`, `#SS`, `#MF`, `#AC`, `#XM`,
`#VE`, `#CP`, `#HV`, `#VC`, `#SX` y los reservados: usan el mismo
`user_exc`, pero no hay forma probada de provocarlos (QEMU 11.1.3 da `#GP`
en vez de `#SS` con RSP no canónico). Detalle en `docs/zonas.md`.
**(2) Espacio del kernel.** `kernel.bin` ya no se carga bajo 1 MB: la
etapa 2 lee de a 128 sectores a un rebote en `0x10000` y copia cada trozo
con INT 15h AH=87h a `0x400000`; el kernel se enlaza en
`0xFFFFFFFF80400000` (PD alta [2], una página de 2 MiB que el PMM reserva
entera). El tope pasa de 512 a 2048 sectores (1 MiB de archivo, otro MiB
para la `.bss`): `kernel.bin` 239796 bytes = 469 sectores, 1579 libres en
la región LBA 9..2056 y 823 libres después (2057..2879). El disco de
datos y el FS no cambian. `nx_split` arma la tabla de la imagen (`.text`
sin escritura, resto NX), `hh_retire` retira el rebote `0x10000` en vez
de la imagen y `pmm free` baja de 32480 a 31968. Nueva
`tests/stage2_big_test.sh` (la corre `make qemu-test`): imagen con 2048
sectores, el kernel arranca y 512 KiB de la parte alta del archivo,
volcados con `pmemsave`, coinciden byte a byte. Layout en
`docs/higher-half.md`. Probado solo en QEMU 11.1.3 (TCG, macOS); INT 15h
AH=87h en otro BIOS u hardware no. Copihue: `x / 0` = 0, `cx` no asignable
en `bits 16` y recorte a 8 bits de `0 - *u8` anotados en
`docs/PEDIDOS_COPIHUE.md`; no hay `asm()` nuevo ni Python.

SG-01 (parte 2): (d) anillo 3 contra la memoria del kernel y las páginas
NX, y (e) punteros del kernel como argumento de syscalls. **Bug real
encontrado y arreglado:** un proceso de `exec` o de zona que fallaba en
anillo 3 (`#PF`) no tenía punto de recuperación (`proc_rec0/1`, que solo
arma la prueba `sched`), así que `note_user_fault` imprimía
`pf-cross norec` y paraba TODA la máquina con `hlt`: cualquier programa de
una zona podía colgar el kernel leyendo `0xFFFFFFFF80010000`. Un `#GP`
de anillo 3 (dirección no canónica) también era fatal para el kernel
(`cpu_fault` hace `hlt`). Ahora ambos matan solo al proceso: `user_kill`
(`sched.lap`) imprime `user killed pid= vec= err= addr=`, lo da de baja como
`exit` (devuelve páginas y cupo de zona) y vuelve al shell o al otro
proceso. Los `#PF` con registro de recuperación (prueba `sched`) siguen
igual. Prueba nueva: `src/user/ataque.lap` (un ataque por corrida, modo en
el archivo `zkq`; `zone atk` lo planta como `zatk`), 11 ataques en
`tests/qemu_shell_test.sh`. Detalle y resultados en
[docs/zonas.md](docs/zonas.md). No quedan syscalls con punteros de usuario;
lo que sí se probó para (e) está en ese documento. Quedan sin arreglar y
sin probar los demás vectores de excepción de anillo 3 (`#UD`, `#DE`,
…): por lectura del código siguen deteniendo el kernel. Corrido en QEMU
(qemu-system-x86_64 11.1.3, macOS, `socat` de /opt/homebrew/bin): sin el
arreglo, la prueba se cuelga en `pf-cross norec` en el primer ataque; con
el arreglo, `make qemu-test` termina en 0 (también las pruebas de la parte
1, que sí pasaron). La prueba detectó además que Copihue trunca a 32 bits
un operando absoluto de 64 bits (el ataque 3 leía `0x1000`): anotado en
`docs/PEDIDOS_COPIHUE.md`. `kernel.bin` 235686 bytes (461 sectores).

SG-01 (parte 1): pruebas adversarias de zonas, solo (a) archivos fuera
del prefijo, (b) cuota de memoria y (c) syscalls fuera de la máscara.
(d) anillo 3 contra memoria del kernel y NX, y (e) punteros de usuario,
quedan para otra vuelta. `src/user/zona.lap` intenta 14 nombres fuera
del prefijo (lectura y escritura), 4 largos inválidos, 63 números de
syscall fuera de la máscara (58 del 0 al 63, más 64, 1000, 2^32+1, 2^32+2
y -1), 5 escapes de zona y 40 pedidos de página después del tope.
`tests/qemu_shell_test.sh` revisa lo que el programa no puede falsear:
`niega=64`, `fuga=5`, `max=12`, el directorio del disco (solo aparece
`zan`), la zona `b` intacta, siete `zone create` inválidos que fallan
con `zone fail 11` y una zona de 1 página que da `zone fail 6` sin
filtrar memoria. Cambio en el kernel: `zone ls` agrega `max=`, la
marca de agua de páginas por zona (`zone_hi` en `zone.lap`); no cambia
ninguna decisión del kernel. Bugs de aislamiento encontrados: ninguno
por lectura del código; las pruebas de esta parte no se habían corrido
en QEMU al escribir esta entrada (la parte 2 las corrió: pasan).
`make` compila: `kernel.bin` 198741 bytes (389 sectores, `.bss` 22252),
`zona.axe` 3642 bytes (tope 4080 de código). `tests/qemu_shell_test.sh`
suelta también `hola` antes de plantar `ztest`, para dejar un cupo libre
en el directorio y que un archivo filtrado se vea. `src/bootloader/stage2.lap`:
el comentario sobre `ebx` ahora dice que v0.34.1 lo preserva (y `edx`);
se verificó desensamblando `build/stage2.bin` con `ndisasm -b 16`. No se
leyó la salida de `copihue -S`.

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
