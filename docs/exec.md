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
