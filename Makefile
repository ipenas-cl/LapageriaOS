# LapageriaOS — kernel y arranque en Copihue.
#
# Targets:
#   all        Construye build/lapageriaos.img (etapa 1 + etapa 2 + kernel plano).
#   qemu       Arranca esa imagen en QEMU con consola curses (teclado PS/2).
#   qemu-test  Arranque sin pantalla: sendkey y comprobaciones por COM1.
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
#   LBA KERNEL_LBA ..             kernel cargado en físico 0x10000,
#                                 enlazado en 0xFFFFFFFF80010000
# KERNEL_LBA es 1 + STAGE2_SECTORS. boot.lap tiene que contener los mismos
# STAGE2_SECTORS y STAGE2_ORG, y el salto a STAGE2_ORG. stage2.lap contiene
# `dq KERNEL_LBA` y el marcador `dw 0; // KERNEL_SECTORS`. La regla de la
# etapa 2 reescribe ese marcador, en una copia bajo build/, con
# ceil(kernel.bin / 512).
#
# Un paquete INT 13h, con offset 0, admite 128 sectores (64 KiB): el
# offset es de 16 bits. stage2.lap repite la lectura y sube el segmento
# 0x1000 cada vez. El conteo total sigue siendo el marcador
# KERNEL_SECTORS, escrito por make.
#
# El tope no es el disquete (FLOPPY_SECTORS - KERNEL_LBA da 2871 y eso
# pasaría de 1 MB). El archivo del kernel entra en físico 0x10000
# (el enlace es 0xFFFFFFFF80010000). La .bss no va en
# kernel.bin: _start la limpia justo después del archivo. La primera
# pila fija es proc_rsp0 del proceso 0, en 0x60000, y crece hacia abajo.
# Entre topes de pila hay 32 KiB, así que imagen + .bss tienen que
# terminar antes de 0x58000. KERNEL_BSS_RESERVE (32 KiB) queda para la
# .bss; el archivo no puede pasar de ahí. make también suma los resb y
# resq de la .bss y falla si 0x10000 + kernel.bin + .bss pasa de 0x58000.

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
# 0x58000 - 0x10000 - 32 KiB = 256 KiB = 512 sectores.
KERNEL_LOAD_ADDR := $(shell echo $$((0x10000)))
KERNEL_IMAGE_END := $(shell echo $$((0x58000)))
KERNEL_BSS_RESERVE := $(shell echo $$((0x8000)))
KERNEL_IMAGE_SECTORS := $(shell echo $$(( ($(KERNEL_IMAGE_END) - $(KERNEL_LOAD_ADDR) - $(KERNEL_BSS_RESERVE)) / 512 )))
KERNEL_MAX_SECTORS := $(shell a=$$(($(FLOPPY_SECTORS)-$(KERNEL_LBA))); b=$(KERNEL_IMAGE_SECTORS); if [ $$a -lt $$b ]; then echo $$a; else echo $$b; fi)
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
COPIHUE_COMMIT ?= v0.34.1
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
                     $(KERNEL_SRC)/copihue/exec.lap \
                     $(KERNEL_SRC)/copihue/zone_img.lap \
                     $(KERNEL_SRC)/copihue/zone.lap \
                     $(KERNEL_SRC)/copihue/net.lap \
                     $(KERNEL_SRC)/copihue/trace.lap \
                     $(KERNEL_SRC)/copihue/shell.lap \
                     $(KERNEL_SRC)/copihue/kernel.lap

.PHONY: all qemu qemu-test debug clean help

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
	  printf '%s\n' "$$hex" | grep -q "1000$${lo}$${hi}000000100900000000000000" || { echo "stage2 DAP does not load $$sectors sectors from LBA $(KERNEL_LBA) to 0x10000"; rm -f $@; exit 1; }

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
	$(abspath $(COPIHUE)) --flat 0xFFFFFFFF80010000 -S -o $(BUILD_DIR)/kernel.asm $(KERNEL_SRC)/copihue/kernel.lap
	nasm -f bin -o $@ $(BUILD_DIR)/kernel.asm
	@set -eu; \
	  size=$$(wc -c < $@ | tr -d ' '); \
	  bss=$$(awk '/^__bss_start:/{s=1; next} /^__bss_end:/{s=0} s && /resb /{b += $$NF} s && /resw /{b += $$NF * 2} s && /resd /{b += $$NF * 4} s && /resq /{b += $$NF * 8} END{print b + 0}' $(BUILD_DIR)/kernel.asm); \
	  end=$$(( $(KERNEL_LOAD_ADDR) + size + bss )); \
	  printf 'kernel.bin: %s bytes, bss %s, image end 0x%x (max 0x%x)\n' "$$size" "$$bss" "$$end" "$(KERNEL_IMAGE_END)"; \
	  test "$$size" -le $(KERNEL_MAX_BYTES) || { echo "kernel too large for stage 2"; rm -f $@; exit 1; }; \
	  test "$$end" -le $(KERNEL_IMAGE_END) || { echo "kernel image and bss reach 0x$$(printf '%x' $$end), past 0x58000"; rm -f $@; exit 1; }

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

# Programa de la zona. Misma cabecera AXE1; zone plant lo escribe como ztest.
ZONE_BIN = $(BUILD_DIR)/zona.bin
ZONE_AXE = $(BUILD_DIR)/zona.axe
ZONE_IMG = $(KERNEL_SRC)/copihue/zone_img.lap

$(ZONE_IMG): src/user/zona.lap scripts/mkaxe.sh $(COPIHUE) | $(BUILD_DIR)
	$(abspath $(COPIHUE)) --flat 0x400000 -o $(ZONE_BIN) src/user/zona.lap
	scripts/mkaxe.sh $(ZONE_BIN) $(ZONE_AXE) $@ zone_fill

# Consola curses: QEMU entrega el teclado al controlador PS/2 que lee el shell.
qemu: $(OS_IMAGE) $(DATA_IMG)
	qemu-system-$(ARCH) $(QEMU_CPU) $(QEMU_DRIVES) -display curses

# tests/qemu_shell_test.sh exige qemu-system-x86_64 y socat.
# El disco de datos se reescribe en cada corrida: la prueba no depende
# de lo que haya quedado de la anterior.
qemu-test: $(OS_IMAGE)
	dd if=/dev/zero of=$(DATA_IMG) bs=512 count=$(DATA_SECTORS) status=none
	$(TESTS_DIR)/qemu_shell_test.sh $(OS_IMAGE)

# La imagen es un binario plano: gdb no tiene tabla de símbolos ELF.
debug: $(OS_IMAGE) $(DATA_IMG)
	qemu-system-$(ARCH) $(QEMU_CPU) $(QEMU_DRIVES) -display curses -s -S

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(KERNEL_SRC)/copihue/exec_img.lap $(KERNEL_SRC)/copihue/zone_img.lap

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
	@echo "  make debug      Igual que qemu, esperando gdb en tcp::1234."
	@echo "  make clean      Borra build/."
	@echo "  make help       Esta lista."
	@echo ""
	@echo "La etapa 2 pide ceil(tamaño de kernel.bin / 512) sectores (tope $(KERNEL_MAX_SECTORS))."
	@echo "Compilador local: make COPIHUE=/ruta/al/copihue all"
