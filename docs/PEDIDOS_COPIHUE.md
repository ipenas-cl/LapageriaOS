# Pedidos a Copihue

Lapageria rosea es el nombre científico del copihue; antes AtomicOS.

Compilador fijado en el Makefile: v0.34.1, commit
`330ec195b27c8cd66aa1cf5ee5113c767a1ea5ca`. `git ls-remote` devuelve
ese commit para `refs/tags/v0.34.1`, y `git -C build/copihue rev-parse
HEAD` después del `make` también. No se comprobó `HEAD` ni
`refs/heads/main` del remoto, ni la salida de `copihue --version`.
Sin pedidos nuevos al subir desde v0.31.0: el kernel compila sin
cambios de código.

## Cerrado en v0.27.0 y v0.27.1

Un arreglo adentro de `packed struct` ahora mide `N * sizeof(T)`.
`FsEnt` (nombre `[u8; 16]`, tamaño, cantidad, `[u32; 8]`) sale en 56
bytes, no en 13. `sizeof` y `offsetof` lo comprueban en `fs_layout`,
`blk_layout` y `axe_layout`. El sector en disco sigue siendo el de
`docs/fs.md`.

`save_context(&ctx)` / `restore_context(&ctx)` y `label` /
`label_addr` reemplazan el marco de `sched_go` y de `enter_user`.
`interrupt fn` con `*InterruptFrame` o `*PfFrame` (primer campo
`error_code`) reemplaza el `rbp` del PIT y del `#PF`. El kernel no
tiene `asm()`.

En v0.26.1 esta sonda de Ethernet salía en 0 sin mensaje. `EthHdr`
medía 4 bytes, `etype` quedaba en el offset 2 y `e.dst[0] = 255` no
almacenaba. v0.27.0 lo cierra. En v0.27.3, `copihue --flat 0x10000 -S`
mide `EthHdr` 14, `ArpPkt` 42, `IpPkt` 34, `IcmpEcho` 12, `ZoneStr`
16, `TrEv` 40 y `RxD` 16, con los `offsetof` del fuente. El store
`e.dst[0] = 255` escribe el byte. La red, las trazas y las zonas
leen esos structs. La trama y el disco no cambian: los campos de más
de un byte de la trama van en dos `u8`, en orden de red.

## Cerrado en v0.27.3

`cld()` y `std()` ensamblan, también en `bits 16`. `clear_df` es
`cld()` antes de `lodsb` y de `rep_stosd`. `pushfd` / `popfd` queda
en `check_long_mode`, porque ahí se prueba el bit ID, y en
`trace_save_if`, porque ahí se guardan los flags (en 64 bits
`pushfd()` emite `pushfq`).

`jmp rax` y `jmp [resume_rip]` existen dentro de `naked`. El
planificador no los usa: `restore_context` salta solo y el PIT
cambia de proceso con `frame = (saved_ksp + 120) as *InterruptFrame`.

`ebx` se puede asignar en `bits 16`. El token de INT 15h vive ahí.
Un `if (ebx == 0)` igual lo pisa (`mov ebx, eax` con el cero del
comparando), así que `get_e820` copia el token a memoria antes de
mirarlo y lo restaura al volver al lazo.

`syscall(n, a, ...)` existe en `--flat`. En v0.27.3 el programa de la
zona seguía con `syscall()` sin argumentos: el resultado quedaba en
`rax` y el caso de abajo lo pisaba igual.

## Cerrado en v0.28.1: `rax` sobrevive al `if` y al `while`

Un `if` o un `while` cuya condición es una comparación salta por los
flags. No deja 0 o 1 en `rax`. Un store de una constante que cabe en
el apuntado es `mov tamaño [addr], imm` y no pasa por `rax`.

La cuota de `src/user/zona.lap` quedó así. `r` es un local de
`zone_pages` (pila de `0x402000`). Un `let` dentro del `_start` naked
caería en la página de código, y el kernel la mapea solo lectura:

```copihue
let r: i64 = 0;
let n: i64 = 0;
while (r == 0 && n <= 8) {
    r = syscall(8);
    if (r == 0) { n = n + 1; }
}
if (r == 0 - 1) { say_quota(); }
```

`copihue --flat 0x400000 -S` con este pin escribe la syscall y guarda
`r` antes de comparar. Al salir del `while` recarga ese slot, resta 1
y salta con `jne`. No hay `sete`:

```
mov rax, 8
syscall
mov [rbp-8], rax
```

```
mov rax, [rbp-8]
push rax
mov rax, 0
push rax
mov rax, 1
mov rbx, rax
pop rax
sub rax, rbx
mov rbx, rax
pop rax
cmp rax, rbx
jne .L23
call say_quota
```

En QEMU 8.2.2, `make qemu-test` de la imagen con el pin v0.28.1
terminó en 0. La línea de la zona fue `zone fs, denied, syscall,
quota mem 32473, escape`: la syscall 2 denegada devolvió -1 (`zone
syscall denied`) y la cuota también (`zone quota ok`). El resultado
no se perdió. El `make qemu-test` de v0.29.2 también imprimió esa
línea de resumen y terminó en 0. El de v0.29.4 también: `zone fs,
denied, syscall, quota mem 32473, escape`, código 0.

## Cerrado en v0.29.2: el `while` y el `if` restauran `ebx`

En `bits 16` la comparación sigue siendo `cmp eax, ebx`. Alrededor
hay `push ebx` y `pop ebx`. `pop` no toca los flags, así que un
`while (c != 0)` ya no deja el cero del comparando en `ebx`.

Esta función se compiló con `copihue --freestanding` de este pin. No
se ensambló y no se arrancó:

```copihue
bits 16 naked fn while_keeps() {
    ebx = 7;
    let c: u16 = 1;
    while (c != 0) { c = 0; }
}
```

```
mov ebx, 7
mov eax, 1
mov [__loc_while_keeps_0], eax
.L0:
mov eax, [__loc_while_keeps_0]
push ebx
push eax
push edx
mov eax, 0
mov ebx, eax
pop edx
pop eax
cmp eax, ebx
pop ebx
je .L1
mov eax, 0
mov [__loc_while_keeps_0], eax
```

El cuerpo escribe el cero en memoria y no en `ebx`. El `pop ebx`
devuelve el 7. El fallo de v0.28.1 (el `while` dejaba `ebx` en 0, el
siguiente `int 0x15` reiniciaba el mapa y QEMU imprimía `e820 n=16`)
queda cerrado por ese `push` / `pop`.

## Cerrado en v0.29.4: un `+` fuera de la condición restaura `ebx`

En v0.29.2, `di = di + 24` fuera de un `if` o un `while` dejaba 24 en
`ebx`. Este pin hace `push ebx` antes del sumando y `pop ebx` después
del `add`. Esta función se compiló con `copihue --freestanding` de este
pin. No se arrancó:

```copihue
bits 16 naked fn add_clobber() {
    ebx = 7;
    di = di + 24;
}
```

```
add_clobber:
mov ebx, 7
movzx eax, di
push ebx
push eax
push edx
mov eax, 24
mov ebx, eax
pop edx
pop eax
add eax, ebx
pop ebx
mov di, ax
```

El `pop ebx` devuelve el 7. El changelog de v0.29.4 dice que `-`, `&`,
`|`, `^`, `*`, `/`, `%` y un desplazamiento hacen el mismo par (el
desplazamiento también guarda `ecx`), y que una comparación usada como
valor hace el `pop` después del `cmp` y antes del `sete`. Esas otras
formas no se compilaron en este árbol.

`get_e820` ya no copia el token. `ebx = 0` abre el mapa. Después de
`int 0x15` el conteo y `di = di + 24` restauran `ebx`, y `if (ebx == 0)`
mira el token. `copihue --flat 0x8200 -S` de este pin, sobre
`build/stage2.lap`, escribe esto entre el `int` y ese uso:

```
mov dword [di+20], 1
mov eax, 59424
int 21
```

```
movzx eax, word [32768]
push ebx
push eax
push edx
mov eax, 1
mov ebx, eax
pop edx
pop eax
add eax, ebx
pop ebx
movzx eax, ax
mov word [32768], ax
movzx eax, di
push ebx
push eax
push edx
mov eax, 24
mov ebx, eax
pop edx
pop eax
add eax, ebx
pop ebx
mov di, ax
```

```
mov eax, ebx
push ebx
```

`[di+20]` y `[32768]` son un operando de memoria. El `pop ebx` del `+`
ocurre antes del store. v0.30.0 mete `movzx eax, ax` entre ese `pop` y
el `mov word`: el destino es un `u16` y el `+` recorta. El store sigue
escribiendo `ax`. El mapa para antes de `di >= 0x8184`, así que el
conteo no pasa de 16 bits. `lgdt` de esta etapa es `lgdt [gdtr]`,
después de que `get_e820` vuelve.

En QEMU 8.2.2, `make qemu-test` de esta imagen terminó en 0 e imprimió
`e820 n=7` y `pmm free=32480 base=0x0000000000100000
end=0x0000000007fe0000`. El humo de 10 s
(`timeout 10 qemu-system-x86_64 -drive format=raw,file=build/lapageriaos.img
-display none -no-reboot -serial file:…`, sin disco de datos) salió
124 y la serie mostró `e820 n=7`, las siete entradas (la usable de
1 MB termina en `0x7fe0000`) y el mismo `pmm free=32480`. No fue 1 ni
16.

## Sigue abierto: un store de dirección no simple, y `lgdt` / `lidt` / `invlpg` sin etiqueta

Un store cuya dirección no es un número, un registro desnudo o
`reg±disp` sigue dejando esa dirección en `ebx`. `lgdt`, `lidt` e
`invlpg` de un puntero que no es una etiqueta de `data` mueven la
dirección a `bx` o a `ebx`. Una etiqueta (`lgdt(&gdtr)`) sigue siendo
`lgdt [gdtr]` y no toca `ebx`.

Estas funciones se compilaron con `copihue --freestanding` de este pin
y se ensamblaron con nasm. No se arrancaron:

```copihue
data gdtr {
    dw 39;
    dd 0;
}

bits 16 naked fn store_clobber() {
    ebx = 7;
    *((di + si) as *u16) = 1;
}

bits 16 naked fn lgdt_label() {
    ebx = 7;
    lgdt(&gdtr);
}

bits 16 naked fn lgdt_reg() {
    ebx = 7;
    lgdt(di);
}
```

```
store_clobber:
mov ebx, 7
movzx eax, di
push ebx
push eax
push edx
movzx eax, si
mov ebx, eax
pop edx
pop eax
add eax, ebx
pop ebx
push eax
mov eax, 1
pop ebx
mov word [ebx], ax
```

```
lgdt_label:
mov ebx, 7
lgdt [gdtr]
```

```
lgdt_reg:
mov ebx, 7
movzx eax, di
mov bx, ax
lgdt [bx]
```

El `+` de `di + si` restaura el 7. El store de después hace `pop ebx`
con la dirección y `mov word [ebx], ax`. `ebx` sale con esa dirección,
no con 7. `mov bx, ax` pisa la mitad baja del token. `lidt(di)` e
`invlpg(di)` salen igual (`lidt [bx]`, `invlpg [bx]`). En `bits 32`,
`*((edi + esi) as *u32) = 1` termina en `pop ebx` / `mov dword [ebx], eax`.

`get_e820` no usa esos casos entre el `int 0x15` y el `if (ebx == 0)`.
`*((di + 20) as *u32) = 1` es `[di+20]` y va antes del `int`. El conteo
escribe en `[32768]`. Los stores `kern_packet+N` sí pasan por `ebx`, y
están en `load_kernel`, antes de `get_e820`. `lgdt(&gdtr)` es la
etiqueta y va después. En `protected_mode` (`bits 32`) no hay
`int 0x15` ni un uso del token.

## v0.30.0: el `<<` de un `u8` recorta

Un `u8` (un byte de un arreglo o de un campo) operado con un literal
que cabe en 8 bits sigue siendo `u8`. El desplazamiento usa el
operando izquierdo, así que `(b[0] & 255) << 8` recorta después del
`shl` y el byte alto queda en 0. El `or` de dos `u8` también recorta.
Esta función se compiló con `copihue --freestanding` de este pin. No
se ejecutó:

```copihue
fn pack(b: *u8) -> i64 {
    return ((b[0] & 255) << 8) | (b[1] & 255);
}
```

```
shl rax, cl
movzx rax, al
```

```
or rax, rbx
movzx rax, al
```

El mismo `<<` con el byte ensanchado a `i64` no recorta el
desplazamiento ni el `or`:

```copihue
fn pack_wide(b: *u8) -> i64 {
    return (((b[0] & 255) as i64) << 8) | (b[1] & 255);
}
```

```
shl rax, cl
```

```
or rax, rbx
```

No pedimos que un `<<` de `u8` deje de recortar. El kernel ensancha
con `as i64` donde el byte es la parte alta de un entero de más de 8
bits: la palabra IDENTIFY (`ata_id_word`), la MAC que se reescribe en
el e1000, el ethertype, el largo IP, el fragmento, el id y la
secuencia ICMP, el opcode ARP y el byte impar del checksum. `hi` y
`lo` de `net_csum` siguen sin tipo: el acumulador es `i64` y `(hi <<
8) | lo` no recorta. `ata_pio_out` hace lo mismo con `let lo` y `let
hi`.

El CRC-32 no cambió de forma. `crc` no tiene tipo, así que sigue en
`i64`. `p[i] & 255` recorta a `u8` (`movzx rax, al`) y el valor ya
estaba en 0..255. El `>> 1` es del acumulador, y `& 0x7FFFFFFF`
después. `parse_int` resta `'0'` solo dentro de `line[i]` entre `'0'`
y `'9'`; el `movzx rax, al` deja 0..9. `fs_commit` hace `s.gen + 1`
con `gen` en `u32` (`mov eax, eax`). Es un solo `add`: el `u32` que
vuelve a `s.gen` es el mismo que el store recortaba antes, también si
`gen` era `0xFFFFFFFF` (el local `i64` sí difiere en ese borde; no se
ejecutó). `e_rd` hace `p[0] & 0xFFFFFFFF` (`mov eax, eax`); el MMIO es
de 32 bits y el `i64` devuelto es ese valor con ceros arriba. Las
páginas y las PTE se mueven en `i64` / `u64`. No hay un `<<` de un
`u32` en esta imagen. Los contadores (`ticks`, IRQ, trazas) son
`i64`.

## Para v0.31.0: conversiones implícitas puntero/entero

El chequeo de v0.30.0 (`899dc7de`) ya separa puntero de entero. Lo que sigue
acepta sin `as` es lo que este árbol usa. Se listó compilando boot,
stage2, kernel y los dos programas de usuario con el fuente de
`899dc7de`, anotando cada permiso de `check_types` y cada `+`/`-`
entre puntero e entero. El compilador del repositorio no se tocó.
Cero errores. No apareció `ptr+int`, ni un puntero pasado a un
`i64`, ni `*volatile T` asignado a `*T`, ni `*i8` contra `*u8`.

Un literal entero no negativo puede inicializar cualquier puntero.
Son direcciones físicas:

- `console.lap` 36, 49 y 72: `*u16 = 0xB8000`
- `pmm.lap` 104: `*u16 = 0x8000`
- `pmm.lap` 193: `*u8 = 0x300000`
- `sched.lap` 307: `*u8 = 0x10000`
- `sched.lap` 334: `*u8 = 0x300000`
- `sched.lap` 356: `*u8 = 0x400000`
- `shell.lap` 276: `*u8 = 0x200000`
- `usermode.lap` 116: `*u8 = 0x400000`
- `usermode.lap` 150: `*u64 = 0x1000`
- `usermode.lap` 152: `*u64 = 0x2000`
- `zone.lap` 355 y 365: `*u8 = 0x401C00`

Tiene que seguir permitido. Un entero que no es literal no se asigna
a un puntero sin `as` (ya es error en 0.30.0) y este árbol no lo hace.

`kernel.lap` 31: `bss_end() - bss_start()` es `*u8 - *u8` y el
resultado es `i64`. Es el largo de la `.bss`. Tiene que seguir
siendo un entero.

Estos builtins reciben la dirección en un hueco sin tipo. El
argumento es `&` de un struct, o sea un puntero:

- `stage2.lap` 120: `lgdt(&gdtr)` (en `bits 16` el tipo es dirección)
- `gdt.lap` 111: `lgdt(&gdtr)` (`*DescPtr`)
- `idt.lap` 262: `lidt(&idtr)` (`*DescPtr`)
- `gdt.lap` 121: `restore_context(&shell_ctx)` (`*Ctx`)
- `sched.lap` 479 y `usermode.lap` 158: `save_context(&shell_ctx)` (`*Ctx`)

`lgdt`, `lidt`, `save_context` y `restore_context` tienen que seguir
aceptando ese puntero. `invlpg` en este árbol recibe un `i64` (`va` o
el literal `0x300000`), no un puntero.

El resto ya es `as` y tiene que seguir compilando, no volverse
implícito: `i64` a `*T` y a `*volatile u32`, puntero a `i64`/`u64`
antes de sumar (`p as i64 + n`, `gdt as u64`, `idt as u64`), `*u8` a
un puntero de struct, y `(byte & 255) as i64` antes de un `<<`. Una
cadena literal ya es `*u8`; no es un entero.

## Cerrado en v0.31.0: el estrechamiento y `&struct` en QEMU

v0.31.0 pide `as` para meter un entero más ancho en un campo, un
elemento, un store, un argumento o un `return`. Este árbol agrega los
75 que lista el CHANGELOG de Copihue. Después de eso, `boot.lap`,
`stage2.lap`, `kernel.lap` y los dos programas de usuario compilan
sin otro error. Las conversiones de la sección anterior siguen
implícitas: no salió un diagnóstico nuevo en un literal a puntero, en
`bss_end() - bss_start()`, ni en `lgdt` / `lidt` / `save_context` /
`restore_context`.

El ensamblado `-S` del kernel coincide con v0.30.0 salvo el dígito
del banner. `boot.bin` y `stage2.bin` (con el marcador de sectores en
0) coinciden byte a byte. Un `as` de esos 75 no agrega una máscara
que el store de v0.30.0 no tuviera. El límite de la IDT es 767 y cabe
en el `u16`. El largo del descriptor de envío queda entre 60 y 2048
antes del `as u16`. El CRC-32 ya vuelve enmascarado a 32 bits.

En QEMU 8.2.2 el humo de 10 s mostró `gdt load` y después `gdt ok`,
y llegó a `lapageria>`. Ese prompt sale después del `lgdt` de la
etapa 2 y del `lgdt(&gdtr)` del kernel. `make qemu-test` terminó en
0: el PIT avanzó (ticks 100 → 200 en 935 ms), la IRQ1 contó 151
teclas, el `#PF` y el `#UD` imprimieron su línea, el round-robin
devolvió `timer=29 yield=4` y la zona imprimió `zone fs, denied,
syscall, quota mem 32473, escape`. Esos caminos pasan por
`lidt(&idtr)`, `save_context(&shell_ctx)` y
`restore_context(&shell_ctx)`. No queda un pedido nuevo.

## Mitad alta, sin pedido nuevo

`copihue --flat 0xFFFFFFFF80010000` en v0.31.0 emite `org` de esa
dirección. NASM 2.16.01 `-f bin` no rellena el hueco: `kernel.bin`
de esta imagen mide 157775 bytes y el primer byte es `_start`.
`mov rax, símbolo` sale `mov rax, imm64` con la dirección canónica
(`__bss_end` es `0xFFFFFFFF8003BEFC`). `section_start` / `section_end`
devuelven esa misma dirección y `nx_ranges` las usa. Un `jmp`
relativo desde la etapa 2 hasta ahí no cabe en rel32; el salto es
`jmp rax`, que el lenguaje ya tenía. No hace falta `section @ addr`
ni un caso mínimo nuevo.
