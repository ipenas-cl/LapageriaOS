# HR-03: AHCI detrás de `blk.lap` (disco bajo UEFI)

Tercera tajada sobre `docs/hr01-uefi-ahci.md` y `docs/hr02-uefi-ahci.md`. Pin de
Copihue sin cambios: **v0.44.4**. El camino BIOS + IDE no cambia: sigue siendo el
backend por omisión.

## Qué arranca

| Pieza | Estado |
|---|---|
| `blk_read` / `blk_write` / `disk` / `fs` con BIOS + IDE | Igual que antes (`ata ok`, `blk ok`, `blk corrupt detected`; todas las pruebas de `fs` sin tocar). |
| Los mismos sobre el disco SATA, forzado con `blk ahci` | **Probado en QEMU** (BIOS + IDE + AHCI): `qemu-ahci-fs-test`. |
| Los mismos bajo UEFI (q35 + OVMF, sin IDE) | **Probado en QEMU con OVMF**: `qemu-uefi-blk-test`. Sin elegir nada, `blk` cae en AHCI porque el ATA no existe. |
| Sin ningún disco | Falla limpio: `blk fail 3`, `ata fail 3`, `fs fail 3`; el shell sigue (probado en ambos caminos). |

Primera vez que el controlador AHCI (HR-01/HR-02) se ejerce bajo UEFI: el BAR5 se
reubica a `0x10100000`, se arma el puerto y se lee/escribe por DMA con el kernel
cargado por `BOOTX64.EFI`. Funcionó a la primera con OVMF de Homebrew.

## Cómo se elige el backend

`src/kernel/copihue/blk.lap`, al frente:

```
blk_dev      0 ninguno, 1 ATA, 2 AHCI
blk_sectors  capacidad del backend activo (0 mientras no haya uno)
blk_set_dev(d)  fuerza 1 o 2: identify/ahci_init; si falla, el activo no cambia
blk_open()      si ya hay backend, 0; si no, ATA primero y AHCI si no hay ATA
blk_rd / blk_wr  un sector, al backend activo (3 si no hay)
```

`blk_read`/`blk_write` (bloques lógicos: datos en LBA `2n`, metadatos en `2n+1`,
magic `ABLK`, número, CRC-32; código 5 si no calza) no cambiaron de semántica:
solo llaman a `blk_rd`/`blk_wr` en vez de `ata_*`, y el rango sale de
`blk_sectors`. `fs.lap` perdió sus cuatro referencias a `ata_sectors` /
`ata_identify` / `ata_write` (ahora `blk_sectors`, `blk_open`, `blk_wr`).

**Por qué ATA primero y no «si hay AHCI, AHCI».** La propuesta era preferir AHCI
cuando `ahci_init` encuentre disco. No se hizo porque rompe lo que ya anda: en el
camino BIOS de `qemu_ahci_test.sh` el disco SATA es una *copia de la imagen de
arranque* (MBR y kernel en los LBA 0 y 9 en adelante) y `disk` escribiría ahí;
cualquiera que cuelgue un SATA además del disco de datos IDE vería cambiar el
backend sin pedirlo. Con ATA primero, el camino BIOS no depende de lo que haya en
el bus PCI, y en q35 (sin IDE) AHCI se elige solo porque ATA responde 3 al primer
sondeo (estado `0xFF`).

Comando de shell:

```
blk              elige (blk_open) y dice cuál quedó
blk ata          fuerza el esclavo IDE
blk ahci         fuerza el primer disco SATA
```

Salida: `blk dev=ata sectors=2048` / `blk dev=ahci sectors=2048`; si falla, `blk
dev=<el que había>` y `blk fail <código>` (3 sin unidad). `disk` imprime `ata ok`
con el backend ATA (línea que ya miraban las pruebas) y `ahci ok` con el AHCI;
`blk ok` y `blk corrupt detected` son iguales. El byte pisado para la prueba de
CRC ahora va por `blk_wr` (sin pasar por `blk_write`), así que se ejerce igual en
los dos backends.

## Pruebas

| Objetivo | Qué ejerce |
|---|---|
| `make qemu-test` | Todo lo de antes (camino BIOS + IDE) y, nuevo, `qemu-ahci-fs-test` y, si hay OVMF, `qemu-uefi-blk-test`. Sin firmware: `SKIP qemu-uefi-test, qemu-uefi-blk-test`, igual que antes. |
| `make qemu-ahci-fs-test` | BIOS + IDE de datos + AHCI con un SATA de datos en cero. `blk` elige ATA; `blk ahci` fuerza AHCI y `blk` lo conserva; `disk` → `ahci ok`, `blk ok`, `blk corrupt detected` (y no `ata ok`); `fs format/mkdir/write/cat/scrub` sobre el SATA. Con QEMU parado el anfitrión lee del archivo SATA `AFS1` en el LBA 4 (superbloque) y `ABLK` en el LBA 5, y comprueba que el IDE de datos sigue en cero. Otro arranque: `fs ls` sin elegir cae en el IDE (`fs fail 8`, vacío), `blk ahci` + `fs cat` ve el archivo persistido, `fs corrupt` + `fs cat` → `fs corrupt detected`. Sin controlador: `blk ahci` → `blk fail 3` y `blk`/`disk` por ATA. |
| `make qemu-uefi-blk-test` | q35 + OVMF, ESP en un virtio-blk (con `bootindex=0`) y un SATA de datos en el AHCI de q35. `blk` → `blk dev=ahci` sin pedirlo; `disk` y `fs` como arriba; el anfitrión ve `AFS1`/`ABLK`. Segunda corrida sin SATA: `blk fail 3`, `ata fail 3`, `fs fail 3`, y `echo` sigue contestando. |

La ESP va en virtio-blk a propósito: si estuviera en el SATA (como en
`make qemu-uefi`) sería el primer disco del puerto 0, que es el que elige
`ahci_find_port`, y `disk`/`fs` escribirían sobre ella.

## Qué falta

- **Elegir el puerto/controlador AHCI.** `ahci_find_port` toma el primer puerto
  con disco SATA (si el enlace no está arriba, COMRESET y espera ≤ 200 ms) y
  `ahci_init` prueba los controladores 01:06:01 del bus 0 en orden hasta dar con
  un disco (el ICH9 integrado de q35 suele estar vacío). Con la
  ESP en el SATA (`make qemu-uefi`) `disk`/`fs` apuntarían a la ESP. Falta
  `blk ahci <puerto>` o equivalente. No hay protección contra escribir en el
  disco del que arrancó el kernel.
- **Cambiar de backend con un fs usado.** `blk ata`/`blk ahci` en medio de una
  sesión no invalida nada del fs: `fs_open` relee los superbloques del disco
  nuevo, pero nadie comprueba que sea el mismo disco ni hay estado que se
  descarte (`qemu_ahci_fs_test.sh` cambia de ATA a AHCI entre dos órdenes y
  anda, pero eso es una observación, no una garantía).
- **Multi-sector.** Un sector por comando (`ahci_cmd`); un bloque lógico son dos
  comandos y cada escritura AHCI lleva su `FLUSH CACHE EXT`.
- **Interrupciones y NCQ.** Sondeo de `PxCI` con tope de 10 s del PIT; sin IRQ, sin
  NCQ (fuera de esta tajada a propósito).
- **NVMe.** Solo detección (`nvme`); no es backend de `blk`.
- **Pantalla (GOP).** Bajo UEFI toda la evidencia sigue siendo COM1 y PS/2;
  `0xB8000` no se ve.
- **Hardware real.** Solo QEMU (q35 + OVMF de Homebrew, ICH9-AHCI). Nada en un
  AHCI físico ni en otro firmware.
- **Discos de más de 2^32 sectores** y de más de 1024 bloques útiles para el fs
  (`limit` ≤ 1024, sin cambios).

## Probar

```bash
make qemu-test               # todo
make qemu-ahci-fs-test       # disk y fs sobre el SATA (BIOS + IDE + AHCI)
make qemu-uefi-blk-test      # lo mismo bajo UEFI, sin IDE (exige OVMF)
```

A mano, con el SATA de datos en `/tmp/sata.img`:

```bash
qemu-system-x86_64 -cpu qemu64 -drive format=raw,file=build/lapageriaos.img \
    -drive file=build/data.img,format=raw,if=ide,index=1 \
    -device ahci,id=ahci -drive id=s0,file=/tmp/sata.img,format=raw,if=none \
    -device ide-hd,drive=s0,bus=ahci.0 -display curses
# lapageria> blk ahci
# lapageria> disk
```

## Pedidos a Copihue

Ninguno nuevo. Ver `docs/PEDIDOS_COPIHUE.md`, sección HR-03.
