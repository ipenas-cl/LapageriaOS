# Red mínima

El dispositivo es el e1000 de QEMU, el 82540EM (`8086:100e`; también
se acepta `8086:100f`). No es virtio-net.

virtio-net legacy pide la cola available/used, el header de 10 bytes
y la negociación de features. El e1000 se programa con registros MMIO
y descriptores de 16 bytes que están en el manual de Intel. Para esta
etapa eso alcanza, y se puede revisar en un volcado. Desde RD-01 la
recepción va por interrupción (ver «Interrupciones»). En el arranque la
máscara del PIC sigue en `0xFC` (solo el PIT y el teclado); solo `net`
abre la línea del e1000.

## PCI

Mecanismo 1: `outl` a `0xCF8`, `inl` de `0xCFC`. Se recorre el bus 0.
El BAR0 es memoria de 32 bits y 128 KiB. Se apaga el decode, se mide
el BAR, y se reescribe en `0x10000000`.

Esa dirección está sobre los 128 MiB de RAM y dentro del primer GiB.
El PDPT del arranque solo tiene presente la entrada 0, y `map_page` no
crea un PDPT nuevo. `0x10000000` sí entra en ese GiB: una tabla de
páginas cubre los 32 marcos. Los bits de la PTE son presente, escritura,
PWT y PCD (`0x1B`), sin bit de usuario.

Después se prenden memoria y bus master en el comando PCI (el byte de
estado se escribe en 0 para no borrarlo). INTx queda habilitado (bit 10
en 0); el chip no emite nada mientras IMS esté en 0.

## Anillos

32 descriptores de recepción (RD-01b; eran 8) y 8 de transmisión, más
un buffer de envío. Los de recepción son 32 buffers de 2048 bytes, dos
por página, de 16 páginas. Cada página sale de `alloc_low_page`. Se
rechaza la página si no está alineada a 4 KiB, si pasa de 4 GiB, o si
no cae en la identidad de 2 MiB (ahí la CPU puede escribirla). El alto
del descriptor de 64 bits queda en 0. `RDLEN` es 512 y `TDLEN` 128,
ambos múltiplos de 128. `RDT` parte en 31: el chip no deja que la
cabeza alcance a la cola, así que caben 31 tramas sin atender.
`net_rx_drain` recorre hasta 64 descriptores por llamada (dos vueltas),
para no dejar listos sin que nadie vuelva a levantar la interrupción.

El descriptor es un `packed struct` de 16 bytes (`sizeof(RxD)` y
`sizeof(TxD)`). La trama también: `EthHdr` mide 14, `ArpPkt` 42 e
`IpPkt` 34. Los campos de más de un byte van en dos `u8`, en orden
de red: un `u16` nativo los guardaría al revés. `net_layout` exige
esos `sizeof` y `offsetof`. El buffer DMA sigue siendo el mismo.

## Protocolos

IP fija `10.0.2.15`. La puerta de la red de usuario es `10.0.2.2`.

- ARP who-has para esa IP se contesta. El comando también pregunta por
  la puerta.
- IPv4 lleva checksum de cabecera. Se tira el fragmento y el checksum
  malo.
- ICMP echo request a nuestra IP se contesta. El comando manda un echo
  a la puerta (id `0x4242`, seq 1, datos `ATOM`) y espera el reply.

UDP está en «UDP» y TCP en «TCP». Nada de esto escucha en el arranque:
`net` prende el chip y al salir apaga `RCTL` y `TCTL`; `net up` lo deja
prendido y `net down` lo apaga.

El largo que manda el paquete no es el tope. El tope es el largo del
descriptor (o el de la prueba), y no puede pasar de 2048. Si el total
IPv4 no cabe ahí, o es menor que la cabecera, la trama se descarta y
se sigue.

QEMU, al escribir `RCTL`, deja de recibir durante un segundo de reloj
virtual y encola lo que llega. `net` espera 120 ticks (el PIT va a
100 Hz) antes de mandar el ARP. Las esperas usan `hlt` y tienen tope:
si no hay respuesta, se imprime el fallo y vuelve el prompt.

## Interrupciones

La línea sale del registro PCI `0x3C` que dejó el firmware (en QEMU 11
con SeaBIOS fue la IRQ 11). Se acepta 1..15 salvo 2. `net_irq_setup`:

- pone la puerta `32 + línea` en `irq_net` (la IDT ya tenía 48 puertas);
- abre esa línea en el PIC (para IRQ 8..15 también la cascada, IRQ 2);
- programa `ITR = 0`, limpia `ICR` y escribe `IMS = 0xD4`
  (RXT0, RXO, RXDMT0, LSC).

`irq_net` lee `ICR` (eso baja la línea), vacía el anillo con
`net_rx_drain` y manda EOI al final. ARP, ICMP y UDP se procesan ahí
mismo. Para contestar (ARP reply, echo reply) usa `net_tx`, que ahora
**gira sobre DD en vez de dormir con `hlt`**: dentro de la interrupción
y en una syscall IF está en 0 y un `hlt` no vuelve. Con IRQ armada los
`net_wait_flag` del shell no sondean: duermen en `hlt` y despiertan por
la interrupción. Si la línea no sirve, `net` lo dice (`net irq fail
line`) y vuelve al sondeo con IF apagado (`net_poll`).

Dos cosas que importan:

- **El BAR no está en el PML4 de un proceso.** `0x10000000` está mapeado
  solo en las tablas base (CR3 `0x1000`); un proceso de anillo 3 tiene
  PML4 privado. La interrupción o la syscall `send` con ese CR3 daban
  `#PF` (`cr2=0x100000c0`, el registro `ICR`; lo encontró la prueba).
  `net_cr3_in` / `net_cr3_out` cambian a `0x1000` mientras se toca el
  chip y restauran. La mitad alta, la identidad baja con los buffers
  DMA y las pilas existen en ambos.
- **Un solo buffer de envío.** Lo comparten la interrupción y el hilo.
  El hilo del shell manda con IF apagado (`net_*_locked`); las syscalls
  ya corren con IF en 0 (`SFMASK = 0x200`).

Contadores (`net stat`): `irqs` (entradas con causa en `ICR`), `isr`
(tramas atendidas por la interrupción) y `poll` (por sondeo). `net` imprime
`net irq ok` solo si `isr >= 2`, `poll == 0` e `irqs >= 1`, es decir, si
el ARP reply y el echo reply los atendió la interrupción.

## UDP

Código en `udp.lap`. Tabla de 8 sockets; cada uno con cola de hasta 64
datagramas de hasta 512 bytes, sacados de un pool compartido de 96 slots
(48 KiB; si se agota cuenta como `full`; con 8 colas de 64 la `.bss`
pasaba de `0x480000` y rompía `stage2_big_test`). No hay fragmentos: se
tiran. Un proceso
tiene hasta 4 sockets (fd 0..3, en el orden en que los abre) y se cierran
solos cuando el proceso muere (`release_proc`). IP fija `10.0.2.15`.
Hay dos ranuras de proceso (`exec2 a b` los corre a la vez).

Recepción (`udp_rx`, desde `net_ip` con la cabecera IP validada): el
largo UDP tiene que ser igual al total IP menos la cabecera; el checksum,
si no es 0, se verifica con la pseudo-cabecera (0 significa «sin
checksum», que IPv4 permite y slirp usa). Malformado: se descarta
(`bad`). Sin socket en ese puerto: `nosock` y un ICMP port-unreachable.
Cola llena: `full` (el datagrama se descarta y se cuenta).

ICMP port-unreachable (`udp_icmp_build`, `udp_unreach`): tipo 3, código
3, desde `10.0.2.15` a quien mandó, a su MAC de origen, con la cabecera IP
original y los primeros 8 bytes del UDP; checksums IP e ICMP calculados.
No se contesta a un origen `0.0.0.0` ni `255.255.255.255`, ni con el chip
apagado. Tope de 20 por ventana de 100 ticks; lo que pasa del tope se
cuenta en `unrdrop`. Solo se contesta después de validar largo y checksum
del UDP: un datagrama malo no genera ICMP.

Envío (`udp_build`): Ethernet + IPv4 (DF, TTL 64, id creciente) + UDP con
checksum calculado; un resultado 0 se manda como `0xFFFF`. El destino
Ethernet es siempre la MAC de la puerta, aprendida por el ARP de
`net up`; no hay otra tabla ARP. Sin eso, `-113`; sin `net up`, `-100`.

Syscalls (en la máscara de zona solo si se agregan; ver `zonas.md`):

La ABI cambió en RD-01b: `syscall fn sys_user` recibe ahora 5 argumentos
(`rdi rsi rdx r10 r8`) y el fd va primero.

| Nº | Llamada | Resultado |
|---|---|---|
| 12 | `bind(puerto)` | el fd (0..3); `-22` puerto fuera de 1..65535; `-98` en uso; `-24` sin fd o sin socket libre; `-100` red apagada |
| 13 | `send(fd, buf, largo, dst)` | 0; `-9` fd malo; `-14` puntero; `-22` largo o puerto; `-100`, `-113`, `-5` |
| 14 | `recv(fd, buf, max, src, plazo)` | largo (recortado a `max`); `-11` nada y plazo 0; `-110` venció el plazo; `-9`; `-14`; `-22` |
| 15 | `close(fd)` | 0; `-9` |
| 16 | `ticks()` | ticks del PIT, para plazos |

`dst` y `src` son un i64: `(ip << 16) | puerto`, con la IP como entero
`0x0A000202` para `10.0.2.2`. `src` puede ser 0. `plazo` va en ticks
(100 por segundo): 0 no espera; 1..6000 duerme hasta ese plazo; fuera de
ese rango, `-22` (no hay espera infinita: el shell queda parado mientras
corre un proceso).

recv bloqueante: si no hay datagrama, el proceso queda en estado 4 con su
plazo absoluto y el planificador corre al otro. Lo pasa a listo (estado
1) `udp_rx` cuando llega un datagrama **a ese socket** (`woke`), o
`udp_tick` desde el PIT cuando vence el plazo (`wtmo`); el PIT lo reparte
en el siguiente tick. Para dormir, `udp_park` reescribe el marco de
retorno: `rip` apunta a la instrucción `syscall` (RIP - 2), `rax = 14`,
los argumentos vuelven a `rdi rsi rdx r10 r8` y `rbp` es el del usuario.
Al despertar la syscall se ejecuta de nuevo con los mismos argumentos y
decide con lo que haya: entrega, vuelve a dormir o devuelve `-110`. Si no
hay otro proceso listo, duerme dentro de la propia syscall (`sti; hlt;
cli`) hasta la próxima interrupción. Si un proceso termina mientras el
otro duerme, `exit_current` lo cuenta como vivo (`other_alive`) y le da la
CPU. `yield` ahora también conserva `rbp`.

Punteros de usuario (`udp_uptr_ok`): el rango entero tiene que caer en
las páginas del propio proceso: desde `0x400000` para leer y desde
`0x401000` para escribir (la página de código es de solo lectura) hasta
`0x402000` o hasta donde llegó con la syscall 8, y nunca más de
`0x500000`. Una dirección del kernel, negativa, del MMIO, baja o que
cruce el final da `-14` y el kernel no la toca. Se valida todo antes de
copiar o transmitir.

Zonas: las syscalls 12..16 no están en la máscara de una zona nueva.
Reciben `-1` y suman `niega`. `zone net nombre` (solo desde la zona 0)
las agrega.

Comandos: `net up`, `net down`, `net stat`, `net hold N`, `udp test`,
`udp plant` (escribe `udpeco`, `udpdos` y `udpwait`, de `src/user/`),
`udp stat`, `exec2 a b`.

`udp stat` imprime `rx bad nosock full tx unr unrdrop blk woke wtmo tmo`:
`blk` es cuántas llamadas de recv se durmieron, `woke` las que despertó
una llegada, `wtmo` las que despertó el plazo en el PIT y `tmo` las que
devolvieron `-110`. `net stat` agrega `net ring 32 rxo R mpc M`: `rxo` son
las interrupciones de desborde del chip y `mpc` su contador de tramas
perdidas por falta de descriptor (se acumula; el registro se borra al
leerlo).

`net hold N` apaga las interrupciones del chip (IMC) N ticks para que una
ráfaga llene el anillo sin que nadie lo vacíe, y después cuenta los
descriptores listos (`ring`), las tramas sacadas (`drained`) y `mpc`.

Programas de anillo 3 (`src/user/`), sin cadenas: cada mensaje va por la
syscall 1, de a 8 bytes (`say8`):

- `udpeco`: puerto 7777, punteros malos (`udp ptr denied`), recv de hasta
  5 s y eco (`udp echo ok`).
- `udpdos`: dos sockets, 7781 (fd 0) y 7782 (fd 1), eco por cada uno
  (`udp dos echo ok`).
- `udpwait`: puertos 7790 y 7791. Plazo de 50 ticks (`udp timeout ok`),
  duerme hasta que llega «despierta» (`udp wake ok`) y cuenta una ráfaga
  de 64 datagramas en orden mientras duerme en el otro socket
  (`udp burst n=64`, `udp burst ok`).

Límites conocidos: sin fragmentación, sin multicast, sin más vecino que la
puerta, IP fija, dos ranuras de proceso (8 sockets en total), sin `select`
(un recv espera un solo socket) y sin espera infinita.

## TCP

Código en `tcp.lap` (RD-02; endurecido en RD-03, ver «TCP endurecido»). Ocho
bloques de control (TCB; eran seis) con 4 KiB de
envío y 4 KiB de recepción cada uno (64 KiB de `.bss`), compartidos por
todos los procesos y por los huérfanos que quedan cerrando. Los estados son
los de RFC 793: 1 LISTEN, 2 SYN_SENT, 3 SYN_RCVD, 4 ESTABLISHED, 5..9
FIN_WAIT_1, FIN_WAIT_2, CLOSE_WAIT, CLOSING, LAST_ACK, 10 TIME_WAIT, y un 11
propio: conexión muerta por error cuyo fd sigue existiendo para devolver el
error (`-104` reset, `-111` rechazada, `-110` agotó los reintentos).

**Qué hace.**

- Handshake de 3 vías activo (`connect`) y pasivo (`listen` + `accept`,
  hasta 3 hijos pendientes por escuchador; con la cola llena el SYN se
  descarta y el cliente reintenta; un SYN sin TCB libre recibe RST|ACK, ver
  «TCP endurecido»).
- ISN aleatorio: xorshift64 sembrado con la MAC que se vuelve a mezclar en
  cada llamada con `rdtsc()` (Copihue v0.42.5), los ticks y el número de
  conexión. **No es criptográfico**: en una máquina virtual la entropía es
  poca, y `qemu64` no tiene `rdrand`.
- Aritmética de secuencia de 32 bits con vuelta (`tcp_sub`).
- Ventana: se anuncia `4096 - bytes sin leer` en cada segmento; el envío
  respeta la ventana del par. Si el par la cierra con datos pendientes, un
  timer de sondeo manda 1 byte con el mismo backoff.
- ACK inmediato por cada segmento con datos o FIN. Lo repetido se descarta
  y se contesta con un ACK (contador `dup`); lo adelantado va a la cola
  fuera de orden (RD-03).
- Retransmisión con timer: el PIT llama a `tcp_tick` en cada tick (con o sin
  procesos). RTO inicial 50 ticks, se duplica hasta 400; al vencer se
  vuelve a mandar desde lo no confirmado (go-back-N); 8 intentos (6 para
  SYN y SYN|ACK) y se abandona con RST y `-110` (`giveup`). Desde RD-03 el RTO
  sale del RTT medido (ver «TCP endurecido»).
- Cierre FIN en ambos sentidos. `close` manda el FIN después de los datos
  pendientes y el socket queda huérfano hasta que termina: el que cierra
  primero pasa por FIN_WAIT_1/2 y TIME_WAIT (200 ticks; el estándar pide 2
  MSL, aquí se acortó), el otro por CLOSE_WAIT y LAST_ACK. Cerrar con datos
  sin leer manda RST y libera. Datos que llegan a un huérfano también
  reciben RST. FIN_WAIT_2 de un huérfano vence a los 1000 ticks.
- RST: un segmento a un puerto sin socket recibe RST (`seq = ack` si traía
  ACK; si no, `seq 0` y `ack = seq + largo` con ACK), salvo que sea un RST;
  tope de 20 por ventana de 100 ticks (`rstdrop`). Un RST en SYN_SENT da
  `-111`; en otro estado sincronizado, `-104` (solo si su número de
  secuencia es exactamente el esperado).
- Checksum con pseudo-cabecera verificado siempre (malo: `bad`, se
  descarta). Opción MSS en los SYN (anuncia 1460; se respeta la del par,
  tope 1460).

**Qué no hace.** Ventana escalada, SACK, reinicio de la ventana de
congestión tras inactividad, datos urgentes, keepalive, opciones de
timestamps, `shutdown` a medias, `SO_REUSEADDR`. Un solo vecino (la puerta)
e IP fija, como en UDP. Sin espera infinita (plazo máximo 6000 ticks). (RD-02
tampoco tenía congestión, RTT, retransmisión rápida ni cola fuera de orden:
RD-03 los agregó.)

Syscalls. Los fd de TCP son una tabla aparte de la de UDP (4 por proceso en
cada una). `dst` es `(ip << 16) | puerto`, como en UDP. Todas pasan por
`zone_gate`: una zona sin red recibe `-1` y suma `niega`; `zone net`
agrega 12..22. Los punteros se validan antes de tocar nada con el mismo
rango que UDP (`uptr_range_ok`, ahora compartido), pero hasta 4096 bytes.

| Nº | Llamada | Resultado |
|---|---|---|
| 17 | `listen(puerto)` | el fd; `-22` puerto fuera de 1..65535; `-98` en uso; `-24` sin fd o TCB; `-100` red apagada |
| 18 | `accept(fd, plazo)` | fd nuevo; `-9`; `-22` no es escuchador; `-11` nada y plazo 0; `-110`; `-24` |
| 19 | `connect(dst, plazo)` | el fd; plazo 1..6000 (`-22` si no); `-113` sin ARP de la puerta; `-111` rechazada; `-104`; `-110` venció (el intento se aborta); `-24` |
| 20 | `send(fd, buf, largo, plazo)` | bytes copiados al buffer de envío (>= 1; puede ser menos que `largo`); 0 si `largo` es 0; `-14` puntero; `-22` largo; `-32` el socket ya no envía; `-104`/`-111` error del socket; `-11` buffer lleno y plazo 0; `-110` |
| 21 | `recv(fd, buf, max, plazo)` | bytes (1..max); **0 = el par cerró y no queda nada**; `-14`; `-22`; error del socket; `-11`; `-110` |
| 22 | `close(fd)` | 0; `-9` |

`send` y `recv` duermen igual que el `recv` de UDP (estado 4, plazo en
`udp_wdl`, marco reescrito para repetir la `syscall` al despertar). Cualquier
evento del TCB (segmento aceptado, cambio de estado) pasa a listo a su
dueño (a la del escuchador, si es un hijo sin `accept`); un despertar de más
es inofensivo porque la llamada mira de nuevo. `connect` además guarda su
TCB pendiente por proceso, para que la repetición no abra otra conexión. Al
morir el proceso (`release_proc`) se cierran sus fd como un `close`.

Comandos: `tcp test`, `tcp plant` (escribe `tcpeco`, `tcpcli`, `tcpmulti` y
`tcphog`), `tcp fault` (RD-03), `tcp stat`:
`rx bad tx retx rstout rstin rstdrop est closed dup blk tmo giveup used lst tw
iss ooo oodrop fast rtos full bklog recyc rtts rtt rto cwmax fdrop peak fswap`.
`used` es el número de TCB ocupados (la prueba de fugas exige 0 al
final), `tw` los que están en TIME_WAIT e `iss` el último ISN. Los
contadores de RD-03 (todos al final de la línea) se explican en «TCP
endurecido».

Programas de anillo 3 (`src/user/`):

- `tcpeco`: escucha en 7001. Prueba 9 punteros malos contra 20 y 21 (`tcp ptr
  denied`), `tcp listen`. Conexión 1: devuelve todo en trozos de 1024 hasta
  el EOF del par y cuenta bytes y suma (`tcp eof n=… sum=…`, `tcp echo1 ok`).
  Conexión 2: un mensaje de vuelta y cierra primero (`tcp echo2 ok`). Sale
  con `tcp srv done`.
- `tcpcli`: conecta a 10.0.2.100:7100 (guestfwd). `tcp conn ok`, `tcp
  pause` (duerme 150 ticks en recv, `-110`), envía 3000 bytes (`tcp sent
  n=3000 sum=…`), lee «respuesta» y el EOF (`tcp got ok`), `tcp cli ok`. Luego
  `connect` a 10.0.2.2:1, donde nadie escucha: `-111` (`tcp refused ok`).

Los programas no pueden tener globales: la página de código es de solo
lectura y un `let` global cae ahí (el primer intento de `tcpeco` murió con
`#PF` en 0x400af8). Los totales van a la página de la pila.

**Tamaño.** `scripts/mkaxe.sh` generaba una asignación por byte
(`p[i] = n;`) y el compilador emite unas 7 líneas de ensamblador (≈ 20 bytes de kernel) por
cada byte de la imagen. Con las dos imágenes nuevas el kernel pasaba de 495 KB y
`stage2_big_test` (que exige `kernel.bin + 64 KiB < 0x80000`) fallaba. Ahora
las imágenes se escriben de a 4 bytes (`q[i] = n` con `q: *u32`): el
contenido de los AXE no cambia y el kernel mide menos que antes de TCP
(278 189 bytes, 544 sectores, contra 351 250 y 687). La `.bss` sube de 83 764 a 134 580
bytes (fin de imagen en `0x464C61`, tope `0x600000`).

## TCP endurecido (RD-03)

**Bloques y conexiones simultáneas.** Ocho TCB. Los fd siguen siendo 4 por
proceso y hay dos ranuras de proceso (`exec2`). Cuatro conexiones a la vez
más dos escuchadores caben (6 de 8). El tamaño es un literal repetido en
`tcp.lap` (ver `PEDIDOS_COPIHUE.md`); subirlo cuesta 8 KiB de `.bss` por bloque, y la
`.bss` tiene que terminar bajo `0x480000` (`stage2_big_test`): hoy termina en
`0x47726C`, o sea unos 36 KiB de margen.

**Agotar los bloques.** `tcp_free_tcb` busca uno libre; si no hay, recicla el
TIME_WAIT huérfano más viejo (`recyc`); si tampoco, falla. Entonces:

- un SYN a un escuchador con cola libre recibe RST|ACK (`seq 0`,
  `ack = seq + 1`) y no se reserva nada (`full`);
- un SYN a un escuchador con la cola de 3 hijos llena se descarta sin RST y
  el cliente reintenta (`bklog`);
- `listen` y `connect` devuelven `-24` sin dejar fd ni TCB a medias.

Cerrar un escuchador manda RST a sus hijos SYN_RCVD y los libera; los fd de un
proceso muerto se cierran en `release_proc`. `peak` es el máximo de bloques
ocupados a la vez.

**Cola fuera de orden.** Un segmento adelantado (dentro de la ventana) se copia
al anillo de recepción en su posición final, `rxh + rxn + (seq - rnxt)`, y se
anota en una tabla de 4 bloques por conexión (inicio de secuencia y largo). Los
bloques que se tocan o son contiguos se funden. Cuando llega el hueco, los
bloques que quedan en el punto de lectura pasan a datos en orden sin volver a
copiarse (`tcp_oo_absorb`). Cada segmento adelantado provoca un ACK repetido
(el que cuenta el emisor para la retransmisión rápida). Fuera de la ventana, o
con la tabla llena, el segmento se descarta (`oodrop`). Un FIN adelantado se
ignora: el par lo reenvía cuando se llene el hueco. `ooo` cuenta los
segmentos encolados.

**RTT y RTO (RFC 6298).** Un segmento de datos nuevo por vez lleva
cronómetro (`rseq`, `rts`); el ACK que lo cubre da la muestra R (en ticks de
10 ms). Karn: un segmento retransmitido no se mide. También se mide el
SYN o SYN|ACK si no se retransmitió. Con `srtt` guardado por 8 y `4 * rttvar`:
la primera muestra da `SRTT = R`, `RTTVAR = R / 2`; después
`RTTVAR = 3/4 RTTVAR + 1/4 |SRTT - R|` y `SRTT = 7/8 SRTT + 1/8 R`;
`RTO = SRTT + max(G, 4 * RTTVAR)` con `G = 1` tick. Tres desviaciones de la
RFC, elegidas por el tamaño de los tiempos de esta red de prueba: RTO inicial
50 ticks (la RFC pide 1 s), mínimo 20 (pide 1 s) y máximo 400 (pide al menos
60 s). El timer se duplica en cada vencimiento (se conserva el comportamiento
de RD-02) y un ACK nuevo recalcula el RTO desde `SRTT`/`RTTVAR` (sin muestra
todavía, vuelve a 50). Si el SYN o SYN|ACK se retransmitió, el RTO es de 3 s
al empezar los datos (RFC 6298, 5.7). `rtts` cuenta las muestras, `rtt` y
`rto` son la última muestra y el último RTO calculado.

**Congestión (RFC 5681 y 6582).** Por conexión: `cwnd`, `ssthresh`. Se
envía lo que quepa en `min(ventana del par, cwnd)`.

- Ventana inicial: 2 segmentos (SMSS = MSS del par, tope 1460); `ssthresh`
  muy grande.
- Arranque lento (`cwnd < ssthresh`): cada ACK nuevo suma `min(bytes
  confirmados, SMSS)`.
- Evitación de congestión: cada ACK nuevo suma `SMSS * SMSS / cwnd`.
- Timeout: `ssthresh = max(en vuelo / 2, 2 * SMSS)`, `cwnd = 1 SMSS`, se
  vuelve a mandar desde lo no confirmado (go-back-N). `tc_nxt` retrocede pero
  `tc_max` guarda lo más alto enviado, y un ACK que lo pasa se acepta (el
  código de RD-02 habría tratado ese ACK como «de datos no enviados»; es
  lectura del código, no se reprodujo).
- Retransmisión rápida: al tercer ACK repetido (mismo ack, sin datos, SYN ni
  FIN, misma ventana, hay datos en vuelo) se reenvía el primer segmento sin
  confirmar, `ssthresh = max(en vuelo / 2, 2 * SMSS)` y `cwnd = ssthresh + 3 *
  SMSS`; cada ACK repetido más suma 1 SMSS. Un ACK parcial (RFC 6582) reenvía
  el siguiente hueco y desinfla la ventana; el ACK completo la deja en
  `ssthresh`. `fast` cuenta las entradas a la recuperación.
- Un sondeo de ventana cero no cuenta como congestión. `cwnd` se acota en
  1 MiB. Sin reinicio tras inactividad (RFC 5681, 4.1): no se hizo.

`rtos` cuenta los vencimientos del timer y `cwmax` la `cwnd` más alta vista.
`retx` cuenta todas las retransmisiones (timer, rápida y ACK parcial).

**Fallas inyectadas: `tcp fault`.** Para ejercitar lo anterior con tráfico
real de QEMU sin tocar la red, el propio TCP del invitado puede perder o
reordenar segmentos *con datos*, contados desde el momento del comando:

| Comando | Efecto |
|---|---|
| `tcp fault rxdrop K C` | pierde `C` segmentos seguidos al entrar, desde el K-ésimo |
| `tcp fault txdrop K C` | idem, antes de entregarlos al chip |
| `tcp fault swap K` | retiene el K-ésimo que llega y lo procesa después del siguiente (o a los 20 ticks si no llega otro) |
| `tcp fault off` | desarma todo y entrega lo retenido |

`fdrop` cuenta los perdidos y `fswap` los retenidos. **No es pérdida en la
red:** el segmento ya pasó por el chip, el checksum y el IP; se pierde dentro
del TCP. No usé un filtro de QEMU ni un socat para descartar: socat trabaja
sobre el flujo, no sobre segmentos, y los filtros de QEMU que conozco
(`filter-buffer`, `-dump`, `-mirror`, `-redirector`, `-rewriter`) no descartan
paquetes sueltos; un `filter-redirector` con un relevo en shell sí podría, y no
se intentó. El único corte «de red» de las pruebas sigue siendo `set_link`.

**Programas nuevos** (`src/user/`, `tcp plant` los escribe):

- `tcpmulti`: eco de varias conexiones a la vez con un solo hilo (recv sin
  plazo sobre cada fd, y un recv de 1 tick si la vuelta no hizo nada). Escucha
  en el 7001, o en el 7002 si ya está ocupado: `exec2 tcpmulti tcpmulti`
  levanta dos. Atiende 2 conexiones y termina; imprime `tcp multi listen
  <p>`, `tcp multi <p> n=<bytes> sum=<suma>` por conexión y `tcp multi done <p>`
  (3717 bytes de 4080).
- `tcphog`: abre escuchadores en el 7003, 7004 y 7006, no acepta nunca, y
  espera 400 ticks en el 7006. Sirve para llenar los 8 bloques con hijos
  pendientes. `tcp hog listen`, `tcp hog done -110`.

**Qué se probó y con qué, y qué no.**

- `tcp test` (sin dispositivo, con las interrupciones apagadas para que los
  ticks no se muevan solos): cola fuera de orden con bloques que se funden,
  solapados, duplicados, fuera de ventana, FIN adelantado, tabla llena y
  contenido leído byte a byte (`tcp test ooo ok`); RTT con valores exactos
  calculados a mano (R = 8, 8, 16: `SRTT` 64, 64, 72, `4 RTTVAR` 16, 12, 17,
  `RTO` 24, 20, 26), Karn y RTO de 3 s tras retransmitir el SYN|ACK (`rtt`);
  arranque lento, evitación (+486 con SMSS 1460 y `cwnd` 4380), timeout,
  ACK que pasa `tc_nxt` retrocedido, 3 ACK repetidos, inflado, ACK parcial y
  completo (`cc`); 8 bloques llenos, RST|ACK, `-24` en `listen` y `connect`,
  cola de 3 llena sin RST, liberación al cerrar, reciclaje de TIME_WAIT
  (`full`); `swap`, `rxdrop`, `txdrop` y la entrega retenida por tiempo
  (`fault`). Se verificó con una mutación (se quitó `tcp_oo_absorb`): la prueba
  falló en el chequeo 106.
- En QEMU con tráfico real: ver «RD-03» en «Prueba».
- La retransmisión rápida **solo está probada sin dispositivo**: en las
  corridas reales (`fast 0`) el invitado se recuperó siempre por timeout.
- Ningún corte de red de un solo segmento: la pérdida real es la del
  `tcp fault`. El reordenamiento también es inyectado.
- No se probó `exec2` dentro de una zona, ni más de dos procesos.

## Prueba

`make qemu-test` arranca con `-nic none -netdev user,id=n0 -device
e1000,netdev=n0`. Si el monitor no muestra esa red, el script falla
al tiro.

| Línea | Qué pasó |
|---|---|
| `net arp ok` | llegó el ARP reply de `10.0.2.2` |
| `net ping ok` | llegó el ICMP echo reply de la puerta |
| `net drop ok` | una trama con total IP de 200 y buffer de 48 se descartó |
| `net fail pci` | no apareció el 82540 |
| `net arp fail` | no hubo reply dentro del tope |
| `net ping fail` | el ARP anduvo y el echo no |
| `net drop fail` | el parser aceptó la trama mala |
| `net irq ok` | el ARP reply y el echo reply los atendió la interrupción, sin sondeo |
| `net irq fail ...` | `irqs isr poll` no cumplen; `net irq fail line` si la línea no sirve |

### RD-01: `tests/qemu_udp_test.sh`

`make qemu-test` lo corre después del shell, y `make qemu-udp-test` solo
a él. Arranca QEMU con `-netdev user,id=n0,hostfwd=udp:127.0.0.1:P-:7777`
(P al azar entre 20000 y 49999; si está ocupado, otro) y un disco de datos
nuevo. Habla con el invitado desde socat. `UDP_PCAP=ruta` guarda la captura
(`filter-dump`).

| Paso | Qué exige |
|---|---|
| `net` | `net arp ok`, `net ping ok`, `net irq ok`, `net drop ok` |
| `udp test` | `udp test ok`: vector a mano (checksum `0x5C2D`), checksum malo y largo UDP malo descartados, checksum 0 aceptado, puerto sin socket, cola llena, trama de envío con el mismo `0x5C2D`, punteros del kernel/MMIO/código/fuera de rango rechazados |
| `net up`, `exec udpeco` | `udp ptr denied` (8 intentos con punteros malos dan -14 en las syscalls reales), `udp listen`; socat manda `hola copihue` y lee de vuelta lo mismo; `udp echo ok` |
| `net stat` | `isr >= 2` y `poll == 0` |
| datagrama a otro puerto | `nosock` sube exactamente 1 |
| `zone exec n udpeco` | `udp denied`; `niega >= 1`; no llegó a las pruebas de punteros |
| `zone net m` y `zone exec m udpeco` | eco idéntico dentro de la zona |
| `exec udpeco` otra vez | el puerto 7777 se liberó al morir el proceso; eco |
| `exec2 udpeco udpdos` | tres datagramas juntos (7777, 7781, 7782); cada uno vuelve idéntico; `blk` sube >= 2 y `woke` >= 1 |
| `exec udpwait` | `udp timeout ok`; `udp wake ok` con «despierta» enviado al ver `udp sleep`; ráfaga de 64 en orden: `udp burst n=64`, `udp burst ok`; `udp stat`: `rx` +65, `full` +0, `bad` +0, `tmo` +3 o más; `net stat`: `mpc 0` |
| datagrama al 7999 (sin socket) | `nosock` +1, `unr` +1, y en el pcap un ICMP 3/3 de `10.0.2.15` a `10.0.2.2` con el puerto 7999 en el UDP original (bytes, y con `tcpdump -vv` si está: `udp port 7999 unreachable` sin checksum malo) |
| `net hold 150` | 40 datagramas al 7999 con el chip enmascarado: `ring >= 31`; `nosock + mpc == 40`; `unr + unrdrop == nosock` |
| `net down`, `echo vivo` | el shell sigue |

Qué probó cada cosa y qué no:

- La ráfaga de 64 sin `net hold` **no** llenó el anillo: la interrupción
  lo vacía al vuelo (`rxo 0`, `mpc 0`). Sirve para la cola de 64 por
  socket y el orden. El desborde del anillo solo se produjo con `net hold`.
- Con el anillo lleno, QEMU 11.1.3 **sí pierde tramas**: en la corrida de
  este informe, de 40 datagramas el invitado atendió 32 y `mpc` dio 8.
  No se evita; se contabiliza (`mpc`) y la prueba exige que
  `nosock + mpc` sea exacto. Con interrupciones armadas no se vio pérdida.
- El port-unreachable se ve en la captura (`filter-dump`), no en el socket
  del host: slirp no devuelve el ICMP del invitado al emisor. No se probó
  `ECONNREFUSED` en el host.
- Con `exec2` los dos procesos corren en la zona 0. No se probó `exec2`
  dentro de una zona.
- Nunca se probaron más de dos procesos (hay dos ranuras).

Con socat, `nosock` subió 2 por un solo `nadie` (con bash subió 1). Se
supone que socat manda además un datagrama vacío al ver el fin de su
entrada; no se verificó en la captura. Por eso el chequeo de `nosock` usa
`/dev/udp` de bash (un solo datagrama). La prueba de RD-01b también usa
`/dev/udp` para la ráfaga y el unreachable, y arranca QEMU con cinco
`hostfwd` (HPORT..HPORT+4 hacia 7777, 7781, 7782, 7790 y 7999) y un
`filter-dump` siempre prendido (`UDP_PCAP=ruta` lo conserva).

### RD-02: `tests/qemu_tcp_test.sh`

`make qemu-test` lo corre después de la prueba de UDP, y `make
qemu-tcp-test` solo a él. QEMU arranca con `hostfwd=tcp:127.0.0.1:P-:7001`
(eco), `hostfwd=tcp:127.0.0.1:P+1-:7999` (sin socket),
`guestfwd=tcp:10.0.2.100:7100-cmd:socat - TCP:127.0.0.1:P+100` (el
invitado conecta al host) y un `filter-dump` (`TCP_PCAP=ruta` lo conserva).
P sale de `$RANDOM`.

| Paso | Qué exige |
|---|---|
| `net`, `tcp test` | `net irq ok`; `tcp test ok`: sin dispositivo (trama inyectada por `net_frame`, salida en seco en `tcp_last`): vuelta de 32 bits en la secuencia; SYN, SYN\|ACK con MSS 1460 y checksum válido, ACK; checksum malo descartado (`bad`); datos, duplicado y adelantado (ACK sin cambio, `dup`); lectura y envío; retransmisión: a 40 ticks no, a 60 sí, el RTO pasa de 50 a 100 y vuelve a 50 con el ACK; FIN del par, `recv` 0, `close`, LAST_ACK; RST\|ACK y RST para SYN y ACK a un puerto cerrado, un RST no se contesta; connect activo, RST en SYN_SENT (`-111`) y en ESTABLISHED (`-104`); cierre activo FIN_WAIT_1 → 2 → TIME_WAIT → libre a los 200 ticks; `close` con datos sin leer manda RST; ventana: 100 segmentos de 200 bytes sin leer llenan 4096 y la ventana anunciada es 0; al final 0 TCB ocupados |
| `fs format`, `tcp plant`, `net up` | `tcp stat` con `used 0` |
| (a) `exec tcpeco` | `tcp ptr denied` (9 punteros malos dan -14); socat envía 64 KiB de `/dev/urandom` por `hostfwd` y lee de vuelta: `cmp` idéntico; el invitado cuenta `n=65536` y la misma suma de bytes que calcula el host (`od`+`awk`); el FIN de socat llega al servidor (recv 0) y el servidor cierra |
| (a) segunda conexión | `adios` vuelve idéntico y socat termina porque el invitado cerró primero; `tcp echo2 ok`, `tcp srv done`; `est` = 2 |
| ISN | en el pcap, los dos SYN\|ACK desde el 7001 (puerto `0x1B59`, offset 6, flags `0x12`) llevan números distintos y mayores que 65535 |
| (b) `exec tcpcli` | socat del host escucha en P+100; el invitado conecta (guestfwd), imprime `tcp pause`; la prueba hace `set_link n0 off` 2,4 s y `on`; el cliente manda 3000 bytes durante el corte; `retx` sube >= 1; el host recibe 3000 bytes con la misma suma que imprimió el invitado; recibe «respuesta» y el EOF; `connect` a 10.0.2.2:1 da -111 (`rstin` +1) |
| (c) RST | socat del host conecta a P+1 (invitado 7999, sin socket): `rstout` +1 y en el pcap un segmento desde el puerto 7999 con `seq 0`, offset 5 y flags `0x14`; con `tcpdump`, `Flags [R.]` y sin checksum malo |
| (d) zonas | `zone exec n tcpeco` (sin red): `tcp denied`, `niega >= 1`, no llega a las pruebas de punteros; `zone net m` y `zone exec m tcpeco`: dos ecos idénticos |
| (e) fugas | `tcp stat` llega a `used 0`, `lst 0`, `tw 0`, con `bad 0` y `giveup 0`; todos los procesos liberan las mismas páginas (`freed=7` desde EX-04: la pila AXE1 tiene página propia); `net down` deja 0 TCB y el shell sigue |

Qué probó cada cosa y qué no:

- El corte de enlace con `set_link n0 off` descarta los dos sentidos: el
  invitado perdió sus envíos y los retransmitió; el host (slirp) tiene su
  propio TCP y también retransmite. La prueba mide solo `retx` del invitado.
  No se probó pérdida de un solo segmento en medio de una ráfaga, ni
  reordenamiento, ni duplicados de la red: eso solo lo ejerce `tcp test`.
- El eco de 64 KiB con ventana de 4096 pasa por muchos ACK y ventanas
  (corrida de referencia, tras las dos conexiones: `rx 76 tx 164 retx 0 dup
  2`; en otra corrida `dup 0`; sin retransmisiones, y 0 a 2 segmentos repetidos o adelantados que
  el invitado descartó con ACK; no se investigó cuáles fueron). El
  descarte de segmentos adelantados con pérdida real solo está probado sin
  dispositivo.
- El RST del puerto cerrado sale por el chip y se ve en el pcap; el host no
  lo observa como `ECONNREFUSED` (slirp ya aceptó la conexión del host). El
  rechazo que sí llega al invitado es el de `tcpcli` hacia 10.0.2.2:1.
- (RD-02; `exec2`, conexiones simultáneas y agotamiento de bloques se
  probaron en RD-03, ver abajo.) Con `exec2` en zonas no se probó TCP. Las
  ranuras de proceso siguen siendo dos: no hizo falta subirlas.
- El ISN es aleatorio pero con poca entropía (ver «TCP»).

### RD-03: más de `tests/qemu_tcp_test.sh`

Mismo QEMU y mismo script; agrega `hostfwd` al 7002 (P+2), 7003 (P+3) y 7004
(P+4) del invitado. Los pasos nuevos van entre el eco de RD-02 y la prueba de
`tcpcli`:

| Paso | Qué exige |
|---|---|
| `tcp test` | además de `tcp test ok`, las líneas `tcp test ooo ok`, `rtt ok`, `cc ok`, `full ok` y `fault ok` (ver «TCP endurecido») |
| (a) `exec2 tcpmulti tcpmulti` | cuatro `socat` a la vez (2 al 7001, 2 al 7002 del invitado), cada uno con 64 KiB distintos de `/dev/urandom`: las 4 salidas son idénticas a su entrada (`cmp`); las sumas de bytes que cuenta el invitado, por servidor, son las del host; `tcp multi done` de los dos y `exec2 ok`; `peak >= 6` (4 conexiones y 2 escuchadores ocupando bloques a la vez) |
| (b) pérdida | `tcp fault rxdrop 6 2` y `tcp fault txdrop 9 1`, `exec tcpeco`, 64 KiB desde socat: el eco vuelve idéntico (`cmp`), el invitado cuenta n=65536 y la suma del host, `fdrop` sube exactamente 3 y `retx` sube al menos 1; segunda conexión con `adios` |
| (c) reordenamiento | `tcp fault swap 5`, `exec tcpeco`, 64 KiB: eco idéntico, `fswap` sube exactamente 1 |
| (d) agotamiento | `exec tcphog`; cinco conexiones del host que quedan abiertas 3 s (3 al 7003 y 2 al 7004) y una sexta al 7004: `peak = 8`, `full` sube >= 1, `rstout` sube, en el pcap hay un RST\|ACK con `seq 0` desde el puerto 7004, y al terminar el acaparador `used = 0` |
| (e) | `used 0`, `lst 0`, `tw 0`, `bad 0` y `giveup 0` al final, como en RD-02 |

Los conteos de la zona (`tcp ptr denied`, `tcp listen`) pasaron a compararse
con la línea base, porque ahora hay más ejecuciones de `tcpeco`.

Qué probó cada cosa y qué no:

- (a) son dos procesos de anillo 3 con 2 conexiones a la vez cada uno: no se
  probaron 3 por proceso (el tope de fd es 4 y uno es el escuchador). Los
  servidores usan un hilo y sondean; no hay `poll`/`select`.
- (b) y (c): la pérdida y el reordenamiento los hace el `tcp fault` dentro
  del TCP del invitado, no la red (ver «TCP endurecido»). En las corridas de
  este informe la recuperación fue siempre por el timer de retransmisión
  (`fast 0`) del invitado (retx +1 en la corrida de referencia); no se
  investigó qué hizo slirp. En (b) se encolaron 2 a 3 segmentos
  adelantados (`ooo`), en (c) uno; no se exige un mínimo de `ooo` porque
  depende de cuántos segmentos manda slirp seguidos, y la reconstrucción
  exacta de segmentos desordenados la prueba `tcp test`, no QEMU.
- (d): la sexta conexión se rechaza con RST|ACK; el host no lo ve como error
  (slirp ya había aceptado la conexión del host). Se prueba que no hay fuga
  porque `used` vuelve a 0 y las pruebas de zona que siguen vuelven a abrir
  puertos; `tcphog` termina solo por su plazo, no por una señal del host.
- Las corridas de referencia de `tcp stat` al final dieron, con todo
  lo anterior: `ooo 3 oodrop 0 fast 0 rtos 4 full 1 bklog 0 recyc 0 peak 8
  fdrop 3 fswap 1 giveup 0 bad 0`.
