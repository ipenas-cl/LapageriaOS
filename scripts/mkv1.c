/* mkv1: arma un disco de datos de LapageriaOS en formato de sistema de
 * archivos versión 1 (el anterior a FS-02), sin pasar por ningún kernel.
 * Sirve para probar `fs migrate` (tests/qemu_fs3_test.sh).
 *
 *   cc -O1 -o mkv1 scripts/mkv1.c
 *   mkv1 <data.img> <escenario>
 *
 * Escenarios:
 *   std      cuatro generaciones con dos snapshots: archivos compartidos entre
 *            la raíz viva y los snapshots, uno que solo vive en un snapshot,
 *            uno vacío, uno de 8 bloques, uno de 600 bytes y 7 archivos vivos.
 *   full     8 snapshots, cada uno con una raíz distinta (9 raíces).
 *   badname  como std más un archivo "x/y": v2 no lo acepta.
 *   badcrc   como std, con un byte pisado en un bloque de datos vivo.
 *
 * Formato (docs/disco.md y el docs/fs.md del commit anterior a d122028):
 *   bloque n = dos sectores: datos en LBA 2n, metadatos en LBA 2n+1
 *     (magic ABLK, número de bloque, CRC-32/ISO-HDLC de los 512 bytes).
 *   superbloques v1 en los bloques 2 y 3, la copia viva es la de mayor
 *     generación; bitmap de 128 bytes; 8 snapshots de 24 bytes.
 *   directorio v1: un bloque, magic ADIR, cuenta, hasta 7 entradas de 64
 *     bytes (nombre 16, tamaño, nbloques, 8 bloques, 8 de relleno).
 * Los archivos mantienen el patrón del kernel (fs_pat / fs_bigpat) para que
 * `fs check` y `fs bigr` los verifiquen desde adentro; el manifiesto que
 * imprime lleva los CRC calculados acá, de forma independiente.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#define NBLK 1024
#define MAXSNAP 8

static int fd;
static uint8_t bitmap[128];
static uint32_t gen = 1;
static int slot = 2;
static uint32_t root;
static int nsnaps;
static struct { char name[12]; uint32_t root, gen; } snaps[MAXSNAP];

static uint32_t crc32(const uint8_t *p, int n) {
    uint32_t c = 0xFFFFFFFFu;
    for (int i = 0; i < n; i++) {
        c ^= p[i];
        for (int b = 0; b < 8; b++) c = (c >> 1) ^ ((c & 1) ? 0xEDB88320u : 0);
    }
    return c ^ 0xFFFFFFFFu;
}

static void put32(uint8_t *p, int off, uint32_t v) {
    p[off] = v & 255; p[off + 1] = (v >> 8) & 255;
    p[off + 2] = (v >> 16) & 255; p[off + 3] = (v >> 24) & 255;
}
static uint32_t get32(const uint8_t *p, int off) {
    return p[off] | (p[off + 1] << 8) | (p[off + 2] << 16) | ((uint32_t)p[off + 3] << 24);
}

static void blk_write(int n, const uint8_t *data) {
    uint8_t meta[512];
    memset(meta, 0, 512);
    memcpy(meta, "ABLK", 4);
    put32(meta, 4, n);
    put32(meta, 8, crc32(data, 512));
    if (pwrite(fd, data, 512, (off_t)n * 2 * 512) != 512 ||
        pwrite(fd, meta, 512, (off_t)(n * 2 + 1) * 512) != 512) {
        perror("pwrite"); exit(1);
    }
}
static void blk_read(int n, uint8_t *data) {
    if (pread(fd, data, 512, (off_t)n * 2 * 512) != 512) { perror("pread"); exit(1); }
}

static int taken(int n) { return bitmap[n / 8] & (1 << (n % 8)); }
static void mark(int n, int v) {
    if (v) bitmap[n / 8] |= 1 << (n % 8); else bitmap[n / 8] &= ~(1 << (n % 8));
}
static int alloc_blk(void) {
    for (int n = 4; n < NBLK; n++) if (!taken(n)) { mark(n, 1); return n; }
    fprintf(stderr, "mkv1: disco lleno\n"); exit(1);
}

static void write_super(int dest, uint32_t g) {
    uint8_t s[512];
    memset(s, 0, 512);
    memcpy(s, "AFS1", 4);
    put32(s, 4, 1);
    put32(s, 8, g);
    put32(s, 12, root);
    put32(s, 16, NBLK);
    put32(s, 20, 4);
    put32(s, 24, nsnaps);
    memcpy(s + 32, bitmap, 128);
    for (int i = 0; i < nsnaps; i++) {
        memcpy(s + 160 + i * 24, snaps[i].name, 12);
        put32(s, 160 + i * 24 + 12, snaps[i].root);
        put32(s, 160 + i * 24 + 16, snaps[i].gen);
    }
    blk_write(dest, s);
}

/* Directorio v1 en memoria. */
struct ent { char name[16]; uint32_t size, nb, blk[8]; };
static struct ent dir[7];
static int ndir;

static void load_dir(uint32_t b, struct ent *d, int *n) {
    uint8_t buf[512];
    blk_read(b, buf);
    *n = get32(buf, 4);
    for (int i = 0; i < *n; i++) {
        const uint8_t *e = buf + 8 + i * 64;
        memset(&d[i], 0, sizeof d[i]);
        memcpy(d[i].name, e, 16);
        d[i].size = get32(e, 16);
        d[i].nb = get32(e, 20);
        for (int k = 0; k < 8; k++) d[i].blk[k] = get32(e, 24 + k * 4);
    }
}
static uint32_t store_dir(void) {
    uint8_t buf[512];
    memset(buf, 0, 512);
    memcpy(buf, "ADIR", 4);
    put32(buf, 4, ndir);
    for (int i = 0; i < ndir; i++) {
        uint8_t *e = buf + 8 + i * 64;
        memcpy(e, dir[i].name, 16);
        put32(e, 16, dir[i].size);
        put32(e, 20, dir[i].nb);
        for (int k = 0; k < 8; k++) put32(e, 24 + k * 4, dir[i].blk[k]);
    }
    int b = alloc_blk();
    blk_write(b, buf);
    return b;
}

/* Lo alcanzable desde la raíz viva y los snapshots (lo que v1 conserva). */
static void gc(void) {
    uint8_t reach[NBLK / 8];
    memset(reach, 0, sizeof reach);
    uint32_t roots[1 + MAXSNAP];
    int nr = 0;
    roots[nr++] = root;
    for (int i = 0; i < nsnaps; i++) roots[nr++] = snaps[i].root;
    for (int r = 0; r < nr; r++) {
        struct ent d[7]; int n;
        load_dir(roots[r], d, &n);
        reach[roots[r] / 8] |= 1 << (roots[r] % 8);
        for (int i = 0; i < n; i++)
            for (unsigned k = 0; k < d[i].nb; k++) reach[d[i].blk[k] / 8] |= 1 << (d[i].blk[k] % 8);
    }
    for (int n = 4; n < NBLK; n++) mark(n, (reach[n / 8] >> (n % 8)) & 1);
}

static void commit(void) {
    gen++;
    int dest = (slot == 3) ? 2 : 3;
    write_super(dest, gen);
    slot = dest;
}

static void fmt(void) {
    memset(bitmap, 0, 128);
    for (int n = 0; n < 4; n++) mark(n, 1);
    ndir = 0;
    root = store_dir();
    nsnaps = 0;
    gen = 1;
    write_super(2, 1);
    write_super(3, 0);
    slot = 2;
}

static int find(const char *name) {
    for (int i = 0; i < ndir; i++) if (strncmp(dir[i].name, name, 16) == 0) return i;
    return -1;
}

static void put_file(const char *name, const uint8_t *data, int len) {
    int nb = (len + 511) / 512;
    struct ent e;
    memset(&e, 0, sizeof e);
    strncpy(e.name, name, 15);
    e.size = len;
    e.nb = nb;
    for (int k = 0; k < nb; k++) {
        uint8_t buf[512];
        memset(buf, 0, 512);
        int n = len - k * 512; if (n > 512) n = 512;
        memcpy(buf, data + k * 512, n);
        int b = alloc_blk();
        blk_write(b, buf);
        e.blk[k] = b;
    }
    load_dir(root, dir, &ndir);
    int i = find(name);
    if (i < 0) {
        if (ndir >= 7) { fprintf(stderr, "mkv1: mas de 7 archivos\n"); exit(1); }
        i = ndir++;
    }
    dir[i] = e;
    root = store_dir();
    gc();
    commit();
}
static void rm_file(const char *name) {
    load_dir(root, dir, &ndir);
    int i = find(name);
    if (i < 0) { fprintf(stderr, "mkv1: rm %s\n", name); exit(1); }
    for (int j = i; j < ndir - 1; j++) dir[j] = dir[j + 1];
    ndir--;
    root = store_dir();
    gc();
    commit();
}
static void snap(const char *name) {
    memset(snaps[nsnaps].name, 0, 12);
    strncpy(snaps[nsnaps].name, name, 11);
    snaps[nsnaps].root = root;
    snaps[nsnaps].gen = gen;
    nsnaps++;
    commit();
}

/* Patrones del kernel. */
static int pat(int i) { return (i + 0x5A) & 255; }
static int bigpat(int i, int seed) { return (i * 31 + (i / 512) * 7 + 5 + seed * 91) & 255; }
static void txt(const char *name, const char *s) { put_file(name, (const uint8_t *)s, strlen(s)); }
static void m600(const char *name) {
    uint8_t b[600];
    for (int i = 0; i < 600; i++) b[i] = pat(i);
    put_file(name, b, 600);
}
static void big(const char *name, int kib, int seed) {
    static uint8_t b[8192];
    int n = kib * 1024;
    for (int i = 0; i < n; i++) b[i] = bigpat(i, seed);
    put_file(name, b, n);
    printf("crc %s size=%d seed=%d 0x%08x\n", name, n, seed, crc32(b, n));
}

static void std_disk(void) {
    fmt();
    txt("a", "v1-a-uno");
    txt("e", "");
    txt("keep", "se queda");
    m600("m");
    big("big", 4, 3);
    snap("s1");
    txt("a", "v1-a-dos");
    rm_file("e");
    txt("f1", "uno");
    snap("s2");
    m600("m2");
    txt("g", "ge");
    txt("a", "v1-a-tres");
    /* vivo: a keep m big f1 m2 g (7 entradas) */
}

static void full_disk(void) {
    fmt();
    txt("a", "gen0");
    for (int i = 1; i <= 8; i++) {
        char nm[12], v[16];
        snprintf(nm, sizeof nm, "s%d", i);
        snprintf(v, sizeof v, "gen%d", i);
        txt("a", v);
        if (i <= 6) { char f[8]; snprintf(f, sizeof f, "f%d", i); txt(f, v); }
        snap(nm);
    }
    txt("a", "vivo");
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "uso: mkv1 <data.img> <std|full|badname|badcrc>\n"); return 2; }
    fd = open(argv[1], O_RDWR);
    if (fd < 0) { perror(argv[1]); return 1; }
    if (strcmp(argv[2], "std") == 0) std_disk();
    else if (strcmp(argv[2], "full") == 0) full_disk();
    else if (strcmp(argv[2], "badname") == 0) { std_disk(); rm_file("g"); txt("x/y", "mal"); }
    else if (strcmp(argv[2], "badcrc") == 0) {
        std_disk();
        /* pisa un byte del sector de datos del primer bloque de "keep" vivo */
        load_dir(root, dir, &ndir);
        int i = find("keep");
        uint8_t z = 0xEE;
        if (pwrite(fd, &z, 1, (off_t)dir[i].blk[0] * 2 * 512 + 3) != 1) { perror("pwrite"); return 1; }
    } else { fprintf(stderr, "escenario desconocido\n"); return 2; }
    close(fd);
    return 0;
}
