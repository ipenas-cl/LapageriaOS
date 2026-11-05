#!/bin/sh
# EX-02: prueba de scripts/mkaxe.sh en el anfitrión (sin QEMU).
# Comprueba las cabeceras AXE1 y AXE2 byte por byte, el relleno de página, la
# bss y los rechazos (sin datos, demasiadas páginas, opciones malas).
# Uso: tests/mkaxe_test.sh
set -u
MK=${MKAXE:-$(dirname "$0")/../scripts/mkaxe.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok   $*"; }

# u32 little-endian en el offset $2 de $1, y un byte
u32() {
    set -- $(od -An -tu1 -v -j "$2" -N4 "$1")
    echo $(($1 + $2 * 256 + $3 * 65536 + $4 * 16777216))
}
u8() { set -- $(od -An -tu1 -v -j "$2" -N1 "$1"); echo "$1"; }
magic() { od -An -c -N4 "$1" | tr -d ' \n'; }
blob() { head -c "$1" /dev/zero | tr '\0' "$2" > "$3"; }

# 1. AXE1 como siempre: 16 bytes de cabecera, nada de AXE2.
blob 300 a "$TMP/p1.bin"
"$MK" "$TMP/p1.bin" "$TMP/p1.axe" "$TMP/p1.lap" f1 > /dev/null || fail "AXE1 de 300 bytes"
[ "$(magic "$TMP/p1.axe")" = "AXE1" ] || fail "AXE1: magic $(magic "$TMP/p1.axe")"
[ "$(wc -c < "$TMP/p1.axe" | tr -d ' ')" = 316 ] || fail "AXE1: largo"
[ "$(u32 "$TMP/p1.axe" 4)" = 300 ] || fail "AXE1: tamaño"
[ "$(u32 "$TMP/p1.axe" 8)" = 4194304 ] || fail "AXE1: entrada"
grep -q '^fn f1(p: \*u8) -> i64 {$' "$TMP/p1.lap" || fail "AXE1: nombre de la función"
grep -q 'p\[z\] = 0;' "$TMP/p1.lap" && fail "AXE1: el .lap trae la limpieza del buffer (solo es de AXE2)"
ok "AXE1 de 300 bytes sin opciones: cabecera de 16 bytes, entrada 0x400000"

# 2. AXE1 en el borde: 4080 sigue siendo AXE1 y 4081 pasa a AXE2.
blob 4080 b "$TMP/p2.bin"
"$MK" "$TMP/p2.bin" "$TMP/p2.axe" "$TMP/p2.lap" > /dev/null || fail "4080 bytes"
[ "$(magic "$TMP/p2.axe")" = "AXE1" ] || fail "4080 bytes debía ser AXE1"
blob 4081 b "$TMP/p3.bin"
"$MK" "$TMP/p3.bin" "$TMP/p3.axe" "$TMP/p3.lap" > /dev/null || fail "4081 bytes"
[ "$(magic "$TMP/p3.axe")" = "AXE2" ] || fail "4081 bytes debía ser AXE2"
ok "4080 bytes es AXE1; 4081 es AXE2"

# 3. Texto de varias páginas, sin datos ni bss: sin relleno, memoria = texto.
blob 10000 c "$TMP/p4.bin"
"$MK" "$TMP/p4.bin" "$TMP/p4.axe" "$TMP/p4.lap" > /dev/null || fail "texto de 10000 bytes"
a="$TMP/p4.axe"
[ "$(magic "$a")" = "AXE2" ] || fail "p4: magic"
[ "$(wc -c < "$a" | tr -d ' ')" = 10032 ] || fail "p4: largo $(wc -c < "$a")"
[ "$(u32 "$a" 4)" = 10000 ] || fail "p4: imagen $(u32 "$a" 4)"
[ "$(u32 "$a" 8)" = 4194304 ] || fail "p4: entrada"
[ "$(u32 "$a" 12)" = 0 ] || fail "p4: entrada, parte alta"
[ "$(u32 "$a" 16)" = 10000 ] || fail "p4: texto $(u32 "$a" 16)"
[ "$(u32 "$a" 20)" = 10000 ] || fail "p4: memoria $(u32 "$a" 20)"
[ "$(u32 "$a" 24)" = 0 ] && [ "$(u32 "$a" 28)" = 0 ] || fail "p4: reservado"
ok "AXE2 de solo texto (10000 bytes, 3 páginas): imagen = texto = memoria"

# 4. Texto + datos: el texto se rellena hasta la página, los datos empiezan ahí.
blob 100 t "$TMP/t.bin"
blob 4096 D "$TMP/d.dat"
"$MK" -d "$TMP/d.dat" "$TMP/t.bin" "$TMP/p5.axe" "$TMP/p5.lap" > /dev/null || fail "texto + datos"
a="$TMP/p5.axe"
[ "$(magic "$a")" = "AXE2" ] || fail "p5: magic"
[ "$(wc -c < "$a" | tr -d ' ')" = $((32 + 8192)) ] || fail "p5: largo $(wc -c < "$a")"
[ "$(u32 "$a" 4)" = 8192 ] || fail "p5: imagen"
[ "$(u32 "$a" 16)" = 100 ] || fail "p5: texto"
[ "$(u32 "$a" 20)" = 8192 ] || fail "p5: memoria $(u32 "$a" 20)"
[ "$(u8 "$a" 32)" = 116 ] || fail "p5: primer byte del texto"
[ "$(u8 "$a" $((32 + 99)))" = 116 ] || fail "p5: último byte del texto"
[ "$(u8 "$a" $((32 + 100)))" = 0 ] || fail "p5: relleno"
[ "$(u8 "$a" $((32 + 4095)))" = 0 ] || fail "p5: último byte del relleno"
[ "$(u8 "$a" $((32 + 4096)))" = 68 ] || fail "p5: primer byte de datos"
[ "$(u8 "$a" $((32 + 8191)))" = 68 ] || fail "p5: último byte de datos"
ok "texto de 100 bytes + 4096 de datos: datos en el offset 4096 de la imagen, relleno en cero"

# 5. Texto + datos + bss: la memoria suma la bss.
"$MK" -d "$TMP/d.dat" -b 5000 "$TMP/t.bin" "$TMP/p6.axe" "$TMP/p6.lap" > /dev/null || fail "texto + datos + bss"
a="$TMP/p6.axe"
[ "$(u32 "$a" 4)" = 8192 ] || fail "p6: imagen"
[ "$(u32 "$a" 20)" = 13192 ] || fail "p6: memoria $(u32 "$a" 20) (esperaba 13192)"
[ "$(wc -c < "$a" | tr -d ' ')" = $((32 + 8192)) ] || fail "p6: la bss no va en el archivo"
ok "datos + 5000 bytes de bss: memoria 13192 (4 páginas), la bss no ocupa archivo"

# 6. Texto + bss sin datos: la bss empieza en la página siguiente al texto.
"$MK" -b 100 "$TMP/t.bin" "$TMP/p7.axe" "$TMP/p7.lap" > /dev/null || fail "texto + bss"
a="$TMP/p7.axe"
[ "$(u32 "$a" 4)" = 100 ] || fail "p7: imagen $(u32 "$a" 4)"
[ "$(u32 "$a" 16)" = 100 ] || fail "p7: texto"
[ "$(u32 "$a" 20)" = 4196 ] || fail "p7: memoria $(u32 "$a" 20) (esperaba 4096 + 100)"
[ "$(wc -c < "$a" | tr -d ' ')" = 132 ] || fail "p7: largo"
ok "texto + bss sin datos: la bss queda en su propia página (memoria 4196)"

# 7. El .lap de un AXE2 escribe solo las palabras no nulas.
head -c 4096 /dev/zero > "$TMP/sparse.dat"
printf 'SEG2' | dd of="$TMP/sparse.dat" bs=1 conv=notrunc 2> /dev/null
"$MK" -d "$TMP/sparse.dat" "$TMP/t.bin" "$TMP/p13.axe" "$TMP/p13.lap" > /dev/null || fail "datos dispersos"
words=$(grep -c ' q\[' "$TMP/p13.lap")
[ "$words" -lt 60 ] || fail "p13.lap: $words palabras (4096 bytes de datos casi vacíos cuestan 1024 si no se saltan los ceros)"
grep -q 'p\[z\] = 0;' "$TMP/p13.lap" || fail "p13.lap: sin limpieza del buffer"
grep -q 'return 8224;' "$TMP/p13.lap" || fail "p13.lap: return"
# con datos densos (todo no nulo) no se salta nada: 8224 / 4 palabras menos las del relleno
dense=$(grep -c ' q\[' "$TMP/p5.lap")
[ "$dense" -gt 1000 ] || fail "p5.lap: datos densos, $dense palabras"
ok "AXE2: el .lap limpia el buffer y escribe solo palabras no nulas ($words)"

# 8. Tope: 16 páginas pasan, 17 no; imagen de 64 KiB justa.
blob 4096 u "$TMP/t4k.bin"
"$MK" -b $((15 * 4096)) "$TMP/t4k.bin" "$TMP/p8.axe" "$TMP/p8.lap" > /dev/null || fail "16 páginas debía pasar"
[ "$(u32 "$TMP/p8.axe" 20)" = 65536 ] || fail "p8: memoria"
ok "texto de 1 página + 15 de bss = 16 páginas: aceptado (memoria 65536)"
"$MK" -b $((15 * 4096 + 1)) "$TMP/t4k.bin" "$TMP/p9.axe" "$TMP/p9.lap" 2> "$TMP/err" > /dev/null && fail "17 páginas debía fallar"
grep -q 'maximo' "$TMP/err" || fail "17 páginas: mensaje: $(cat "$TMP/err")"
blob 65537 v "$TMP/big.bin"
"$MK" "$TMP/big.bin" "$TMP/p10.axe" "$TMP/p10.lap" 2> "$TMP/err" > /dev/null && fail "texto de 65537 debía fallar"
blob 8192 w "$TMP/d8k.dat"
"$MK" -d "$TMP/d8k.dat" "$TMP/t4k.bin" "$TMP/p11.axe" "$TMP/p11.lap" 2> "$TMP/err" > /dev/null || fail "4096 + 8192 debía pasar"
blob 61441 w "$TMP/d60k.dat"
"$MK" -d "$TMP/d60k.dat" "$TMP/t4k.bin" "$TMP/p12.axe" "$TMP/p12.lap" 2> "$TMP/err" > /dev/null && fail "4096 + 61441 de datos debía fallar"
ok "más de 16 páginas, texto de 65537 y datos que desbordan: rechazados"

# 9. Entradas malas.
: > "$TMP/empty.bin"
"$MK" "$TMP/empty.bin" "$TMP/e1.axe" "$TMP/e1.lap" 2> /dev/null > /dev/null && fail "payload vacío debía fallar"
"$MK" -d "$TMP/empty.bin" "$TMP/t.bin" "$TMP/e2.axe" "$TMP/e2.lap" 2> /dev/null > /dev/null && fail "datos vacíos debía fallar"
"$MK" -d "$TMP/no-existe" "$TMP/t.bin" "$TMP/e3.axe" "$TMP/e3.lap" 2> /dev/null > /dev/null && fail "datos inexistentes debía fallar"
"$MK" -b abc "$TMP/t.bin" "$TMP/e4.axe" "$TMP/e4.lap" 2> /dev/null > /dev/null && fail "bss no numérico debía fallar"
"$MK" -b -5 "$TMP/t.bin" "$TMP/e5.axe" "$TMP/e5.lap" 2> /dev/null > /dev/null && fail "bss negativo debía fallar"
"$MK" -x "$TMP/t.bin" "$TMP/e6.axe" "$TMP/e6.lap" 2> /dev/null > /dev/null && fail "opción desconocida debía fallar"
"$MK" "$TMP/t.bin" "$TMP/e7.axe" "$TMP/e7.lap" "1mala" 2> /dev/null > /dev/null && fail "nombre de función malo debía fallar"
ok "payload vacío, datos vacíos o ausentes, bss malo, opción y nombre malos: rechazados"

# 10. EX-05, -a: un AXE2 que armó el compilador (copihue --flat --axe2). Aquí se
# arma a mano con printf, con la forma de la salida del compilador: texto
# redondeado a páginas, entrada = dirección virtual de _start, datos pegados
# detrás del texto. mkaxe.sh no lo toca: solo lo valida y deja el .lap.
oct3() { printf '%03o' "$1"; }
le32() { printf "\\$(oct3 $(($1 & 255)))\\$(oct3 $((($1 >> 8) & 255)))\\$(oct3 $((($1 >> 16) & 255)))\\$(oct3 $((($1 >> 24) & 255)))"; }
# ccaxe archivo imagen entrada texto memoria reservado-byte0 magic
ccaxe() {
    {
        printf '%s' "${7:-AXE2}"
        le32 "$2"
        le32 "$3"; le32 0
        le32 "$4"
        le32 "$5"
        le32 "${6:-0}"; le32 0
        head -c "$2" /dev/zero | tr '\0' 'x'
    } > "$1"
}
ccaxe "$TMP/c1.axe" 4108 4194304 4096 8192
cp "$TMP/c1.axe" "$TMP/c1.orig"
"$MK" -a "$TMP/c1.axe" "$TMP/c1.lap" cc_fill > /dev/null || fail "-a: AXE2 válido"
cmp -s "$TMP/c1.axe" "$TMP/c1.orig" || fail "-a: mkaxe.sh tocó el AXE2 del compilador"
grep -q '^fn cc_fill(p: \*u8) -> i64 {$' "$TMP/c1.lap" || fail "-a: nombre de la función"
grep -q 'return 4140;' "$TMP/c1.lap" || fail "-a: return"
grep -q 'p\[z\] = 0;' "$TMP/c1.lap" || fail "-a: sin limpieza del buffer"
ok "-a: el AXE2 del compilador queda tal cual y el .lap lo reproduce (4140 bytes)"
# la entrada en la segunda página de texto (align(4096)) es válida
ccaxe "$TMP/c2.axe" 8204 4198400 8192 12288
"$MK" -a "$TMP/c2.axe" "$TMP/c2.lap" > /dev/null || fail "-a: entrada en la segunda página de texto"
ok "-a: entrada 0x401000 con 2 páginas de texto: aceptada"
ccaxe "$TMP/c3.axe" 4108 4198400 4096 8192
"$MK" -a "$TMP/c3.axe" "$TMP/c3.lap" 2> "$TMP/err" > /dev/null && fail "-a: entrada fuera del texto debía fallar"
grep -q 'fuera del texto' "$TMP/err" || fail "-a entrada: mensaje $(cat "$TMP/err")"
ccaxe "$TMP/c4.axe" 4108 4194304 4096 8192 1
"$MK" -a "$TMP/c4.axe" "$TMP/c4.lap" 2> /dev/null > /dev/null && fail "-a: reservado distinto de cero debía fallar"
ccaxe "$TMP/c5.axe" 4108 4194304 4096 4000
"$MK" -a "$TMP/c5.axe" "$TMP/c5.lap" 2> /dev/null > /dev/null && fail "-a: memoria menor que la imagen debía fallar"
ccaxe "$TMP/c6.axe" 4108 4194304 8192 8192
"$MK" -a "$TMP/c6.axe" "$TMP/c6.lap" 2> /dev/null > /dev/null && fail "-a: texto mayor que la imagen debía fallar"
ccaxe "$TMP/c7.axe" 4108 4194304 4096 8192 0 AXE1
"$MK" -a "$TMP/c7.axe" "$TMP/c7.lap" 2> /dev/null > /dev/null && fail "-a: magic AXE1 debía fallar"
ccaxe "$TMP/c8.axe" 4108 4194304 4096 70000
"$MK" -a "$TMP/c8.axe" "$TMP/c8.lap" 2> /dev/null > /dev/null && fail "-a: más de 16 páginas debía fallar"
head -c 3000 "$TMP/c1.axe" > "$TMP/c9.axe"
"$MK" -a "$TMP/c9.axe" "$TMP/c9.lap" 2> /dev/null > /dev/null && fail "-a: archivo corto debía fallar"
"$MK" -a -b 100 "$TMP/c1.axe" "$TMP/c10.lap" 2> /dev/null > /dev/null && fail "-a con -b debía fallar"
"$MK" -a "$TMP/no-existe.axe" "$TMP/c11.lap" 2> /dev/null > /dev/null && fail "-a: archivo inexistente debía fallar"
ok "-a: entrada fuera del texto, reservado, memoria corta, texto largo, magic AXE1, más de 16 páginas, archivo corto, -b y archivo ausente: rechazados"

# 11. Si ya hay salida del compilador (make all), la de pag2 y atk2 pasa -a.
for p in pag2 atk2; do
    f=$(dirname "$0")/../build/$p.axe
    [ -f "$f" ] || continue
    "$MK" -a "$f" "$TMP/$p.lap" "${p}_fill" > /dev/null || fail "-a: build/$p.axe"
    ok "-a: build/$p.axe, salida real de copihue --axe2, validada"
done

# 12. EX-08: -a con un AXE1 (copihue --axe1). Se arma uno con la cabecera de
# 16 bytes (magic, imagen u32, entrada u64) y se valida.
ax1() {
    {
        printf 'AXE1'
        le32 "$2"
        le32 "$3"; le32 0
        head -c "$2" /dev/zero | tr '\0' 'x'
    } > "$1"
}
ax1 "$TMP/e1.axe" 300 4194304
"$MK" -a "$TMP/e1.axe" "$TMP/e1.lap" e1_fill > /dev/null || fail "-a AXE1 de 300 bytes"
[ "$(wc -c < "$TMP/e1.axe" | tr -d ' ')" = 316 ] || fail "-a AXE1: el archivo cambió"
grep -q '^fn e1_fill(p: \*u8) -> i64 {$' "$TMP/e1.lap" || fail "-a AXE1: nombre de la función"
grep -q 'p\[z\] = 0;' "$TMP/e1.lap" && fail "-a AXE1: el .lap trae la limpieza del buffer (solo es de AXE2)"
grep -q 'return 316;' "$TMP/e1.lap" || fail "-a AXE1: debía devolver 316"
ax1 "$TMP/e2.axe" 4080 4198383
"$MK" -a "$TMP/e2.axe" "$TMP/e2.lap" > /dev/null || fail "-a AXE1 en el borde (4080 bytes, entrada en el último byte)"
ax1 "$TMP/e3.axe" 300 4194604
"$MK" -a "$TMP/e3.axe" "$TMP/e3.lap" 2> /dev/null > /dev/null && fail "-a AXE1: entrada fuera de la imagen debía fallar"
ax1 "$TMP/e4.axe" 4081 4194304
"$MK" -a "$TMP/e4.axe" "$TMP/e4.lap" 2> /dev/null > /dev/null && fail "-a AXE1: 4081 bytes debía fallar"
ax1 "$TMP/e5.axe" 300 4194303
"$MK" -a "$TMP/e5.axe" "$TMP/e5.lap" 2> /dev/null > /dev/null && fail "-a AXE1: entrada bajo 0x400000 debía fallar"
head -c 200 "$TMP/e1.axe" > "$TMP/e6.axe"
"$MK" -a "$TMP/e6.axe" "$TMP/e6.lap" 2> /dev/null > /dev/null && fail "-a AXE1: archivo corto debía fallar"
ok "-a AXE1: 300 bytes y borde de 4080 aceptados; entrada fuera, 4081 bytes, entrada bajo 0x400000 y archivo corto rechazados"
f=$(dirname "$0")/../build/ataque.axe
if [ -f "$f" ]; then
    "$MK" -a "$f" "$TMP/atk.lap" atk_fill > /dev/null || fail "-a: build/ataque.axe"
    ok "-a: build/ataque.axe, salida real de copihue --axe1, validada"
fi

if [ "$fails" -ne 0 ]; then
    echo "mkaxe_test: $fails fallas"
    exit 1
fi
echo "mkaxe_test: todo bien"
