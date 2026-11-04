# Zonas

Aislamiento liviano, al estilo de una jail: un proceso vive en una
zona y no sale de ahí. La zona 0 es la global. Ahí corre el shell.
Solo ella crea zonas y mete un programa en otra.

Hasta 8 zonas, contando la global. Cada una tiene:

| Campo | Qué es |
|---|---|
| id | 0 es la global. Las demás salen de `zone create` |
| nombre | hasta 8 letras o dígitos |
| tope de páginas | cuántos marcos de 4 KiB puede tener |
| máscara | syscalls permitidas. Lo que no está, se niega |
| prefijo | se antepone a cada nombre de archivo |
| tope de procesos | en una zona nueva son 2 |

El programa no elige el prefijo ni la zona. El kernel agrega el
prefijo y rechaza un nombre que no sea relativo (`/`, `.`, otro
prefijo, o un archivo que ya existe fuera de la zona).

## Syscalls

La máscara de una zona nueva deja pasar solo estas:

| Número | Qué hace |
|---|---|
| 1 | escribe un carácter |
| 5 | `exit` |
| 6 | escribe un archivo. El nombre está en `0x401800` y los datos en `0x401C00`. `rdi` es el largo |
| 7 | lee con el mismo convenio |
| 8 | pide una página. Si pasa el tope, devuelve -1 y no toma el marco |

Cualquier otra syscall de una zona distinta de 0 devuelve -1 y suma
`niega`. Cambiar de zona es la syscall 9: desde una zona distinta de
0 devuelve -2 y suma `fuga`, aunque alguien prenda ese bit. No crea
zonas y no toca el tope.

`exec` del shell hereda la zona 0. `zone exec` es el único camino que
pone un proceso en otra zona, y solo lo puede pedir la zona 0. Un
hijo usaría la zona del padre (`zone_for_new`).

## Cuota

El asignador no entrega un marco si la zona ya llegó a su tope. El
error vuelve al que pidió la página. Las otras zonas siguen igual.
Al hacer `exit` esos marcos vuelven al asignador global.

Si armar el proceso ya no cabe, `zone exec` imprime `zone fail 6` y
suelta lo que alcanzó a tomar. Si el tope de procesos está lleno,
`zone fail 4`.

## Comandos

Solo responden en la zona 0. Si no, `zone denied`.

```
zone create nombre prefijo paginas
zone ls
zone exec zona programa
zone plant
```

`zone plant` escribe el programa de prueba `ztest` con `fs_write`,
igual que `exec plant`. El directorio cabe 7 nombres; la prueba suelta
`malo` y `gordo` antes.

`zone ls` muestra `pre`, `cap`, `proc`, `pag`, `niega`, `fuga` y `max`.
`max` es la marca de agua de `pag`: lo más alto que llegó la zona desde
que se creó. Nunca pasa de `cap`; si pasara, la cuota falló.

## Errores del programa

| Código | Qué pasó |
|---|---|
| -1 | syscall fuera de la máscara, o página sobre el tope |
| -2 | quiso cambiar de zona |
| -12 | el nombre no pertenece a la zona |

## Prueba

`make qemu-test` crea las zonas `a` (prefijo `za`, 12 páginas) y `b`
(prefijo `zb`). `zone exec a ztest` tiene que imprimir, en orden,
`zone fs ok`, `zone fs denied`, `zone fs denied create`,
`zone syscall denied`, `zone syscall flood denied`, `zone quota ok`,
`zone quota hold` y `zone escape denied`. El archivo queda como `zan`
(el programa pidió `n`). `fs cat n` no lo encuentra. Las dos líneas
`zone mem` tienen el mismo número: la memoria libre global volvió al
valor de antes. Si falta una línea, el script termina en 1.

## Pruebas adversarias (SG-01, parte 1)

El programa `src/user/zona.lap` y el script intentan romper la zona a
propósito. Una línea `zone ...` del programa sale solo si todos los
intentos de su grupo fueron negados; además el script revisa lo que el
programa no puede mentir: los contadores del kernel y el disco. (La
syscall 1 deja a un programa imprimir cualquier texto, así que las
líneas solas no prueban nada.)

| Ataque | Cómo se niega | Lo que revisa el script |
|---|---|---|
| (a) leer o escribir el prefijo de otra zona (`zb`, `zbx`) | -12 | `fs ls` antes y después: solo aparece `zan`; `fs cat zbx` y `fs cat x` dan `fs fail 7` |
| (a) nombres de la zona 0 (`c`, `a`, `m`, `ztest`) | -12 | `fs cat c` sigue vacío |
| (a) `/c`, `../c`, `.c`, vacío, byte alto, espacio, 9 letras, 16 sin NUL | -12 | igual |
| (a) largo 0, 65, -1 (escritura) y -1 (lectura) | -9 | igual |
| (a) `zone create` con prefijo repetido, cabeza o extensión del de otra zona, tope 0, 5000 o -5, nombre repetido | `zone fail 11` | siete `zone fail 11` y solo dos `zone created` |
| (b) pedir páginas pasado el tope, 40 veces más | -1 | `zone ls`: `max=12` (llegó al tope, no lo pasó), `pag=0` al salir |
| (b) zona de 1 página: no cabe ni armar el proceso | `zone fail 6` | `max=1`, `pag=0`, `proc=0/`; la memoria libre es la misma antes y después de cada intento (7 líneas `zone mem` iguales) |
| (b) la zona `b` | no se toca | `pag=0 niega=0 fuga=0 max=0` |
| (c) las 58 syscalls del 0 al 63 fuera de la máscara, más 64, 1000, 2^32+1, 2^32+2 y -1 | -1 | `niega=64` con el `rax=2` de la prueba vieja; sin `user leak`, `getpid`, `nx ok sched`, `hh ok sched` ni `X` en la salida |
| (c) cambiar de zona hacia 0, 1, 2, 7 y -1 | -2 | `fuga=5` |

2^32+1 sirve para ver si el kernel recorta el número a 32 bits: eso
sería la syscall 1 con `rdi=88` y saldría una `X`.

El archivo de prueba tiene que caber en 4080 bytes (`mkaxe.sh`). `zona`
pesa 3626; `ataque` pesa 1648.

## Pruebas adversarias (SG-01, parte 2)

`src/user/ataque.lap` hace un ataque por corrida, en una zona `k`
(`zone create k zk 12`). El modo está en el archivo `zkq` de la zona (el
shell lo escribe con `fs write zkq N`); `zone atk` planta el programa
como `zatk`. Cada ataque tiene que terminar con la línea
`user killed pid=1 vec= err= addr=` del kernel, sin `atk survived`, con
`zone exec ok` (el shell recupera el control), sin `zone leak`, y la zona
queda con `pag=0` y `proc=0/`.

| Modo | Ataque desde anillo 3 | Resultado |
|---|---|---|
| 1 / 2 | leer / escribir `0xFFFFFFFF80400000` (texto del kernel) | #PF `err=0x5` / `0x7` |
| 3 / 4 | leer / escribir `0xFFFF800000001000` (alias alto de las tablas) | #PF `0x5` / `0x7` |
| 5 | leer `0x1000` (identidad baja, tablas) | #PF `0x5` |
| 6 | ejecutar la pila (`0x401800`, NX) | #PF `0x15` |
| 7 | ejecutar la página pedida con la syscall 8 (`0x402000`, NX) | #PF `0x15` |
| 8 | escribir su página de código (solo lectura) | #PF `0x7` |
| 9 | ejecutar el texto del kernel | #PF `0x15` |
| a | leer una dirección no canónica | #GP (vec 13) |
| b | leer una página de usuario inexistente (`0x500000`) | #PF `0x4` |
| u | `ud2` | #UD, vec 6, sin código de error, addr = RIP de `ud2` |
| z | `INT64_MIN / -1` (Copihue define `x / 0` como 0) | #DE, vec 0, addr = RIP del `idiv` |
| i | `int 3` | #GP vec 13 `err=0x1a` (3·8+2): la puerta 3 es DPL 0, no #BP |

**Bug encontrado y arreglado.** Antes de este cambio, el modo 1 (y todos
los demás) paraba la máquina: un proceso de `exec` o de zona no tiene
punto de recuperación (`proc_rec0/1` solo los arma la prueba `sched`), y
`note_user_fault` imprimía `pf-cross norec` y hacía `hlt`. Se corrió la
prueba contra el kernel sin el arreglo: el serial termina en
`atk 1` / `pf-cross norec` y el shell no vuelve. El #GP de anillo 3 era
fatal por la misma vía (`cpu_fault`). Arreglo: `user_fault_rec` y
`user_kill` en `sched.lap`, y `exc13` con marco en `idt.lap`. El proceso
muere como en `exit` (devuelve páginas y cupo de la zona). Los #PF con
registro de recuperación (la prueba `sched`) no cambian.

**(e) Punteros de usuario.** Hoy ninguna syscall recibe un puntero: el
nombre y los datos se leen de `0x401800` y `0x401C00`, direcciones fijas
del propio proceso, y `rdi` es un largo o un carácter. No hay superficie
de «puntero de usuario hacia el kernel» que probar tal cual. Lo que sí se
probó (modo `d` y `exec kentry`):

- largos que son punteros del kernel (`0xFFFFFFFF80400000`,
  `0xFFFF800000001000`, `2^63-1` en la syscall 6; los dos primeros y
  `1<<63` en la 7): `-9`. La lectura con un largo positivo enorme se
  recorta a 64 y devuelve 1 (el archivo mide 1 byte), sin copiar de más;
- punteros del kernel en `rsi` y `rdx`: el kernel no los usa, la lectura
  sigue dando el mismo byte;
- un AXE1 cuya cabecera pone la entrada en `0xFFFFFFFF80400000`
  (`kentry`, el único valor que llega del disco): `exec bad entry`, tanto
  con `exec` como con `zone exec`, sin `run begin`.

Si alguna syscall pasa a recibir un puntero, hay que agregar la
validación (rango de usuario) y un ataque nuevo.

**Límites.** Las excepciones de anillo 3 distintas de #PF y #GP (#UD,
#DE, …) siguen entrando a `cpu_fault` y deteniendo el kernel; se leyó el
código, no se probó, y no se arregló (fuera de alcance de memoria).
La dirección absoluta de 64 bits se trunca en el compilador; ver
`docs/PEDIDOS_COPIHUE.md`.

**Estado:** `make qemu-test` termina en 0 en QEMU con estas pruebas y las
de la parte 1 (ver CHANGELOG).

## Excepciones de CPU de anillo 3 (SG-02)

Todo vector que no sea #PF pasa por `user_exc` (`idt.lap`). Con `CS & 3 == 3`
y el planificador prendido llama a `user_kill`, el mismo camino de #PF y
#GP: imprime `user killed pid= vec= err= addr=` (addr = RIP), da de baja
al proceso como `exit` (páginas y cupo de zona) y sigue el otro proceso o
el shell. Sin planificador (comando `user`) informa y vuelve al shell
(`user blocked`; esa rama no se probó para los vectores que no son #PF). Con `CS & 3 == 0` sigue siendo `cpu_fault`: imprime
`exception: vector …` y detiene el kernel. Siguen fatales aunque vengan de
anillo 3: NMI (2, externa), #DF (8) y #MC (18), abortos que no se pueden
atribuir al proceso ni reanudar.

Probados en QEMU (modos u, z, i arriba; `make qemu-test` exige vector y
error exactos, el RIP dentro del programa y que los bytes de
`build/ataque.bin` en ese RIP sean la instrucción esperada): #UD, #DE y
#GP (por `int 3`). Cubiertos por el mismo `user_exc` pero **sin prueba**:
#DB, #BP, #OF, #BR, #NM, #TS, #NP, #SS, #MF, #AC, #XM/#VE/#CP/#HV/#VC/#SX
y los reservados. Motivos: `into` y `bound` no existen en 64 bits (darían #UD
y ese vector ya está probado con `ud2`); `int 3` (CD 03) de anillo 3 da #GP por la puerta DPL 0, y el opcode CC no se probó;
#NM y #MF necesitan CR0.TS/EM/NE que el kernel no prende; #AC necesita
CR0.AM; #XM necesita CR4.OSXMMEXCPT; #SS por RSP no canónico: QEMU 11.1.3
entrega #GP (`vec=13 err=0x00000000`, RIP en el `push`), no #SS, así que
esa prueba no distingue el vector y se descartó.


## Red (RD-01)

Las syscalls 12..16 (UDP, ver `red.md`) no están en la máscara de una
zona nueva: devuelven -1 y suman `niega`, como cualquier otra fuera de
la máscara. `zone net nombre` (solo desde la zona 0) agrega esos cinco
bits. Probado en `tests/qemu_udp_test.sh`: la zona sin red imprime
`udp denied` (el `bind` dio -1) y su `niega` queda en 1 o más; la zona con
`zone net` hace el eco UDP.
