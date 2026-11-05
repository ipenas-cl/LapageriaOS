# LapageriaOS — kernel y arranque en Copihue.
#
# Targets:
#   all        Construye build/lapageriaos.img (etapa 1 + etapa 2 + kernel plano).
#   qemu       Arranca esa imagen en QEMU con consola curses (teclado PS/2).
#   qemu-test  Arranque sin pantalla: sendkey y comprobaciones por COM1.
#   qemu-udp-test  Solo la prueba de red por IRQ y UDP (tests/qemu_udp_test.sh).
#   qemu-big-test  Solo programas de varias páginas, AXE2 (tests/qemu_big_test.sh).
#   mkaxe-test  Solo scripts/mkaxe.sh en el anfitrión (tests/mkaxe_test.sh).
#   qemu-axe2-test  Solo AXE2 del compilador y ataques de anillo 3 (tests/qemu_axe2_test.sh).
#   qemu-atk1-test  Solo ataques de anillo 3 contra un AXE1 (tests/qemu_atk1_test.sh).
#   qemu-fast-test  Solo la retransmisión rápida de TCP con pérdida real (tests/qemu_fast_test.sh).
#   qemu-burst-test  Solo la pérdida de varios segmentos en una ráfaga de TCP (tests/qemu_burst_test.sh).
#   qemu-shell-test  Solo el arranque, las demos (nx, hh, user, sched con guarda) y el resto del shell (tests/qemu_shell_test.sh).
#   qemu-stab-test  6 corridas de las dos baterías de ataques, de la retransmisión rápida y de la pérdida en ráfaga,
#              con -icount shift=7 y sin icount.
#   qemu-tcp-test  Solo la prueba de TCP (tests/qemu_tcp_test.sh).
#   qemu-trace-test  Solo la prueba de trazas (tests/qemu_trace_test.sh).
#   qemu-zswitch-test  Solo el cambio de zona en switch_to (tests/qemu_zswitch_test.sh).
#   qemu-iso-test  Solo el aislamiento entre zonas (tests/qemu_iso_test.sh).
#   qemu-fs2-test  Solo directorios, archivos grandes, scrub y raíz por zona
#              (tests/qemu_fs2_test.sh).
#   qemu-fs3-test  Solo fs migrate, fs snap rm y fs rm -r (tests/qemu_fs3_test.sh;
#              necesita cc para scripts/mkv1.c).
#   qemu-ata-test  Solo la prueba del timeout ATA con -icount shift=4 (tests/qemu_ata_test.sh).
#   qemu-ahci-test  Solo la lectura de sectores por AHCI (tests/qemu_ahci_test.sh).
#   uefi-image  Arma build/uefi/esp/EFI/BOOT/BOOTX64.EFI (stub UEFI en Copihue, HR-01).
#   uefi-pe-test  Solo la comprobación estática del PE32+ (sin QEMU).
#   qemu-uefi  Arranca el stub UEFI en QEMU con OVMF (OVMF_CODE/OVMF_VARS/OVMF_BIOS; falla si no hay).
#   qemu-uefi-test  Solo el arranque UEFI automatizado (tests/qemu_uefi_test.sh).
#   qemu-cpu-test  Solo la cuota de CPU por zona (tests/qemu_cpu_test.sh), normal y con -icount shift=4.
#   debug      Igual que qemu, y espera a gdb en tcp::1234 (-s -S).
#   clean      Borra build/.
#   help       Muestra esta lista.
#
# La primera vez `all` clona y compila Copihue en build/copihue.
# COPIHUE_COMMIT fija la etiqueta. COPIHUE=/ruta/copihue usa un binario local
# y no clona el repositorio.
#
# Disco (imagen cruda de FLOPPY_SECTORS sectores de 512 bytes):
#   LBA 0                         etapa 1 (boot.lap, copihue --boot, 512 bytes)
#   LBA 1 .. STAGE2_SECTORS       etapa 2 en STAGE2_ORG
#   LBA KERNEL_LBA ..             kernel (hasta KERNEL_MAX_SECTORS sectores),
#                                 copiado a físico KERNEL_PHYS (0x400000),
#                                 enlazado en 0xFFFFFFFF80400000
#   LBA KERNEL_LBA+KERNEL_MAX_SECTORS .. FLOPPY_SECTORS-1   libre
# KERNEL_LBA es 1 + STAGE2_SECTORS. boot.lap tiene que contener los mismos
# STAGE2_SECTORS y STAGE2_ORG, y el salto a STAGE2_ORG. stage2.lap contiene
# `dq KERNEL_LBA` y el marcador `dw 0; // KERNEL_SECTORS`. La regla de la
# etapa 2 reescribe ese marcador, en una copia bajo build/, con
# ceil(kernel.bin / 512).
#
# Un paquete INT 13h, con offset 0, admite 128 sectores (64 KiB): el
# offset es de 16 bits. stage2.lap lee de a 128 sectores a un rebote en
# 0x10000 (segmento 0x1000) y copia cada trozo con INT 15h AH=87h a
# KERNEL_PHYS + 64 KiB * k. El conteo total sigue siendo el marcador
# KERNEL_SECTORS, escrito por make.
#
# SG-02: el tope ya no es la memoria convencional (antes 0x58000, por las
# pilas fijas de 0x60000..0x90000). La imagen vive en una página de 2 MiB
# de la ventana alta (PD alta [2], físico 0x400000..0x5FFFFF, VA
# 0xFFFFFFFF80400000..): archivo + .bss tienen que caber ahí. Tope del
# archivo: KERNEL_MAX_SECTORS = 2048 (1 MiB); el otro MiB queda para la
# .bss. make suma los resb y resq de la .bss y falla si
# KERNEL_PHYS + kernel.bin + .bss pasa de KERNEL_IMAGE_END. Ver
# docs/higher-half.md.

PROJECT_NAME = LapageriaOS
VERSION = 0.8
ARCH = x86_64

SRC_DIR = src
BUILD_DIR = build
TESTS_DIR = tests

KERNEL_SRC = $(SRC_DIR)/kernel
BOOT_SRC = $(SRC_DIR)/bootloader

BOOTLOADER = $(BUILD_DIR)/boot.bin
STAGE2 = $(BUILD_DIR)/stage2.bin
KERNEL = $(BUILD_DIR)/kernel.bin
OS_IMAGE = $(BUILD_DIR)/lapageriaos.img

STAGE2_ORG = 0x8200
STAGE2_SECTORS = 8
KERNEL_LBA = 9
FLOPPY_SECTORS = 2880
# Imagen en la página de 2 MiB 0x400000..0x5FFFFF (PD alta [2]).
# KERNEL_MAX_SECTORS = 2048 sectores (1 MiB) de archivo; la .bss va después.
KERNEL_LOAD_ADDR := $(shell echo $$((0x400000)))
KERNEL_IMAGE_END := $(shell echo $$((0x600000)))
KERNEL_LINK = 0xFFFFFFFF80400000
KERNEL_SECTOR_CAP = 2048
KERNEL_MAX_SECTORS := $(shell a=$$(($(FLOPPY_SECTORS)-$(KERNEL_LBA))); b=$(KERNEL_SECTOR_CAP); if [ $$a -lt $$b ]; then echo $$a; else echo $$b; fi)
KERNEL_MAX_BYTES := $(shell echo $$(( $(KERNEL_MAX_SECTORS) * 512 )))

# Disco de datos, aparte de la imagen de arranque. 2048 sectores de
# 512 bytes (1 MiB). QEMU lo cuelga como esclavo del IDE primario
# (index=1, ide0-hd1). El primer -drive sigue siendo lapageriaos.img
# en el maestro (ide0-hd0). Ver docs/disco.md.
DATA_IMG = $(BUILD_DIR)/data.img
DATA_SECTORS = 2048
QEMU_DRIVES = -drive format=raw,file=$(OS_IMAGE) -drive file=$(DATA_IMG),format=raw,if=ide,index=1

# qemu64 expone NX: CPUID hoja 0x80000001, EDX bit 20. Sin ese bit el
# kernel no prende EFER.NXE (MSR 0xC0000080 bit 11). El mismo -cpu está
# en tests/qemu_shell_test.sh, .github/workflows/ci.yml y
# scripts/pre-commit.sh. No usar un modelo sin nx (qemu64,-nx).
QEMU_CPU = -cpu qemu64

# $(COPIHUE) se expande al leer las listas de prerequisitos. Tiene que
# existir antes de esas reglas: si no, la etapa 1 y la etapa 2 no esperan
# al compilador (el CI de la etapa 2 falló así la primera vez).
COPIHUE_REPO   ?= https://github.com/ipenas-cl/copihue.git
COPIHUE_COMMIT ?= v0.44.2
COPIHUE_DIR     = $(BUILD_DIR)/copihue
COPIHUE       ?= $(COPIHUE_DIR)/copihue

# kernel.lap importa estos archivos, en este orden, y es el que se compila.
# `copihue --flat` coloca fn _start al inicio del binario.
COPIHUE_KERNEL_SRC = $(KERNEL_SRC)/copihue/console.lap \
                     $(KERNEL_SRC)/copihue/keyboard.lap \
                     $(KERNEL_SRC)/copihue/pmm.lap \
                     $(KERNEL_SRC)/copihue/paging.lap \
                     $(KERNEL_SRC)/copihue/gdt.lap \
                     $(KERNEL_SRC)/copihue/sched.lap \
                     $(KERNEL_SRC)/copihue/usermode.lap \
                     $(KERNEL_SRC)/copihue/nx.lap \
                     $(KERNEL_SRC)/copihue/hh.lap \
                     $(KERNEL_SRC)/copihue/idt.lap \
                     $(KERNEL_SRC)/copihue/ata.lap \
                     $(KERNEL_SRC)/copihue/blk.lap \
                     $(KERNEL_SRC)/copihue/fs.lap \
                     $(KERNEL_SRC)/copihue/exec_img.lap \
                     $(KERNEL_SRC)/copihue/grande_img.lap \
                     $(KERNEL_SRC)/copihue/pag2_img.lap \
                     $(KERNEL_SRC)/copihue/atk2_img.lap \
                     $(KERNEL_SRC)/copihue/exec.lap \
                     $(KERNEL_SRC)/copihue/zone_img.lap \
                     $(KERNEL_SRC)/copihue/atk_img.lap \
                     $(KERNEL_SRC)/copihue/par_img.lap \
                     $(KERNEL_SRC)/copihue/parcpu_img.lap \
                     $(KERNEL_SRC)/copihue/zone.lap \
                     $(KERNEL_SRC)/copihue/net.lap \
                     $(KERNEL_SRC)/copihue/udpeco_img.lap \
                     $(KERNEL_SRC)/copihue/udpdos_img.lap \
                     $(KERNEL_SRC)/copihue/udpwait_img.lap \
                     $(KERNEL_SRC)/copihue/tcpeco_img.lap \
                     $(KERNEL_SRC)/copihue/tcpcli_img.lap \
                     $(KERNEL_SRC)/copihue/tcpmulti_img.lap \
                     $(KERNEL_SRC)/copihue/tcphog_img.lap \
                     $(KERNEL_SRC)/copihue/tcpsnd_img.lap \
                     $(KERNEL_SRC)/copihue/traza_img.lap \
                     $(KERNEL_SRC)/copihue/udp.lap \
                     $(KERNEL_SRC)/copihue/tcp.lap \
                     $(KERNEL_SRC)/copihue/trace.lap \
                     $(KERNEL_SRC)/copihue/ahci.lap \
                     $(KERNEL_SRC)/copihue/nvme.lap \
                     $(KERNEL_SRC)/copihue/shell.lap \
                     $(KERNEL_SRC)/copihue/kernel.lap

.PHONY: all qemu qemu-test qemu-shell-test mkaxe-test qemu-axe2-test qemu-atk1-test qemu-fast-test qemu-burst-test qemu-stab-test qemu-big-test qemu-udp-test qemu-tcp-test qemu-trace-test qemu-zswitch-test qemu-iso-test qemu-fs2-test qemu-fs3-test qemu-ata-test qemu-ahci-test uefi-image uefi-pe-test qemu-uefi qemu-uefi-check qemu-uefi-test qemu-cpu-test debug clean help

# Imagen de arranque: LBA 0 etapa 1, LBA 1 etapa 2, LBA KERNEL_LBA el kernel.
all: $(OS_IMAGE)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(COPIHUE_DIR)/copihue: | $(BUILD_DIR)
	@echo "Building Copihue compiler @ $(COPIHUE_COMMIT)..."
	rm -rf $(COPIHUE_DIR)
	git init -q $(COPIHUE_DIR)
	git -C $(COPIHUE_DIR) fetch -q --depth 1 $(COPIHUE_REPO) $(COPIHUE_COMMIT)
	git -C $(COPIHUE_DIR) checkout -q FETCH_HEAD
	$(MAKE) -C $(COPIHUE_DIR) copihue

$(BOOTLOADER): $(BOOT_SRC)/boot.lap $(COPIHUE) | $(BUILD_DIR)
	@echo "Compiling stage-1 boot sector with Copihue..."
	@grep -q 'dw $(STAGE2_SECTORS);' $<
	@grep -q 'dw $(STAGE2_ORG), 0;' $<
	@grep -q 'jmp $(STAGE2_ORG)' $<
	$(abspath $(COPIHUE)) --boot -o $@ $<
	@test $$(wc -c < $@ | tr -d ' ') -eq 512
	@test "$$(tail -c 2 $@ | od -An -tx1 | tr -d ' \n')" = "55aa"

# El conteo del DAP sale del tamaño de kernel.bin. Sin este prerequisito
# la etapa 2 podría arrancar con el marcador en cero.
$(STAGE2): $(BOOT_SRC)/stage2.lap $(KERNEL) $(COPIHUE) | $(BUILD_DIR)
	@echo "Compiling stage-2 bootloader with Copihue..."
	@set -eu; \
	  test $(KERNEL_LBA) -eq $$((1 + $(STAGE2_SECTORS))); \
	  grep -q 'dq $(KERNEL_LBA);' $<; \
	  grep -q 'dw 0; // KERNEL_SECTORS' $<; \
	  size=$$(wc -c < $(KERNEL) | tr -d ' '); \
	  sectors=$$(( (size + 511) / 512 )); \
	  echo "kernel.bin: $$size bytes, $$sectors sectors (max $(KERNEL_MAX_SECTORS))"; \
	  test $$sectors -ge 1; \
	  test $$sectors -le $(KERNEL_MAX_SECTORS) || { echo "kernel too large for stage 2"; rm -f $@; exit 1; }; \
	  sed 's/^    dw 0; \/\/ KERNEL_SECTORS$$/    dw '"$$sectors"'; \/\/ KERNEL_SECTORS/' $< > $(BUILD_DIR)/stage2.lap; \
	  grep -q "^    dw $$sectors; // KERNEL_SECTORS$$" $(BUILD_DIR)/stage2.lap; \
	  $(abspath $(COPIHUE)) --flat $(STAGE2_ORG) -o $@ $(BUILD_DIR)/stage2.lap; \
	  st2=$$(wc -c < $@ | tr -d ' '); \
	  echo "stage2.bin: $$st2 bytes (max $$(($(STAGE2_SECTORS) * 512)))"; \
	  test $$st2 -le $$(($(STAGE2_SECTORS) * 512)) || { echo "stage2 too large for its sectors"; rm -f $@; exit 1; }; \
	  lo=$$(printf '%02x' $$((sectors & 255))); \
	  hi=$$(printf '%02x' $$((sectors >> 8))); \
	  hex=$$(od -An -tx1 -v $@ | tr -d ' \n'); \
	  printf '%s\n' "$$hex" | grep -q "1000$${lo}$${hi}000000100900000000000000" || { echo "stage2 DAP does not load $$sectors sectors from LBA $(KERNEL_LBA) to the 0x10000 bounce buffer"; rm -f $@; exit 1; }

# Un solo archivo raíz. Los import de kernel.lap tienen que seguir el orden
# de COPIHUE_KERNEL_SRC (sin contar el propio kernel.lap).
$(KERNEL): $(COPIHUE_KERNEL_SRC) $(COPIHUE) | $(BUILD_DIR)
	@echo "Compiling kernel with Copihue..."
	@set -eu; \
	  root=$(KERNEL_SRC)/copihue/kernel.lap; \
	  prev=0; \
	  for src in $(COPIHUE_KERNEL_SRC); do \
	    base=$$(basename $$src); \
	    if [ "$$base" = kernel.lap ]; then continue; fi; \
	    line=$$(grep -n "^import \"$$base\";" $$root | head -1 | cut -d: -f1); \
	    test -n "$$line" || { echo "$$root does not import $$base"; exit 1; }; \
	    test "$$line" -gt "$$prev" || { echo "import $$base is out of order in $$root"; exit 1; }; \
	    prev=$$line; \
	  done
	$(abspath $(COPIHUE)) --flat $(KERNEL_LINK) -S -o $(BUILD_DIR)/kernel.asm $(KERNEL_SRC)/copihue/kernel.lap
	nasm -f bin -o $@ $(BUILD_DIR)/kernel.asm
	@set -eu; \
	  size=$$(wc -c < $@ | tr -d ' '); \
	  bss=$$(awk '/^__bss_start:/{s=1; next} /^__bss_end:/{s=0} s && /resb /{b += $$NF} s && /resw /{b += $$NF * 2} s && /resd /{b += $$NF * 4} s && /resq /{b += $$NF * 8} END{print b + 0}' $(BUILD_DIR)/kernel.asm); \
	  end=$$(( $(KERNEL_LOAD_ADDR) + size + bss )); \
	  printf 'kernel.bin: %s bytes, bss %s, image end 0x%x (max 0x%x)\n' "$$size" "$$bss" "$$end" "$(KERNEL_IMAGE_END)"; \
	  test "$$size" -le $(KERNEL_MAX_BYTES) || { echo "kernel too large for stage 2"; rm -f $@; exit 1; }; \
	  test "$$end" -le $(KERNEL_IMAGE_END) || { echo "kernel image and bss reach 0x$$(printf '%x' $$end), past 0x$$(printf '%x' $(KERNEL_IMAGE_END))"; rm -f $@; exit 1; }

$(OS_IMAGE): $(BOOTLOADER) $(STAGE2) $(KERNEL) | $(BUILD_DIR)
	@echo "Creating OS image..."
	dd if=/dev/zero of=$@ bs=512 count=$(FLOPPY_SECTORS) status=none
	dd if=$(BOOTLOADER) of=$@ conv=notrunc status=none
	dd if=$(STAGE2) of=$@ bs=512 seek=1 conv=notrunc status=none
	dd if=$(KERNEL) of=$@ bs=512 seek=$(KERNEL_LBA) conv=notrunc status=none
	@echo "LapageriaOS v$(VERSION) image created: $@"

$(DATA_IMG): | $(BUILD_DIR)
	dd if=/dev/zero of=$@ bs=512 count=$(DATA_SECTORS) status=none

# Ejecutable de anillo 3. copihue --flat deja el código en hola.bin;
# mkaxe.sh agrega la cabecera AXE1 y genera exec_img.lap. El kernel no
# salta a esos bytes: `exec plant` los escribe con fs_write y `exec`
# los vuelve a leer. Ver docs/exec.md. exec_img.lap no se versiona.
USER_BIN = $(BUILD_DIR)/hola.bin
USER_AXE = $(BUILD_DIR)/hola.axe
EXEC_IMG = $(KERNEL_SRC)/copihue/exec_img.lap

$(EXEC_IMG): src/user/hola.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(USER_BIN) src/user/hola.lap
	scripts/mkaxe.sh $(USER_BIN) $(USER_AXE) $@

# Programa de varias páginas (EX-01). mkaxe.sh lo deja como AXE1 con su código;
# `exec bigplant` lo reempaca como AXE2 de 3 páginas más bss. Ver docs/exec.md.
GRANDE_BIN = $(BUILD_DIR)/grande.bin
GRANDE_AXE = $(BUILD_DIR)/grande.axe
GRANDE_IMG = $(KERNEL_SRC)/copihue/grande_img.lap

$(GRANDE_IMG): src/user/grande.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(GRANDE_BIN) src/user/grande.lap
	scripts/mkaxe.sh $(GRANDE_BIN) $(GRANDE_AXE) $@ grande_fill

# Programa de tres páginas (EX-02, EX-05). El compilador (v0.44.2) arma el AXE2
# entero: `copihue --flat 0x400000 --axe2 --sizes`. pag2.lap tiene texto en dos
# páginas (`where` va con align(4096)), los `let` con valor como datos y un
# `let` sin valor como bss, hasta cerrar la tercera página. --sizes se compara
# con scripts/chksizes.sh y mkaxe.sh -a valida la cabecera y deja el .lap.
# `exec axe2plant` lo escribe como pag2.
PAG2_AXE = $(BUILD_DIR)/pag2.axe
PAG2_SIZES = $(BUILD_DIR)/pag2.sizes
PAG2_IMG = $(KERNEL_SRC)/copihue/pag2_img.lap

$(PAG2_IMG): src/user/pag2.lap scripts/mkaxe.sh scripts/chksizes.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 --axe2 --sizes -o $(PAG2_AXE) src/user/pag2.lap > $(PAG2_SIZES)
	scripts/chksizes.sh $(PAG2_SIZES) data=12 bss=4084 text_bytes=8192 image=8204 memsize=12288 entry=0x400000
	scripts/mkaxe.sh -a $(PAG2_AXE) $@ pag2_fill

# Ataques de anillo 3 contra un AXE2 (EX-02). Texto de atk2.lap, una página de
# datos con un `ret` (0xC3) en el byte 0 y "ATK2" en el 16, y bss hasta
# 0x403000: todo sale de dos `let` globales de atk2.lap (EX-05).
# `exec axe2plant` lo escribe como atk2 (y atk2w, con 2 páginas de texto).
ATK2_AXE = $(BUILD_DIR)/atk2.axe
ATK2_SIZES = $(BUILD_DIR)/atk2.sizes
ATK2_IMG = $(KERNEL_SRC)/copihue/atk2_img.lap

$(ATK2_IMG): src/user/atk2.lap scripts/mkaxe.sh scripts/chksizes.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 --axe2 --sizes -o $(ATK2_AXE) src/user/atk2.lap > $(ATK2_SIZES)
	scripts/chksizes.sh $(ATK2_SIZES) data=20 bss=8172 text_bytes=4096 image=4116 memsize=12288 entry=0x400000
	scripts/mkaxe.sh -a $(ATK2_AXE) $@ atk2_fill

# Programa de la zona. Misma cabecera AXE1; zone plant lo escribe como ztest.
ZONE_BIN = $(BUILD_DIR)/zona.bin
ZONE_AXE = $(BUILD_DIR)/zona.axe
ZONE_IMG = $(KERNEL_SRC)/copihue/zone_img.lap

$(ZONE_IMG): src/user/zona.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(ZONE_BIN) src/user/zona.lap
	scripts/mkaxe.sh $(ZONE_BIN) $(ZONE_AXE) $@ zone_fill

# Programa de ataque de la zona (SG-01 parte 2). `zone atk` lo escribe
# como zatk. Ver docs/zonas.md.
ATK_BIN = $(BUILD_DIR)/ataque.bin
ATK_AXE = $(BUILD_DIR)/ataque.axe
ATK_IMG = $(KERNEL_SRC)/copihue/atk_img.lap

$(ATK_IMG): src/user/ataque.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(ATK_BIN) src/user/ataque.lap
	scripts/mkaxe.sh $(ATK_BIN) $(ATK_AXE) $@ atk_fill

# Programa de pares de zonas (OB-02). `zone par` lo escribe como par y
# `zone pair za zb par` corre dos copias a la vez, una en cada zona.
# Ver docs/zonas.md.
PAR_BIN = $(BUILD_DIR)/par.bin
PAR_AXE = $(BUILD_DIR)/par.axe
PAR_IMG = $(KERNEL_SRC)/copihue/par_img.lap

$(PAR_IMG): src/user/par.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(PAR_BIN) src/user/par.lap
	scripts/mkaxe.sh $(PAR_BIN) $(PAR_AXE) $@ par_fill

# Programa de la prueba de cuota de CPU (OB-03), salido de par: `zone parcpu`
# lo escribe como parcpu y `zone pair za zb parcpu` corre dos copias.
PARCPU_BIN = $(BUILD_DIR)/parcpu.bin
PARCPU_AXE = $(BUILD_DIR)/parcpu.axe
PARCPU_IMG = $(KERNEL_SRC)/copihue/parcpu_img.lap

$(PARCPU_IMG): src/user/parcpu.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(PARCPU_BIN) src/user/parcpu.lap
	scripts/mkaxe.sh $(PARCPU_BIN) $(PARCPU_AXE) $@ parcpu_fill

# Programa de eco UDP de anillo 3 (RD-01). `udp plant` lo escribe como
# udpeco. Ver docs/red.md.
UDPECO_BIN = $(BUILD_DIR)/udpeco.bin
UDPECO_AXE = $(BUILD_DIR)/udpeco.axe
UDPECO_IMG = $(KERNEL_SRC)/copihue/udpeco_img.lap

$(UDPECO_IMG): src/user/udpeco.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(UDPECO_BIN) src/user/udpeco.lap
	scripts/mkaxe.sh $(UDPECO_BIN) $(UDPECO_AXE) $@ udpeco_fill

# Eco con dos sockets y prueba de recv con plazo y ráfaga (RD-01 parte 2).
# `udp plant` los escribe como udpdos y udpwait.
UDPDOS_BIN = $(BUILD_DIR)/udpdos.bin
UDPDOS_AXE = $(BUILD_DIR)/udpdos.axe
UDPDOS_IMG = $(KERNEL_SRC)/copihue/udpdos_img.lap

$(UDPDOS_IMG): src/user/udpdos.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(UDPDOS_BIN) src/user/udpdos.lap
	scripts/mkaxe.sh $(UDPDOS_BIN) $(UDPDOS_AXE) $@ udpdos_fill

UDPWAIT_BIN = $(BUILD_DIR)/udpwait.bin
UDPWAIT_AXE = $(BUILD_DIR)/udpwait.axe
UDPWAIT_IMG = $(KERNEL_SRC)/copihue/udpwait_img.lap

$(UDPWAIT_IMG): src/user/udpwait.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(UDPWAIT_BIN) src/user/udpwait.lap
	scripts/mkaxe.sh $(UDPWAIT_BIN) $(UDPWAIT_AXE) $@ udpwait_fill

# Servidor de eco y cliente TCP de anillo 3 (RD-02). `tcp plant` los escribe
# como tcpeco y tcpcli. Ver docs/red.md.
TCPECO_BIN = $(BUILD_DIR)/tcpeco.bin
TCPECO_AXE = $(BUILD_DIR)/tcpeco.axe
TCPECO_IMG = $(KERNEL_SRC)/copihue/tcpeco_img.lap

$(TCPECO_IMG): src/user/tcpeco.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(TCPECO_BIN) src/user/tcpeco.lap
	scripts/mkaxe.sh $(TCPECO_BIN) $(TCPECO_AXE) $@ tcpeco_fill

TCPCLI_BIN = $(BUILD_DIR)/tcpcli.bin
TCPCLI_AXE = $(BUILD_DIR)/tcpcli.axe
TCPCLI_IMG = $(KERNEL_SRC)/copihue/tcpcli_img.lap

$(TCPCLI_IMG): src/user/tcpcli.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(TCPCLI_BIN) src/user/tcpcli.lap
	scripts/mkaxe.sh $(TCPCLI_BIN) $(TCPCLI_AXE) $@ tcpcli_fill

# Eco con varias conexiones a la vez y acaparador de bloques (RD-03).
# `tcp plant` los escribe como tcpmulti y tcphog. Ver docs/red.md.
TCPMULTI_BIN = $(BUILD_DIR)/tcpmulti.bin
TCPMULTI_AXE = $(BUILD_DIR)/tcpmulti.axe
TCPMULTI_IMG = $(KERNEL_SRC)/copihue/tcpmulti_img.lap

$(TCPMULTI_IMG): src/user/tcpmulti.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(TCPMULTI_BIN) src/user/tcpmulti.lap
	scripts/mkaxe.sh $(TCPMULTI_BIN) $(TCPMULTI_AXE) $@ tcpmulti_fill

TCPHOG_BIN = $(BUILD_DIR)/tcphog.bin
TCPHOG_AXE = $(BUILD_DIR)/tcphog.axe
TCPHOG_IMG = $(KERNEL_SRC)/copihue/tcphog_img.lap

$(TCPHOG_IMG): src/user/tcphog.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(TCPHOG_BIN) src/user/tcphog.lap
	scripts/mkaxe.sh $(TCPHOG_BIN) $(TCPHOG_AXE) $@ tcphog_fill

# Emisor TCP de 32 KiB en trozos de 256 (EX-04): da muchos segmentos en vuelo
# para la prueba de retransmisión rápida. `tcp plant` lo escribe como tcpsnd.
TCPSND_BIN = $(BUILD_DIR)/tcpsnd.bin
TCPSND_AXE = $(BUILD_DIR)/tcpsnd.axe
TCPSND_IMG = $(KERNEL_SRC)/copihue/tcpsnd_img.lap

$(TCPSND_IMG): src/user/tcpsnd.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(TCPSND_BIN) src/user/tcpsnd.lap
	scripts/mkaxe.sh $(TCPSND_BIN) $(TCPSND_AXE) $@ tcpsnd_fill

# Programa de trazas de anillo 3 (OB-01). `trace plant` lo escribe como
# traza y `traza ...` lo corre. Ver docs/trace.md.
TRAZA_BIN = $(BUILD_DIR)/traza.bin
TRAZA_AXE = $(BUILD_DIR)/traza.axe
TRAZA_IMG = $(KERNEL_SRC)/copihue/traza_img.lap

$(TRAZA_IMG): src/user/traza.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(TRAZA_BIN) src/user/traza.lap
	scripts/mkaxe.sh $(TRAZA_BIN) $(TRAZA_AXE) $@ traza_fill

# UEFI (HR-01). Solo un stub: una aplicación EFI en Copihue (src/uefi/stub.lap)
# envuelta en PE32+ por src/uefi/pe.asm. No carga el kernel todavía; ver
# docs/hr01-uefi-ahci.md. El stub se compila con --flat 0x1000 (RVA de .text) y es
# independiente de la posición. La ESP es un directorio (fat:rw:), sin mkfs.
UEFI_DIR = $(BUILD_DIR)/uefi
UEFI_STUB = $(UEFI_DIR)/stub.bin
UEFI_ESP = $(UEFI_DIR)/esp
UEFI_EFI = $(UEFI_ESP)/EFI/BOOT/BOOTX64.EFI

# Firmware: OVMF_CODE (+ OVMF_VARS) o OVMF_BIOS a mano, o la primera ruta conocida.
OVMF_CODE ?= $(firstword $(wildcard \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    /usr/local/share/qemu/edk2-x86_64-code.fd \
    /usr/share/qemu/edk2-x86_64-code.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd))
OVMF_VARS ?= $(firstword $(wildcard \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/ovmf/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd))
OVMF_BIOS ?=
export OVMF_CODE OVMF_VARS OVMF_BIOS

$(UEFI_STUB): src/uefi/stub.lap $(COPIHUE) | $(BUILD_DIR)
	mkdir -p $(UEFI_DIR)
	$(abspath $(COPIHUE)) --flat 0x1000 -S -o $(UEFI_DIR)/stub.asm $<
	$(abspath $(COPIHUE)) --flat 0x1000 -o $@ $<
	@test $$(wc -c < $@ | tr -d ' ') -le 4096 || { echo "uefi stub: pasa de una página"; rm -f $@; exit 1; }

$(UEFI_EFI): $(UEFI_STUB) src/uefi/pe.asm
	mkdir -p $(dir $@)
	@set -eu; \
	  size=$$(wc -c < $(UEFI_STUB) | tr -d ' '); \
	  raw=$$(( (size + 511) / 512 * 512 )); \
	  echo "uefi stub: $$size bytes (.text $$raw en el archivo)"; \
	  nasm -f bin -DSTUB_FILE='"$(UEFI_STUB)"' -DSTUB_SIZE=$$size -DTEXT_RAW=$$raw -o $@ src/uefi/pe.asm

# build/uefi/esp/EFI/BOOT/BOOTX64.EFI
uefi-image: $(UEFI_EFI)

# Comprobación estática del PE32+ (sin QEMU ni OVMF). Entra en qemu-test.
uefi-pe-test: $(UEFI_EFI)
	bash $(TESTS_DIR)/uefi_pe_test.sh $(UEFI_EFI) $(UEFI_STUB) $(UEFI_DIR)/stub.asm

# Arranca el stub en QEMU con OVMF. Falla con un mensaje claro si no hay firmware.
qemu-uefi-check:
	@if [ -z "$(OVMF_CODE)$(OVMF_BIOS)" ]; then \
	  echo "qemu-uefi: no encuentro firmware UEFI (OVMF/EDK2)."; \
	  echo "  Instálalo y pasa OVMF_CODE=/ruta/OVMF_CODE.fd [OVMF_VARS=/ruta/OVMF_VARS.fd]"; \
	  echo "  o OVMF_BIOS=/ruta/OVMF.fd. Ver docs/hr01-uefi-ahci.md."; \
	  exit 1; \
	fi

qemu-uefi: qemu-uefi-check $(UEFI_EFI)
	@set -eu; \
	  if [ -n "$(OVMF_BIOS)" ]; then fw="-bios $(OVMF_BIOS)"; \
	  else \
	    fw="-drive if=pflash,format=raw,unit=0,readonly=on,file=$(OVMF_CODE)"; \
	    if [ -n "$(OVMF_VARS)" ]; then cp "$(OVMF_VARS)" $(UEFI_DIR)/vars.fd; fw="$$fw -drive if=pflash,format=raw,unit=1,file=$(UEFI_DIR)/vars.fd"; fi; \
	  fi; \
	  qemu-system-$(ARCH) -machine q35 -m 256 $$fw -drive format=raw,file=fat:rw:$(UEFI_ESP) -net none -nographic -no-reboot

qemu-uefi-test: qemu-uefi-check $(UEFI_EFI)
	bash $(TESTS_DIR)/qemu_uefi_test.sh $(UEFI_ESP)

# Consola curses: QEMU entrega el teclado al controlador PS/2 que lee el shell.
qemu: $(OS_IMAGE) $(DATA_IMG)
	qemu-system-$(ARCH) $(QEMU_CPU) $(QEMU_DRIVES) -display curses

# tests/qemu_shell_test.sh exige qemu-system-x86_64 y socat.
# El disco de datos se reescribe en cada corrida: la prueba no depende
# de lo que haya quedado de la anterior.
qemu-test: $(OS_IMAGE)
	$(TESTS_DIR)/mkaxe_test.sh
	dd if=/dev/zero of=$(DATA_IMG) bs=512 count=$(DATA_SECTORS) status=none
	$(TESTS_DIR)/qemu_shell_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_udp_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_big_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_axe2_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_atk1_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_tcp_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_fast_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_burst_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_trace_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_zswitch_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_iso_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_fs2_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_fs3_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_ata_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_ahci_test.sh $(OS_IMAGE)
	$(MAKE) uefi-pe-test
	@if [ -n "$(OVMF_CODE)$(OVMF_BIOS)" ]; then $(MAKE) qemu-uefi-test; \
	  else echo "SKIP qemu-uefi-test: no hay firmware UEFI (OVMF_CODE/OVMF_BIOS); el stub UEFI NO se arrancó"; fi
	$(TESTS_DIR)/qemu_cpu_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_cpu_test.sh $(OS_IMAGE) "-icount shift=4"
	COPIHUE=$(abspath $(COPIHUE)) $(TESTS_DIR)/stage2_big_test.sh $(BUILD_DIR)

# Solo el arranque y las demos (tests/qemu_shell_test.sh): nx, hh, user, sched,
# disco, fs, exec, zonas, red de usuario y trazas. Reescribe el disco de datos.
qemu-shell-test: $(OS_IMAGE)
	dd if=/dev/zero of=$(DATA_IMG) bs=512 count=$(DATA_SECTORS) status=none
	$(TESTS_DIR)/qemu_shell_test.sh $(OS_IMAGE)

# Solo la red por IRQ y UDP. Usa una copia nueva del disco de datos.
qemu-udp-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_udp_test.sh $(OS_IMAGE)

# HR-01: lectura de sectores por AHCI (tests/qemu_ahci_test.sh). Arranca por
# BIOS+IDE como siempre y cuelga un controlador AHCI con un disco SATA.
qemu-ahci-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_ahci_test.sh $(OS_IMAGE)

# Solo scripts/mkaxe.sh (EX-02): cabeceras AXE1 y AXE2, relleno, bss y rechazos.
# No arranca QEMU.
mkaxe-test:
	$(TESTS_DIR)/mkaxe_test.sh

# Solo AXE2 de mkaxe.sh (EX-02) y ataques de anillo 3 contra un AXE2. Usa
# copias nuevas de imagen y disco.
qemu-axe2-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_axe2_test.sh $(OS_IMAGE)

# Solo ataques de anillo 3 contra un AXE1 (los de qemu_shell_test.sh, aparte y
# con QEMU_EXTRA). Usa copias nuevas de imagen y disco.
qemu-atk1-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_atk1_test.sh $(OS_IMAGE)

# EX-03/EX-04: estabilidad de las baterías de ataques AXE2 y AXE1 y de la
# retransmisión rápida de TCP (tests/qemu_fast_test.sh). STAB_N corridas de
# cada una (6 por defecto), STAB_PAR a la vez, con -icount shift=7 y sin icount.
# Deja los registros en build/stab/ y falla si alguna corrida falla.
STAB_N   ?= 6
STAB_PAR ?= 3
STAB_TESTS ?= axe2 atk1 fast burst
STAB_DIR  = $(BUILD_DIR)/stab
qemu-stab-test: $(OS_IMAGE)
	rm -rf $(STAB_DIR) && mkdir -p $(STAB_DIR)
	@set -e; for t in $(STAB_TESTS); do \
	  echo "--- $$t, -icount shift=7"; \
	  bash $(TESTS_DIR)/repeat.sh $(STAB_DIR)/$${t}_icount $(STAB_N) $(STAB_PAR) $(TESTS_DIR)/qemu_$${t}_test.sh $(OS_IMAGE) || rc=1; \
	  echo "--- $$t, sin icount"; \
	  bash $(TESTS_DIR)/repeat.sh $(STAB_DIR)/$${t}_sin $(STAB_N) $(STAB_PAR) $(TESTS_DIR)/qemu_$${t}_test.sh $(OS_IMAGE) sin-icount || rc=1; \
	done; exit $${rc:-0}

# Solo programas de varias páginas (EX-01). Usa copias nuevas de imagen y disco.
qemu-big-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_big_test.sh $(OS_IMAGE)

# Solo TCP (RD-02). Usa una copia nueva del disco de datos.
qemu-tcp-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_tcp_test.sh $(OS_IMAGE)

# EX-04: retransmisión rápida con pérdida real. Usa copias nuevas de imagen y
# disco; QEMU_EXTRA="-icount shift=7" suma opciones a QEMU.
qemu-fast-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_fast_test.sh $(OS_IMAGE)

# EX-05: pérdida de varios segmentos dentro de una ráfaga (par, separados,
# tanda de 4 y cola) con tcpsnd. Mismas opciones que la anterior.
qemu-burst-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_burst_test.sh $(OS_IMAGE)

# Solo trazas (OB-01). Usa una copia nueva del disco de datos.
qemu-trace-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_trace_test.sh $(OS_IMAGE)

# Solo el cambio de zona en switch_to (OB-02). Usa una copia nueva del disco.
qemu-zswitch-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_zswitch_test.sh $(OS_IMAGE)

# Solo el aislamiento entre zonas (OB-02, etapa 7). Usa una copia nueva del disco.
qemu-iso-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_iso_test.sh $(OS_IMAGE)

# Solo FS-02: directorios, archivos grandes, scrub, raíz por zona y
# zone destroy. Usa una copia nueva del disco de datos.
qemu-fs2-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_fs2_test.sh $(OS_IMAGE)

# Solo FS-03: fs migrate (discos v1 armados con scripts/mkv1.c), fs snap rm y
# fs rm -r. Usa copias nuevas de la imagen y del disco de datos. Con
# V1_KERNEL_IMG=ruta suma la sección del kernel v1 real (ver la prueba).
qemu-fs3-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_fs3_test.sh $(OS_IMAGE)

# Solo FS-04/1: 6 corridas de la prueba de aislamiento con -icount shift=4,
# a la vez, sin timeout ATA ("exec fail 1").
qemu-ata-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_ata_test.sh $(OS_IMAGE)

# Solo FS-04/3: cuota de CPU por zona (zone cpu), con el reloj normal y con
# -icount shift=4.
qemu-cpu-test: $(OS_IMAGE)
	$(TESTS_DIR)/qemu_cpu_test.sh $(OS_IMAGE)
	$(TESTS_DIR)/qemu_cpu_test.sh $(OS_IMAGE) "-icount shift=4"

# La imagen es un binario plano: gdb no tiene tabla de símbolos ELF.
debug: $(OS_IMAGE) $(DATA_IMG)
	qemu-system-$(ARCH) $(QEMU_CPU) $(QEMU_DRIVES) -display curses -s -S

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(KERNEL_SRC)/copihue/exec_img.lap $(KERNEL_SRC)/copihue/grande_img.lap $(KERNEL_SRC)/copihue/pag2_img.lap $(KERNEL_SRC)/copihue/atk2_img.lap $(KERNEL_SRC)/copihue/zone_img.lap $(KERNEL_SRC)/copihue/atk_img.lap $(KERNEL_SRC)/copihue/par_img.lap $(KERNEL_SRC)/copihue/parcpu_img.lap $(KERNEL_SRC)/copihue/udpeco_img.lap $(KERNEL_SRC)/copihue/udpdos_img.lap $(KERNEL_SRC)/copihue/udpwait_img.lap $(KERNEL_SRC)/copihue/tcpeco_img.lap $(KERNEL_SRC)/copihue/tcpcli_img.lap $(KERNEL_SRC)/copihue/tcpmulti_img.lap $(KERNEL_SRC)/copihue/tcphog_img.lap $(KERNEL_SRC)/copihue/tcpsnd_img.lap $(KERNEL_SRC)/copihue/traza_img.lap

help:
	@echo "LapageriaOS $(VERSION) — kernel y arranque en Copihue $(COPIHUE_COMMIT)"
	@echo ""
	@echo "  make all        Imagen de arranque en build/lapageriaos.img"
	@echo "                  (copihue --boot, --flat; la primera vez compila Copihue)."
	@echo "  make qemu       Arranca la imagen en QEMU (curses, teclado PS/2)."
	@echo "                  Agrega build/data.img como IDE esclavo (index=1)."
	@echo "  make qemu-test  Arranque mudo: sendkey y comprobaciones por COM1."
	@echo "                  Incluye el disco de datos (ata, bloques, CRC, fs, exec)"
	@echo "                  la red de usuario con e1000 (arp, ping, descarte)"
	@echo "                  y trace (sondas, anillo, perdidos)."
	@echo "                  Y la red por IRQ con UDP (eco con socat y hostfwd, zonas,"
	@echo "                  recv bloqueante, dos procesos, ráfaga, ICMP unreachable)."
	@echo "  make qemu-udp-test  Solo esa prueba de red (tests/qemu_udp_test.sh)."
	@echo "  make qemu-big-test  Solo programas de varias páginas, AXE2 (tests/qemu_big_test.sh)."
	@echo "  make mkaxe-test  Solo scripts/mkaxe.sh en el anfitrión (tests/mkaxe_test.sh)."
	@echo "  make qemu-axe2-test  Solo AXE2 del compilador y ataques de anillo 3 (tests/qemu_axe2_test.sh)."
	@echo "  make qemu-atk1-test  Solo ataques de anillo 3 contra un AXE1 (tests/qemu_atk1_test.sh)."
	@echo "  make qemu-fast-test  Solo la retransmisión rápida de TCP con pérdida real (tests/qemu_fast_test.sh)."
	@echo "  make qemu-burst-test  Solo la pérdida de varios segmentos en una ráfaga de TCP (tests/qemu_burst_test.sh)."
	@echo "  make qemu-shell-test  Solo el arranque, las demos (con guarda) y el shell (tests/qemu_shell_test.sh)."
	@echo "  make qemu-stab-test  6 corridas de las baterías AXE2 y AXE1, de la retransmisión rápida y de la pérdida en ráfaga, con y sin -icount shift=7."
	@echo "  make qemu-tcp-test  Solo la prueba de TCP (tests/qemu_tcp_test.sh)."
	@echo "  make qemu-trace-test  Solo la prueba de trazas (tests/qemu_trace_test.sh)."
	@echo "  make qemu-zswitch-test  Solo el cambio de zona en switch_to (tests/qemu_zswitch_test.sh)."
	@echo "  make qemu-iso-test  Solo el aislamiento entre zonas (tests/qemu_iso_test.sh)."
	@echo "  make qemu-fs2-test  Solo directorios, archivos grandes, scrub y raíz por zona (tests/qemu_fs2_test.sh)."
	@echo "  make qemu-fs3-test  Solo fs migrate, fs snap rm y fs rm -r (tests/qemu_fs3_test.sh)."
	@echo "  make qemu-ata-test  Solo el timeout ATA con -icount shift=4 (tests/qemu_ata_test.sh)."
	@echo "  make qemu-cpu-test  Solo la cuota de CPU por zona (tests/qemu_cpu_test.sh)."
	@echo "  make debug      Igual que qemu, esperando gdb en tcp::1234."
	@echo "  make clean      Borra build/."
	@echo "  make help       Esta lista."
	@echo ""
	@echo "La etapa 2 pide ceil(tamaño de kernel.bin / 512) sectores (tope $(KERNEL_MAX_SECTORS))."
	@echo "Compilador local: make COPIHUE=/ruta/al/copihue all"
