# Ejecutable plano

Lapageria rosea es el nombre científico del copihue; antes AtomicOS.

Un programa de anillo 3 es un archivo del disco de datos. La cabecera
mide 16 bytes y el código va justo después. Little-endian.

| Offset | Bytes | Contenido |
|---|---|---|
| 0 | 4 | magic `AXE1` (`41 58 45 31`) |
| 4 | 4 | tamaño del código, en bytes |
| 8 | 8 | punto de entrada, dirección virtual |

`Axe` mide 16. `axe_layout` exige `sizeof(Axe) == 16`, tamaño en 4
y entrada en 8. Un dword alto distinto de cero no cae en la página.

`exec` copia el código a `0x400000` y la pila a `0x401000`, en un PML4
nuevo (el mismo camino que `sched`: `build_proc` y `sched_go`). El
punto de entrada tiene que caer en esa página de código. El programa
vuelve al shell con el syscall 5 (`exit`). El syscall 1 escribe un
carácter, el mismo `write` de `user`.

El archivo no puede pasar de 4096 bytes (8 bloques). La cabecera ocupa
16, así que el código llega hasta 4080. Tamaño 0, tamaño mayor que
4080, tamaño mayor que los bytes leídos, magic distinto o entrada
fuera de la página: el shell imprime el error y sigue. No se cuelga.

| Línea | Causa |
|---|---|
| `exec fail 7` | el archivo no está |
| `exec fail N` | otro código de `fs_read` / `fs_write` (1..5 ATA y bloques, 6 sin espacio, 8 superbloque, 9 no cabe, 11 nombre) |
| `exec corrupt` | `fs_read` devolvió 5: magic, número o CRC del bloque |
| `exec bad magic` | los 4 bytes no son `AXE1` |
| `exec bad size` | cabecera corta, tamaño 0, más de 4080, o más largo que el archivo |
| `exec bad entry` | la entrada no cae en `0x400000` .. `0x400000+tamaño` |
| `exec ok` | el proceso hizo `exit` y volvió el shell |

## AXE2: programas de varias páginas (EX-01)

Un AXE1 es una sola página de código. Un AXE2 trae de 1 a 16 páginas (64 KiB)
de imagen, con el texto de solo lectura y los datos escribibles. La cabecera
mide 32 bytes, little-endian, y la imagen va justo después:

| Offset | Bytes | Contenido |
|---|---|---|
| 0 | 4 | magic `AXE2` (`41 58 45 32`) |
| 4 | 4 | bytes de imagen en el archivo (1 a 65536) |
| 8 | 8 | punto de entrada, dentro del texto |
| 16 | 4 | bytes de texto: el principio de la imagen, redondeado hacia arriba a páginas |
| 20 | 4 | tamaño en memoria (de lo que hay en el archivo hasta 65536): lo que pasa del archivo queda en cero (bss) |
| 24 | 8 | reservado, en cero (EX-02: si no lo está, `exec bad size`) |

Las páginas de texto quedan presentes, de usuario, de solo lectura y
ejecutables (`5`). Las demás de la imagen y la de bss son de lectura y
escritura, sin ejecución. Se carga con `build_image` (`sched.lap`) en el mismo
PML4 por proceso que un AXE1, y `exec`, `exec2` y `zone exec` / `zone pair`
eligen una u otra por el magic.

### Distribución de memoria de usuario

| Región | AXE1 (legado) | AXE2 |
|---|---|---|
| Imagen | `0x400000`, 1 página, solo lectura y ejecutable | `0x400000`, 1 a 16 páginas; texto RX, datos y bss RW sin ejecución |
| Página de E/S | `0x401000` (compartida con la pila) | `0x410000`, sola |
| Pila | `0x401000`..`0x402000`, tope `0x402000` | `0x411000`..`0x412000`, tope `0x412000` |
| Páginas de la syscall 8 | desde `0x402000` | desde `0x412000` |
| Nombre de las syscalls 6, 7 y 27 | `0x401800` | `0x410800` |
| Datos de las syscalls 6 y 7 | `0x401C00` | `0x410C00` |

Los búferes de E/S dejaron de ser direcciones del kernel: el kernel los busca
en `uio_base()` (`proc_io` del proceso en curso: `0x401000` si es un AXE1, la
página de E/S si es un AXE2), así que los programas que ya existen no
cambian. Los rangos que un programa pasa al kernel (UDP, TCP, trazas) se
validan región por región (`uptr_range_ok`, `udp.lap`): un rango puede
cruzar de una página a la siguiente si están pegadas, pero no un hueco
(entre el fin de la imagen y `0x410000`), ni escribir en el texto, ni pasar
del tope de la pila o de las páginas pedidas. Un proceso toma hasta 32 páginas
(el máximo de un AXE2 es 16 de imagen + 2 + 4 de tablas).

Un AXE2 válido que no cabe en el cupo de su zona falla con `zone fail 6` sin
dejar páginas tomadas. `grande` (4 páginas de imagen) toma 10 páginas, que son
las que devuelve al salir (`freed=10`): 3 tablas (PML4, PDPT, PD), 1 tabla de
páginas (`0x400000` y `0x410000` comparten una), 4 de imagen, la de E/S y la
pila.

| Línea | Causa |
|---|---|
| `exec bad size` | cabecera de menos de 32 bytes, tamaño 0 o mayor que 65536 o que el archivo, tamaño en memoria menor que el del archivo o mayor que 65536, o texto 0 o mayor que el tamaño |
| `exec bad entry` | la entrada no cae en `0x400000` .. `0x400000+texto` |

### Salida por líneas

La syscall 1 escribe un carácter. Con dos procesos y el PIT repartiendo la
CPU, sus líneas se mezclaban a mitad de palabra. Desde EX-01 los procesos
que carga `exec` (y `exec2`, `zone exec`, `zone pair`) juntan sus caracteres
y los sacan de una vez al llegar un `\n` (o a los 128 bytes), con
interrupciones apagadas, y el resto se vacía antes de cualquier mensaje del
kernel sobre ese proceso (salida, falla, muerte). Las demos de `sched`, `nx`
y `hh` siguen con salida carácter a carácter: la prueba de `sched` usa la
mezcla de sus letras como evidencia de que el PIT los alterna.

### `grande`, el programa de prueba

`src/user/grande.lap` (`copihue --flat 0x400000`, 1965 bytes de código) es el
código de un AXE2 de 3 páginas más una de bss. `exec bigplant` lo arma: la
página 1 es el código; las páginas 2 y 3 llevan un patrón que el programa
conoce (`big_pat` en `exec.lap`, `pat` en el programa); la 4 es bss.
`exec bigplant` escribe en la raíz:

| Nombre | Qué es |
|---|---|
| `grande` | AXE2 válido; `big ok` si lee el patrón, la bss en cero, escribe y lee de vuelta las 3 páginas de datos, y deja y recupera el archivo `gdat` con las syscalls 6 y 7 (nombre y datos en `0x410800` y `0x410C00`) |
| `grandew` | el mismo con 2 páginas de texto: su escritura en la segunda cae en solo lectura y el kernel lo mata (`user killed pid=1 vec=14 err=0x7`) |
| `gbad1` | tamaño en memoria de 65537 |
| `gbad2` | texto 0 |
| `gbad3` | entrada en la página de datos |
| `gbad4` | archivo más corto que el tamaño de la cabecera |

`tests/qemu_big_test.sh` (`make qemu-big-test`, y parte de `make qemu-test`)
corre todo eso, `exec2 grande hola` (un AXE2 y un AXE1 a la vez) y
`zone exec` de `grande` en una zona de 16 páginas (sin fugas) y en una de 8
(`zone fail 6`).

## Empacar un AXE2 con mkaxe.sh (EX-02)

```
scripts/mkaxe.sh [-d datos.bin] [-b bss] payload.bin salida.axe salida.lap [funcion]
```

Sin opciones y con un payload de 1 a 4080 bytes sale un AXE1, como siempre.
Sale un AXE2 si el payload pasa de 4080 bytes o si se pide `-d` o `-b`:

| Parte | Dónde queda |
|---|---|
| `payload.bin` (texto) | principio de la imagen; el campo `text` de la cabecera es su largo; se rellena con ceros hasta la página |
| `-d datos.bin` | en la primera página después del texto; cuenta como imagen en el archivo |
| `-b bss` | bytes en cero detrás de los datos, o en la página siguiente al texto si no hay datos (la bss no puede compartir página con el texto, que es de solo lectura); no ocupa archivo |

El campo `mem` es todo eso sumado y la imagen no puede pasar de 64 KiB (16
páginas); `mkaxe.sh` rechaza lo que se pase, un payload vacío, datos vacíos o
inexistentes y una bss que no es un número. El `.lap` que genera limpia el
buffer que le pasan y solo escribe las palabras no nulas: una página de datos
casi vacía cuesta poco kernel, una llena unos 5 bytes por byte.

Ejemplo (el Makefile lo hace así para `pag2` y `atk2`): `copihue --flat
0x400000 -o pag2.bin src/user/pag2.lap` y `mkaxe.sh -d pag2.dat -b 4096 pag2.bin
pag2.axe pag2_img.lap pag2_fill`. El compilador no emite datos ni bss en `--flat`
(`docs/PEDIDOS_COPIHUE.md`): `pag2.dat` se arma con `printf` y `dd`, y el programa
direcciona sus páginas con constantes (`0x401000` datos, `0x402000` bss).

`exec axe2plant` escribe en la raíz:

| Nombre | Qué es |
|---|---|
| `pag2` | texto + 1 página de datos (`SEG2` en el byte 0, `DE AD BE EF` en el `0x800`, `Z` en el último) + 1 de bss. `exec pag2` imprime `pag2 ok`; toma 9 páginas |
| `atk2` | texto de `src/user/atk2.lap`, 1 página de datos con un `ret` (`0xC3`) en el byte 0, 1 de bss |
| `atk2w` | `atk2` con 2 páginas de texto: la segunda, que en `atk2` es de datos, es de solo lectura |

`exec hdrcheck` arma `pag2` en memoria, le estropea la cabecera de a una (28
casos) y pasa cada una por `exec_hdr`, la función que usan `exec`, `exec2` y
`zone exec`. Imprime `hdr <caso> ok|bad size|bad entry|bad magic`; lo esperado
está en `tests/qemu_axe2_test.sh`. Rechaza: tamaño de imagen 0, 65537, `0xFFFFFFFF`
o más largo que el archivo; memoria menor que la imagen, 0, 17 páginas o
`0xFFFFFFFF`; texto 0, más largo que la imagen o `0xFFFFFFFF`; reservado
distinto de cero; archivo de 15, 31 o 32 bytes o con un byte de menos; entrada
bajo la imagen, justo al final del texto, en datos, en la página de E/S, en el
kernel, en la mitad alta o con el bit 63; magic `AXE3`.

### Ataques de anillo 3 contra un AXE2

`atk2` (en una zona; el modo está en el archivo `q`) hace un ataque por corrida:

| Modo | Ataque | Falla esperada (`user killed`) |
|---|---|---|
| `a` `b` | escribir el primer y el último byte del texto | `vec=14 err=0x7` en `0x400000`, `0x400fff` |
| `c` `d` `e` `f` `q` | ejecutar datos, bss, página de E/S, pila, página de la syscall 8 (con un `ret` de destino) | `vec=14 err=0x15` en `0x401000`, `0x402000`, `0x410000`, `0x411000`, `0x412000` |
| `g` `h` | leer, escribir justo después de la bss | `err=0x4`, `err=0x6` en `0x403000` |
| `i` `j` `k` | leer el hueco antes de la E/S, sobre la pila, bajo la imagen | `err=0x4` en `0x40ffff`, `0x412000`, `0x3fffff` |
| `s` | desbordar la pila hacia abajo | `err=0x6` en `0x40fxxx` (cruza antes su propia E/S) |
| `l` `m` `n` | leer el kernel, escribir la mitad alta, leer `0x1000` | `err=0x5`, `0x7`, `0x5` |
| `o` | dirección no canónica | `#GP` o `#PF`, según el QEMU |
| `w` en `atk2w` | escribir la segunda página (texto) | `err=0x7` en `0x401000` |
| `w` en `atk2` | escribir la segunda página (datos) | nada: `atk2 w ok` (control) |
| `p` | 13 punteros malos en la syscall 23 op 5 (texto, hueco, fin de imagen, tope de pila, kernel, enormes) | nadie muere: `-14` y el texto igual; 5 rangos válidos que cruzan de página funcionan. Necesita `zone trace` (la syscall 23 está fuera de la máscara de una zona nueva) |

Todos los que matan dejan `zone ls` con `pag=0` y sin procesos.

## De dónde sale el archivo

`src/user/hola.lap` es el programa (`copihue --flat 0x400000`).
`scripts/mkaxe.sh` (sh, `od` y `awk`; sin Python) le pone la cabecera
y genera `exec_img.lap`, un `exec_fill` con esos bytes.

No armamos `data.img` en el host. El superbloque, el CRC y el
directorio ya están en el kernel, y `make qemu-test` parte de un disco
en cero: otra copia del formato se desfasaría. `exec plant` escribe
con `fs_write` tres archivos:

| Nombre | Qué es |
|---|---|
| `hola` | imagen válida; imprime `desde disco` |
| `malo` | el mismo archivo con el primer byte del magic en cero (el CRC del bloque sí calza) |
| `gordo` | magic bueno y tamaño 65535 |

`exec hola` no salta a la copia embebida: vuelve a leer el archivo con
`fs_read`. Si se pisó un byte del bloque (`fs corrupt hola`), la
lectura falla por checksum y no hay proceso.

`exec plant` escribe `hola`, `malo` y `gordo` en la raíz, después de `fs blocks`
(el directorio de la raíz guarda hasta 64 entradas; ver fs.md).
