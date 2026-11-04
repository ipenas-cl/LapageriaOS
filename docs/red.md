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

No hay TCP. UDP está en «UDP». Nada de esto escucha en el arranque:
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
