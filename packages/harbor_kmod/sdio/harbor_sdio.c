// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor SD/SDIO/eMMC host controller driver
 *
 * The controller is Harbor's own (lib/src/peripherals/sdio.dart). It is NOT the
 * SD Host Controller Standard (SDHCI) register map, so it does not bind to
 * sdhci-pltfm. Each register sits in its own 8-byte slot: the controller sits
 * on a byte-addressed fabric that decodes byte-offset >> 3, like every other
 * Harbor peripheral. 4-byte spacing aliases every register onto its neighbour.
 *
 *   0x00 CTRL, 0x08 STATUS, 0x10 CLK_DIV, 0x18 CMD, 0x20 CMD_ARG,
 *   0x28 RESP0, 0x30 RESP1, 0x38 RESP2, 0x40 RESP3, 0x48 DATA,
 *   0x50 BLK_SIZE, 0x58 BLK_COUNT, 0x60 INT_STATUS, 0x68 INT_ENABLE,
 *   0x70 ADMA_ADDR
 *
 * Data moves through the ADMA descriptor engine, never the DATA register. The
 * DATA path is a single-word holding register with no flow control on the CPU
 * side, so it cannot keep up with the card at the transfer clock. The ADMA
 * engine gates the SD clock while a word waits, so it is the only correct path
 * for a block transfer.
 *
 * Commands are polled. The controller holds STATUS.BUSY from the command until
 * the end of the data phase, so one wait covers the whole request. The MMC core
 * calls ->request from a context that may sleep (the block queue sets
 * BLK_MQ_F_BLOCKING), so the poll sleeps rather than spins.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/mmc/host.h>
#include <linux/mmc/mmc.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/of.h>
#include <linux/clk.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>

#define HARBOR_SD_CTRL	     0x00
#define HARBOR_SD_STATUS     0x08
#define HARBOR_SD_CLK_DIV    0x10
#define HARBOR_SD_CMD	     0x18
#define HARBOR_SD_CMD_ARG    0x20
#define HARBOR_SD_RESP(n)    (0x28 + (n) * 8)
#define HARBOR_SD_DATA	     0x48
#define HARBOR_SD_BLK_SIZE   0x50
#define HARBOR_SD_BLK_COUNT  0x58
#define HARBOR_SD_INT_STATUS 0x60
#define HARBOR_SD_INT_ENABLE 0x68
#define HARBOR_SD_ADMA_ADDR  0x70

#define HARBOR_SD_CTRL_ENABLE	   BIT(0)
#define HARBOR_SD_CTRL_WIDTH_SHIFT 4
#define HARBOR_SD_CTRL_WIDTH_1	   0
#define HARBOR_SD_CTRL_WIDTH_4	   1
#define HARBOR_SD_CTRL_WIDTH_8	   2

#define HARBOR_SD_ST_CARD_DETECT BIT(0)
#define HARBOR_SD_ST_BUSY	 BIT(8)
#define HARBOR_SD_ST_DATA_VALID	 BIT(9)

/*
 * CMD: [5:0] index, [7:6] response type, [8] data, [9] read, [10] ADMA,
 * [11] ADMA_ADDR is a descriptor table.
 */
#define HARBOR_SD_CMD_INDEX	 GENMASK(5, 0)
#define HARBOR_SD_CMD_RESP_SHIFT 6
#define HARBOR_SD_CMD_RESP_NONE	 0
#define HARBOR_SD_CMD_RESP_SHORT 1
#define HARBOR_SD_CMD_RESP_LONG	 2
#define HARBOR_SD_CMD_RESP_BUSY	 3
#define HARBOR_SD_CMD_DATA	 BIT(8)
#define HARBOR_SD_CMD_READ	 BIT(9)
#define HARBOR_SD_CMD_DMA	 BIT(10)
#define HARBOR_SD_CMD_TABLE	 BIT(11)

/* INT_STATUS, write-1-to-clear. */
#define HARBOR_SD_INT_CMD_DONE	  BIT(0)
#define HARBOR_SD_INT_DATA_DONE	  BIT(1)
#define HARBOR_SD_INT_DATA_REQ	  BIT(2)
#define HARBOR_SD_INT_DATA_CRC	  BIT(3)
#define HARBOR_SD_INT_CMD_TIMEOUT BIT(4)
#define HARBOR_SD_INT_WRITE_ERR	  BIT(5)
#define HARBOR_SD_INT_RX_OVERRUN  BIT(6)
#define HARBOR_SD_INT_ADMA_ERR	  BIT(7)
#define HARBOR_SD_INT_ALL	  GENMASK(7, 0)

/*
 * ADMA descriptor: two 32-bit words, [buffer address], [byte length in [15:0],
 * end flag in [31]]. The engine walks the table until it retires a descriptor
 * with the end flag set. It moves whole 32-bit words, so both the address and
 * the length must be 4-byte multiples, and the length field is 16 bits wide.
 */
struct harbor_sd_desc {
	__le32 addr;
	__le32 ctrl;
} __packed;

#define HARBOR_SD_DESC_END     BIT(31)
#define HARBOR_SD_DESC_MAX_LEN 65532u /* largest 4-byte multiple under 64K */
#define HARBOR_SD_MAX_SEGS     128

/* BLK_SIZE is 12 bits and BLK_COUNT is 16. */
#define HARBOR_SD_MAX_BLK_SIZE	2048
#define HARBOR_SD_MAX_BLK_COUNT 65535

/* A command without a data phase answers inside the response window. */
#define HARBOR_SD_CMD_TIMEOUT_US 100000
/* A data phase includes the card's programming time on a write. */
#define HARBOR_SD_DATA_TIMEOUT_US 5000000

/* CLK_DIV counts full SD periods, so the divider is freq/(2*rate) - 1. */
#define HARBOR_SD_CLK_DIV_MAX 65535

struct harbor_sd {
	void __iomem *base;
	struct mmc_host *mmc;
	struct device *dev;
	unsigned int clk_freq;
	u32 ctrl;		     /* the CTRL value in force */
	struct harbor_sd_desc *desc; /* descriptor table (coherent) */
	dma_addr_t desc_dma;
};

static void harbor_sd_write_ctrl(struct harbor_sd *hs, u32 ctrl)
{
	hs->ctrl = ctrl;
	writel(ctrl, hs->base + HARBOR_SD_CTRL);
}

static void harbor_sd_set_clock(struct harbor_sd *hs, unsigned int hz)
{
	unsigned int half;
	u32 div;

	if (!hz || !hs->clk_freq)
		return;

	half = hs->clk_freq / (2 * hz);
	div = half > 0 ? half - 1 : 0;
	if (div > HARBOR_SD_CLK_DIV_MAX)
		div = HARBOR_SD_CLK_DIV_MAX;
	writel(div, hs->base + HARBOR_SD_CLK_DIV);
}

static void harbor_sd_set_ios(struct mmc_host *mmc, struct mmc_ios *ios)
{
	struct harbor_sd *hs = mmc_priv(mmc);
	u32 width;

	if (ios->power_mode == MMC_POWER_OFF || !ios->clock) {
		/* Clearing CTRL.ENABLE gates the SD clock at the pad. */
		harbor_sd_write_ctrl(hs, hs->ctrl & ~HARBOR_SD_CTRL_ENABLE);
		return;
	}

	harbor_sd_set_clock(hs, ios->clock);

	switch (ios->bus_width) {
	case MMC_BUS_WIDTH_8:
		width = HARBOR_SD_CTRL_WIDTH_8;
		break;
	case MMC_BUS_WIDTH_4:
		width = HARBOR_SD_CTRL_WIDTH_4;
		break;
	default:
		width = HARBOR_SD_CTRL_WIDTH_1;
		break;
	}

	/*
	 * The controller clamps the selection to the width it was built with,
	 * so a card negotiated wider than the hardware still lands on the
	 * hardware maximum rather than sampling absent lanes.
	 */
	harbor_sd_write_ctrl(hs, HARBOR_SD_CTRL_ENABLE |
				     (width << HARBOR_SD_CTRL_WIDTH_SHIFT));
}

static int harbor_sd_get_cd(struct mmc_host *mmc)
{
	struct harbor_sd *hs = mmc_priv(mmc);

	return !!(readl(hs->base + HARBOR_SD_STATUS) &
		  HARBOR_SD_ST_CARD_DETECT);
}

static u32 harbor_sd_resp_type(struct mmc_command *cmd)
{
	if (!(cmd->flags & MMC_RSP_PRESENT))
		return HARBOR_SD_CMD_RESP_NONE;
	if (cmd->flags & MMC_RSP_136)
		return HARBOR_SD_CMD_RESP_LONG;
	if (cmd->flags & MMC_RSP_BUSY)
		return HARBOR_SD_CMD_RESP_BUSY;
	return HARBOR_SD_CMD_RESP_SHORT;
}

/*
 * Read the captured response. RESP0 holds bits [31:0] of the frame payload and
 * RESP3 holds [127:96], while the MMC core wants resp[0] to be the most
 * significant word, so the long form reverses. A long response keeps the CRC7
 * in its low byte, which is the alignment mmc_decode_csd() expects, so no shift
 * is needed.
 */
static void harbor_sd_read_response(struct harbor_sd *hs,
				    struct mmc_command *cmd)
{
	if (!(cmd->flags & MMC_RSP_PRESENT))
		return;

	if (cmd->flags & MMC_RSP_136) {
		cmd->resp[0] = readl(hs->base + HARBOR_SD_RESP(3));
		cmd->resp[1] = readl(hs->base + HARBOR_SD_RESP(2));
		cmd->resp[2] = readl(hs->base + HARBOR_SD_RESP(1));
		cmd->resp[3] = readl(hs->base + HARBOR_SD_RESP(0));
	} else {
		cmd->resp[0] = readl(hs->base + HARBOR_SD_RESP(0));
	}
}

/*
 * Build the descriptor table from the mapped scatterlist. Every segment must be
 * 4-byte aligned in both address and length, and no longer than the 16-bit
 * length field. Reject anything else rather than truncating the transfer, which
 * would silently return short data.
 */
static int harbor_sd_build_desc(struct harbor_sd *hs, struct mmc_data *data)
{
	struct scatterlist *sg;
	int i;

	if (data->sg_len > HARBOR_SD_MAX_SEGS)
		return -EINVAL;

	for_each_sg(data->sg, sg, data->sg_len, i)
	{
		dma_addr_t addr = sg_dma_address(sg);
		unsigned int len = sg_dma_len(sg);

		if ((addr | len) & 0x3)
			return -EINVAL;
		if (len == 0 || len > HARBOR_SD_DESC_MAX_LEN)
			return -EINVAL;
		if (upper_32_bits(addr))
			return -EINVAL;

		hs->desc[i].addr = cpu_to_le32(lower_32_bits(addr));
		hs->desc[i].ctrl = cpu_to_le32(len);
	}

	/* The engine stops on the descriptor carrying the end flag. */
	hs->desc[data->sg_len - 1].ctrl |= cpu_to_le32(HARBOR_SD_DESC_END);
	return 0;
}

/* Issue one command, and its data phase when it has one. */
static void harbor_sd_run_cmd(struct harbor_sd *hs, struct mmc_command *cmd,
			      struct mmc_data *data)
{
	unsigned int timeout_us;
	u32 val, ist, sts;
	int ret;

	val = (cmd->opcode & HARBOR_SD_CMD_INDEX) |
	      (harbor_sd_resp_type(cmd) << HARBOR_SD_CMD_RESP_SHIFT);

	if (data) {
		val |= HARBOR_SD_CMD_DATA | HARBOR_SD_CMD_DMA |
		       HARBOR_SD_CMD_TABLE;
		if (data->flags & MMC_DATA_READ)
			val |= HARBOR_SD_CMD_READ;

		writel(data->blksz, hs->base + HARBOR_SD_BLK_SIZE);
		writel(data->blocks, hs->base + HARBOR_SD_BLK_COUNT);
		writel(lower_32_bits(hs->desc_dma),
		       hs->base + HARBOR_SD_ADMA_ADDR);
		timeout_us = HARBOR_SD_DATA_TIMEOUT_US;
	} else {
		timeout_us = HARBOR_SD_CMD_TIMEOUT_US;
	}

	/*
	 * Clear the latched status first. Without this the timeout and error
	 * checks below would report a previous command's result.
	 */
	writel(HARBOR_SD_INT_ALL, hs->base + HARBOR_SD_INT_STATUS);
	writel(cmd->arg, hs->base + HARBOR_SD_CMD_ARG);
	writel(val, hs->base + HARBOR_SD_CMD);

	/* BUSY covers the command and, when present, the whole data phase. */
	ret = readl_poll_timeout(hs->base + HARBOR_SD_STATUS, sts,
				 !(sts & HARBOR_SD_ST_BUSY), 10, timeout_us);
	if (ret) {
		cmd->error = -ETIMEDOUT;
		if (data)
			data->error = -ETIMEDOUT;
		return;
	}

	ist = readl(hs->base + HARBOR_SD_INT_STATUS);
	writel(HARBOR_SD_INT_ALL, hs->base + HARBOR_SD_INT_STATUS);

	if (ist & HARBOR_SD_INT_CMD_TIMEOUT) {
		cmd->error = -ETIMEDOUT;
		if (data)
			data->error = -ETIMEDOUT;
		return;
	}

	harbor_sd_read_response(hs, cmd);

	if (!data)
		return;

	if (!(ist & HARBOR_SD_INT_DATA_DONE))
		data->error = -ETIMEDOUT;
	else if (ist & HARBOR_SD_INT_ADMA_ERR)
		data->error = -EIO;
	else if (ist & HARBOR_SD_INT_DATA_CRC)
		data->error = -EILSEQ;
	else if (ist & HARBOR_SD_INT_WRITE_ERR)
		data->error = -EIO;
	else
		data->bytes_xfered = data->blocks * data->blksz;
}

static void harbor_sd_request(struct mmc_host *mmc, struct mmc_request *mrq)
{
	struct harbor_sd *hs = mmc_priv(mmc);
	struct mmc_data *data = mrq->data;
	enum dma_data_direction dir = DMA_NONE;
	int sg_cnt = 0;

	if (data) {
		if (data->blksz > HARBOR_SD_MAX_BLK_SIZE ||
		    data->blocks > HARBOR_SD_MAX_BLK_COUNT) {
			data->error = -EINVAL;
			goto done;
		}

		dir = (data->flags & MMC_DATA_READ) ? DMA_FROM_DEVICE
						    : DMA_TO_DEVICE;
		sg_cnt = dma_map_sg(hs->dev, data->sg, data->sg_len, dir);
		if (!sg_cnt) {
			data->error = -ENOMEM;
			goto done;
		}

		data->error = harbor_sd_build_desc(hs, data);
		if (data->error) {
			dma_unmap_sg(hs->dev, data->sg, data->sg_len, dir);
			goto done;
		}
	}

	harbor_sd_run_cmd(hs, mrq->cmd, data);

	if (data)
		dma_unmap_sg(hs->dev, data->sg, data->sg_len, dir);

	/*
	 * An open-ended multi-block transfer needs its stop command, and so
	 * does a failed one: the card is still streaming otherwise.
	 */
	if (mrq->stop)
		harbor_sd_run_cmd(hs, mrq->stop, NULL);

done:
	mmc_request_done(mmc, mrq);
}

static const struct mmc_host_ops harbor_sd_ops = {
    .request = harbor_sd_request,
    .set_ios = harbor_sd_set_ios,
    .get_cd = harbor_sd_get_cd,
};

static int harbor_sd_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct harbor_sd *hs;
	struct mmc_host *mmc;
	struct clk *clk;
	int ret;

	mmc = mmc_alloc_host(sizeof(*hs), dev);
	if (!mmc)
		return -ENOMEM;

	hs = mmc_priv(mmc);
	hs->mmc = mmc;
	hs->dev = dev;

	hs->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hs->base)) {
		ret = PTR_ERR(hs->base);
		goto err_free_host;
	}

	/*
	 * The controller input clock. Harbor's device tree states the rate
	 * directly in `clock-frequency` rather than through a clock provider, so
	 * take that first and fall back to a `clocks` phandle. Without a rate
	 * there is no way to pick a divider, so refuse to probe.
	 */
	clk = devm_clk_get_optional_enabled(dev, NULL);
	if (IS_ERR(clk)) {
		ret = PTR_ERR(clk);
		goto err_free_host;
	}
	if (device_property_read_u32(dev, "clock-frequency", &hs->clk_freq))
		hs->clk_freq = clk ? clk_get_rate(clk) : 0;
	if (!hs->clk_freq) {
		dev_err(
		    dev,
		    "no controller clock rate, cannot derive the SD clock\n");
		ret = -EINVAL;
		goto err_free_host;
	}

	/* The ADMA engine drives 32-bit addresses. */
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret) {
		dev_err(dev, "no 32-bit DMA mask: %d\n", ret);
		goto err_free_host;
	}

	hs->desc =
	    dma_alloc_coherent(dev, HARBOR_SD_MAX_SEGS * sizeof(*hs->desc),
			       &hs->desc_dma, GFP_KERNEL);
	if (!hs->desc) {
		ret = -ENOMEM;
		goto err_free_host;
	}

	mmc->ops = &harbor_sd_ops;
	mmc->ocr_avail = MMC_VDD_32_33 | MMC_VDD_33_34;
	mmc->caps |= MMC_CAP_SD_HIGHSPEED | MMC_CAP_MMC_HIGHSPEED;

	/* The slowest and fastest SD clocks CLK_DIV can produce. */
	mmc->f_min = hs->clk_freq / (2 * (HARBOR_SD_CLK_DIV_MAX + 1));
	mmc->f_max = hs->clk_freq / 2;

	/*
	 * bus-width, max-frequency, non-removable, broken-cd and the rest come
	 * from the firmware node. This may lower f_max, never raise it past what
	 * the divider can make.
	 */
	ret = mmc_of_parse(mmc);
	if (ret)
		goto err_free_dma;

	/*
	 * Belt and braces on the data-bus width. mmc_of_parse() reads generic
	 * device properties, so it covers an ACPI _DSD as well as a DT node, but
	 * that has not been confirmed on every kernel this driver is built
	 * against. Losing bus-width is not a probe failure, it silently drops the
	 * card to one lane and quarters the throughput, which is expensive on the
	 * boot path. Re-read it and fill in the caps if they came back empty; a
	 * cap already set by mmc_of_parse is left alone.
	 */
	if (!(mmc->caps & (MMC_CAP_4_BIT_DATA | MMC_CAP_8_BIT_DATA))) {
		u32 bus_width;

		if (!device_property_read_u32(dev, "bus-width", &bus_width)) {
			if (bus_width == 8)
				mmc->caps |=
				    MMC_CAP_8_BIT_DATA | MMC_CAP_4_BIT_DATA;
			else if (bus_width == 4)
				mmc->caps |= MMC_CAP_4_BIT_DATA;
			else if (bus_width != 1)
				dev_warn(dev, "ignoring bus-width %u\n",
					 bus_width);
		}
	}

	/*
	 * `max-frequency` states what the card slot is rated for, which can be
	 * above what CLK_DIV can make. Clamp, so the negotiated mode matches the
	 * clock the card actually gets.
	 */
	mmc->f_max = min(mmc->f_max, hs->clk_freq / 2);

	mmc->max_blk_size = HARBOR_SD_MAX_BLK_SIZE;
	mmc->max_blk_count = HARBOR_SD_MAX_BLK_COUNT;
	mmc->max_segs = HARBOR_SD_MAX_SEGS;
	mmc->max_seg_size = HARBOR_SD_DESC_MAX_LEN;
	mmc->max_req_size = min_t(
	    unsigned int,
	    (unsigned int)HARBOR_SD_MAX_SEGS *HARBOR_SD_DESC_MAX_LEN,
	    (unsigned int)HARBOR_SD_MAX_BLK_SIZE *HARBOR_SD_MAX_BLK_COUNT);

	/* Poll the transfer, so leave the interrupt line masked. */
	writel(0, hs->base + HARBOR_SD_INT_ENABLE);
	writel(HARBOR_SD_INT_ALL, hs->base + HARBOR_SD_INT_STATUS);
	harbor_sd_write_ctrl(hs, HARBOR_SD_CTRL_ENABLE);

	platform_set_drvdata(pdev, hs);

	ret = mmc_add_host(mmc);
	if (ret)
		goto err_free_dma;

	return 0;

err_free_dma:
	dma_free_coherent(dev, HARBOR_SD_MAX_SEGS * sizeof(*hs->desc), hs->desc,
			  hs->desc_dma);
err_free_host:
	mmc_free_host(mmc);
	return ret;
}

static void harbor_sd_remove(struct platform_device *pdev)
{
	struct harbor_sd *hs = platform_get_drvdata(pdev);

	mmc_remove_host(hs->mmc);
	harbor_sd_write_ctrl(hs, 0);
	dma_free_coherent(hs->dev, HARBOR_SD_MAX_SEGS * sizeof(*hs->desc),
			  hs->desc, hs->desc_dma);
	mmc_free_host(hs->mmc);
}

static const struct of_device_id harbor_sd_of_match[] = {
    {.compatible = "harbor,sdio"},
    /* The names the hardware description emits today. */
    {.compatible = "harbor,sdhci"},
    {.compatible = "harbor,sdhci-emmc"},
    {}};
MODULE_DEVICE_TABLE(of, harbor_sd_of_match);

static struct platform_driver harbor_sd_driver = {
    .probe = harbor_sd_probe,
    .remove = harbor_sd_remove,
    .driver =
	{
	    .name = "harbor-sdio",
	    .of_match_table = harbor_sd_of_match,
	},
};
module_platform_driver(harbor_sd_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor SD/SDIO/eMMC host controller driver");
MODULE_LICENSE("GPL");
