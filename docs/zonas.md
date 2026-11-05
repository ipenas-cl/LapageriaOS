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
| raíz | el directorio `/zonas/<nombre>`; la zona lo ve como `/` |
| tope de procesos | en una zona nueva son 2 |

## Raíz propia (FS-02)

`zone create nombre paginas` crea `/zonas` (si falta) y `/zonas/<nombre>`
en el sistema de archivos ([fs.md](fs.md)) y deja la ranura viva. La
zona global no tiene raíz propia: ve todo el árbol (`root=/` en `zone ls`).

El programa no elige la raíz ni la zona. Las syscalls 6 y 7 reciben un
nombre relativo (hasta 15 bytes en `0x401800`, con NUL) y el kernel arma
`/zonas/<nombre>/<relativo>`. El relativo puede tener subdirectorios
(`d/n`) si el directorio ya existe: la zona no tiene syscall para crearlos
(`fs mkdir /zonas/a/d` desde el shell). Se niega con **-1**, suma `niega`
y deja `zone-deny` (sonda 19, `b` = 3):

- cualquier `..`, y cualquier `.`;
- una ruta absoluta (empieza con `/`), aunque nombre algo que sí existe
  (`/c`, `/zonas/otra/x`). Dentro de la zona no hay nada que decir con una
  ruta absoluta: se prefirió negarla a reinterpretarla;
- componentes vacíos (`x//y`, `x/`, nombre vacío);
- bytes fuera de 33..126 (espacio, byte alto), o 16 bytes sin NUL.

Un nombre válido que no existe en la raíz de la zona da -7, igual que en
cualquier lugar: un archivo de la zona 0 (`c`) no existe para la zona
aunque esté en `/c`. Los chequeos de largo (`rdi` 0, mayor que 64, -1)
siguen dando -9 antes de leer el nombre y no suman `niega`.

**Compatibilidad.** El mecanismo anterior (un prefijo de nombre,
`zone create nombre prefijo paginas`) se eliminó. La forma de tres
argumentos se rechaza con `zone fail 11`. Los archivos que una zona vieja
dejó en la raíz con su prefijo (`zan`) quedan donde estaban y ya no son
de nadie.

**Rollback.** `fs rollback` vuelve el árbol entero, también `/zonas`. Si el
snapshot es anterior a `zone create`, la zona sigue viva pero su
directorio no existe: escribir da -7 hasta que se vuelva a crear
(`fs mkdir /zonas/<nombre>`).

## Syscalls

La máscara de una zona nueva deja pasar solo estas:

| Número | Qué hace |
|---|---|
| 1 | escribe un carácter |
| 5 | `exit` |
| 6 | escribe un archivo en la raíz de la zona. El nombre está en `0x401800` y los datos en `0x401C00`. `rdi` es el largo |
| 7 | lee con el mismo convenio |
| 8 | pide una página. Si pasa el tope, devuelve -1 y no toma el marco |

Además, solo la zona 0 tiene la **27** `zone_destroy` (ver abajo).

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
zone create nombre paginas
zone destroy nombre
zone rm nombre ruta
zone ls
zone exec zona programa
zone plant
```

`zone plant` escribe el programa de prueba `ztest` con `fs_write`,
igual que `exec plant`, en la raíz global. El programa de `zone exec` se
lee de la raíz global, no de la de la zona.

`zone ls` muestra `root=/zonas/<nombre>` (`root=/` en la global), `cap`,
`proc`, `pag`, `niega`, `fuga`, `max` y, desde OB-03, `cpu=<cuota>/20` y
`tot=<ticks cobrados>` (los mismos de `zone cpu`).

## Administración de zonas (OB-03)

Todos los comandos son del shell de la zona 0; en una zona dan `zone denied`.
Una zona vive en una ranura de las 8 y su tabla está en RAM: no se guarda en
el disco, así que tras un reinicio hay que volver a crearlas (los archivos de
`/zonas/<nombre>` sí quedan).

| Comando | Qué hace | Salida |
|---|---|---|
| `zone create <nombre> <páginas>` | crea la zona y su raíz `/zonas/<nombre>` (1 a 4096 páginas; nombre de hasta 8 letras o dígitos) | `zone created ...`; `zone fail 11` si el nombre está repetido o mal formado, `zone fail 6` si no hay ranura |
| `zone ls` | una línea por zona viva | `zone <id> <nombre> root= cap= proc= pag= niega= fuga= max= cpu=<cuota>/20 tot=<ticks>` |
| `zone destroy <nombre>` | libera la ranura; los archivos quedan | `zone destroyed N`, `zone busy` |
| `zone rm <nombre> <ruta>` | borra recursivamente dentro de la raíz de la zona | `zone rm ok` |
| `zone cpu <nombre> [n]` | cuota de CPU (n de 0 a 20 ticks por ventana de 20) y contadores | ver «Cuota de CPU» |
| `zone sched <nombre>` | agrega a la máscara las syscalls 4, 25, 26 y 28 (ceder, ver, matar, ticks propios) | `zone sched ok` |
| `zone trace <nombre>` | agrega 23 y 24 (`trace_ctl`, `trace_read`), acotadas a la propia zona | `zone trace ok` |
| `zone net <nombre>` | agrega 12..22 (UDP y TCP) | `zone net ok` |
| `zone exec <zona> <programa>` | corre un programa AXE1 del disco (raíz global) dentro de la zona | `zone exec ok` |
| `zone pair <za> <zb> <programa>` | dos copias a la vez, una por zona (`global` vale) | `zone pair ok` |
| `zone plant`, `zone atk`, `zone par`, `zone parcpu` | escriben en el disco los programas de prueba `ztest`, `zatk`, `par` y `parcpu` | `zone ... plant ok` |

Receta para una zona completa, con observabilidad y tope de CPU:

```
zone create web 64        # raíz /zonas/web, 64 páginas
zone sched web            # puede ceder la CPU y ver sus procesos
zone trace web            # puede leer su propia traza
zone net web              # puede usar UDP y TCP
zone cpu web 10           # como mucho 10 de cada 20 ticks (50%)
zone ls                   # cuota y uso: cpu=10/20 tot=<ticks>
zone destroy web
```

Lo que `zone trace` no da: la zona solo ve sus eventos y no prende ni apaga
sondas (ver la tabla de syscalls arriba). Quien las prende es la zona global
(`trace on`, `traza ...`; ver `trace.md`).

## Cuota de CPU (FS-04, etapa 7)

`zone cpu <nombre> <n>` limita la CPU de una zona: puede gastar `n` ticks del
PIT (de 1 a 20) en cada ventana fija de 20 ticks; `0` quita el límite (es el
valor de una zona nueva). `zone cpu <nombre>` muestra
`zone cpu <nombre> quota=<n>/20 tot=<ticks> cont=<ticks> thr=<veces> idle=<ticks> solo=<ticks>`.
`zone fail 11` si el nombre no existe, es `global` o `n` no es un número de
0 a 20. Poner la cuota pone en cero los contadores.

- Un tick se le cobra a la zona del proceso que corría (`zcpu_tick`, en el
  manejador del PIT con el planificador prendido).
- Con la cuota de la ventana gastada, la zona sale de la CPU en el siguiente
  tick si el otro proceso listo es de una zona que no la agotó, y no recibe
  cesiones (`yield`) de ella hasta que la ventana se renueva.
- `tot` son los ticks cobrados, `cont` los cobrados con otro proceso listo (la
  CPU que disputó) y `thr` las veces que la cuota la sacó de la CPU.
- Todo se mide en ticks, no en tiempo del anfitrión: con `-icount shift=4` el
  reparto sale igual (2/20 da `cont` de la zona acotada un 11% del de la
  otra, 392 frente a 3524 en una corrida).
- Tope duro (FS-05/1): si no hay otro proceso con cuota disponible, la CPU
  pasa a una tarea ociosa (`idle_loop` en `sched.lap`: `hlt` sobre su propia
  pila, con un marco `iretq` a anillo 0 que forja `idle_forge`). La zona
  acotada no corre, aunque esté sola, hasta que la ventana se renueva; ahí el
  PIT la reanuda. Los ticks ociosos no se cobran a nadie: se cuentan en
  `idle=` (de la zona que esperaba) y los cobrados sin otro proceso listo en
  `solo=`. Son dos procesos como máximo.
- Límite: el corte ocurre en el tick del PIT y solo si el proceso está en
  anillo 3; uno que esté dentro de una syscall en ese tick sigue hasta el
  siguiente (puede pasarse de la cuota por un tick).

La prueba es `tests/qemu_cpu_test.sh` (`make qemu-cpu-test`, normal y con
`-icount shift=4`): `zone pair za zb parcpu` con el modo `k<d>` de `parcpu`
(`src/user/parcpu.lap`, salido de `par` en OB-03 porque `par` se quedó sin
espacio): gasta CPU sin ceder hasta que el kernel le cobra `10*d` ticks.
`parcpu` lee el contador a lo sumo 2000000 veces; si no llega, sale solo y
deja un `0` en `r<pid>` de su zona (el modo `n<d>`, con 1000 lecturas, ejerce
esa salida: `n9` pide 90 ticks y no llega). La prueba lo dice
(`el contador de ticks no avanza`) en vez de esperar el plazo de 60 s. Si
llega, no escribe nada: una escritura al disco tras llegar cobraría un tick
más a la zona y rompería la cota del tope duro.

## Borrar dentro de la raíz de una zona

`zone rm nombre ruta` (solo desde el shell) borra recursivamente `ruta`, que es
relativa a `/zonas/<nombre>`. Se niega, sin tocar el disco, con
`fs rm -r refused: ...`: ruta absoluta (`ruta absoluta fuera de la zona`),
`.`, `..` o componentes vacíos (`ruta con componente vacio, . o ..`), y la ruta
vacía, que sería la raíz de la zona (`raiz de la zona`). `zone fail 11` si la
zona no existe o es `global`. `fs rm -r` desde el shell (zona global) rechaza
además `/`, `/zonas` y `/zonas/<nombre>`.

## Destruir una zona

`zone destroy nombre` (solo desde el shell, la zona 0; si no, `zone denied`):

- `zone destroyed N` y la ranura `N` queda libre para otra `zone create`;
- `zone busy` si la zona tiene procesos vivos; no cambia nada;
- `zone fail 11` si no existe, o si es `global`.

**Los archivos quedan.** `/zonas/<nombre>` y todo lo que tiene adentro
siguen en el disco. Una zona nueva con el mismo nombre vuelve a ver esos
archivos (`zone create` acepta un directorio que ya existe). Para
borrarlos hay que usar `fs rm` (archivo por archivo, el directorio vacío
al final).

Desde el shell no hay un proceso de zona vivo que pueda coincidir con el
comando, porque `zone exec` y `zone pair` bloquean el shell hasta el
final. Por eso el caso `busy` se prueba desde un proceso de la zona 0
con la syscall 27: `zone destroy` hecha por un programa de la global
(`zone pair global dz par`, modo `d` de `par`, con `/g` = `d` y
`/zonas/dz/q` = `w`; `dz` necesita `zone sched dz` para ceder la CPU),
mientras otro proceso de `dz` está vivo.

| Syscall | Qué hace | Máscara |
|---|---|---|
| 27 `zone_destroy` | el nombre está en `0x401800`. Imprime `zone busy` o `zone destroyed N`. 0, `-16` si tiene procesos vivos, `-11` si no existe o es la global | solo la zona 0 (una zona la niega con -1 y suma `niega`) |

## Dos zonas a la vez (OB-02)

```
zone sched nombre            agrega las syscalls 4 (yield), 25, 26 y 28 a la máscara
zone par                     escribe el programa par (src/user/par.lap)
zone pair za zb programa     dos copias del programa, a la vez
```

`zone pair` pone la copia 1 (pid 1) en la zona `za` y la 2 (pid 2) en la
`zb`; pueden ser la misma zona o la global (`global`). Las reparte el
planificador, por `yield` y por el PIT. Al terminar imprime
`zone pair sw n=… chg=… yield=… timer=…`: `n` son los cambios de contexto
(los de `switch_to` más la salida del primer proceso con el otro vivo),
`chg` cuántos cambiaron la zona activa, `yield` y `timer` los motivos de
los de `switch_to`. También comprueba que no quedó ni una página ni una
zona con cupo (`zone pair ok`, o `zone leak`).

Cada cambio de contexto pasa por `zone_note_switch` (`sched.lap`): cuenta, y
si la zona activa (la del proceso que corre) cambia deja `zone-switch`
(sonda 18) con la zona que sale en `a` y la que entra en `b`, y el pid del
que sale. La salida de un proceso con el otro vivo no pasa por `switch_to`:
cuenta como cambio y deja `zone-switch`, pero no `switch`.

`par` en modo `y` (el archivo `q` de la zona, o `y` si no se puede leer)
cede la CPU 6 veces. Cada zona lee su modo de `q` en su propia raíz
(`/zonas/<zona>/q`); la zona global lo lee de `/g`. Modo `d`: la global
destruye la zona `dz` (ver arriba).

## Procesos de otras zonas (OB-02, etapa 7)

Un proceso de una zona distinta de 0 no ve, no señala y no traza a los
procesos de otra zona. La zona global lo ve todo. Hay dos syscalls nuevas y
las de trazas se acotan:

| Syscall | Qué hace | Máscara |
|---|---|---|
| 25 `proc_stat(pid)` | `(pid << 8) \| (zona << 4) \| estado` (1 listo, 2 corriendo, 4 dormido); `pid` 0 es el propio | `zone sched` |
| 26 `proc_kill(pid)` | da de baja a otro proceso: sus páginas y su cupo de zona vuelven. `-22` si es el propio | `zone sched` |
| 28 `cpu_ticks` | ticks que el kernel ha cobrado a la propia zona (el `tot` de `zone cpu`); solo lee el contador propio. Los programas de prueba lo usan para gastar CPU por ticks y no por vueltas | `zone sched` |
| 23 `trace_ctl` | fuera de la global solo las operaciones 4 (cuántas sondas) y 5 (nombre); las demás (prender, apagar, leer contador, vaciar, estado) dan `-1` | `zone trace` |
| 24 `trace_read` | fuera de la global el filtro de zona es siempre el propio; pedir otra zona da `-1`, y un pid de otra zona no encuentra nada (0 registros) | `zone trace` |

`zone sched nombre` agrega 4, 25, 26 y 28; `zone trace nombre` agrega 23 y 24. Una
zona nueva no tiene ninguna.

Un pid que existe en otra zona y uno que no existe dan lo mismo: `-3`, sin
distinguirse. Si existe, el intento deja `zone-deny` (sonda 19) con `a` =
syscall (25, 26, 23 o 24) y `b` = 4, con el pid y la zona de quien lo
intentó; no suma `niega` ni `fuga`.

La prueba es `tests/qemu_iso_test.sh` (`make qemu-iso-test`, también en
`make qemu-test`), con dos copias del programa `par` (`zone pair`, modos
`c`, `s` y `g`): 14 intentos negados entre `za` y `zb` (7 por proceso), los
permitidos con la propia zona, la misma zona dos veces (se ven y uno mata al
otro, sin ningún `zone-deny`) y la global contra `za` (ve, lee la traza de
esa zona y la mata). En los tres `zone pair ok`: no queda una página ni un
cupo.

`max` (en `zone ls`) es la marca de agua de `pag`: lo más alto que llegó
la zona desde que se creó. Nunca pasa de `cap`; si pasara, la cuota falló.

## Errores del programa

| Código | Qué pasó |
|---|---|
| -1 | syscall fuera de la máscara, página sobre el tope, o ruta que sale de la raíz de la zona |
| -2 | quiso cambiar de zona |
| -7 | el archivo no existe en la raíz de la zona |
| -9 | largo fuera de 1..64 |
| -12 | el nombre no termina en NUL, para la zona 0 (una zona recibe -1) |
| -16 | `zone_destroy`: la zona tiene procesos vivos |

## Prueba

`make qemu-test` crea las zonas `a` (raíz `/zonas/a`, 12 páginas) y `b`
(`/zonas/b`). `zone exec a ztest` tiene que imprimir, en orden,
`zone fs ok`, `zone fs denied`, `zone fs denied create`,
`zone syscall denied`, `zone syscall flood denied`, `zone quota ok`,
`zone quota hold` y `zone escape denied`. El archivo queda como
`/zonas/a/n` (el programa pidió `n`). `fs cat n` no lo encuentra. Las dos líneas
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
| (a) `c` (archivo de la zona 0): no existe en `/zonas/a` | -7 | `fs cat c` sigue vacío |
| (a) `..`, `../`, `../c`, `a/../b`, `.`, `c/`, `x//y`, `/x`, `/zonas/zb/x`, vacío, byte alto, espacio, 16 sin NUL (13 nombres, dos syscalls cada uno) | -1 y `niega` | `niega=91` (64 + 26 + 1); `fs ls` de la raíz antes y después: igual; `fs cat zbx` y `fs cat x` dan `fs fail 7` |
| (a) largo 0, 65, -1 (escritura) y -1 (lectura) | -9 | igual |
| (a) `zone create` con la forma vieja de prefijo (`c za 5`), tope 0, 5000 o -5, nombre repetido | `zone fail 11` | siete `zone fail 11` y solo tres `zone created` |
| (b) pedir páginas pasado el tope, 40 veces más | -1 | `zone ls`: `max=12` (llegó al tope, no lo pasó), `pag=0` al salir |
| (b) zona de 1 página: no cabe ni armar el proceso | `zone fail 6` | `max=1`, `pag=0`, `proc=0/`; la memoria libre es la misma antes y después de cada intento (7 líneas `zone mem` iguales) |
| (b) la zona `b` | no se toca | `pag=0 niega=0 fuga=0 max=0` |
| (c) las 58 syscalls del 0 al 63 fuera de la máscara (la 27 incluida), más 64, 1000, 2^32+1, 2^32+2 y -1 | -1 | 64 de las 91 de `niega` (con el `rax=2` de la prueba vieja); sin `user leak`, `getpid`, `nx ok sched`, `hh ok sched` ni `X` en la salida |
| (c) cambiar de zona hacia 0, 1, 2, 7 y -1 | -2 | `fuga=5` |

2^32+1 sirve para ver si el kernel recorta el número a 32 bits: eso
sería la syscall 1 con `rdi=88` y saldría una `X`.

El archivo de prueba tiene que caber en 4080 bytes (`mkaxe.sh`). `zona`
pesa 3680 (límite 4080); `ataque` pesa 1648.

## Pruebas adversarias (SG-01, parte 2)

`src/user/ataque.lap` hace un ataque por corrida, en una zona `k`
(`zone create k 12`). El modo está en el archivo `q` de la zona (el
shell lo escribe con `fs write /zonas/k/q N`); `zone atk` planta el programa
como `zatk`. Cada ataque tiene que terminar con la línea
`user killed pid=1 vec= err= addr=` del kernel, sin `atk survived`, con
`zone exec ok` (el shell recupera el control), sin `zone leak`, y la zona
queda con `pag=0` y `proc=0/`.

| Modo | Ataque desde anillo 3 | Resultado |
|---|---|---|
| 1 / 2 | leer / escribir `0xFFFFFFFF80400000` (texto del kernel) | #PF `err=0x5` / `0x7` |
| 3 / 4 | leer / escribir `0xFFFF800000001000` (alias alto de las tablas) | #PF `0x5` / `0x7` |
| 5 | leer `0x1000` (identidad baja, tablas) | #PF `0x5` |
| 6 | ejecutar la página de E/S (`0x401800`, NX; antes de EX-04 era también la pila) | #PF `0x15` |
| 7 | ejecutar la página pedida con la syscall 8 (`0x402000`, NX) | #PF `0x15` |
| 8 | escribir su página de código (solo lectura) | #PF `0x7` |
| 9 | ejecutar el texto del kernel | #PF `0x15` |
| a | leer una dirección no canónica | #GP (vec 13) |
| b | leer una página de usuario inexistente (`0x500000`) | #PF `0x4` |
| u | `ud2` | #UD, vec 6, sin código de error, addr = RIP de `ud2` |
| z | `INT64_MIN / -1` (`/` tiene guarda para `x / 0`) | #DE, vec 0, addr = RIP del `idiv` |
| r | `div_raw(1, 0)` (divisor cero sin guarda) | #DE, vec 0, addr = RIP del `idiv` |
| m | `rem_raw(1, 0)` (divisor cero sin guarda) | #DE, vec 0, addr = RIP del `idiv` |
| i | `int 3` | #GP vec 13 `err=0x1a` (3·8+2): la puerta 3 es DPL 0, no #BP |
| s | recursión sin fin (EX-04) | #PF `0x6` en `0x40Exxx`: cae en la guarda de la pila |
| t | leer el primer byte de la guarda `0x40E000` (EX-04) | #PF `0x4` en `0x40E000` |
| v | `rsp` en `0x40E800` y un `push` (EX-04) | #PF `0x6` en `0x40E7F8` |
| y | marco local de 8 KiB (`let b: [u8; 8192]`, EX-07) | #PF `0x4` en `0x40Exxx`: el sondeo de v0.44.2 toca la guarda antes de que corra el cuerpo |

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

Las syscalls 12..16 (UDP) y 17..22 (TCP), ver `red.md`, no están en la máscara de una
zona nueva: devuelven -1 y suman `niega`, como cualquier otra fuera de
la máscara. `zone net nombre` (solo desde la zona 0) agrega esos once
bits. Probado en `tests/qemu_udp_test.sh`: la zona sin red imprime
`udp denied` (el `bind` dio -1) y su `niega` queda en 1 o más; la zona con
`zone net` hace el eco UDP. Lo mismo para TCP en `tests/qemu_tcp_test.sh`
(`tcp denied`, y con `zone net` el eco TCP).
