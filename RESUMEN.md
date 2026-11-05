# HR-04: efi_call a `ms64 fn` (Copihue v0.44.7)

Rama `hr-04-efi-ms64`, base `origin/main` ea134a1.

## Qué arranca (probado en QEMU + OVMF)

- `make qemu-uefi-test`: ok (cargador, kernel, E820, PIT, shell, caso sin kernel.bin).
- `make qemu-uefi-blk-test`: ok.
- `make qemu-test`: 235 `ok`, sale con 0, incluido `stage2_big_test`.
- Margen de stage2: `kernel.bin` sigue en 535886 bytes. El cargador UEFI es un PE
  aparte; no entra en stage2. `loader.bin` pasó de 5858 a 6227 bytes (límite 32 KiB).

Cambios:

1. `efi_call` (naked fn con asm) fuera. Cada llamada al firmware es
   `let f: ms64 fn = tabla[i]; f(...)`, con los argumentos que cada servicio lee.
   En el árbol solo existía `efi_call`; `efi_call2` y `efi_call4` ya no estaban
   (solo se nombran en `docs/PEDIDOS_COPIHUE.md`). El kernel no tiene código UEFI.
2. `loader.lap` se compila con `--flat 0x1000 --pic` (Makefile). Fuera
   `efi_guid_lip`, `efi_guid_sfs`, `efi_name_kernel`, `efi_tramp_addr`,
   `efi_tramp_len`; se usa `&bloque` y `&efi_tramp`. `efi_str` pasó a Copihue.
   La longitud del trampolín es `&efi_tramp_end - &efi_tramp` (un `naked fn`
   marcador que sigue al trampolín; depende del orden de las funciones en la imagen).
3. `--pic` rechaza `dq 0x7000 + efi_t_gdt - efi_tramp` dentro del asm del
   trampolín. Ahora el trampolín calcula la base de su GDT con `lea [rel]` y la
   escribe en el GDTR antes de `lgdt` (corre desde 0x7000 y escribe en su propia página).
4. `tests/uefi_pe_test.sh` aceptaba solo `[rel ..]`; con `--pic` el asm lleva
   `default rel`. Ahora lo reconoce y rechaza `mov/push reg, etiqueta`.

## Qué falta

- `_start` sigue siendo `naked fn`. Quedan 3 naked: `_start`, `efi_tramp`
  (debe ser asm: cambia CR3, GDT y CS) y `efi_enter`.

## Gaps de lenguaje (Copihue v0.44.7, sin parchear)

- **`ms64 fn _start` con búfer local cuelga en OVMF.** Intento:
  `ms64 fn _start(image, systab) { let buf: [i64; 64]; return efi_main(systab, image, &buf as i64); }`.
  Compila, el entry queda en 0x1000 y sale el banner, pero la 4.ª llamada al
  firmware (`EFI_FILE_PROTOCOL.Open`) deja a OVMF girando en un bucle con `pause`
  (el log de QEMU solo muestra interrupciones de timer v=20, ninguna excepción).
  Poner `buf` a cero no cambia nada. El asm de `efi_main` es idéntico al caso que
  funciona; solo cambia `_start`. **Causa no diagnosticada**: no sé si es el thunk
  de `ms64 fn`, el marco con arreglo local o un error mío. Revertido; no está hecho.
- Con `--pic`, el asm de un `naked fn` no puede guardar la dirección absoluta de
  una etiqueta en datos (por diseño); el trampolín lo resuelve en tiempo de ejecución.
- No hay forma de pedir el tamaño de un `naked fn` o un rango de código; se usa un
  `naked fn` marcador al final.
- `.text` del PE es de solo lectura (pe.asm), así que un `data` no sirve de búfer
  escribible; el búfer tiene que estar en la pila.
