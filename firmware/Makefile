CROSS ?= riscv32-unknown-elf-
PYTHON ?= python3
CC = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump
SIZE = $(CROSS)size
ARCH = -march=rv32im_zicsr_zifencei -mabi=ilp32 -mno-relax -msmall-data-limit=0
CFLAGS = $(CPPFLAGS) $(ARCH) -std=c11 -Os -g -Wall -Wextra -ffreestanding -fno-builtin -ffunction-sections -fdata-sections -I. -MMD -MP
LDFLAGS = $(ARCH) -Wl,--no-relax,--gc-sections -T../linker/app.ld
BUILD = build
COMMON = $(BUILD)/start.o $(BUILD)/trap.o $(BUILD)/platform.o $(BUILD)/storage.o
DIAG = $(COMMON) $(BUILD)/minilib.o $(BUILD)/main.o
DG = ../software/external/doomgeneric/doomgeneric
DG_NAMES = dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop d_main d_mode d_net f_finale f_wipe g_game hu_lib hu_stuff info i_cdmus i_endoom i_joystick i_scale i_sound i_system i_timer memio m_argv m_bbox m_cheat m_config m_controls m_fixed m_menu m_misc m_random p_ceilng p_doors p_enemy p_floor p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr p_saveg p_setup p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data r_draw r_main r_plane r_segs r_sky r_things sha1 sounds statdump st_lib st_stuff s_sound tables v_video wi_stuff w_checksum w_file w_main w_wad z_zone w_file_stdc i_input i_video doomgeneric
DOOM = $(COMMON) $(addprefix $(BUILD)/doom/,$(addsuffix .o,$(DG_NAMES))) $(BUILD)/doom_platform.o $(BUILD)/doom_main.o $(BUILD)/newlib_syscalls.o
CHIP_TIMEDEMO ?= 1
CHIP_FRAME_LOG ?= 8
DGFLAGS = -D_DEFAULT_SOURCE -DNORMALUNIX -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -DCHIP_TIMEDEMO=$(CHIP_TIMEDEMO) -DCHIP_FRAME_LOG=$(CHIP_FRAME_LOG) -I$(DG)

.PHONY: all diagnostic boot doom fetch check-doom clean test FORCE
all: diagnostic boot
diagnostic: $(BUILD)/diagnostic.elf $(BUILD)/diagnostic.mem $(BUILD)/diagnostic.bin $(BUILD)/diagnostic.dis
boot: $(BUILD)/boot.elf $(BUILD)/boot.mem $(BUILD)/boot.bin $(BUILD)/boot.dis
doom: check-doom $(BUILD)/doom.elf $(BUILD)/doom.mem $(BUILD)/doom.bin $(BUILD)/doom.dis
fetch:
	$(PYTHON) ../software/fetch_doomgeneric.py
check-doom:
	$(PYTHON) -c "import sys; sys.path.insert(0, '../software'); import fetch_doomgeneric; fetch_doomgeneric.verify()"

$(BUILD) $(BUILD)/doom:
	mkdir -p $@
$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/%.o: %.S | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/doom_%.o: ../software/doom_%.c | $(BUILD)
	$(CC) $(CFLAGS) $(DGFLAGS) -c $< -o $@
# Recompile the two bindings when configurable demo/log arguments change.
$(BUILD)/doom_main.o $(BUILD)/doom_platform.o: FORCE
FORCE:
$(BUILD)/newlib_syscalls.o: ../software/newlib_syscalls.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD)/doom/%.o: $(DG)/%.c | $(BUILD)/doom
	$(CC) $(CFLAGS) $(DGFLAGS) -Wno-unused-parameter -c $< -o $@
$(BUILD)/diagnostic.elf: $(DIAG) ../linker/app.ld
	$(CC) $(LDFLAGS) -nostdlib $(DIAG) -lgcc -Wl,-Map,$(@:.elf=.map) -o $@
	$(SIZE) $@
$(BUILD)/doom.elf: $(DOOM) ../linker/app.ld | check-doom
	$(CC) $(LDFLAGS) -nostartfiles $(DOOM) -Wl,--start-group -lc -lm -lgcc -Wl,--end-group -Wl,-Map,$(@:.elf=.map) -o $@
	$(SIZE) $@
$(BUILD)/boot.elf: boot.S ../linker/boot.ld | $(BUILD)
	$(CC) $(ARCH) -nostdlib -T../linker/boot.ld -Wl,--no-relax $< -o $@
$(BUILD)/boot.mem: $(BUILD)/boot.elf ../tools/elf_to_mem.py Makefile
	$(PYTHON) ../tools/elf_to_mem.py $< $@ --base 0 --size 0x4000
$(BUILD)/%.mem: $(BUILD)/%.elf ../tools/elf_to_mem.py
	$(PYTHON) ../tools/elf_to_mem.py $< $@ --base 0x80000000 --size 0x800000
$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@
$(BUILD)/%.dis: $(BUILD)/%.elf
	$(OBJDUMP) -d $< > $@
test:
	$(PYTHON) ../software/test_tools.py
clean:
	rm -rf $(BUILD)
-include $(wildcard $(BUILD)/*.d $(BUILD)/doom/*.d)
