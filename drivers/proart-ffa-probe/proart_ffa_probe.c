// SPDX-License-Identifier: GPL-2.0
/*
 * proart_ffa_probe - one-shot, read-only probe of the EC services behind FF-A
 * on the ASUS ProArt P16 H7607BA (NVIDIA N1X). Sends a few query commands via
 * FFA_MSG_SEND_DIRECT_REQ2 and logs the complete response registers (x4..x17).
 * The module does its work in init and then refuses to stay loaded.
 */
#include <linux/arm_ffa.h>
#include <linux/device.h>
#include <linux/module.h>
#include <linux/uuid.h>

#define UUID_BATTERY UUID_INIT(0x25cb5207, 0xac36, 0x427d, 0xaa, 0xef, 0x3a, 0xa7, 0x88, 0x77, 0xd2, 0x7e)
#define UUID_ASUS    UUID_INIT(0x884a63a0, 0x3285, 0x4120, 0x83, 0xaa, 0xee, 0xc0, 0x08, 0xa0, 0xa5, 0x46)

struct probe_req {
	const char *name;
	uuid_t uuid;
	u64 x4, x5;
};

static const struct probe_req reqs[] = {
	/* ODP battery service: x4 = function id */
	{ "battery GET_BIX",  UUID_BATTERY, 0x1, 0 },
	{ "battery GET_BST",  UUID_BATTERY, 0x2, 0 },
	{ "battery GET_PSR",  UUID_BATTERY, 0x3, 0 },
	/* ASUS OEM service, byte layout as in the BIOS AML (rawdata at x4) */
	{ "asus GBST 0x15",   UUID_ASUS,    0x15, 0 },
	/* RRA9(0x90,1): CMDD=0x0c, INP1=0xfe000990, INP2=1 -> AC/charger flags */
	{ "asus RRA9 0x90",   UUID_ASUS,    0x000001fe0009900cULL, 0 },
	/* RWEC(1, 0xc4, {0x2e}): CMDD=0x13, FLAG=1, DNUM=1, ECMD=0xc4, DATA=0x2e */
	{ "asus RWEC c4/2e",  UUID_ASUS,    0x0000002ec4010113ULL, 0 },
};

static int match_uuid(struct device *dev, const void *data)
{
	return uuid_equal(&to_ffa_dev(dev)->uuid, data);
}

static void run(const struct probe_req *r)
{
	struct ffa_send_direct_data2 d = { 0 };
	struct ffa_device *fdev;
	struct device *dev;
	int ret, i;

	dev = bus_find_device(&ffa_bus_type, NULL, &r->uuid, match_uuid);
	if (!dev) {
		pr_info("proart_ffa: %-16s no FF-A device for %pUb\n", r->name, &r->uuid);
		return;
	}
	fdev = to_ffa_dev(dev);
	if (!fdev->ops || !fdev->ops->msg_ops || !fdev->ops->msg_ops->sync_send_receive2) {
		pr_info("proart_ffa: %-16s no direct_req2 op\n", r->name);
		goto out;
	}

	d.data[0] = r->x4;
	d.data[1] = r->x5;
	ret = fdev->ops->msg_ops->sync_send_receive2(fdev, &d);
	pr_info("proart_ffa: %-16s part=%#x ret=%d\n", r->name, fdev->vm_id, ret);
	for (i = 0; i < 14; i += 2)
		pr_info("proart_ffa:   x%-2d %016lx  x%-2d %016lx\n",
			i + 4, d.data[i], i + 5, d.data[i + 1]);
out:
	put_device(dev);
}

static int __init proart_ffa_probe_init(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(reqs); i++)
		run(&reqs[i]);
	pr_info("proart_ffa: done\n");
	return -EAGAIN;	/* one-shot: do not stay loaded */
}
module_init(proart_ffa_probe_init);

MODULE_DESCRIPTION("One-shot read-only probe of FF-A EC services (ASUS ProArt P16 N1X)");
MODULE_LICENSE("GPL");
