# Sistema de archivos

Lapageria rosea es el nombre científico del copihue; antes AtomicOS.

Copy-on-write chico sobre `blk_read` / `blk_write`, con directorios
jerárquicos, archivos de hasta 72 KiB, snapshots, rollback y `fs scrub`.
El checksum del bloque sigue siendo el del sector de metadatos
([disco.md](disco.md)). Si no calza, la lectura devuelve error y el
shell no imprime esos bytes.

Los bloques 0 y 1 los usa el comando `disk` (el 0 es la prueba de CRC,
el LBA 2 es el sector de datos del bloque 1). El sistema de archivos
parte en el bloque 2.

**Versión 2.** El superbloque dice versión 2. Un disco con versión 1
(el directorio plano de 7 archivos) se rechaza: el shell imprime
`fs old version` y no toca nada. `fs migrate` lo pasa a versión 2 sin
perder nada (ver [Migración v1 a v2](#migración-v1-a-v2)); `fs format` lo
reescribe vacío.

## Superbloque

Hay dos copias, en los bloques 2 y 3. Cada operación escribe la copia
que no está publicada y le sube la generación. La copia viva queda
quieta hasta que la nueva cierra el CRC. Al montar se leen las dos y
gana la generación mayor cuyo magic, versión 2 y CRC calzan. Si la copia
nueva quedó a medias, sigue valiendo la anterior.

`fs_format` deja la generación 1 en el bloque 2 y la generación 0 en
el bloque 3, con el mismo árbol (la raíz vacía en el bloque 4). Así un
disco que ya tenía datos no esconde el formato nuevo.

| Offset | Bytes | Contenido |
|---|---|---|
| 0 | 4 | magic `AFS1` (`41 46 53 31`) |
| 4 | 4 | versión 2 |
| 8 | 4 | generación |
| 12 | 4 | raíz: bloque del inodo del directorio raíz vivo |
| 16 | 4 | cantidad de bloques del disco (tope 1024) |
| 20 | 4 | primer bloque asignable (4) |
| 24 | 4 | cantidad de snapshots |
| 28 | 4 | reservado |
| 32 | 128 | bitmap. El bit 1 significa ocupado. Bit `n` en el byte `32 + n/8` |
| 160 | 192 | 8 snapshots de 24 bytes |

Snapshot (desde el offset 160):

| Offset | Bytes | Contenido |
|---|---|---|
| 0 | 12 | nombre, con cero al final |
| 12 | 4 | bloque del inodo de la raíz de ese momento |
| 16 | 4 | generación al momento del snapshot |
| 20 | 4 | cero |

## Inodo

Un archivo y un directorio son un bloque inodo (84 bytes útiles, el
resto en cero) que apunta a sus bloques de datos. Magic `AINO`
(`41 49 4E 4F`).

| Offset | Bytes | Contenido |
|---|---|---|
| 0 | 4 | magic `AINO` |
| 4 | 4 | tipo: 1 archivo, 2 directorio |
| 8 | 4 | tamaño en bytes (en un directorio, 32 por entrada) |
| 12 | 4 | cantidad de bloques de datos |
| 16 | 64 | 16 bloques directos |
| 80 | 4 | bloque indirecto (0 si no hace falta) |

El bloque indirecto es un arreglo de 128 números de bloque (`u32`) y
se usa a partir del bloque 17. Un archivo llega a 16 + 128 = 144
bloques = **73728 bytes (72 KiB)**; escribir más da el código 9. Un
archivo de 64 KiB usa 128 bloques de datos, el indirecto y el inodo.
El bloque de datos es el contenido, sin cabecera: el CRC cubre los
bytes del archivo.

`fs_layout` exige `sizeof(FsIno) == 84`, `kind` en 4, `size` en 8,
`nblocks` en 12, `direct` en 16 e `indirect` en 80.

## Directorio

Un directorio es un inodo de tipo 2 cuyos bloques de datos guardan
entradas de 32 bytes, 16 por bloque, en el orden en que se crearon:

| Offset | Bytes | Contenido |
|---|---|---|
| 0 | 16 | nombre, con cero al final (hasta 15 bytes) |
| 16 | 4 | tipo: 1 archivo, 2 directorio |
| 20 | 4 | bloque del inodo |
| 24 | 4 | tamaño (el del hijo; se actualiza al subir) |
| 28 | 4 | cero |

Un directorio guarda hasta **64 entradas** (4 bloques, todos directos),
más que las 30 que se piden; la 65 da el código 6. Cada
directorio ocupa `ceil(32 * n / 512)` bloques: con 30 archivos son dos.
Un nombre mide 1 a 15 bytes imprimibles (33..126), sin `/`, y no puede
ser `.` ni `..`.

Una **ruta** son nombres separados por `/`, con la barra inicial
opcional y hasta 63 bytes; la profundidad máxima es 8. `/` es la raíz.
Un componente vacío (`a//b`) o un `..` es el código 11.

## Copy-on-write

Escribir reserva bloques libres, los llena y arma un inodo nuevo para
el archivo. Después sube: reescribe el directorio que lo contiene (bloques
de datos e inodo nuevos, con la entrada apuntando al inodo nuevo), luego
el directorio de ese, y así hasta la raíz. Cambiar `/a/b/c/f` escribe
cuatro directorios nuevos y el archivo. Recién al final se publica la
raíz nueva en el otro superbloque.

Qué se libera lo decide un barrido de alcanzabilidad (`fs_gc`) justo
antes de publicar: recorre desde la raíz nueva y desde cada snapshot,
marca todo lo que encuentra, y pone en cero el bit de lo ocupado que no
marcó. Un bloque que todavía cuelga de la raíz viva o de algún snapshot
sigue con el bit puesto y no se vuelve a entregar. Un subárbol que
comparten dos raíces se recorre una sola vez. Si el barrido encuentra un
bloque malo (CRC, inodo roto) no libera nada: es preferible filtrar
espacio que liberar algo que alguien usa.

La única escritura en un bloque ya publicado es la copia vieja del
superbloque, y solo cuando ya hay una copia más nueva.

## Llamadas

| Función | Qué hace |
|---|---|
| `fs_format` | bitmap, raíz vacía, las dos copias del superbloque |
| `fs_create(ruta)` | archivo de tamaño 0 |
| `fs_mkdir(ruta)` | directorio vacío |
| `fs_write(ruta, buf, len)` | reemplaza el contenido; si no existe, lo crea |
| `fs_read(ruta, buf, max)` | bytes leídos, o un código negativo |
| `fs_remove(ruta)` | saca un archivo o un directorio vacío |
| `fs_list(ruta)` | imprime `fs file <nombre>` o `fs dir <nombre>` |
| `fs_stat(ruta)` | imprime tipo, tamaño, bloques, inodo y primer bloque de datos |
| `fs_snapshot(name)` | guarda la raíz actual |
| `fs_read_snap(snap, ruta, buf, max)` | lee esa raíz, no la viva |
| `fs_rollback(snap)` | la raíz viva pasa a ser la del snapshot |
| `fs_snap_remove(snap)` | saca el snapshot y libera lo que solo él mantenía |
| `fs_migrate` | pasa un disco versión 1 a versión 2 en el sitio |
| `fs_scrub` | recorre todo y verifica cada CRC (abajo) |

Los códigos positivos de `fs_write` y compañía, y el valor absoluto de
los de `fs_read`: 1 a 5 son los de ATA y de `blk` (5 es CRC, magic o
número de bloque), 6 sin espacio (disco lleno, o directorio con 64
entradas, o 8 snapshots), 7 no está (o falta un directorio intermedio),
8 superbloque, inodo o directorio malo, 9 no cabe (más de 72 KiB),
11 nombre malo o repetido, 12 disco versión vieja (`fs old version`),
13 es un directorio cuando se esperaba un archivo o al revés,
14 directorio no vacío.

## Shell

Las rutas van con `/`; `fs write /a/b/f hola`.

| Comando | Qué hace |
|---|---|
| `fs format` | `fs format ok` |
| `fs mkdir <ruta>` | `fs mkdir ok` |
| `fs create <ruta>` | `fs create ok` |
| `fs write <ruta> <texto>` | `fs write ok` (el texto es el resto de la línea) |
| `fs cat <ruta>` | `fs live <texto>`, o `fs empty` |
| `fs ls [ruta]` | `fs file <nombre>` o `fs dir <nombre>`, uno por línea, en el orden de creación. Sin ruta: la raíz |
| `fs rm <ruta>` | archivo o directorio vacío. `fs rm ok` |
| `fs snap rm <nombre>` | borra el snapshot y libera los bloques que solo él usaba. `fs snap rm ok`; 7 si no existe. `rm` está reservado: no se puede crear un snapshot con ese nombre (11) |
| `fs migrate` | migra un disco v1 a v2. `fs migrate ok snaps=S files=F`; en un disco que ya es v2, `fs migrate not needed` |
| `fs stat <ruta>` | `fs stat file size=N blocks=K ino=I first=B` (o `dir`) |
| `fs snap <nombre>` | guarda la raíz (hasta 8). `fs snap ok` |
| `fs snap <nombre> <ruta>` | lee la ruta del snapshot: `fs snap <texto>` |
| `fs rollback <nombre>` | `fs rollback ok` |
| `fs scrub` | ver abajo |
| `fs corrupt <ruta>` | pisa un byte del primer bloque de datos con `ata_write`; el sector de metadatos queda con el CRC viejo |
| `fs blocks`, `fs check` | escribe `m` (600 bytes) y lo relee; `check` solo relee |
| `fs bigw <ruta> <kib> [semilla]` | escribe `kib` KiB (1..72) con un patrón que depende del bloque y de la semilla; imprime `fs big w size=N crc=0x...` |
| `fs bigr <ruta> [semilla]` | lo lee y compara con el patrón: `fs big r size=N crc=0x... ok` (o `bad`) |
| `fs leak` | marca como usado un bloque libre que nadie apunta (para probar el scrub) |
| `fs unmark <n>` | marca libre el bloque `n`, esté en uso o no (para probar el scrub) |

Una lectura de un bloque con CRC malo imprime `fs corrupt detected`
(`fs cat`, `fs snap n ruta`) o `fs fail 5` (`fs bigr`). Un error de
fs sale como `fs fail <código>`; el 12 sale como `fs old version`.

## Scrub

`fs scrub` monta el disco, lee los dos superbloques y recorre todo lo
alcanzable desde la raíz viva y desde cada snapshot: cada inodo, cada
bloque indirecto, cada bloque de datos y cada bloque de directorio,
con `blk_read` (que verifica magic, número y CRC). Después cruza lo
alcanzado con el bitmap. Un bloque compartido se cuenta una vez.

| Línea | Qué significa |
|---|---|
| `fs scrub ok bloques=N` | sin problemas. `N` son los bloques distintos verificados, contando los dos superbloques |
| `fs scrub bad bloque=N` | el bloque `N` no pasó: CRC, magic o número malo, un inodo roto, un puntero fuera del disco, o un bloque que alguien usa pero el bitmap da por libre. Sale una línea por bloque (hasta 16) |
| `fs scrub leak N` | el bloque `N` está marcado como usado y nadie lo apunta (hasta 16 líneas) |
| `fs scrub fail problemas=K bloques=N` | cierra la corrida cuando hubo algún `bad` o `leak`. Si no hay problemas, la última línea es la de `ok` |

Si el inodo o el bloque de directorio no se pueden leer, el barrido no
baja a lo que cuelga de él: esos bloques no se cuentan ni se reportan.
Un disco de versión 1 o sin formato no se recorre (`fs old version`,
`fs fail 8`).

## Migración v1 a v2

`fs migrate` convierte en el sitio un disco versión 1: directorio plano de
hasta 7 archivos de hasta 8 bloques (magic `ADIR`, entradas de 64 bytes),
la raíz viva y hasta 8 snapshots. Un bloque de datos v1 es el contenido, igual
que en v2, así que **se reusa sin copiarlo**: cada archivo gana un inodo
(`AINO`) que apunta a sus bloques y cada raíz gana un directorio v2 con
las mismas entradas y en el mismo orden.

Pasos, en este orden:

1. Monta la copia v1 viva (la de mayor generación con magic, versión 1 y CRC).
   Si algún superbloque ya es v2, no hace nada (`fs migrate not needed`); si
   no hay ninguno, `fs fail 8`.
2. Valida **todas** las raíces sin escribir: magic del directorio, hasta 7
   entradas, nombres que v2 acepta (1 a 15 bytes imprimibles, sin `/`, ni `.`
   ni `..`, no repetidos), tamaño coherente con la cantidad de bloques y cada
   bloque de datos legible con su CRC. Marca en el bitmap todo lo que usan,
   así lo que se asigne después no pisa un bloque en uso aunque el bitmap
   viejo lo diera por libre.
3. Escribe inodos y directorios v2 solo en bloques libres. Un archivo con el
   mismo tamaño y los mismos bloques que otro ya convertido comparte su
   inodo, y una raíz idéntica a otra (un snapshot sin cambios desde entonces)
   comparte su directorio: lo que v1 compartía sigue compartido.
4. Apunta la raíz y cada snapshot a su directorio v2, libera con `fs_gc` los
   directorios v1 que quedaron sin dueño y publica el superbloque v2 con la
   generación siguiente en la otra copia.
5. Reescribe la copia v1 vieja como v2 con la generación anterior. Así un
   disco migrado no conserva ningún superbloque v1 que pudiera volver a
   montarse como viejo.

Hasta el paso 4 el disco sigue siendo v1 y válido: ningún bloque v1 se toca y
el superbloque no cambia. Si algo falla o se corta la luz antes de publicar,
a lo sumo quedan bloques v2 sueltos que v1 da por libres. Códigos de
`fs migrate`: 5 un bloque con CRC malo, 6 no hay lugar para los inodos, 8 no
hay fs o la estructura v1 está rota, 11 un nombre que v2 no acepta (v1 no
validaba los caracteres), más los de ATA. El comando no renombra ni salta
nada: o migra todo o no toca nada.

El tope de bloques sigue siendo 1024. Una migración con 9 raíces de 7
archivos necesita, en el peor caso, 63 inodos y 18 bloques de directorio
libres.

## Qué no hace

- No migra de v2 a v1 (no hay vuelta atrás una vez publicado).
- No hay locks. Los buffers del fs son globales: el shell está bloqueado
  mientras corre `zone exec` o `zone pair`, pero dos procesos de `zone pair`
  que escriban a la vez entran al fs por syscall uno tras otro, sin
  reentrar (un cambio de proceso no ocurre dentro de la syscall).
- No guarda fechas, permisos ni nombres de más de 15 bytes.
- `fs snap rm` libera por alcanzabilidad (`fs_gc`): si el barrido
  encuentra un bloque malo no libera nada y el espacio se filtra hasta que
  el disco se repare.
- El barrido de `fs_gc` lee todos los directorios e inodos alcanzables en
  cada escritura: cuesta tiempo con muchos archivos.

## Prueba

`make qemu-fs2-test` (también dentro de `make qemu-test`) corre
`tests/qemu_fs2_test.sh` en un disco nuevo: mkdir de tres niveles, un
archivo de 64 KiB con el mismo checksum al escribir y al leer, 30
archivos en un directorio, snapshot + cambio profundo + rollback, un
snapshot que sostiene un archivo borrado, reinicio de QEMU con el mismo
`data.img`, un sector de datos y uno de inodo pisados desde afuera que
`fs scrub` nombra, un `leak` y un bloque libre en uso, y un disco
versión 1 que da `fs old version`. La historia corta de la etapa 5
(formato, `a` con `v1`, snapshot `s1`, `a` con `v2`, rollback, dos
bloques, reinicio, `fs corrupt`) sigue en `tests/qemu_shell_test.sh`.

## Prueba FS-03

`make qemu-fs3-test` (también dentro de `make qemu-test`) corre
`tests/qemu_fs3_test.sh`. El disco v1 se arma con `scripts/mkv1.c` (C, sin
Python): escenarios `std` (2 snapshots, un archivo que solo vive en un
snapshot, uno vacío, uno de 8 bloques, 7 archivos vivos), `full` (8
snapshots, 9 raíces), `badname` (un archivo `x/y`) y `badcrc` (un bloque
pisado). Comprueba, con las cuentas hechas a mano:

- v1: `fs ls`, `fs write`, `fs scrub` y `fs snap` dicen `fs old version` y no
  cambian el disco. `fs migrate` da `files=10` y `scrub ok bloques=36` (std)
  o `files=15` y `bloques=50` (full); los dos superbloques quedan en v2;
  texto, 600 bytes y 4 KiB (con el CRC que calculó `mkv1`) y los archivos de
  cada snapshot, intactos; sobrevive a un reinicio; el segundo `migrate` no
  hace nada; `badname` y `badcrc` se rechazan (11 y 5) con los superbloques
  byte a byte iguales.
- `fs snap rm`: tres snapshots que comparten bloques entre sí y con el vivo
  (archivos de 20 KiB con bloque indirecto). Borrarlos libera 2, 44 y 44
  bloques (los exclusivos de cada uno); `fs rollback` a lo que quedó trae los
  archivos intactos después de escribir un archivo grande encima; el scrub
  final (116) coincide con un disco de control con el mismo contenido y sin
  snapshots. Ocho snapshots, el noveno falla (6), borrar uno de en medio
  libera el lugar.

Con un segundo argumento (o `V1_KERNEL_IMG`) apuntando a la imagen de un
kernel anterior a FS-02 (`git worktree add <dir> d122028^` y `make all
COPIHUE=<copihue>`), agrega la sección D: ese kernel v1 real lee el disco de
`mkv1` (valida el formato del generador) y escribe un disco v1 que el kernel
nuevo migra.
