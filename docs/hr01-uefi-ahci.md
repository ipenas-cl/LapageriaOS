# HR-01: arranque UEFI y disco AHCI/NVMe (primera tajada)

> **HR-02 ya superó parte de esto** (ver `docs/hr02-uefi-ahci.md`): el stub de esta
> página es ahora `src/uefi/loader.lap` y **sí carga el kernel** en QEMU + OVMF, y
> AHCI **escribe** un sector. Lo que sigue describe HR-01 tal como quedó entonces;
> la sección «Qué falta» está desactualizada en los puntos UEFI (1) a (4) y en la
> escritura AHCI.

Esta tajada empieza el camino a hardware moderno **sin tocar** el camino
BIOS + ATA: la imagen `build/lapageriaos.img`, el cargador de dos etapas y el
disco de datos IDE siguen igual, y `make qemu-test` los sigue ejerciendo.

## Qué arranca y qué no

| Pieza | Estado |
|---|---|
| Kernel por BIOS (MBR, etapa 2, INT 13h) + ATA PIO | Sin cambios. Es lo único que arranca el kernel. |
| UEFI | **Un stub**: una aplicación EFI en Copihue que OVMF carga y ejecuta. **No carga el kernel.** |
| AHCI | Lectura de un sector por DMA de un disco SATA (comando `ahci`). Sin escritura, sin interrupciones. |
| NVMe | Solo detección del controlador (comando `nvme`). Sin colas ni lectura. |

### UEFI: el stub

`src/uefi/stub.lap` (Copihue, `copihue --flat 0x1000`) es independiente de la
posición: sin globales, sin cadenas de Copihue; los datos están en bloques
`data` y se alcanzan con `lea reg, [rel etiqueta]`. Hace tres cosas:

1. escribe `LapageriaOS UEFI stub ok` por COM1 (puerto `0x3F8`);
2. la escribe por `ConOut->OutputString` del firmware (UTF-16);
3. apaga la máquina con `RuntimeServices->ResetSystem(EfiResetShutdown)`.

Tres `naked fn` hacen el paso de la ABI Microsoft x64 del firmware (`rcx`,
`rdx`, `r8`, `r9`, 32 bytes de sombra) a la System V de Copihue; alinean la
pila a 16 antes de cada llamada al firmware.

`src/uefi/pe.asm` (nasm, `-f bin`) solo empaqueta: cabeceras PE32+ (máquina
`0x8664`, subsistema 10 = aplicación EFI, entry en RVA `0x1000`), `.text` con el
stub y un `.reloc` con un bloque vacío. Es el único código que no es Copihue en
esta ruta y no contiene lógica. `make uefi-image` deja el resultado en
`build/uefi/esp/EFI/BOOT/BOOTX64.EFI`; esa carpeta es la ESP (QEMU la presenta
como FAT con `fat:rw:`, sin `mkfs`).

#### Probar en QEMU

El Makefile busca el firmware en rutas conocidas (Homebrew, Debian/Ubuntu,
Fedora, Arch). Si no lo encuentra, `make qemu-uefi` y `make qemu-uefi-test`
**fallan con un mensaje claro** y no dan nada por bueno.

```bash
make qemu-uefi            # arranca el stub; se ve la línea y QEMU termina solo
make qemu-uefi-test       # lo mismo, sin pantalla, y exige la línea por COM1
make uefi-pe-test         # solo la comprobación estática del PE32+ (sin QEMU)

# Firmware a mano:
make qemu-uefi OVMF_CODE=/ruta/OVMF_CODE.fd OVMF_VARS=/ruta/OVMF_VARS.fd
make qemu-uefi OVMF_BIOS=/ruta/OVMF.fd       # un solo archivo (-bios)
```

La línea de QEMU que arma el Makefile (con dos `pflash`):

```bash
qemu-system-x86_64 -machine q35 -m 256 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=OVMF_CODE.fd \
    -drive if=pflash,format=raw,unit=1,file=vars.fd \
    -drive format=raw,file=fat:rw:build/uefi/esp -net none -nographic -no-reboot
```

Debian/Ubuntu: `apt-get install ovmf` (`/usr/share/OVMF/OVMF_CODE_4M.fd`).
Homebrew: el paquete `qemu` trae `share/qemu/edk2-x86_64-code.fd` (solo código:
va como `pflash`, no con `-bios`).

`make qemu-test` corre `uefi-pe-test` siempre y `qemu-uefi-test` solo si hay
firmware; si no lo hay imprime `SKIP qemu-uefi-test: ...` en voz alta. El CI
(`ubuntu-latest`, sin `ovmf`) por eso solo corre la parte estática.

### AHCI: lectura

`src/kernel/copihue/ahci.lap`, comando `ahci [lba]`:

- busca en el bus 0 un dispositivo PCI de clase `01:06:01`;
- mueve el BAR5 (ABAR) a `0x10100000`, dentro del primer GiB
  que el arranque tiene mapeado (el firmware lo deja arriba de 3 GiB), y activa
  memoria y bus master con INTx apagado;
- elige el primer puerto implementado con un disco SATA (`DET=3`, firma `0x101`);
- arma lista de comandos, FIS recibido y tabla de comando en una página baja
  (< 2 MiB, identidad) y lee `IDENTIFY` y `READ DMA EXT` (LBA48, un sector);
- sondea `PxCI` con tope de 10 s del PIT. Códigos: 0 listo, 1 tiempo, 2 error del
  disco, 3 sin controlador o sin disco, 4 LBA fuera de rango, 5 BAR/DMA inutilizable.

Salida (las líneas que mira `tests/qemu_ahci_test.sh`):

```
ahci found 0x00008086:0x00002922 abar=0x10100000 pi=0x0000003f
ahci disk port=0 sectors=2880
ahci read lba=0 crc=0xf480857b tail=0x000055aa
```

`crc` es el CRC-32 ISO-HDLC del sector (el de `blk.lap`). La prueba lo compara
con el que calcula el anfitrión con `gzip` del mismo sector de la imagen, para
los sectores 0 y 9 (el primero del kernel), y exige `ahci read fail 4` fuera
del disco, que `disk` (ATA + blk) siga verde con el controlador presente, y
`ahci none` sin él.

```bash
make qemu-ahci-test     # tests/qemu_ahci_test.sh; también corre dentro de make qemu-test

qemu-system-x86_64 -cpu qemu64 -drive format=raw,file=build/lapageriaos.img \
    -drive file=build/data.img,format=raw,if=ide,index=1 \
    -device ahci,id=ahci -drive id=sata0,file=disco.img,format=raw,if=none \
    -device ide-hd,drive=sata0,bus=ahci.0 -display none -serial stdio
# en el shell: ahci 0
```

### NVMe: detección

`src/kernel/copihue/nvme.lap`, comando `nvme`: busca clase `01:08:02`, mueve el
BAR0 a `0x10200000`, lee `VS` y `CAP` (MQES, TO). QEMU lo expone como
`1b36:0010`. `tests/qemu_ahci_test.sh` lo comprueba con `-device nvme`.

```
nvme found 0x00001b36:0x00000010 vs=0x00010400 mqes=2047 to=15
```

## Qué falta

**UEFI.** El kernel sigue siendo un binario plano que carga `stage2.lap` con
INT 13h y que entra en modo largo desde modo real. Para arrancarlo por UEFI hace
falta: (1) en el stub, `LocateProtocol`/`OpenVolume` para leer `kernel.bin` de la
ESP (o incrustarlo); (2) `GetMemoryMap` y traducirlo al formato E820 que ya lee
`pmm.lap` (hoy lo guarda la etapa 2 en `0x8000`); (3) `ExitBootServices`; (4)
armar los mismos GDT y tablas de páginas que deja la etapa 2 (CR3 `0x1000`,
ventana alta) y saltar a `0x400000`, con el kernel enlazado donde el firmware
permita ponerlo (hoy exige físico `0x400000`; puede estar ocupado); (5) que el
kernel no dependa del PS/2/VGA de BIOS (hoy VGA texto en `0xB8000`: bajo UEFI hay
que usar el framebuffer GOP). (6) Firma/Secure Boot no se tocó. (7) El CI no
instala `ovmf`: el arranque UEFI no corre ahí.

**AHCI.** Sin escritura (`WRITE DMA EXT`), sin varios sectores por comando, sin
`blk`/`fs` encima (el sistema de archivos sigue en el IDE esclavo), sin
interrupciones (se sondea), sin NCQ, sin hot-plug, sin más de un puerto a la vez,
sin pasar PRDT de más de una entrada. En hardware real falta el *BIOS/OS handoff*
(`BOHC`), el reinicio del HBA, la espera de `COMRESET` y manejar `PxSERR`/`CPS`;
solo se probó contra el `ich9-ahci` de QEMU (`8086:2922`). El controlador se busca
solo en el bus 0 y el BAR5 se coloca a mano (sin leer el mapa de recursos del
firmware). Solo discos con firma `0x101` (no ATAPI). El buffer DMA tiene que
estar bajo 2 MiB.

**NVMe.** Solo detección. Falta: reiniciar el controlador (`CC.EN`), cola de
administración (ASQ/ACQ), `Identify`, crear colas E/S, `Read`, y bus master para el
DMA; PRP para más de una página; interrupciones (MSI-X) o sondeo del *phase tag*.
Es la siguiente tajada.

**Camino común.** Hoy el disco que ve el kernel es `ata_*`. Poner AHCI/NVMe detrás
de `blk.lap` pide una capa de dispositivos de bloque (hoy `blk_*` llama a `ata_*`
directo).

## Pedidos a Copihue

Ver `docs/PEDIDOS_COPIHUE.md`, sección HR-01. Siguen abiertos, ninguno se da por
cerrado.
