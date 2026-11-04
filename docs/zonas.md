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

Quedan para otra vuelta: anillo 3 contra memoria del kernel y página NX
en una zona (d), y punteros de usuario hacia el kernel (e). Hoy ninguna
syscall de zona recibe un puntero: el nombre y los datos se leen de
`0x401800` y `0x401C00`, direcciones fijas del propio proceso.

El archivo de prueba tiene que caber en 4080 bytes (`mkaxe.sh`). El
programa pesa 3626. Para sumar más ataques hay que repartirlos en otro
programa o comprimir mensajes.

**Estado:** `make` compila. La prueba nueva no se ha corrido en QEMU
(ver CHANGELOG).
