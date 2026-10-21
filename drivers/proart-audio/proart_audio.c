// SPDX-License-Identifier: GPL-2.0
/*
 * proart_audio - firmware UID for the speaker amplifiers of the ASUS ProArt P16
 * H7607BA (NVIDIA N1X)
 *
 * The cs35l56 driver names its tuning files after the sound card's PCI SSID or
 * the "cirrus,firmware-uid" device property. The MT8901 SoundWire machine
 * driver sets no SSID and the ACPI tables carry no firmware-uid, so both
 * amplifiers would only look for generic files and run without ASUS's tuning.
 * This module attaches cirrus,firmware-uid = "10431484" (the card's ACPI _SUB)
 * to the CS35L56 SoundWire peripherals before the cs35l56 driver binds; it is
 * loaded as a softdep ahead of snd_soc_cs35l56_sdw and also catches
 * peripherals that enumerate later.
 */
#include <linux/device.h>
#include <linux/dmi.h>
#include <linux/module.h>
#include <linux/property.h>
#include <linux/soundwire/sdw.h>
#include <linux/soundwire/sdw_type.h>
#include <linux/string.h>

#define FIRMWARE_UID "10431484"

static const struct property_entry amp_props[] = {
	PROPERTY_ENTRY_STRING("cirrus,firmware-uid", FIRMWARE_UID),
	{ }
};

/* sdw:<bus>:<link>:<mfg>:<part>:<class>[:<uid>] - Cirrus Logic (01fa) CS35L56 (3556) */
static bool is_cs35l56(struct device *dev)
{
	return strstr(dev_name(dev), ":01fa:3556:");
}

static void add_firmware_uid(struct device *dev)
{
	int ret;

	if (!is_cs35l56(dev) || device_property_present(dev, "cirrus,firmware-uid"))
		return;

	ret = device_create_managed_software_node(dev, amp_props, NULL);
	if (ret) {
		dev_warn(dev, "proart_audio: could not add firmware UID: %d\n", ret);
		return;
	}
	dev_info(dev, "proart_audio: firmware UID %s%s\n", FIRMWARE_UID,
		 dev->driver ? " (driver already bound, effective after re-probe)" : "");
}

static int sdw_bus_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	/* ADD_DEVICE is sent before the device is probed */
	if (action == BUS_NOTIFY_ADD_DEVICE)
		add_firmware_uid(data);
	return NOTIFY_DONE;
}

static struct notifier_block sdw_nb = {
	.notifier_call = sdw_bus_notify,
};

static int add_existing(struct device *dev, void *data)
{
	add_firmware_uid(dev);
	return 0;
}

static int __init proart_audio_init(void)
{
	int ret;

	if (!dmi_match(DMI_SYS_VENDOR, "ASUS") || !dmi_match(DMI_BOARD_NAME, "H7607BA"))
		return -ENODEV;

	ret = bus_register_notifier(&sdw_bus_type, &sdw_nb);
	if (ret)
		return ret;
	bus_for_each_dev(&sdw_bus_type, NULL, NULL, add_existing);
	return 0;
}

static void __exit proart_audio_exit(void)
{
	bus_unregister_notifier(&sdw_bus_type, &sdw_nb);
}

module_init(proart_audio_init);
module_exit(proart_audio_exit);

MODULE_DESCRIPTION("CS35L56 firmware UID for the ASUS ProArt P16 H7607BA (NVIDIA N1X)");
MODULE_LICENSE("GPL");
