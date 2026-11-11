# EX-12: pin de Copihue v0.45.1 (desde v0.44.7)

Rama `ex-12-copihue-0451`, base `origin/main` 0626d48. Copihue v0.45.1, commit
`d1a5fc392d5d3f1951d45d615cb7c6bca6d8607f` (salta v0.45.0). `git -C build/copihue
rev-parse HEAD` después de `make clean && make all` devolvió ese commit.

## Qué arranca (probado en QEMU)

- `make qemu-test`: 235 `ok`, sale con 0, incluido `stage2_big_test`.
- `make qemu-uefi-test`: ok (cargador, kernel, E820, PIT, shell, caso sin kernel.bin).
- `make qemu-uefi-blk-test`: ok.
- `make copihue-gaps-test`: ok.
- Tamaños: `kernel.bin` 535886 bytes (1047 sectores) y `stage2.bin` 1990 bytes,
  idénticos byte a byte a los de v0.44.7. El margen de stage2 no cambia.
  `loader.bin` (UEFI) sigue en 6227 bytes.

Cambios:

1. `COPIHUE_COMMIT ?= v0.45.1` en el Makefile. `ci.yml` no fija versión: construye
   con la etiqueta del Makefile.
2. Línea de pin en README, `docs/PEDIDOS_COPIHUE.md`, `docs/exec.md` y
   `docs/hr03-ahci-blk.md`; entrada en CHANGELOG.

Sin cambios de código. Se revisó el `.lap` del árbol buscando lo que v0.45.1 vuelve
error de compilación (`P{...}.x`, `let p: P = Q{...}`, literal de struct como
argumento en `naked fn` o `bits 16`/`32`, `gb->ptr[i]` con puntero global,
`&x[i]` sobre algo que no es arreglo ni puntero, literal de arreglo con más
valores o fuera de `let`): no aparece ninguno, y el árbol compila limpio con
v0.45.1, que los rechaza.

## Qué falta

- Las novedades de v0.45.0/v0.45.1 (struct por valor como retorno, `-> str`,
  `-> []T`, `str`/`[]T` como campo) no se usan todavía en el kernel.

## Gaps de lenguaje (Copihue v0.45.1, sin parchear)

- En un arreglo **local** de structs un índice fuera de rango todavía no atrapa,
  y `ps[i].y = v` no comprueba límites en hosted. El árbol no tiene arreglos
  locales de structs (`zone_name`, `idt`, `tr_ring` son globales). Regla para
  código nuevo: no indexar un arreglo local de structs con un valor dinámico sin
  comprobar el índice antes.
