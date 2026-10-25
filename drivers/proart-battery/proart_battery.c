// SPDX-License-Identifier: GPL-2.0
/*
 * proart_battery - battery, AC adapter, fan, performance modes and charge limit for the
 * ASUS ProArt P16 H7607BA (NVIDIA N1X)
 *
 * The BIOS reaches the ASUS EC service (FF-A partition 0x8003, UUID 884a63a0-...) through an
 * FFH operation region with Offset 2 (Arm DEN0048D, FFA_MSG_SEND_DIRECT_REQ2), which linux-nvidia
 * implements in nvidia-ffa-ec. Whether ACPI then works depends on the BIOS:
 *
 *  - H7607BA.300: the EC accessors (\_SB.EC0.RRA9/RRA8/WRA9/WRA8/RWEC, \_SB.BAT0.GBST) build the
 *    FF-A packet in a Local (Local0 = Buffer(){}; CreateQWordField (Local0, ...)) and then do
 *    "Local0 = FFAC = Local0". ACPICA returns the FF-A response in a new buffer object, the Store
 *    rebinds Local0 to it, and the buffer fields still point at the old object holding the
 *    request: the AML reads its own request back ("the EC echoes"). _BST/_PSR/_FST are then
 *    garbage. This driver sends the EC commands itself and registers BAT1/ADP1 ("ec" mode).
 *  - H7607BA.303: the same methods use Name (RBUF, Buffer(){}), which a Store updates in place;
 *    the stock ACPI battery (BAT0), AC adapter (AC0), fan and thermal zones should work. The
 *    driver then only adds what ACPI does not provide ("acpi" mode): the charge limit on BAT0,
 *    the ASUS fan modes as a platform profile, EC sensors and the UEFI power-off.
 *
 * "auto" (default) picks the mode by reading EC register 0x90 both through the AML
 * (\_SB.EC0.RRA9) and directly and comparing the two.
 *
 * EC command layouts (rawdata from x4 on, little endian), taken from the BIOS AML:
 *   0x15 battery status: response x4 = status | current<<16 | remaining<<32 | voltage<<48
 *        (current in mA as s16, remaining capacity in mAh, voltage in mV)
 *   0x0c read register:  x4 = 0x0c | (0xfe000900 + reg)<<8 | len<<40, response x4 = value
 *   0x0b write register: as 0x0c, value in x5 bits 8..39
 *   0x13 EC command:     x4 = 0x13 | flag<<8 | dnum<<16 | cmd<<24 | data<<32, response x4 = value
 *        (flag 1 = read; cmd 0xc4 reads, 0xc5 writes an EC register)
 * The ASUS WMI functions use a mailbox in the registers (AML WEBC/REBC, serialized by the AML
 * mutex \_SB.EC0.CMUT): data at 0x40, command at 0x6e, control at 0x6f (bit 7 go/ready, bit 6
 * release, bit 5 read request).
 *   mailbox 0x11 [mode, 0]: thermal policy, ATKD DEVS 0x00120075
 *        (1 standard, 4 performance, 2 silent)
 *   mailbox 0x06 [percent, 0]: charge limit, ATKD DEVS 0x00120057; mailbox read 0x05 returns it
 *
 * The Modern Standby notifications (PEPD _DSM) moved to drivers/proart-s2idle.
 */
#include <acpi/battery.h>
#include <linux/acpi.h>
#include <linux/arm_ffa.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dmi.h>
#include <linux/efi.h>
#include <linux/hwmon.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/platform_profile.h>
#include <linux/power_supply.h>
#include <linux/reboot.h>
#include <linux/string.h>
#include <linux/suspend.h>
#include <linux/uuid.h>
#include <linux/workqueue.h>

#define UUID_ASUS_EC \
	UUID_INIT(0x884a63a0, 0x3285, 0x4120, 0x83, 0xaa, 0xee, 0xc0, 0x08, 0xa0, 0xa5, 0x46)

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

/* the AML mutex around every multi-step EC sequence (GBST, GPWS, WEBC, REBC, ...) */
#define AML_EC_MUTEX		"\\_SB.EC0.CMUT"
#define AML_EC_MUTEX_TIMEOUT_MS	2000
/* the EC service answers BUSY/RETRY while another request (e.g. from the AML) is in flight */
#define EC_SEND_RETRY_MS	20

/* the EC raises no ACPI event when the charger is (un)plugged on .300: polling it is */
static unsigned int poll_interval = 2;
module_param(poll_interval, uint, 0644);
MODULE_PARM_DESC(poll_interval, "Polling interval in seconds in ec mode (default 2, minimum 2)");

static bool efi_poweroff = true;
module_param(efi_poweroff, bool, 0444);
MODULE_PARM_DESC(efi_poweroff,
		 "Power off through UEFI ResetSystem instead of PSCI SYSTEM_OFF (default true)");

static bool hide_acpi = true;
module_param(hide_acpi, bool, 0444);
MODULE_PARM_DESC(hide_acpi,
		 "Unbind the ACPI devices that report wrong values while loaded (default true)");

static char *mode = "auto";
module_param(mode, charp, 0444);
MODULE_PARM_DESC(mode,
		 "auto (default): use ACPI BAT0/AC0 if the BIOS's EC path works, else BAT1/ADP1; acpi; ec");

struct proart_bat {
	struct platform_device *pdev;
	struct ffa_device *ffa;
	struct power_supply *bat;	/* ec mode only */
	struct power_supply *ac;	/* ec mode only */
	struct delayed_work work;
	struct mutex lock;		/* protects the fields below and EC access */
	bool acpi_mode;
	bool have_aml_mutex;

	u32 design_mah, full_mah, design_mv;
	bool valid;
	bool ac_online;
	int current_ma;			/* > 0 charging, < 0 discharging */
	u32 remaining_mah, voltage_mv, cycles;

	enum platform_profile_option profile;
	u32 charge_limit;		/* percent, 100 = no limit */

	struct device *hwmon, *ppdev;
	struct sys_off_handler *sys_off;
	bool pm_nb_registered;
	bool hook_registered;
	struct notifier_block pm_nb;
	struct work_struct resume_work;
	struct acpi_battery_hook hook;
	struct device *acpi_bat_dev, *acpi_ac_dev, *acpi_fan_dev;
	struct device *acpi_tz_dev[4];
};

/*
 * ACPI thermal zones that mislead: PSYS and PSOC report system and SoC power (mW) as
 * temperatures (any BIOS); THRM and THZ0 read the EC through the AML path, which only works
 * in acpi mode. The driver unbinds them and reports the same quantities through its hwmon.
 */
static const char * const misleading_tz[] = {
	"\\_TZ_.PSYS", "\\_TZ_.PSOC", "\\_TZ_.THRM", "\\_TZ_.THZ0"
};

#define MISLEADING_TZ_ANY_BIOS	2	/* the first two are wrong on every BIOS */

static struct proart_bat *pb;

/* --- EC transport ------------------------------------------------------------------------- */

static int ec_send2(u64 x4, u64 x5, u64 *resp)
{
	ktime_t deadline = ktime_add_ms(ktime_get(), EC_SEND_RETRY_MS);
	struct ffa_send_direct_data2 d;
	int ret;

	for (;;) {
		memset(&d, 0, sizeof(d));
		d.data[0] = x4;
		d.data[1] = x5;
		ret = pb->ffa->ops->msg_ops->sync_send_receive2(pb->ffa, &d);
		if ((ret != -EBUSY && ret != -EAGAIN) || ktime_after(ktime_get(), deadline))
			break;
		usleep_range(500, 1000);
	}
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

/*
 * Serialize with the AML, which uses the same EC registers and mailbox under \_SB.EC0.CMUT
 * (e.g. _BST reads the charge-limit mailbox, EC events run REBC). Caller holds pb->lock.
 */
static int ec_aml_lock(void)
{
	if (!pb->have_aml_mutex)
		return 0;
	if (ACPI_FAILURE(acpi_acquire_mutex(NULL, AML_EC_MUTEX, AML_EC_MUTEX_TIMEOUT_MS)))
		return -EBUSY;
	return 0;
}

static void ec_aml_unlock(void)
{
	if (pb->have_aml_mutex)
		acpi_release_mutex(NULL, AML_EC_MUTEX);
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
	u32 ctrl = 0;
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

/* caller holds pb->lock and the AML mutex */
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

/* caller holds pb->lock and the AML mutex */
static int ec_mbox_read(u8 cmd, u8 *data, int len)
{
	u32 ctrl = 0, val;
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

/* --- mode detection ----------------------------------------------------------------------- */

/* \_SB.EC0.RRA9(reg, 1) through the AML and the FFH operation region */
static int aml_read_reg(u8 reg, u64 *val)
{
	union acpi_object args[2] = {
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = reg } },
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = 1 } },
	};
	struct acpi_object_list list = { .count = ARRAY_SIZE(args), .pointer = args };
	unsigned long long v;

	if (ACPI_FAILURE(acpi_evaluate_integer(NULL, "\\_SB.EC0.RRA9", &list, &v)))
		return -EIO;
	*val = v;
	return 0;
}

/*
 * The AML path works if RRA9 returns the register itself. On BIOS .300 it returns the low
 * 32 bits of its own request (0x0009900c for register 0x90), on failure Ones.
 */
static bool aml_ec_path_works(void)
{
	u64 aml;
	u32 direct;
	int i;

	for (i = 0; i < 3; i++) {
		if (i)
			msleep(100);
		if (aml_read_reg(EC_REG_POWER, &aml))
			continue;
		mutex_lock(&pb->lock);
		if (ec_read_reg(EC_REG_POWER, &direct)) {
			mutex_unlock(&pb->lock);
			continue;
		}
		mutex_unlock(&pb->lock);
		pr_info("proart_battery: EC register 0x90: AML %#llx, direct %#x\n", aml, direct);
		if (aml <= 0xff && aml == direct)
			return true;
	}
	return false;
}

/* --- fan modes and charge limit ----------------------------------------------------------- */

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
	if (read_acpi_u32("\\_SB.ECFG", &ecfg) || (ecfg & 0xff) != 1) {
		done = true;
		return 0;
	}
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
	done = true;
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

	ret = ec_aml_lock();
	if (ret)
		return ret;
	ret = ec_command_read(0xc4, EC_XREG_SILENT, &val);
	if (ret)
		goto out;
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
out:
	ec_aml_unlock();
	return ret;
}

/* ATKD DEVS 0x00120057 (MyASUS battery care); caller holds pb->lock */
static int ec_set_charge_limit(u32 percent)
{
	u8 buf[2] = { percent, 0 };
	int ret;

	ret = ec_aml_lock();
	if (ret)
		return ret;
	ret = ec_mbox_write(EC_MBOX_CHARGE_LIMIT, buf, 2);
	ec_aml_unlock();
	/* the EC does not answer for a moment; the AML waits one second as well */
	msleep(1000);
	return ret;
}

static int pb_set_charge_limit(u32 percent)
{
	int ret;

	if (percent < 20 || percent > 100)
		return -EINVAL;
	mutex_lock(&pb->lock);
	ret = ec_set_charge_limit(percent);
	if (!ret)
		pb->charge_limit = percent;
	mutex_unlock(&pb->lock);
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

/* --- ec mode: BAT1 / ADP1 ----------------------------------------------------------------- */

static void proart_bat_update(void)
{
	u32 power, cyc_lo, cyc_hi;
	bool changed;
	u64 st;
	int cur;

	mutex_lock(&pb->lock);
	if (ec_aml_lock()) {
		mutex_unlock(&pb->lock);
		return;
	}
	if (ec_send(EC_CMD_BAT_STATUS, &st) || ec_read_reg(EC_REG_POWER, &power)) {
		ec_aml_unlock();
		pb->valid = false;
		mutex_unlock(&pb->lock);
		return;
	}
	if (!ec_command_read(0xc4, 0x2f, &cyc_hi) && !ec_command_read(0xc4, 0x2e, &cyc_lo))
		pb->cycles = cyc_hi << 8 | cyc_lo;
	ec_aml_unlock();

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

static void proart_bat_schedule(void)
{
	/* freezable: no EC traffic while tasks are frozen for system sleep */
	queue_delayed_work(system_freezable_wq, &pb->work,
			   secs_to_jiffies(max(poll_interval, 2U)));
}

static void proart_bat_work(struct work_struct *work)
{
	proart_bat_update();
	proart_bat_schedule();
}

/* caller holds pb->lock */
static int proart_bat_capacity(void)
{
	if (!pb->full_mah)
		return 0;
	return clamp_t(int, pb->remaining_mah * 100 / pb->full_mah, 0, 100);
}

/* caller holds pb->lock */
static int proart_bat_status(void)
{
	if (pb->current_ma > 10)
		return POWER_SUPPLY_STATUS_CHARGING;
	if (pb->current_ma < -10)
		return POWER_SUPPLY_STATUS_DISCHARGING;
	/* as ACPI reports it: held at the charge limit is "not charging", not "full" */
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
	if (psp != POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD)
		return -EINVAL;
	return pb_set_charge_limit(val->intval);
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

/* --- acpi mode: charge limit on the ACPI battery (power supply extension) ----------------- */

static const enum power_supply_property ext_props[] = {
	POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,
};

static int ext_get_property(struct power_supply *psy, const struct power_supply_ext *ext,
			    void *data, enum power_supply_property psp,
			    union power_supply_propval *val)
{
	if (psp != POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD)
		return -EINVAL;
	mutex_lock(&pb->lock);
	val->intval = pb->charge_limit;
	mutex_unlock(&pb->lock);
	return 0;
}

static int ext_set_property(struct power_supply *psy, const struct power_supply_ext *ext,
			    void *data, enum power_supply_property psp,
			    const union power_supply_propval *val)
{
	if (psp != POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD)
		return -EINVAL;
	return pb_set_charge_limit(val->intval);
}

static int ext_property_is_writeable(struct power_supply *psy,
				     const struct power_supply_ext *ext, void *data,
				     enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD;
}

static const struct power_supply_ext pb_battery_ext = {
	.name = "proart_battery",
	.properties = ext_props,
	.num_properties = ARRAY_SIZE(ext_props),
	.get_property = ext_get_property,
	.set_property = ext_set_property,
	.property_is_writeable = ext_property_is_writeable,
};

static int pb_hook_add_battery(struct power_supply *battery, struct acpi_battery_hook *hook)
{
	/* only the internal battery; returning an error would unload the hook */
	if (strcmp(battery->desc->name, "BAT0"))
		return 0;
	return power_supply_register_extension(battery, &pb_battery_ext, &pb->pdev->dev, NULL);
}

static int pb_hook_remove_battery(struct power_supply *battery, struct acpi_battery_hook *hook)
{
	if (!strcmp(battery->desc->name, "BAT0"))
		power_supply_unregister_extension(battery, &pb_battery_ext);
	return 0;
}

/* --- hwmon --------------------------------------------------------------------------------- */

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
	u32 lo = 0, hi = 0;
	int ret;

	if (type == hwmon_power)
		return read_tz_power(channel, val);

	mutex_lock(&pb->lock);
	ret = ec_aml_lock();
	if (ret)
		goto out;
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
	ec_aml_unlock();
out:
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

/* --- platform profile ---------------------------------------------------------------------- */

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

/* --- suspend / resume ---------------------------------------------------------------------- */

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
	if (!pb->acpi_mode) {
		/* report a charger change during sleep now, not one poll interval later */
		proart_bat_update();
		mod_delayed_work(system_freezable_wq, &pb->work,
				 secs_to_jiffies(max(poll_interval, 2U)));
	}
}

static int proart_pm_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	if (action == PM_POST_SUSPEND)
		schedule_work(&pb->resume_work);
	return NOTIFY_DONE;
}

/* --- setup --------------------------------------------------------------------------------- */

/* Performance modes, charge limit and sensors are extras: failures only disable them */
static void proart_ec_extras_init(void)
{
	u8 status[3];
	u32 thpl;
	int ret;

	pb->hwmon = hwmon_device_register_with_info(&pb->pdev->dev, "proart_ec", NULL,
						    &ec_hwmon_chip, NULL);
	if (IS_ERR(pb->hwmon)) {
		pr_warn("proart_battery: sensors not registered (%ld)\n", PTR_ERR(pb->hwmon));
		pb->hwmon = NULL;
	}

	pb->charge_limit = 100;
	mutex_lock(&pb->lock);
	ret = ec_aml_lock();
	if (!ret) {
		ret = ec_mbox_read(EC_MBOX_CHARGE_STATUS, status, sizeof(status));
		ec_aml_unlock();
	}
	if (!ret) {
		pr_info("proart_battery: EC charge status %*ph\n", (int)sizeof(status), status);
		/* bit 7 is set while no limit is active (0xe4 = 100 %) */
		if ((status[0] & 0x7f) >= 20 && (status[0] & 0x7f) <= 100)
			pb->charge_limit = status[0] & 0x7f;
	} else {
		pr_warn("proart_battery: EC charge status not readable (%d)\n", ret);
	}

	/* the AML keeps the last mode in \_SB.THPL; apply it so EC and driver agree */
	pb->profile = PLATFORM_PROFILE_BALANCED;
	if (!read_acpi_u32("\\_SB.THPL", &thpl)) {
		if ((thpl & 0xff) == EC_POLICY_SILENT)
			pb->profile = PLATFORM_PROFILE_QUIET;
		else if ((thpl & 0xff) == EC_POLICY_PERFORMANCE)
			pb->profile = PLATFORM_PROFILE_PERFORMANCE;
	}
	ret = ec_set_thermal_policy(profile_to_policy(pb->profile));
	mutex_unlock(&pb->lock);
	if (ret) {
		pr_warn("proart_battery: EC rejected the thermal policy (%d), no performance modes\n",
			ret);
		return;
	}

	pb->ppdev = platform_profile_register(&pb->pdev->dev, "proart-ec", NULL, &pp_ops);
	if (IS_ERR(pb->ppdev)) {
		pr_warn("proart_battery: platform profile not registered (%ld)\n",
			PTR_ERR(pb->ppdev));
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

/* Take an ACPI device that reports wrong values off its driver so userspace sees only ours */
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

static void restore_acpi_devs(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(pb->acpi_tz_dev); i++)
		restore_platform_dev(pb->acpi_tz_dev[i]);
	restore_platform_dev(pb->acpi_fan_dev);
	restore_platform_dev(pb->acpi_ac_dev);
	restore_platform_dev(pb->acpi_bat_dev);
}

static void hide_acpi_devs(void)
{
	int i, n = pb->acpi_mode ? MISLEADING_TZ_ANY_BIOS : ARRAY_SIZE(misleading_tz);

	if (!hide_acpi)
		return;
	if (!pb->acpi_mode) {
		pb->acpi_bat_dev = hide_platform_dev("PNP0C0A:00");
		pb->acpi_ac_dev = hide_platform_dev("ACPI0003:00");
		pb->acpi_fan_dev = hide_platform_dev("PNP0C0B:00");
	}
	for (i = 0; i < n; i++)
		pb->acpi_tz_dev[i] = hide_thermal_zone(misleading_tz[i]);
}

/* ec mode: static data from the EC shared memory, first status, BAT1/ADP1 */
static int proart_ec_mode_init(void)
{
	struct power_supply_config cfg = { 0 };
	int i;

	if (read_acpi_u32("\\_SB.B0DC", &pb->design_mah) ||
	    read_acpi_u32("\\_SB.B0FC", &pb->full_mah) ||
	    read_acpi_u32("\\_SB.B0DV", &pb->design_mv)) {
		pr_err("proart_battery: battery information (\\_SB.B0DC/B0FC/B0DV) not readable\n");
		return -ENODEV;
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
		pr_err("proart_battery: EC battery status query failed\n");
		return -EIO;
	}

	cfg.supplied_to = ac_supplied_to;
	cfg.num_supplicants = ARRAY_SIZE(ac_supplied_to);
	pb->ac = power_supply_register(&pb->pdev->dev, &ac_desc, &cfg);
	if (IS_ERR(pb->ac)) {
		i = PTR_ERR(pb->ac);
		pb->ac = NULL;
		return i;
	}
	pb->bat = power_supply_register(&pb->pdev->dev, &bat_desc, NULL);
	if (IS_ERR(pb->bat)) {
		i = PTR_ERR(pb->bat);
		pb->bat = NULL;
		power_supply_unregister(pb->ac);
		pb->ac = NULL;
		return i;
	}
	return 0;
}

static void proart_ec_mode_exit(void)
{
	cancel_delayed_work_sync(&pb->work);
	if (pb->bat)
		power_supply_unregister(pb->bat);
	if (pb->ac)
		power_supply_unregister(pb->ac);
	pb->bat = NULL;
	pb->ac = NULL;
}

static int __init proart_bat_init(void)
{
	static const uuid_t ec_uuid = UUID_ASUS_EC;
	acpi_handle cmut;
	struct device *dev;
	int ret;

	if (!dmi_match(DMI_SYS_VENDOR, "ASUS") || !dmi_match(DMI_BOARD_NAME, "H7607BA"))
		return -ENODEV;
	if (strcmp(mode, "auto") && strcmp(mode, "acpi") && strcmp(mode, "ec")) {
		pr_err("proart_battery: mode must be auto, acpi or ec\n");
		return -EINVAL;
	}

	/* nvidia-ffa-ec (built in, arch_initcall) has enumerated the FF-A services by now */
	dev = bus_find_device(&ffa_bus_type, NULL, &ec_uuid, match_uuid);
	if (!dev) {
		pr_err("proart_battery: ASUS EC service not found on the FF-A bus\n");
		return -ENODEV;
	}

	pb = kzalloc(sizeof(*pb), GFP_KERNEL);
	if (!pb) {
		put_device(dev);
		return -ENOMEM;
	}
	pb->ffa = to_ffa_dev(dev);
	mutex_init(&pb->lock);
	INIT_DELAYED_WORK(&pb->work, proart_bat_work);
	INIT_WORK(&pb->resume_work, proart_resume_work);
	pb->have_aml_mutex = ACPI_SUCCESS(acpi_get_handle(NULL, AML_EC_MUTEX, &cmut));
	if (!pb->have_aml_mutex)
		pr_warn("proart_battery: %s not found, EC access not serialized with the AML\n",
			AML_EC_MUTEX);

	if (!pb->ffa->ops || !pb->ffa->ops->msg_ops || !pb->ffa->ops->msg_ops->sync_send_receive2) {
		ret = -ENODEV;
		goto err_put_ffa;
	}

	if (!strcmp(mode, "acpi")) {
		pb->acpi_mode = true;
		pr_info("proart_battery: acpi mode (forced)\n");
	} else if (!strcmp(mode, "ec")) {
		pr_info("proart_battery: ec mode (forced)\n");
	} else {
		pb->acpi_mode = aml_ec_path_works();
		if (pb->acpi_mode)
			pr_info("proart_battery: acpi mode: the BIOS's EC path works, using BAT0/AC0\n");
		else
			pr_info("proart_battery: ec mode: the BIOS's EC path is broken, providing BAT1/ADP1\n");
	}

	pb->pdev = platform_device_register_simple("proart-battery", PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(pb->pdev)) {
		ret = PTR_ERR(pb->pdev);
		goto err_put_ffa;
	}

	if (!pb->acpi_mode) {
		ret = proart_ec_mode_init();
		if (ret)
			goto err_unreg_pdev;
	}
	hide_acpi_devs();

	proart_ec_extras_init();
	if (pb->acpi_mode) {
		pb->hook.name = "proart_battery";
		pb->hook.add_battery = pb_hook_add_battery;
		pb->hook.remove_battery = pb_hook_remove_battery;
		battery_hook_register(&pb->hook);
		pb->hook_registered = true;
	}

	if (efi_poweroff && efi_enabled(EFI_RUNTIME_SERVICES) && efi.reset_system) {
		/* priorities are unique per chain; above PSCI's FIRMWARE level runs first */
		pb->sys_off = register_sys_off_handler(SYS_OFF_MODE_POWER_OFF,
						       SYS_OFF_PRIO_FIRMWARE + 16,
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
	pb->pm_nb_registered = !register_pm_notifier(&pb->pm_nb);

	if (pb->acpi_mode) {
		pr_info("proart_battery: charge limit %u %%\n", pb->charge_limit);
	} else {
		pr_info("proart_battery: %u/%u mAh (design %u mAh, %u mV), %d mA, %u mV, AC %s, charge limit %u %%\n",
			pb->remaining_mah, pb->full_mah, pb->design_mah, pb->design_mv,
			pb->current_ma, pb->voltage_mv, pb->ac_online ? "online" : "offline",
			pb->charge_limit);
		proart_bat_schedule();
	}
	return 0;

err_unreg_pdev:
	platform_device_unregister(pb->pdev);
err_put_ffa:
	put_device(&pb->ffa->dev);
	kfree(pb);
	pb = NULL;
	return ret;
}

static void __exit proart_bat_exit(void)
{
	if (pb->sys_off)
		unregister_sys_off_handler(pb->sys_off);
	if (pb->pm_nb_registered)
		unregister_pm_notifier(&pb->pm_nb);
	cancel_work_sync(&pb->resume_work);
	if (pb->hook_registered)
		battery_hook_unregister(&pb->hook);
	proart_ec_mode_exit();
	proart_ec_extras_exit();
	restore_acpi_devs();
	platform_device_unregister(pb->pdev);
	put_device(&pb->ffa->dev);
	kfree(pb);
}

module_init(proart_bat_init);
module_exit(proart_bat_exit);

MODULE_DESCRIPTION("Battery, AC adapter, fan, performance modes and charge limit via the ASUS EC FF-A service (ASUS ProArt P16 H7607BA, NVIDIA N1X)");
MODULE_LICENSE("GPL");
