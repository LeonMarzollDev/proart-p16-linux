/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Out-of-tree build helpers for the posted spi-hid series on kernels that do not carry it.
 * Patch 2111 of the series adds HID_SPI_DEVICE to include/linux/hid.h; BUS_SPI itself has been in
 * the input UAPI (0x1C) for years. Forced in front of every file by the Makefile (-include).
 */
#ifndef PROART_SPI_HID_COMPAT_H
#define PROART_SPI_HID_COMPAT_H
#include <linux/hid.h>
#ifndef HID_SPI_DEVICE
#define HID_SPI_DEVICE(ven, prod) \
	.bus = BUS_SPI, .vendor = (ven), .product = (prod)
#endif
#endif
