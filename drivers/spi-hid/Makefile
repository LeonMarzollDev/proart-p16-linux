# SPDX-License-Identifier: GPL-2.0-only
# Out-of-tree build of the posted HID-over-SPI transport (core + ACPI glue) for the ProArt P16
# sensor hub (\_SB.SENH, MSFW1111 / PNP0C51 on SPI3: ambient light sensor).
# Run drivers/spi-hid/prepare.sh first; it fills src/.
ifneq ($(KERNELRELEASE),)
ccflags-y += -include $(src)/compat.h -I$(src)/src
obj-m += spi-hid.o spi-hid-acpi.o
spi-hid-y := src/spi-hid-core.o
spi-hid-acpi-y := src/spi-hid-acpi.o
else
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
endif
