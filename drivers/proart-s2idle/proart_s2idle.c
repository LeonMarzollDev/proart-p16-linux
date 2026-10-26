// SPDX-License-Identifier: GPL-2.0
/*
 * proart_s2idle - Modern Standby (LPS0 _DSM) notifications for suspend-to-idle on ACPI arm64
 *
 * On x86, drivers/acpi/x86/s2idle.c evaluates the Microsoft "Modern Standby" _DSM
 * (11e00d56-ce64-47ce-837b-1f898f9aa461) of the PNP0D80 device around suspend-to-idle:
 * display off (3), Modern Standby entry (7) and LPS0 entry (5) after the devices are suspended,
 * and LPS0 exit (6), "turn on display" (9), Modern Standby exit (8) and display on (4) before
 * they resume. arm64 has no such code: with ACPI the arm64 kernel installs no
 * platform_s2idle_ops at all, so firmware never learns that the system sleeps.
 *
 * On the ASUS ProArt P16 H7607BA (NVIDIA N1X) that _DSM lives in \_SB.PEPD (HID NVDA6210,
 * CID PNP0D80). Each function sends a command to the ASUS EC through RWEC (3: 0xb7, 4: 0xb8,
 * 5: 0xae, 6: 0xaf, 7: 0x9a, 8: 0x9b), notifies PEPD (0xc3-0xc9) and, on exit, clears the
 * FF-A wake state (\_SB.FFA0.ERST). Without these calls the EC keeps the fans running and the
 * machine draws ~11 W in s2idle.
 *
 * A module cannot install platform_s2idle_ops (s2idle_set_ops() is not exported), so this
 * driver uses the noirq phase of its own device instead: by then every device has completed its
 * suspend and suspend_late callbacks, which is as close to ->prepare_late() as a module gets.
 * The exit functions run in resume_noirq, before any device's resume_early/resume callbacks.
 *
 * The proper fix is generic LPS0 support for ACPI arm64 in drivers/acpi (see
 * docs/technical-notes.md / research notes); this module is the stop-gap.
 */
#include <linux/acpi.h>
#include <linux/bitops.h>
#include <linux/dmi.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/suspend.h>
#include <linux/uuid.h>

#define LPS0_DSM_UUID_MICROSOFT	"11e00d56-ce64-47ce-837b-1f898f9aa461"

#define LPS0_SCREEN_OFF		3
#define LPS0_SCREEN_ON		4
#define LPS0_ENTRY		5
#define LPS0_EXIT		6
#define LPS0_MS_ENTRY		7
#define LPS0_MS_EXIT		8
#define LPS0_TURN_ON_DISPLAY	9

#define LPS0_ALL_FUNCS		(BIT(LPS0_SCREEN_OFF) | BIT(LPS0_SCREEN_ON) | BIT(LPS0_ENTRY) | \
				 BIT(LPS0_EXIT) | BIT(LPS0_MS_ENTRY) | BIT(LPS0_MS_EXIT) | \
				 BIT(LPS0_TURN_ON_DISPLAY))

/* same order as drivers/acpi/x86/s2idle.c */
static const u8 entry_funcs[] = { LPS0_SCREEN_OFF, LPS0_MS_ENTRY, LPS0_ENTRY };
static const u8 exit_funcs[] = { LPS0_EXIT, LPS0_TURN_ON_DISPLAY, LPS0_MS_EXIT, LPS0_SCREEN_ON };

static unsigned int funcs = LPS0_ALL_FUNCS;
module_param(funcs, uint, 0644);
MODULE_PARM_DESC(funcs,
		 "Bit mask of the _DSM functions to call (default 0x3f8 = 3-9; firmware support still required)");

static bool enable = true;
module_param(enable, bool, 0644);
MODULE_PARM_DESC(enable, "Call the Modern Standby _DSM on suspend-to-idle (default true)");

static bool force;
module_param(force, bool, 0444);
MODULE_PARM_DESC(force, "Load on machines other than the ASUS ProArt P16 H7607BA (default false)");

static bool debug;
module_param(debug, bool, 0644);
MODULE_PARM_DESC(debug, "Log every _DSM call and its duration (default false)");

static struct {
	struct platform_device *pdev;
	acpi_handle handle;
	guid_t guid;
	u64 mask;		/* functions the firmware implements (function 0) */
	bool entered;		/* entry functions were called; call the exit ones */
} lps0;

static void lps0_run(u8 func)
{
	union acpi_object *obj;
	ktime_t start;

	if (!(lps0.mask & BIT(func)) || !(funcs & BIT(func)))
		return;
	start = ktime_get();
	obj = acpi_evaluate_dsm(lps0.handle, &lps0.guid, 0, func, NULL);
	ACPI_FREE(obj);
	if (debug)
		pr_info("proart_s2idle: _DSM function %u done in %lld us\n", func,
			ktime_us_delta(ktime_get(), start));
}

static int proart_s2idle_suspend_noirq(struct device *dev)
{
	int i;

	/* only suspend-to-idle; "deep" (PSCI SYSTEM_SUSPEND) is the firmware's business */
	if (!enable || pm_suspend_target_state != PM_SUSPEND_TO_IDLE)
		return 0;
	for (i = 0; i < ARRAY_SIZE(entry_funcs); i++)
		lps0_run(entry_funcs[i]);
	lps0.entered = true;
	return 0;
}

static int proart_s2idle_resume_noirq(struct device *dev)
{
	int i;

	/* also runs when a later device fails to suspend: undo what was done */
	if (!lps0.entered)
		return 0;
	for (i = 0; i < ARRAY_SIZE(exit_funcs); i++)
		lps0_run(exit_funcs[i]);
	lps0.entered = false;
	return 0;
}

static const struct dev_pm_ops proart_s2idle_pm_ops = {
	.suspend_noirq = proart_s2idle_suspend_noirq,
	.resume_noirq = proart_s2idle_resume_noirq,
};

static int proart_s2idle_probe(struct platform_device *pdev)
{
	return 0;
}

static struct platform_driver proart_s2idle_driver = {
	.probe = proart_s2idle_probe,
	.driver = {
		.name = "proart-s2idle",
		.pm = &proart_s2idle_pm_ops,
	},
};

static int __init proart_s2idle_init(void)
{
	union acpi_object *obj;
	struct acpi_device *adev;
	int i, ret;

	if (!force && (!dmi_match(DMI_SYS_VENDOR, "ASUS") || !dmi_match(DMI_BOARD_NAME, "H7607BA")))
		return -ENODEV;
	if (IS_ENABLED(CONFIG_X86)) {
		pr_err("proart_s2idle: x86 has drivers/acpi/x86/s2idle.c for this\n");
		return -ENODEV;
	}
	if (!(acpi_gbl_FADT.flags & ACPI_FADT_LOW_POWER_S0))
		pr_warn("proart_s2idle: the FADT does not declare low-power S0 idle\n");

	adev = acpi_dev_get_first_match_dev("PNP0D80", NULL, -1);
	if (!adev) {
		pr_err("proart_s2idle: no PNP0D80 (Windows-compatible power management) device\n");
		return -ENODEV;
	}
	lps0.handle = adev->handle;
	acpi_dev_put(adev);

	if (guid_parse(LPS0_DSM_UUID_MICROSOFT, &lps0.guid))
		return -EINVAL;
	/* function 0: bit n set = function n implemented (bit 0 = any implemented) */
	obj = acpi_evaluate_dsm_typed(lps0.handle, &lps0.guid, 0, 0, NULL, ACPI_TYPE_BUFFER);
	if (!obj) {
		acpi_handle_err(lps0.handle, "proart_s2idle: no Modern Standby _DSM\n");
		return -ENODEV;
	}
	for (i = 0; i < obj->buffer.length && i < sizeof(lps0.mask); i++)
		lps0.mask |= (u64)obj->buffer.pointer[i] << (8 * i);
	ACPI_FREE(obj);
	if (!(lps0.mask & BIT(0)) || !(lps0.mask & LPS0_ALL_FUNCS)) {
		acpi_handle_err(lps0.handle, "proart_s2idle: _DSM implements no usable function (%#llx)\n",
				lps0.mask);
		return -ENODEV;
	}
	acpi_handle_info(lps0.handle, "proart_s2idle: Modern Standby _DSM functions %#llx, calling %#llx\n",
			 lps0.mask, lps0.mask & funcs & LPS0_ALL_FUNCS);

	ret = platform_driver_register(&proart_s2idle_driver);
	if (ret)
		return ret;
	/* registered last, so in the noirq phase it runs before (suspend) / after (resume)
	 * the noirq callbacks of devices registered earlier; all suspend_late callbacks are done
	 */
	lps0.pdev = platform_device_register_simple("proart-s2idle", PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(lps0.pdev)) {
		platform_driver_unregister(&proart_s2idle_driver);
		return PTR_ERR(lps0.pdev);
	}
	return 0;
}

static void __exit proart_s2idle_exit(void)
{
	platform_device_unregister(lps0.pdev);
	platform_driver_unregister(&proart_s2idle_driver);
}

module_init(proart_s2idle_init);
module_exit(proart_s2idle_exit);

MODULE_DESCRIPTION("Modern Standby _DSM notifications for suspend-to-idle on ACPI arm64 (ASUS ProArt P16 H7607BA)");
MODULE_LICENSE("GPL");
