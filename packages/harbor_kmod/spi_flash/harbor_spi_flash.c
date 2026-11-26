// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor SPI flash write port driver
 *
 * The flash reads through the XIP window. Erase and program go through the
 * write port of the flash controller. Registers are 32 bits wide:
 *
 *   0x00: CTRL      (RW) - bits [1:0] op (1 erase, 2 program), bit 31 go
 *   0x04: ADDR      (RW) - flash byte offset
 *   0x08: LEN       (RW) - program byte count, 1 to 256
 *   0x0c: STATUS    (RW) - busy, done, err (write 1 to clear), locked
 *   0x10: LOCK_MASK (RW) - set by firmware, one bit for each partition
 *   0x14: QE_STATUS (RO) - bit 0 quad enable done, bit 1 QE set, bit 2 QE
 *                          failed and reads use one line, bit 3 JEDEC ID mismatch
 *   0x1c: CLAIM     (RW) - a read takes the claim, a write of 1 gives it back
 *   0x100 - 0x1ff : page buffer, the program data
 *
 * Firmware uses the same registers. Both sides take the claim before they
 * touch CTRL, ADDR, LEN or the page buffer and give it back after the op.
 * The hardware does not check the claim.
 *
 * A completed erase or program changes the flash under the XIP window. The
 * driver reads it through its own ioremap mapping. Whether a CPU cache can
 * hold other mappings of the window depends on the memory map of the SoC,
 * which must mark the window as IO. The owner of any cacheable mapping must
 * invalidate it.
 */

#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/mtd/mtd.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/unaligned.h>

#define HSF_CTRL      0x00
#define HSF_ADDR      0x04
#define HSF_LEN       0x08
#define HSF_STATUS    0x0c
#define HSF_CLAIM     0x1c
#define HSF_PAGE      0x100
#define HSF_PAGE_SIZE 256

#define HSF_OP_ERASE   1
#define HSF_OP_PROGRAM 2
#define HSF_GO	       BIT(31)

#define HSF_ST_BUSY   BIT(0)
#define HSF_ST_DONE   BIT(1)
#define HSF_ST_ERR    BIT(2)
#define HSF_ST_LOCKED BIT(3)

#define HSF_CLAIM_TIMEOUT_MS 10000
#define HSF_READ_CHUNK	     4096

struct harbor_spi_flash {
	void __iomem *ctrl;
	void __iomem *xip;
	struct mtd_info mtd;
	/* The engine ends an op with an error after these times. */
	u32 erase_timeout_ms;
	u32 program_timeout_ms;
	/* Serialises the operations of this driver. */
	struct mutex lock;
};

static struct harbor_spi_flash *to_hsf(struct mtd_info *mtd)
{
	return container_of(mtd, struct harbor_spi_flash, mtd);
}

/* The claim read returns 1 when it takes the claim and 0 when it is taken. */
static int hsf_claim(struct harbor_spi_flash *f)
{
	unsigned long end = jiffies + msecs_to_jiffies(HSF_CLAIM_TIMEOUT_MS);

	do {
		if (readl(f->ctrl + HSF_CLAIM) & 1)
			return 0;
		usleep_range(100, 200);
	} while (time_before(jiffies, end));

	return -EBUSY;
}

static void hsf_release(struct harbor_spi_flash *f)
{
	writel(1, f->ctrl + HSF_CLAIM);
}

/*
 * The wait is twice the engine timeout and 100 ms more, so the engine ends a
 * stuck op with an error before this wait ends. The claim is then never
 * given back while an op still runs.
 */
static unsigned int hsf_wait_us(u32 engine_ms)
{
	return (2 * engine_ms + 100) * 1000;
}

/* Runs one op that the caller has set up and returns an errno. */
static int hsf_run(struct harbor_spi_flash *f, u32 op, u32 addr, u32 len,
		   const u8 *data, unsigned int timeout_us)
{
	u32 status;
	u8 page[HSF_PAGE_SIZE] = {};
	unsigned int i;
	int ret;

	ret = hsf_claim(f);
	if (ret)
		return ret;

	/* Clear an error that an earlier owner left. */
	writel(HSF_ST_ERR, f->ctrl + HSF_STATUS);

	if (data) {
		memcpy(page, data, len);
		for (i = 0; i < DIV_ROUND_UP(len, 4); i++)
			writel(get_unaligned_le32(page + 4 * i),
			       f->ctrl + HSF_PAGE + 4 * i);
	}
	writel(addr, f->ctrl + HSF_ADDR);
	writel(len, f->ctrl + HSF_LEN);
	writel(op | HSF_GO, f->ctrl + HSF_CTRL);

	ret = readl_poll_timeout(f->ctrl + HSF_STATUS, status,
				 !(status & HSF_ST_BUSY), 100, timeout_us);
	if (ret) {
		ret = -ETIMEDOUT;
	} else if (status & HSF_ST_ERR) {
		ret = (status & HSF_ST_LOCKED) ? -EROFS : -EIO;
		writel(HSF_ST_ERR, f->ctrl + HSF_STATUS);
	} else if (!(status & HSF_ST_DONE)) {
		ret = -EIO;
	}

	hsf_release(f);
	return ret;
}

static int hsf_read(struct mtd_info *mtd, loff_t from, size_t len,
		    size_t *retlen, u_char *buf)
{
	struct harbor_spi_flash *f = to_hsf(mtd);

	*retlen = 0;
	mutex_lock(&f->lock);
	while (len) {
		size_t chunk = min_t(size_t, len, HSF_READ_CHUNK);

		memcpy_fromio(buf, f->xip + from, chunk);
		from += chunk;
		buf += chunk;
		len -= chunk;
		*retlen += chunk;
		cond_resched();
	}
	mutex_unlock(&f->lock);
	return 0;
}

static int hsf_write(struct mtd_info *mtd, loff_t to, size_t len,
		     size_t *retlen, const u_char *buf)
{
	struct harbor_spi_flash *f = to_hsf(mtd);
	int ret = 0;

	*retlen = 0;
	mutex_lock(&f->lock);
	while (len) {
		size_t chunk = min_t(size_t, len,
				     mtd->writebufsize -
				     ((u32)to & (mtd->writebufsize - 1)));

		ret = hsf_run(f, HSF_OP_PROGRAM, to, chunk, buf,
			      hsf_wait_us(f->program_timeout_ms));
		if (ret)
			break;
		to += chunk;
		buf += chunk;
		len -= chunk;
		*retlen += chunk;
	}
	mutex_unlock(&f->lock);
	return ret;
}

static int hsf_erase(struct mtd_info *mtd, struct erase_info *instr)
{
	struct harbor_spi_flash *f = to_hsf(mtd);
	u64 addr = instr->addr;
	u64 end = instr->addr + instr->len;
	int ret = 0;

	if ((instr->addr | instr->len) & (mtd->erasesize - 1))
		return -EINVAL;

	mutex_lock(&f->lock);
	for (; addr < end; addr += mtd->erasesize) {
		ret = hsf_run(f, HSF_OP_ERASE, addr, 0, NULL,
			      hsf_wait_us(f->erase_timeout_ms));
		if (ret) {
			instr->fail_addr = addr;
			break;
		}
	}
	mutex_unlock(&f->lock);
	return ret;
}

static int harbor_spi_flash_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct harbor_spi_flash *f;
	struct resource *ctrl, *xip;
	u32 size, erase, page;
	int ret;

	f = devm_kzalloc(dev, sizeof(*f), GFP_KERNEL);
	if (!f)
		return -ENOMEM;

	/* A device from ACPI has no reg-names, so use the order: ctrl, xip. */
	ctrl = platform_get_resource_byname(pdev, IORESOURCE_MEM, "ctrl");
	if (!ctrl)
		ctrl = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	xip = platform_get_resource_byname(pdev, IORESOURCE_MEM, "xip");
	if (!xip)
		xip = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!ctrl || !xip)
		return dev_err_probe(dev, -EINVAL, "ctrl and xip regions needed\n");

	/*
	 * The xip window is also the reg of the jedec,spi-nor node, so the two
	 * regions overlap. Map without a region request.
	 */
	f->ctrl = devm_ioremap(dev, ctrl->start, resource_size(ctrl));
	f->xip = devm_ioremap(dev, xip->start, resource_size(xip));
	if (!f->ctrl || !f->xip)
		return -ENOMEM;

	ret = device_property_read_u32(dev, "harbor,flash-size", &size);
	if (ret)
		return dev_err_probe(dev, ret, "no harbor,flash-size\n");
	ret = device_property_read_u32(dev, "harbor,erase-size", &erase);
	if (ret)
		return dev_err_probe(dev, ret, "no harbor,erase-size\n");
	ret = device_property_read_u32(dev, "harbor,page-size", &page);
	if (ret)
		return dev_err_probe(dev, ret, "no harbor,page-size\n");
	ret = device_property_read_u32(dev, "harbor,erase-timeout-ms",
				       &f->erase_timeout_ms);
	if (ret)
		return dev_err_probe(dev, ret, "no harbor,erase-timeout-ms\n");
	ret = device_property_read_u32(dev, "harbor,program-timeout-ms",
				       &f->program_timeout_ms);
	if (ret)
		return dev_err_probe(dev, ret, "no harbor,program-timeout-ms\n");
	if (!erase || !page || page > HSF_PAGE_SIZE || !is_power_of_2(page) ||
	    !is_power_of_2(erase) || size > resource_size(xip))
		return dev_err_probe(dev, -EINVAL, "bad flash geometry\n");

	mutex_init(&f->lock);
	f->mtd.name = "harbor-spi-flash";
	f->mtd.type = MTD_NORFLASH;
	f->mtd.flags = MTD_CAP_NORFLASH;
	f->mtd.size = size;
	f->mtd.erasesize = erase;
	f->mtd.writesize = 1;
	f->mtd.writebufsize = page;
	f->mtd.owner = THIS_MODULE;
	f->mtd.dev.parent = dev;
	f->mtd._read = hsf_read;
	f->mtd._write = hsf_write;
	f->mtd._erase = hsf_erase;
	if (dev->of_node)
		mtd_set_of_node(&f->mtd, dev->of_node);

	platform_set_drvdata(pdev, f);
	return mtd_device_register(&f->mtd, NULL, 0);
}

static void harbor_spi_flash_remove(struct platform_device *pdev)
{
	struct harbor_spi_flash *f = platform_get_drvdata(pdev);

	WARN_ON(mtd_device_unregister(&f->mtd));
}

static const struct of_device_id harbor_spi_flash_of_match[] = {
    {.compatible = "harbor,spi-flash-port"}, {}};
MODULE_DEVICE_TABLE(of, harbor_spi_flash_of_match);

static struct platform_driver harbor_spi_flash_driver = {
    .probe = harbor_spi_flash_probe,
    .remove = harbor_spi_flash_remove,
    .driver =
	{
	    .name = "harbor-spi-flash",
	    .of_match_table = harbor_spi_flash_of_match,
	},
};
module_platform_driver(harbor_spi_flash_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor SPI flash write port driver");
MODULE_LICENSE("GPL");
