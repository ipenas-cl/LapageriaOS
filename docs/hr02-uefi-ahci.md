# HR-02: UEFI que carga el kernel y AHCI con escritura

Segunda tajada sobre `docs/hr01-uefi-ahci.md`. El camino BIOS + ATA no cambia:
`make qemu-test` lo sigue ejerciendo igual, y el kernel que arranca por UEFI es
**el mismo `build/kernel.bin`** que carga la etapa 2 (535528 bytes, 1046 sectores desde EX-09).

## Qué arranca y qué no

| Pieza | Estado |
|---|---|
| Kernel por BIOS (MBR, etapa 2, INT 13h) + ATA PIO | Sin cambios. |
| Kernel por UEFI | **Arranca en QEMU q35 + OVMF (EDK2 de Homebrew)**: el cargador lee `kernel.bin` de la ESP, sale de los servicios de arranque y salta al kernel, que imprime su banner, lee el mapa de memoria, corre el PIT y atiende el shell por PS/2. Probado por `make qemu-uefi-test`. |
| UEFI en hardware real | **No probado.** Solo OVMF en QEMU. |
| Pantalla bajo UEFI | **No funciona**: el kernel escribe en VGA texto `0xB8000`, que bajo OVMF no se ve (la salida es GOP). La evidencia es COM1 y el teclado PS/2. |
| Disco bajo UEFI | **No en HR-02; resuelto en HR-03** (`docs/hr03-ahci-blk.md`): AHCI es ahora un backend de `blk.lap` y `disk`/`fs` andan bajo q35 + OVMF (`make qemu-uefi-blk-test`). En HR-02 q35 no tenía IDE y `ata_*`/`disk`/`fs` no servían. |
| AHCI | Lectura (HR-01) y **escritura de un sector** (`WRITE DMA EXT` + `FLUSH CACHE EXT`), comando `ahci w <lba> [patrón]`. Un sector por comando, sin NCQ, sin interrupciones. |
| NVMe | Solo detección (sin cambios). |

## AHCI: escritura

`src/kernel/copihue/ahci.lap`:

- `ahci_cmd(0x35, lba)`: pone el bit W (6) en la cabecera de la ranura 0, copia
  `ahci_buf` al búfer de DMA (+0x800 de la página baja) y emite `WRITE DMA EXT`
  (LBA48, un sector). `ahci_cmd(0xEA, 0)` es `FLUSH CACHE EXT`: sin datos y sin
  entrada de PRDT. Sondeo de `PxCI` con el mismo tope de 10 s del PIT.
- `ahci_write(lba, src)`: comprueba el rango (código 4 fuera del disco), escribe
  y vacía el caché. Mismos códigos de retorno que `ahci_read`.
- Shell: `ahci w <lba> [patrón]` escribe `byte[i] = (patrón + i) & 255`, lo relee
  con una orden de lectura y compara byte a byte:

```
ahci write lba=2000 crc=0x61ac8c79
ahci verify lba=2000 crc=0x61ac8c79 ok
```

  `ahci w` **escribe de verdad en el disco SATA que ve el controlador**, sin
  confirmación. El kernel arranca por IDE, así que ese disco no es el de
  arranque, pero tampoco hay protección si el SATA contiene algo que importa.
  Sin controlador imprime `ahci none`.

`make qemu-ahci-test` (también dentro de `qemu-test`) cuelga el SATA como copia
de la imagen de arranque, escribe el LBA 2000 (zona libre, lejos del MBR y del
kernel, que ocupa del LBA 9 al 1046), lo relee con `ahci w` y con `ahci 2000`, lo
sobrescribe con otro patrón, exige `ahci write fail 4` fuera del disco, y con
QEMU parado compara en el anfitrión el sector del archivo con el patrón y el
resto del disco (MBR, etapa 2, kernel) con la imagen original. También exige
`disk` verde con el controlador presente y `ahci w` → `ahci none` sin él.

No se probó: escribir varios sectores por comando, escribir y apagar de golpe
(el `FLUSH CACHE EXT` se emite y QEMU lo acepta, pero no se midió su efecto),
discos de más de 2^32 sectores, ni hardware real.

## UEFI: el cargador

`src/uefi/loader.lap` (antes `stub.lap`; Copihue, `--flat 0x1000`, independiente
de la posición) hace, en este orden. Todo menos el último punto sale por COM1 con
el prefijo `uefi:`:

1. `HandleProtocol(ImageHandle, LoadedImage)` → `DeviceHandle`; `HandleProtocol(…,
   SimpleFileSystem)`; `OpenVolume`; `Open(L"kernel.bin")`. Es la ESP de la que
   salió el propio `BOOTX64.EFI`.
2. Tamaño con `SetPosition(-1)` + `GetPosition` + `SetPosition(0)`. Acepta
   1 byte a 1 MiB (el tope de `KERNEL_MAX_BYTES`).
3. `AllocatePages(AllocateAddress, LoaderData, 512)` en `0x400000` (la página de
   2 MiB del kernel) y `Read` directo ahí.
4. `AllocatePages(AllocateAddress, …, 159)` en `0x1000..0x9FFFF`: tablas de
   páginas, mapa E820, trampolín y pila de stage2.
5. `GetMemoryMap` + `ExitBootServices` con reintento de la clave (hasta 8).
6. Convierte el mapa a E820 en `0x8000` (word con la cantidad, entradas de 24
   bytes en `0x8004`, atributo ACPI = 1): LoaderCode/Data, BootServicesCode/Data y
   Conventional → tipo 1; el resto → tipo 2. Une tramos contiguos del mismo tipo.
   **Máximo 16 entradas** (es lo que `pmm.lap` lee); las que no caben se descartan
   y se imprime `uefi: e820 truncated, entries dropped=…`. Como el mapa viene
   ordenado, lo que se pierde es lo de más arriba. En OVMF q35 de 256 MiB: 102
   descriptores de EFI → 16 entradas, 1 descartada (de más arriba de
   `0xE0000000`; no se imprimió cuál). `pmm.lap` solo usa los primeros 128 MiB.
7. Arma en `0x1000..0x5FFF` las **mismas tablas que `stage2.lap`** (PML4[0] →
   identidad de 0..2 MiB; PML4[511] → PDPT[510] → PD con 0..2 MiB y la imagen del
   kernel, 2 MiB desde `0x400000`, en PD[2]).
8. Copia un trampolín (`efi_tramp`, un `asm()` de Copihue) a `0x7000`, que está
   mapeado por identidad tanto en las tablas del firmware como en las nuevas (el
   código del PE no lo está en las nuevas). El trampolín pone la pila en
   `0x90000`, carga la GDT de stage2 (`0x08/0x10` de 32 bits, `0x18/0x20` de 64),
   `CR3 = 0x1000`, recarga CS con `retfq` y los segmentos con `0x20`, pone
   `RSP = 0xFFFFFFFF80090000` y salta a `0xFFFFFFFF80400000`. Ya se está en modo
   largo con PAE: no cambia de modo. `CR4`, `CR0` y `EFER` quedan como los dejó el
   firmware (`CR4=0x668`, `EFER.NXE` prendido; el kernel prende lo suyo en `nx_init`).

Si un paso falla imprime `uefi: FAIL step=0x.. status=0x..` y apaga con
`ResetSystem`, para que el anfitrión vea un fin y no un cuelgue. Pasos: 1/2
`HandleProtocol`, 3 `OpenVolume`, 4 `Open` (aquí cae una ESP sin `kernel.bin`:
`status=0x800000000000000e`, EFI_NOT_FOUND), 5-7 posición, 8 tamaño fuera de
rango (status = el tamaño), 9 `0x400000` ocupado, 10 `Read`, 11 lectura corta,
12 páginas bajas ocupadas, 13 búfer del mapa, 14 `GetMemoryMap`, 15
`ExitBootServices` sin éxito. **En OVMF 256 MiB los pasos 9 y 12 salen bien**:
`0x400000` y `0x1000..0x9FFFF` estaban libres. Otro firmware u otra
configuración puede ocuparlos; ahí el cargador falla en 9 o 12 con el código de
EFI y **no reubica nada** (el kernel está enlazado a `0x400000` físico).

`src/uefi/pe.asm` sigue siendo solo empaquetado PE32+; ya no fija `.text` en una
página (el cargador pesa 5858 bytes): `.reloc` va en la página que sigue.

### Qué se vio en QEMU

`make qemu-uefi-test` (tests/qemu_uefi_test.sh) exige, en este orden:

- la línea del cargador y `kernel.bin size=` igual al del anfitrión;
- `kernel at=0x00400000` y las páginas bajas reservadas;
- `memmap entries=` y `e820 entries=`, y `ExitBootServices ok`;
- el banner `LapageriaOS 0.8 (x86-64)` **del kernel** por COM1;
- `e820 n=16` y `pmm free=31752 base=0x100000 end=0x8000000` (el `pmm_init` del
  kernel leyó el mapa convertido);
- `timer: ticks=` (el PIT del kernel entrega IRQ0 bajo OVMF);
- `echo uefi-ok` tecleado con `sendkey` por PS/2 y contestado por el shell;
- y una segunda corrida con una ESP **sin** `kernel.bin`: `uefi: FAIL step=0x00000004
  status=0x800000000000000e`, QEMU termina solo y no aparece el banner del kernel.

## Qué falta

- **Disco bajo UEFI.** *(Hecho en HR-03, `docs/hr03-ahci-blk.md`.)* En HR-02 el
  kernel arrancado por UEFI no tenía disco: q35 + OVMF presentan SATA (AHCI), y
  `blk`/`fs` llamaban a `ata_*` directo. Ahora `ahci_*` es un backend de `blk`.
- **Pantalla.** Falta usar el framebuffer GOP (`LocateProtocol(GOP)` antes de
  `ExitBootServices`, pasar base/pitch/formato al kernel y una consola de píxeles).
  Hoy `0xB8000` no se ve.
- **Hardware real.** Nada de esto se probó fuera de QEMU. En hardware faltan, al
  menos: ACPI/APIC (el kernel usa el 8259 y el PIT; funcionó bajo OVMF), teclado
  USB, y que `0x400000` y las páginas bajas estén libres (hoy se falla, no se
  reubica).
- **Mapa E820.** Tope de 16 entradas. No se pasan las tablas ACPI ni las
  direcciones de los servicios de ejecución (`RuntimeServices` no se usa tras salir).
- **Secure Boot / firma.** No se tocó. `BOOTX64.EFI` no está firmado.
- **Dónde está el kernel.** `kernel.bin` se lee de la raíz de la ESP; no
  hay `\EFI\LapageriaOS\`, cargador de configuración ni imagen incrustada.
- **CI.** El workflow no instala `ovmf`: `qemu-test` allí corre solo la
  comprobación estática del PE (`uefi-pe-test`) y imprime `SKIP qemu-uefi-test`.

## Probar

```bash
make qemu-test            # todo, incluye qemu-ahci-test y qemu-uefi-test si hay OVMF
make qemu-ahci-test       # AHCI lectura + escritura
make uefi-image           # build/uefi/esp/{EFI/BOOT/BOOTX64.EFI,kernel.bin}
make qemu-uefi-test       # el kernel arranca por UEFI (exige firmware)
make qemu-uefi            # arranque a mano, ver abajo

# Firmware a mano (el Makefile ya busca Homebrew, Debian/Ubuntu, Fedora, Arch):
make qemu-uefi-test OVMF_CODE=/ruta/OVMF_CODE.fd OVMF_VARS=/ruta/OVMF_VARS.fd
```

`make qemu-uefi` usa `-nographic`: se ve todo por COM1 (cargador y kernel), pero
el teclado de la terminal va al puerto serie y el kernel lee PS/2, así que **no
se puede teclear**; QEMU no termina solo (Ctrl-A X). Para teclear, abre una
ventana (`-display cocoa` o `sdl`) y deja la salida en `-serial stdio`:

```bash
qemu-system-x86_64 -machine q35 -m 256 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    -drive format=raw,file=fat:rw:build/uefi/esp -net none -display cocoa -serial stdio
```

Depuración: `make qemu-uefi-test UEFI_WAIT=300 QEMU_EXTRA="-d int,cpu_reset -D build/uefi/qemu.log"`.
Así se encontraron los dos fallos de la primera versión (borrar solo 640 de los
2560 qwords de las tablas; usar la pila del firmware antes de cambiar CR3).

## Pedidos a Copihue

Ver `docs/PEDIDOS_COPIHUE.md`, sección HR-02. No se parchó el lenguaje.
