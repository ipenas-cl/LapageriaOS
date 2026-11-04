# Trazas (OB-01)

Veinte sondas estáticas, un anillo fijo de 64 registros en memoria, dos
syscalls para usarlo desde anillo 3 y un programa de usuario, `traza`.
No hay asignación en el camino de la sonda y no se agregó `asm()`.

## Sondas

Apagadas al arranque; cada una se prende y se apaga sola. El llamador
hace un solo chequeo del indicador (`tr_en[id] != 0`); si está en cero no
llama a `trace_hit`. El contador sube solo cuando la sonda está prendida y
el evento entra al anillo.

| Id | Nombre | Dónde | a | b |
|---|---|---|---|---|
| 0 | `sys-enter` | entrada de `sys_user` | número | argumento |
| 1 | `sys-exit` | vuelta de `sys_user` | número | resultado |
| 2 | `switch` | `switch_to` | pid que sale | pid que entra |
| 3 | `pf` | `#PF` | CR2 | código de error |
| 4 | `pit` | IRQ0, un evento por tick | tick | 0 |
| 5 | `pg-alloc` | página entregada | dirección física | 0 |
| 6 | `pg-free` | página devuelta | dirección física | 0 |
| 7 | `blk-read` | lectura de bloque | bloque | código |
| 8 | `blk-write` | escritura de bloque | bloque | código |
| 9 | `net-rx` | descriptor de recepción listo | largo | error |
| 10 | `net-tx` | paquete entregado al e1000 | largo | estado |
| 11 | `irq-kbd` | IRQ1 | scancode (make; break = make + 128) | 0 |
| 12 | `irq-net` | IRQ del e1000 con ICR ≠ 0 | ICR | 0 |
| 13 | `udp-rx` | datagrama puesto en la cola de un socket | puerto destino | largo de la carga |
| 14 | `udp-tx` | datagrama entregado al e1000 | puerto destino | largo de la carga |
| 15 | `tcp-state` | cada cambio de estado de un TCB | índice del TCB | `(viejo << 8) \| nuevo` |
| 16 | `tcp-retx` | retransmisión (timer o rápida) | índice del TCB | reintentos del TCB |
| 17 | `tcp-rst` | RST enviado (a = 0) o recibido (a = 1) | 0 / 1 | puerto del par |
| 18 | `zone-switch` | `syscall 9` que cambia la zona del proceso; `switch_to` entre procesos de zonas distintas; y la salida de un proceso con el otro vivo en otra zona (pid = el que sale) | zona vieja | zona nueva |
| 19 | `zone-deny` | acceso denegado por la zona | número de syscall (o 3 = ruta) | 1 máscara, 2 escape, 4 proceso o traza de otra zona, errno si es ruta |

Estados de TCP en `tcp-state`: 0 libre, 1 LISTEN, 2 SYN_SENT, 3 SYN_RCVD,
4 ESTABLISHED, 5 FIN_WAIT_1, 6 FIN_WAIT_2, 7 CLOSE_WAIT, 8 CLOSING,
9 LAST_ACK, 10 TIME_WAIT, 11 cerrado por error.

`yield` y `exit` no vuelven al epílogo del syscall, así que queda la
entrada y no la salida. `pit` es el reloj de muestreo. En el shell, o en
una IRQ entre dos `exec`, el pid y la zona del registro son 0.

## Anillo

64 registros, potencia de 2. Cada uno es un struct de siete `i64`
(56 bytes, `trace_layout` lo chequea): tick, id de sonda, pid, zona, dos
argumentos y la marca de ciclos. Vive en la `.bss`. El tick es el contador `ticks` del PIT
(100 Hz). Al llenarse pisa el más viejo y `tr_lost` cuenta ese piso. Un
anidamiento (la sonda ya estaba tomada) también suma un perdido y no
escribe.

La marca de ciclos es `rdtsc()` (Copihue v0.42.5), leído dentro del anillo
ya tomado, después de los demás campos. El tick tiene resolución de 10 ms;
la marca ordena eventos del mismo tick. No es una hora: la frecuencia del
TSC depende de la máquina (QEMU entrega el reloj virtual) y no se calibró.

El registro guarda los flags con `irq_save()` (RFLAGS y `cli`) y los devuelve
con `irq_restore(f)`. No hace `sti()` a ciegas: el syscall entra con IF en 0 y el
PIT también. Si la pila de flags (cuatro niveles) se llena, el evento se
cuenta perdido y se sale. No hay ciclo de espera.

## Syscalls (anillo 3)

Las valida el kernel como a UDP y TCP (`uptr_range_ok`): el buffer tiene
que caer en las páginas de escritura del proceso. Las zonas las niegan por
la máscara (no están en `zone_user_mask`), y eso deja un `zone-deny`.

`23 trace_ctl(op, a, b)`

| op | Qué hace | Devuelve |
|---|---|---|
| 0 | `a` = sonda (255 = todas), `b` = 1 prende, 0 apaga | 0 |
| 1 | lee la sonda `a` | `(contador << 1) \| prendida` |
| 2 | vacía el anillo, los perdidos y los contadores | 0 |
| 3 | estado del anillo | `usados \| (perdidos << 8)` |
| 4 | cuántas sondas | 20 |
| 5 | nombre de la sonda `a` en el buffer `b` (16 bytes, escritura) | largo |

`24 trace_read(buf, max, sel)`: copia a `buf` hasta `max` (1..32)
registros, los más nuevos que pasan el filtro `sel`, del más viejo al más
nuevo. Son 7 `i64` por registro: tick, sonda, pid, zona, a, b, tsc. Devuelve
cuántos. `sel`: bits 0..7 = sonda + 1, bits 8..15 = zona + 1, bits 16..39 =
pid + 1; un campo en 0 no filtra.

Desde una zona distinta de la global (con `zone trace`): `trace_read` solo
devuelve eventos de la zona del que llama (el filtro de zona es el suyo;
pedir otra da `-1`) y `trace_ctl` solo contesta las operaciones 4 y 5. El
anillo y las sondas son de todos, así que lo demás (prender o apagar una
sonda, vaciar, leer contadores o el estado) se niega con `-1`. Cada negación
deja `zone-deny` con `b` = 4. Ver `docs/zonas.md`.

Errores de las dos: `-22` argumento, `-14` puntero fuera del rango
permitido (kernel, MMIO, página de código al escribir, cruzando el final de
la pila, no canónico), `-16` anillo tomado.

## Comandos del shell

`trace` es el comando del kernel y no es un proceso (sirve para contar sin
que la herramienta deje eventos):

```
trace ls
trace on sys-enter
trace off sys-enter
trace dump          (todo lo que hay, del más viejo al más nuevo)
trace dump 8        (los últimos 8)
trace count
trace clear
trace plant         (escribe el programa traza en el disco)
```

`traza` corre el programa de anillo 3 (`src/user/traza.lap`, 3981 bytes de 4080, sin
cadenas). El shell arma una petición de 8 bytes en el archivo `tzq` y el
programa la lee con la syscall 7. Hace falta `fs format` y `trace plant`
antes (el directorio cabe 7 archivos: `traza` y `tzq` ocupan 2).

```
traza ls                        sondas: id, nombre, on/off, contador
traza count                     contador por sonda y perdidos
traza on  <sonda|all>
traza off <sonda|all>
traza dump [ev=<sonda>] [zone=<n>] [pid=<n>] [n=<k>]    k = 1..32, por defecto 16
traza clear
traza ptr                       punteros y argumentos malos: «ptr ok»
traza zone <n>                  pasa el proceso a la zona n y pide la syscall 23
```

Los formatos son los de `trace`: `traza dump` imprime `trace begin`, una
línea `t <tick> <nombre> pid <pid> a <a> b <b> z <zona> c <tsc>` por evento y
`trace end n <cuántos> lost <perdidos>`.

El costo de una sonda apagada se midió (antes de OB-01, con 11 sondas) en
QEMU 8.2.2, con el PIT a 100 Hz. Ocho millones de veces el chequeo
`tr_en[4] != 0` tardaron 6 o 7 ticks contra 4 del mismo lazo sin el
chequeo: del orden de 3 ns por chequeo. El tick mide 10 ms: el número no
es más fino que eso. OB-01 no cambió el chequeo y no se volvió a medir.

## Prueba

`make qemu-test` corre `tests/qemu_shell_test.sh` (las cuatro líneas de
`trace counters`, `trace syscall`, `trace off`, `trace overflow`) y
`tests/qemu_trace_test.sh` (también `make qemu-trace-test`). La segunda
activa y lee todo desde `traza` y compara con los contadores propios del
kernel:

| Línea | Qué comprueba |
|---|---|
| `traza ls` | 20 sondas, todas apagadas |
| punteros | `traza ptr`: -14 y -22 donde corresponde |
| `sys-enter/sys-exit` | `exec hola`: 13 entradas y 12 salidas exactas; una sonda prendida no prende las otras |
| filtros | `exec2 hola hola`: `pid=2` 25 eventos, `pid=1 ev=sys-exit` 12, `ev=sys-enter zone=0` 26, `zone=1` 0 |
| `irq-kbd` | teclear un comando deja 2 IRQ por tecla, con los scancodes make y break |
| anillo | `pit` da la vuelta al anillo (lost > 0) y los últimos 32 son ticks consecutivos |
| rdtsc | cada evento trae `c <tsc>`; en los 32 `pit` seguidos es positivo y estrictamente creciente, y `trace dump` también lo imprime |
| UDP | `udp-rx` y `udp-tx` == los contadores de `udp stat`; largos 12, 4 y 5 al puerto 7777 |
| TCP | `tcp-retx` == `retx` de `tcp stat` (con un segmento perdido con `tcp fault`); `tcp-rst` == `rstout` + `rstin`; transiciones a ESTABLISHED == `est`; `lost 0` |
| zonas | `zone-deny` > `niega` + `fuga` de `zone ls` (el resto son rutas), todos con zona 1; `zone-switch` 0 → 1 |
| apagado | con `traza off all` no se graba nada |

El `zone-switch` de `switch_to` (dos procesos en zonas distintas que se
alternan) tiene su prueba en `tests/qemu_zswitch_test.sh`
(`make qemu-zswitch-test`, también en `make qemu-test`). Se arma con
`zone sched` (da `yield` a una zona) y `zone pair` (dos copias del programa
`par` a la vez, una por zona). Ver `docs/zonas.md`.
