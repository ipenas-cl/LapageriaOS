# Bit NX y W^X

> **SG-02:** desde esta versión la imagen está en el físico `0x400000` (VA `0xFFFFFFFF80400000`), no en `0x10000`; ver [higher-half.md](higher-half.md). Las direcciones de abajo son las de antes.

QEMU arranca con `-cpu qemu64` (`make qemu`, `make debug`, `make qemu-test`, el humo de CI y `scripts/pre-commit.sh`). Ese modelo deja puesto el bit 20 de EDX en la hoja CPUID `0x80000001`. Sin ese bit el kernel no toca el MSR.

`nx_init` corre después de la IDT. Lee el bit, prende EFER.NXE (MSR `0xC0000080`, bit 11) y lo vuelve a leer. En el humo de 10 s y en `make qemu-test` la serie dice `nx efer on`.

La etapa 2 deja dos PD[0] en `0x83`: la identidad baja y la ventana `0xFFFFFFFF80000000`. Cada una es una página de 2 MiB, presente y escribible, que cubre código y datos. Con NXE prendido el kernel parte las dos. Pide dos marcos entre 1 MiB y 2 MiB, escribe 512 entradas de 4 KiB en cada tabla y guarda `tabla|3` en PD[0] (`0x3000`) y en la PD alta (`0x5000`). El bit 63 va solo en las hojas. Un directorio con ese bit ensuciaría la dirección, porque `>>` es aritmético. Después pone CR0.WP (bit 16), recarga CR3 y retira la identidad de la imagen. La serie dice `nx wp on` y `hh on text=0xffffffff80010000`.

`.text` termina alineado a 4096 (`data nx_text_pad { align 4096; }`). En este binario el enlace es `0xFFFFFFFF80010000`. `_start` carga `__bss_start` `0xFFFFFFFF80036850` y `__bss_end` `0xFFFFFFFF8003BEFC`. `kernel.bin` termina en el físico `0x3684F`. `nx_ranges` resta `0xFFFFFFFF80000000` y trabaja con el físico:

| Símbolo | Virtual | Físico |
|---|---|---|
| `__text_start` | `0xFFFFFFFF80010000` | `0x10000` |
| `__text_end` | `0xFFFFFFFF80035000` | `0x35000` |
| `__data_start` | `0xFFFFFFFF80035000` | `0x35000` |
| `__data_end` | `0xFFFFFFFF8003684F` | `0x3684F` |
| `__bss_start` | `0xFFFFFFFF80036850` | `0x36850` |
| `__bss_end` | `0xFFFFFFFF8003BEFC` | `0x3BEFC` |

Hay dos tablas de 4 KiB. Las páginas cuyo físico cae entero en `[0x10000, 0x35000)` quedan presentes, sin escritura y ejecutables en las dos (37 páginas). El resto de esos 2 MiB lleva el bit 63. Después de CR0.WP, `hh_retire` borra de la tabla baja `0x10000`..`0x3C000`. La auditoría clasifica por el físico de la hoja, así que `.text` cuenta una vez. `.data` y `.bss` comparten la página física `0x36000`. Las dos son NX. No queda ninguna hoja de 2 MiB: la auditoría imprimió `huge=0`. La imagen anterior, enlazada en `0x10000`, tenía `__text_end` `0x33000` (35 páginas) y `__bss_end` `0x39cac`.

El código de usuario en `0x400000` queda presente, de usuario, sin escritura y sin NX. La pila (`0x401000`), la página privada (`0x500000`), el heap de la zona y el MMIO de la red llevan el bit 63. Durante la copia el código está NX; al terminar se remapea sin escritura y sin NX.

El comando `nx` corre en la prueba después de `pf`, así que ya existe la página de demanda en `0x200000`. La rama sobre Copihue v0.29.4 imprimió:

```
nx map text 0x00010000 0x00033000 data 0x00033000 0x0003463d bss 0x00034640 0x00039cac
nx ok efer
nx ok wp
exception: vector 14 #PF page fault err=0x00000011 cr2=0x00033000
nx ok fetch err=0x00000011 cr2=0x00033000
exception: vector 14 #PF page fault err=0x00000003 cr2=0x00010000
nx ok write err=0x00000003 cr2=0x00010000
exception: vector 14 #PF page fault err=0x00000015 cr2=0x00401000
nx ok sched
exception: vector 14 #PF page fault err=0x00000015 cr2=0x00500000
nx ok user stack err=0x00000015 cr2=0x00401000
nx ok user data err=0x00000015 cr2=0x00500000
nx ok audit wx=0 leaves=513 code=35 nx=478 huge=0
```

El fetch es de una página presente (bit 0) y de instrucción (bit 4). La escritura en `.text` es presente y de escritura (bits 0 y 1), con CR0.WP. El usuario que ejecuta su pila o sus datos es presente, anillo 3 e instrucción (bits 0, 2 y 4). El segundo proceso alcanza a imprimir `nx ok sched` antes de su `#PF`. El shell sigue. `35 + 478 = 513`: 512 hojas del primer 2 MiB más la página de `pf`. `wx=0`.

Esa corrida de `make qemu-test` imprimió `ok   nx fetch=0x00000011 write=0x00000003 user=0x00000015 audit wx=0 leaves=513 code=35 nx=478`.

En la imagen anterior (v0.31.0, kernel en `0x10000`), tres `make qemu-test` seguidos terminaron en 0 e imprimieron la misma línea: `ok   nx fetch=0x00000011 write=0x00000003 user=0x00000015 audit wx=0 leaves=513 code=35 nx=478`.

En esta imagen la cuenta cambia porque la ventana alta suma otras 512 hojas y `hh_retire` saca las 44 de la imagen en la tabla baja: 512 − 44 + 512 + la página de `pf` = 981, y 37 de ellas son código. Tres `make qemu-test` seguidos terminaron en 0 e imprimieron `ok   nx fetch=0x00000011 write=0x00000003 user=0x00000015 audit wx=0 leaves=981 code=37 nx=944`. `put_hex` sigue mostrando 32 bits, así que el mapa sale con `0x80010000` y `0x80035000`; la prueba resta `0x80000000` y exige físico `0x10000`. El humo de 10 s con `-cpu qemu64` salió 124 y mostró `nx efer on`, `nx wp on` y `hh on text=0xffffffff80010000`.

Copihue v0.31.0 alcanza para esto: `cpuid` / `cpuid_edx`, `rdmsr` / `wrmsr`, `read_cr0` / `write_cr0`, `read_cr2` y un `<<` de 63 bits guardado en 8 bytes (`mov qword`). El único `as` nuevo de este archivo es `p[0] = (old) as u8`: el byte de `.text` que la sonda iba a escribir. El bit 63 no pasa por ese `as`. No se agregó un pedido ni un `asm()`.
