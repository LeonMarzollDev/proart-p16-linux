// SPDX-License-Identifier: GPL-2.0
/*
 * proart_battery - battery, AC adapter, fan, performance modes and charge limit for the
 * ASUS ProArt P16 H7607BA (NVIDIA N1X)
 *
 * The BIOS talks to the ASUS EC service over FF-A, but on Linux the responses never
 * reach the AML, so ACPI _BST/_PSR/_FST report zeros or garbage and the ASUS WMI
 * methods have no effect. This driver sends the same EC commands directly
 * (FFA_MSG_SEND_DIRECT_REQ2) and exposes the result as power supplies, a fan hwmon
 * and a platform profile. Static data (capacities, design voltage) comes from the EC
 * shared memory the BIOS maps as \_SB.B0DC/B0FC/B0DV.
 *
 * EC command layouts (rawdata from x4 on, little endian), taken from the BIOS AML:
 *   0x15 battery status: response x4 = status | current<<16 | remaining<<32 | voltage<<48
 *        (current in mA as s16, remaining capacity in mAh, voltage in mV)
 *   0x0c read register:  x4 = 0x0c | (0xfe000900 + reg)<<8 | len<<40, response x4 = value
 *   0x0b write register: as 0x0c, value in x5 bits 8..39
 *   0x13 EC command:     x4 = 0x13 | flag<<8 | dnum<<16 | cmd<<24 | data<<32, response x4 = value
 *        (flag 1 = read; cmd 0xc4 reads, 0xc5 writes an EC register)
 * The ASUS WMI functions use a mailbox in the registers (AML WEBC/REBC): data at 0x40,
 * command at 0x6e, control at 0x6f (bit 7 go/ready, bit 6 release, bit 5 read request).
 *   mailbox 0x11 [mode, 0]: thermal policy, ATKD DEVS 0x00120075 (1 standard, 4 performance, 2 silent)
 *   mailbox 0x06 [percent, 0]: charge limit, ATKD DEVS 0x00120057; mailbox read 0x05 returns it
 */
#include <linux/acpi.h>
#include <linux/arm_ffa.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dmi.h>
#include <linux/efi.h>
#include <linux/hwmon.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/platform_profile.h>
#include <linux/power_supply.h>
#include <linux/reboot.h>
#include <linux/suspend.h>
#include <linux/uuid.h>
#include <linux/workqueue.h>

#define UUID_ASUS_EC UUID_INIT(0x884a63a0, 0x3285, 0x4120, 0x83, 0xaa, 0xee, 0xc0, 0x08, 0xa0, 0xa5, 0x46)

#define EC_CMD_WRITE_REG	0x0b
#define EC_CMD_READ_REG		0x0c
#define EC_CMD_EC_COMMAND	0x13
#define EC_CMD_BAT_STATUS	0x15
#define EC_REG_BASE		0xfe000900ULL
#define EC_REG_POWER		0x90	/* bit 0: AC adapter present */
#define EC_REG_FAN_LO		0xc6	/* fan speed in rpm, low/high byte */
#define EC_REG_FAN_HI		0xc7
#define EC_REG_TEMP		0x98	/* EC temperature in C (AML RTMP, \_TZ.THRM) */
#define EC_REG_TEMP_CRIT	0x99	/* its critical limit in C (AML RCRT) */
#define EC_XRAM_TEMP		0x0700	/* EC RAM, temperature in C (\_TZ.THZ0._TMP) */
#define EC_REG_MBOX_DATA	0x40
#define EC_REG_MBOX_CMD		0x6e
#define EC_REG_MBOX_CTRL	0x6f
#define EC_MBOX_GO		BIT(7)
#define EC_MBOX_RELEASE		BIT(6)
#define EC_MBOX_READ		BIT(5)

#define EC_MBOX_THERMAL_POLICY	0x11
#define EC_MBOX_CHARGE_LIMIT	0x06
#define EC_MBOX_CHARGE_STATUS	0x05
#define EC_POLICY_STANDARD	1
#define EC_POLICY_SILENT	2
#define EC_POLICY_PERFORMANCE	4
#define EC_XREG_SILENT		0x05	/* EC register, bit 0 set in silent mode */

static unsigned int poll_interval = 10;
module_param(poll_interval, uint, 0644);
MODULE_PARM_DESC(poll_interval, "Polling interval in seconds (default 10)");

static bool efi_poweroff = true;
module_param(efi_poweroff, bool, 0444);
MODULE_PARM_DESC(efi_poweroff,
		 "Power off through UEFI ResetSystem instead of PSCI SYSTEM_OFF (default true)");

static bool hide_acpi = true;
module_param(hide_acpi, bool, 0444);
MODULE_PARM_DESC(hide_acpi, "Unbind the non-working ACPI BAT0/AC0 while loaded (default true)");

struct proart_bat {
	struct platform_device *pdev;
	struct ffa_device *ffa;
	struct power_supply *bat;
	struct power_supply *ac;
	struct delayed_work work;
	struct mutex lock;		/* protects the fields below and EC access */

	u32 design_mah, full_mah, design_mv;
	bool valid;
	bool ac_online;
	int current_ma;			/* > 0 charging, < 0 discharging */
	u32 remaining_mah, voltage_mv, cycles;

	enum platform_profile_option profile;
	u32 charge_limit;		/* percent, 100 = no limit */

	struct device *hwmon, *ppdev;
	struct sys_off_handler *sys_off;
	struct notifier_block pm_nb;
	struct work_struct resume_work;
	struct device *acpi_bat_dev, *acpi_ac_dev, *acpi_fan_dev;
	struct device *acpi_tz_dev[4];
};

/*
 * ACPI thermal zones that mislead: PSYS and PSOC report system and SoC power (mW) as
 * temperatures, THRM and THZ0 read the EC through the broken path and show fixed values.
 * The driver unbinds them and reports the same quantities correctly through its hwmon.
 */
static const char * const misleading_tz[] = {
	"\\_TZ_.PSYS", "\\_TZ_.PSOC", "\\_TZ_.THRM", "\\_TZ_.THZ0"
};

static struct proart_bat *pb;

static int ec_send2(u64 x4, u64 x5, u64 *resp)
{
	struct ffa_send_direct_data2 d = { 0 };
	int ret;

	d.data[0] = x4;
	d.data[1] = x5;
	ret = pb->ffa->ops->msg_ops->sync_send_receive2(pb->ffa, &d);
	if (ret)
		return ret;
	if (resp)
		*resp = d.data[0];
	return 0;
}

static int ec_send(u64 x4, u64 *resp)
{
	return ec_send2(x4, 0, resp);
}

static int ec_read_reg(u8 reg, u32 *val)
{
	u64 resp;
	int ret;

	ret = ec_send(EC_CMD_READ_REG | (EC_REG_BASE + reg) << 8 | 1ULL << 40, &resp);
	if (!ret)
		*val = resp & 0xff;
	return ret;
}

static int ec_write_reg(u8 reg, u8 val)
{
	return ec_send2(EC_CMD_WRITE_REG | (EC_REG_BASE + reg) << 8 | 1ULL << 40, (u64)val << 8,
			NULL);
}

/* AML RWEC: up to 4 data bytes; with read set, returns the low byte of the answer */
static int ec_command(bool read, u8 cmd, const u8 *data, int n, u32 *val)
{
	u64 x4 = EC_CMD_EC_COMMAND | (u64)read << 8 | (u64)n << 16 | (u64)cmd << 24;
	u64 resp;
	int i, ret;

	for (i = 0; i < n; i++)
		x4 |= (u64)data[i] << (32 + 8 * i);
	ret = ec_send(x4, &resp);
	if (!ret && val)
		*val = resp & 0xff;
	return ret;
}

static int ec_command_read(u8 cmd, u8 data, u32 *val)
{
	return ec_command(true, cmd, &data, 1, val);
}

/* AML WEBC/REBC: wait until the mailbox is idle, give up the way the AML does */
static int ec_mbox_idle(void)
{
	u32 ctrl;
	int i;

	for (i = 0; i < 200; i++) {
		if (ec_read_reg(EC_REG_MBOX_CTRL, &ctrl))
			return -EIO;
		if (!ctrl)
			return 0;
		usleep_range(100, 200);
	}
	ec_write_reg(EC_REG_MBOX_CTRL, ctrl | EC_MBOX_RELEASE);
	return -ETIMEDOUT;
}

static int ec_mbox_write(u8 cmd, const u8 *data, int len)
{
	u32 ctrl;
	int i, ret;

	ret = ec_mbox_idle();
	if (ret)
		return ret;
	for (i = 0; i < len; i++) {
		ret = ec_write_reg(EC_REG_MBOX_DATA + i, data[i]);
		if (ret)
			return ret;
	}
	ret = ec_read_reg(EC_REG_MBOX_CTRL, &ctrl);
	if (!ret)
		ret = ec_write_reg(EC_REG_MBOX_CTRL, ctrl | EC_MBOX_GO);
	if (!ret)
		ret = ec_write_reg(EC_REG_MBOX_CMD, cmd);
	return ret;
}

static int ec_mbox_read(u8 cmd, u8 *data, int len)
{
	u32 ctrl, val;
	int i, ret;

	ret = ec_mbox_idle();
	if (ret)
		return ret;
	ret = ec_read_reg(EC_REG_MBOX_CTRL, &ctrl);
	if (!ret)
		ret = ec_write_reg(EC_REG_MBOX_CTRL, ctrl | EC_MBOX_READ);
	if (!ret)
		ret = ec_write_reg(EC_REG_MBOX_CMD, cmd);
	if (ret)
		return ret;
	for (i = 0; i < 500; i++) {
		ret = ec_read_reg(EC_REG_MBOX_CTRL, &ctrl);
		if (ret)
			return ret;
		if (ctrl & EC_MBOX_GO)
			break;
		usleep_range(100, 200);
	}
	if (!(ctrl & EC_MBOX_GO))
		return -ETIMEDOUT;
	for (i = 0; i < len; i++) {
		ret = ec_read_reg(EC_REG_MBOX_DATA + i, &val);
		if (ret)
			return ret;
		data[i] = val;
	}
	return ec_write_reg(EC_REG_MBOX_CTRL, ctrl | EC_MBOX_RELEASE);
}

static int read_acpi_u32(const char *path, u32 *val)
{
	unsigned long long v;
	acpi_status status;

	status = acpi_evaluate_integer(NULL, (acpi_string)path, NULL, &v);
	if (ACPI_FAILURE(status))
		return -ENODEV;
	*val = v;
	return 0;
}

/*
 * Part of DEVS 0x00120075 that the AML runs once while the BIOS flag \_SB.ECFG is set:
 * clear bit 0 of the EC RAM bytes 0xd000 and 0xd800 (EC commands 0xcc read, 0xcd write).
 */
static int ec_ecfg_cleanup(void)
{
	static const u16 addrs[] = { 0xd000, 0xd800 };
	static bool done;
	u32 ecfg, val;
	int i, ret;

	if (done)
		return 0;
	done = true;
	if (read_acpi_u32("\\_SB.ECFG", &ecfg) || (ecfg & 0xff) != 1)
		return 0;
	for (i = 0; i < ARRAY_SIZE(addrs); i++) {
		u8 a[3] = { addrs[i] & 0xff, addrs[i] >> 8, 0 };

		ret = ec_command(true, 0xcc, a, 2, &val);
		if (ret)
			return ret;
		a[2] = val & ~1;
		ret = ec_command(false, 0xcd, a, 3, NULL);
		if (ret)
			return ret;
	}
	return 0;
}

/* ATKD DEVS 0x00120075 (MyASUS fan mode), same steps as the AML; caller holds pb->lock */
static int ec_set_thermal_policy(u8 policy)
{
	static const u8 zero;
	u8 mode[2] = { policy, 0 };
	u8 xreg[2] = { EC_XREG_SILENT, 0 };
	u32 val;
	int ret;

	ret = ec_command_read(0xc4, EC_XREG_SILENT, &val);
	if (ret)
		return ret;
	xreg[1] = val & ~1;
	ret = ec_command(false, 0xc5, xreg, 2, NULL);
	if (!ret)
		ret = ec_mbox_write(0x23, &zero, 1);
	if (!ret)
		ret = ec_mbox_write(0x2a, &zero, 1);
	if (!ret)
		ret = ec_ecfg_cleanup();
	if (!ret && policy == EC_POLICY_SILENT) {
		xreg[1] |= 1;
		ret = ec_command(false, 0xc5, xreg, 2, NULL);
	}
	if (!ret)
		ret = ec_mbox_write(EC_MBOX_THERMAL_POLICY, mode, 2);
	return ret;
}

/* ATKD DEVS 0x00120057 (MyASUS battery care); caller holds pb->lock */
static int ec_set_charge_limit(u32 percent)
{
	u8 buf[2] = { percent, 0 };
	int ret;

	ret = ec_mbox_write(EC_MBOX_CHARGE_LIMIT, buf, 2);
	/* the EC does not answer for a moment; the AML waits one second as well */
	msleep(1000);
	return ret;
}

static u8 profile_to_policy(enum platform_profile_option profile)
{
	switch (profile) {
	case PLATFORM_PROFILE_QUIET:
		return EC_POLICY_SILENT;
	case PLATFORM_PROFILE_PERFORMANCE:
		return EC_POLICY_PERFORMANCE;
	default:
		return EC_POLICY_STANDARD;
	}
}

static void proart_bat_update(void)
{
	u32 power, cyc_lo, cyc_hi;
	bool changed = false;
	u64 st;
	int cur;

	mutex_lock(&pb->lock);
	if (ec_send(EC_CMD_BAT_STATUS, &st) || ec_read_reg(EC_REG_POWER, &power)) {
		pb->valid = false;
		mutex_unlock(&pb->lock);
		return;
	}
	if (!ec_command_read(0xc4, 0x2f, &cyc_hi) && !ec_command_read(0xc4, 0x2e, &cyc_lo))
		pb->cycles = cyc_hi << 8 | cyc_lo;

	cur = (s16)((st >> 16) & 0xffff);
	changed = !pb->valid ||
		  pb->ac_online != !!(power & 1) ||
		  pb->current_ma != cur ||
		  pb->remaining_mah != ((st >> 32) & 0xffff);
	pb->ac_online = power & 1;
	pb->current_ma = cur;
	pb->remaining_mah = (st >> 32) & 0xffff;
	pb->voltage_mv = (st >> 48) & 0xffff;
	pb->valid = true;
	mutex_unlock(&pb->lock);

	/* the first update runs from init, before the power supplies exist */
	if (changed && pb->ac && pb->bat) {
		power_supply_changed(pb->ac);
		power_supply_changed(pb->bat);
	}
}

static void proart_bat_work(struct work_struct *work)
{
	proart_bat_update();
	schedule_delayed_work(&pb->work, secs_to_jiffies(max(poll_interval, 2U)));
}

static int proart_bat_capacity(void)
{
	if (!pb->full_mah)
		return 0;
	return clamp_t(int, pb->remaining_mah * 100 / pb->full_mah, 0, 100);
}

static int proart_bat_status(void)
{
	if (pb->current_ma > 10)
		return POWER_SUPPLY_STATUS_CHARGING;
	if (pb->current_ma < -10)
		return POWER_SUPPLY_STATUS_DISCHARGING;
	if (pb->ac_online)
		return proart_bat_capacity() >= 95 ? POWER_SUPPLY_STATUS_FULL :
						     POWER_SUPPLY_STATUS_NOT_CHARGING;
	return POWER_SUPPLY_STATUS_DISCHARGING;
}

static const enum power_supply_property bat_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_CYCLE_COUNT,
	POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_POWER_NOW,
	POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN,
	POWER_SUPPLY_PROP_ENERGY_FULL,
	POWER_SUPPLY_PROP_ENERGY_NOW,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_CAPACITY_LEVEL,
	POWER_SUPPLY_PROP_SCOPE,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
	POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,
};

static int bat_get_property(struct power_supply *psy, enum power_supply_property psp,
			    union power_supply_propval *val)
{
	int ret = 0, cap;

	mutex_lock(&pb->lock);
	if (!pb->valid && psp != POWER_SUPPLY_PROP_PRESENT &&
	    psp != POWER_SUPPLY_PROP_MODEL_NAME && psp != POWER_SUPPLY_PROP_MANUFACTURER &&
	    psp != POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD) {
		mutex_unlock(&pb->lock);
		return -ENODATA;
	}

	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		val->intval = proart_bat_status();
		break;
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		break;
	case POWER_SUPPLY_PROP_CYCLE_COUNT:
		val->intval = pb->cycles;
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN:
		val->intval = pb->design_mv * 1000;
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		val->intval = pb->voltage_mv * 1000;
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		val->intval = abs(pb->current_ma) * 1000;
		break;
	case POWER_SUPPLY_PROP_POWER_NOW:	/* mA * mV = uW */
		val->intval = abs(pb->current_ma) * pb->voltage_mv;
		break;
	case POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN:	/* mAh * mV = uWh, as the BIOS does */
		val->intval = pb->design_mah * pb->design_mv;
		break;
	case POWER_SUPPLY_PROP_ENERGY_FULL:
		val->intval = pb->full_mah * pb->design_mv;
		break;
	case POWER_SUPPLY_PROP_ENERGY_NOW:
		val->intval = min(pb->remaining_mah, pb->full_mah) * pb->design_mv;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		val->intval = proart_bat_capacity();
		break;
	case POWER_SUPPLY_PROP_CAPACITY_LEVEL:
		cap = proart_bat_capacity();
		if (proart_bat_status() == POWER_SUPPLY_STATUS_FULL)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_FULL;
		else if (cap <= 5)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
		else if (cap <= 15)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_LOW;
		else
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
		break;
	case POWER_SUPPLY_PROP_SCOPE:
		val->intval = POWER_SUPPLY_SCOPE_SYSTEM;
		break;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "ASUS Battery";
		break;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "ASUSTeK";
		break;
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD:
		val->intval = pb->charge_limit;
		break;
	default:
		ret = -EINVAL;
	}
	mutex_unlock(&pb->lock);
	return ret;
}

static int bat_set_property(struct power_supply *psy, enum power_supply_property psp,
			    const union power_supply_propval *val)
{
	int ret;

	if (psp != POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD)
		return -EINVAL;
	if (val->intval < 20 || val->intval > 100)
		return -EINVAL;
	mutex_lock(&pb->lock);
	ret = ec_set_charge_limit(val->intval);
	if (!ret)
		pb->charge_limit = val->intval;
	mutex_unlock(&pb->lock);
	return ret;
}

static int bat_property_is_writeable(struct power_supply *psy, enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD;
}

static const enum power_supply_property ac_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
};

static int ac_get_property(struct power_supply *psy, enum power_supply_property psp,
			   union power_supply_propval *val)
{
	if (psp != POWER_SUPPLY_PROP_ONLINE)
		return -EINVAL;
	mutex_lock(&pb->lock);
	val->intval = pb->ac_online;
	mutex_unlock(&pb->lock);
	return 0;
}

static const struct power_supply_desc bat_desc = {
	.name = "BAT1",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = bat_props,
	.num_properties = ARRAY_SIZE(bat_props),
	.get_property = bat_get_property,
	.set_property = bat_set_property,
	.property_is_writeable = bat_property_is_writeable,
};

static char *ac_supplied_to[] = { "BAT1" };

static const struct power_supply_desc ac_desc = {
	.name = "ADP1",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.properties = ac_props,
	.num_properties = ARRAY_SIZE(ac_props),
	.get_property = ac_get_property,
};

static umode_t ec_hwmon_is_visible(const void *drvdata, enum hwmon_sensor_types type, u32 attr,
				   int channel)
{
	return 0444;
}

/* power from the SoC power monitor, which the AML maps to the PSYS/PSOC "thermal zones" */
static int read_tz_power(int channel, long *val)
{
	u32 mw;

	if (read_acpi_u32(channel ? "\\_TZ.PSOC._TMP" : "\\_TZ.PSYS._TMP", &mw))
		return -EIO;
	*val = (long)mw * 1000;
	return 0;
}

static int ec_hwmon_read(struct device *dev, enum hwmon_sensor_types type, u32 attr, int channel,
			 long *val)
{
	static const u8 xram_temp[2] = { EC_XRAM_TEMP & 0xff, EC_XRAM_TEMP >> 8 };
	u32 lo, hi;
	int ret;

	if (type == hwmon_power)
		return read_tz_power(channel, val);

	mutex_lock(&pb->lock);
	if (type == hwmon_fan) {
		ret = ec_read_reg(EC_REG_FAN_LO, &lo);
		if (!ret)
			ret = ec_read_reg(EC_REG_FAN_HI, &hi);
		lo |= hi << 8;
	} else if (channel == 0) {
		ret = ec_read_reg(attr == hwmon_temp_crit ? EC_REG_TEMP_CRIT : EC_REG_TEMP, &lo);
		lo *= 1000;
	} else {
		ret = ec_command(true, 0xcc, xram_temp, 2, &lo);
		lo *= 1000;
	}
	mutex_unlock(&pb->lock);
	if (!ret)
		*val = lo;
	return ret;
}

static int ec_hwmon_read_string(struct device *dev, enum hwmon_sensor_types type, u32 attr,
				int channel, const char **str)
{
	static const char * const temp_labels[] = { "EC", "EC sensor 2" };
	static const char * const power_labels[] = { "System", "SoC" };

	*str = type == hwmon_temp ? temp_labels[channel] : power_labels[channel];
	return 0;
}

static const struct hwmon_ops ec_hwmon_ops = {
	.is_visible = ec_hwmon_is_visible,
	.read = ec_hwmon_read,
	.read_string = ec_hwmon_read_string,
};

static const struct hwmon_channel_info * const ec_hwmon_info[] = {
	HWMON_CHANNEL_INFO(fan, HWMON_F_INPUT),
	HWMON_CHANNEL_INFO(temp, HWMON_T_INPUT | HWMON_T_CRIT | HWMON_T_LABEL,
			   HWMON_T_INPUT | HWMON_T_LABEL),
	HWMON_CHANNEL_INFO(power, HWMON_P_INPUT | HWMON_P_LABEL, HWMON_P_INPUT | HWMON_P_LABEL),
	NULL
};

static const struct hwmon_chip_info ec_hwmon_chip = {
	.ops = &ec_hwmon_ops,
	.info = ec_hwmon_info,
};

static int pp_probe(void *drvdata, unsigned long *choices)
{
	set_bit(PLATFORM_PROFILE_QUIET, choices);
	set_bit(PLATFORM_PROFILE_BALANCED, choices);
	set_bit(PLATFORM_PROFILE_PERFORMANCE, choices);
	return 0;
}

static int pp_get(struct device *dev, enum platform_profile_option *profile)
{
	mutex_lock(&pb->lock);
	*profile = pb->profile;
	mutex_unlock(&pb->lock);
	return 0;
}

static int pp_set(struct device *dev, enum platform_profile_option profile)
{
	int ret;

	mutex_lock(&pb->lock);
	ret = ec_set_thermal_policy(profile_to_policy(profile));
	if (!ret)
		pb->profile = profile;
	mutex_unlock(&pb->lock);
	return ret;
}

static const struct platform_profile_ops pp_ops = {
	.probe = pp_probe,
	.profile_get = pp_get,
	.profile_set = pp_set,
};

/* the EC may fall back to its defaults during suspend */
static void proart_resume_work(struct work_struct *work)
{
	mutex_lock(&pb->lock);
	if (pb->profile != PLATFORM_PROFILE_BALANCED &&
	    ec_set_thermal_policy(profile_to_policy(pb->profile)))
		pr_warn("proart_battery: could not restore the performance mode\n");
	if (pb->charge_limit < 100 && ec_set_charge_limit(pb->charge_limit))
		pr_warn("proart_battery: could not restore the charge limit\n");
	mutex_unlock(&pb->lock);
}

static int proart_pm_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	if (action == PM_POST_SUSPEND)
		schedule_work(&pb->resume_work);
	return NOTIFY_DONE;
}

/* Performance modes and charge limit are extras: failures only disable them */
static void proart_ec_extras_init(void)
{
	u8 status[3];
	u32 thpl;

	pb->hwmon = hwmon_device_register_with_info(&pb->pdev->dev, "proart_ec", NULL,
						    &ec_hwmon_chip, NULL);
	if (IS_ERR(pb->hwmon)) {
		pr_warn("proart_battery: sensors not registered (%ld)\n", PTR_ERR(pb->hwmon));
		pb->hwmon = NULL;
	}

	pb->charge_limit = 100;
	mutex_lock(&pb->lock);
	if (!ec_mbox_read(EC_MBOX_CHARGE_STATUS, status, sizeof(status))) {
		pr_info("proart_battery: EC charge status %*ph\n", (int)sizeof(status), status);
		/* bit 7 is set while no limit is active (0xe4 = 100 %) */
		if ((status[0] & 0x7f) >= 20 && (status[0] & 0x7f) <= 100)
			pb->charge_limit = status[0] & 0x7f;
	} else {
		pr_warn("proart_battery: EC charge status not readable\n");
	}

	/* the AML keeps the last mode in \_SB.THPL; apply it so EC and driver agree */
	pb->profile = PLATFORM_PROFILE_BALANCED;
	if (!read_acpi_u32("\\_SB.THPL", &thpl)) {
		if ((thpl & 0xff) == EC_POLICY_SILENT)
			pb->profile = PLATFORM_PROFILE_QUIET;
		else if ((thpl & 0xff) == EC_POLICY_PERFORMANCE)
			pb->profile = PLATFORM_PROFILE_PERFORMANCE;
	}
	if (ec_set_thermal_policy(profile_to_policy(pb->profile))) {
		mutex_unlock(&pb->lock);
		pr_warn("proart_battery: EC rejected the thermal policy, no performance modes\n");
		return;
	}
	mutex_unlock(&pb->lock);

	pb->ppdev = platform_profile_register(&pb->pdev->dev, "proart-ec", NULL, &pp_ops);
	if (IS_ERR(pb->ppdev)) {
		pr_warn("proart_battery: platform profile not registered (%ld)\n", PTR_ERR(pb->ppdev));
		pb->ppdev = NULL;
	}
}

static void proart_ec_extras_exit(void)
{
	if (pb->ppdev)
		platform_profile_remove(pb->ppdev);
	if (pb->hwmon)
		hwmon_device_unregister(pb->hwmon);
}

/*
 * arm64 Linux reboots through UEFI ResetSystem() but powers off with PSCI SYSTEM_OFF. After a
 * SYSTEM_OFF the EC cuts the battery (the RTC is reset and the power button only works again
 * with the charger plugged in); after a reboot it does not. Power off the way the reboot goes.
 * If ResetSystem() returns, the next handler (PSCI) powers off as before.
 */
static int proart_efi_power_off(struct sys_off_data *data)
{
	efi.reset_system(EFI_RESET_SHUTDOWN, EFI_SUCCESS, 0, NULL);
	return NOTIFY_DONE;
}

static int match_uuid(struct device *dev, const void *data)
{
	return uuid_equal(&to_ffa_dev(dev)->uuid, data);
}

/* Take the non-working ACPI battery/AC off their drivers so userspace sees only ours */
static struct device *hide_platform_dev(const char *name)
{
	struct device *dev = bus_find_device_by_name(&platform_bus_type, NULL, name);

	if (!dev)
		return NULL;
	if (dev->driver)
		device_release_driver(dev);
	return dev;
}

/* LNXTHERM:xx platform device whose ACPI path is @path, unbound from acpi-thermal */
static struct device *hide_thermal_zone(const char *path)
{
	char name[16];
	int i;

	for (i = 0; i < 32; i++) {
		struct acpi_buffer buf = { ACPI_ALLOCATE_BUFFER, NULL };
		struct device *dev;
		bool match = false;

		snprintf(name, sizeof(name), "LNXTHERM:%02x", i);
		dev = bus_find_device_by_name(&platform_bus_type, NULL, name);
		if (!dev)
			continue;
		if (ACPI_HANDLE(dev) &&
		    ACPI_SUCCESS(acpi_get_name(ACPI_HANDLE(dev), ACPI_FULL_PATHNAME, &buf))) {
			match = !strcmp(buf.pointer, path);
			ACPI_FREE(buf.pointer);
		}
		if (match) {
			if (dev->driver)
				device_release_driver(dev);
			return dev;
		}
		put_device(dev);
	}
	return NULL;
}

static void restore_platform_dev(struct device *dev)
{
	if (!dev)
		return;
	if (device_attach(dev) < 0)
		dev_warn(dev, "could not re-attach ACPI driver\n");
	put_device(dev);
}

static int __init proart_bat_init(void)
{
	static const uuid_t ec_uuid = UUID_ASUS_EC;
	struct power_supply_config cfg = { 0 };
	struct device *dev;
	int i, ret;

	if (!dmi_match(DMI_SYS_VENDOR, "ASUS") || !dmi_match(DMI_BOARD_NAME, "H7607BA"))
		return -ENODEV;

	pb = kzalloc(sizeof(*pb), GFP_KERNEL);
	if (!pb)
		return -ENOMEM;
	mutex_init(&pb->lock);
	INIT_DELAYED_WORK(&pb->work, proart_bat_work);
	INIT_WORK(&pb->resume_work, proart_resume_work);

	dev = bus_find_device(&ffa_bus_type, NULL, &ec_uuid, match_uuid);
	if (!dev) {
		ret = -EPROBE_DEFER;
		pr_err("proart_battery: ASUS EC service not found on the FF-A bus\n");
		goto err_free;
	}
	pb->ffa = to_ffa_dev(dev);
	if (!pb->ffa->ops || !pb->ffa->ops->msg_ops || !pb->ffa->ops->msg_ops->sync_send_receive2) {
		ret = -ENODEV;
		goto err_put_ffa;
	}

	if (read_acpi_u32("\\_SB.B0DC", &pb->design_mah) ||
	    read_acpi_u32("\\_SB.B0FC", &pb->full_mah) ||
	    read_acpi_u32("\\_SB.B0DV", &pb->design_mv)) {
		ret = -ENODEV;
		pr_err("proart_battery: battery information (\\_SB.B0DC/B0FC/B0DV) not readable\n");
		goto err_put_ffa;
	}
	pb->design_mah &= 0xffff;
	pb->full_mah &= 0xffff;
	if (!pb->full_mah)
		pb->full_mah = pb->design_mah;

	/* the EC can be busy for a moment, e.g. right after a charge limit change */
	for (i = 0; i < 5 && !pb->valid; i++) {
		if (i)
			msleep(500);
		proart_bat_update();
	}
	if (!pb->valid) {
		ret = -EIO;
		pr_err("proart_battery: EC battery status query failed\n");
		goto err_put_ffa;
	}

	pb->pdev = platform_device_register_simple("proart-battery", PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(pb->pdev)) {
		ret = PTR_ERR(pb->pdev);
		goto err_put_ffa;
	}

	if (hide_acpi) {
		pb->acpi_bat_dev = hide_platform_dev("PNP0C0A:00");
		pb->acpi_ac_dev = hide_platform_dev("ACPI0003:00");
		pb->acpi_fan_dev = hide_platform_dev("PNP0C0B:00");
		for (i = 0; i < ARRAY_SIZE(misleading_tz); i++)
			pb->acpi_tz_dev[i] = hide_thermal_zone(misleading_tz[i]);
	}

	cfg.supplied_to = ac_supplied_to;
	cfg.num_supplicants = ARRAY_SIZE(ac_supplied_to);
	pb->ac = power_supply_register(&pb->pdev->dev, &ac_desc, &cfg);
	if (IS_ERR(pb->ac)) {
		ret = PTR_ERR(pb->ac);
		goto err_restore;
	}
	pb->bat = power_supply_register(&pb->pdev->dev, &bat_desc, NULL);
	if (IS_ERR(pb->bat)) {
		ret = PTR_ERR(pb->bat);
		goto err_unreg_ac;
	}

	proart_ec_extras_init();
	if (efi_poweroff && efi_enabled(EFI_RUNTIME_SERVICES) && efi.reset_system) {
		/* priorities are unique per chain; anything above PSCI's FIRMWARE level runs first */
		pb->sys_off = register_sys_off_handler(SYS_OFF_MODE_POWER_OFF, SYS_OFF_PRIO_FIRMWARE + 16,
						       proart_efi_power_off, NULL);
		if (IS_ERR(pb->sys_off)) {
			pr_warn("proart_battery: UEFI power-off handler not registered (%ld)\n",
				PTR_ERR(pb->sys_off));
			pb->sys_off = NULL;
		} else {
			pr_info("proart_battery: powering off through UEFI ResetSystem\n");
		}
	}
	pb->pm_nb.notifier_call = proart_pm_notify;
	register_pm_notifier(&pb->pm_nb);

	pr_info("proart_battery: %u/%u mAh (design %u mAh, %u mV), %d mA, %u mV, AC %s, charge limit %u %%\n",
		pb->remaining_mah, pb->full_mah, pb->design_mah, pb->design_mv,
		pb->current_ma, pb->voltage_mv, pb->ac_online ? "online" : "offline",
		pb->charge_limit);
	schedule_delayed_work(&pb->work, secs_to_jiffies(max(poll_interval, 2U)));
	return 0;

err_unreg_ac:
	power_supply_unregister(pb->ac);
err_restore:
	for (i = 0; i < ARRAY_SIZE(pb->acpi_tz_dev); i++)
		restore_platform_dev(pb->acpi_tz_dev[i]);
	restore_platform_dev(pb->acpi_fan_dev);
	restore_platform_dev(pb->acpi_ac_dev);
	restore_platform_dev(pb->acpi_bat_dev);
	platform_device_unregister(pb->pdev);
err_put_ffa:
	put_device(&pb->ffa->dev);
err_free:
	kfree(pb);
	return ret;
}

static void __exit proart_bat_exit(void)
{
	int i;

	if (pb->sys_off)
		unregister_sys_off_handler(pb->sys_off);
	unregister_pm_notifier(&pb->pm_nb);
	cancel_work_sync(&pb->resume_work);
	cancel_delayed_work_sync(&pb->work);
	proart_ec_extras_exit();
	power_supply_unregister(pb->bat);
	power_supply_unregister(pb->ac);
	for (i = 0; i < ARRAY_SIZE(pb->acpi_tz_dev); i++)
		restore_platform_dev(pb->acpi_tz_dev[i]);
	restore_platform_dev(pb->acpi_fan_dev);
	restore_platform_dev(pb->acpi_ac_dev);
	restore_platform_dev(pb->acpi_bat_dev);
	platform_device_unregister(pb->pdev);
	put_device(&pb->ffa->dev);
	kfree(pb);
}

module_init(proart_bat_init);
module_exit(proart_bat_exit);

MODULE_DESCRIPTION("Battery, AC adapter, fan, performance modes and charge limit via the ASUS EC FF-A service (ASUS ProArt P16 H7607BA, NVIDIA N1X)");
MODULE_LICENSE("GPL");
