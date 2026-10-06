// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor I2C controller driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 *   0x00: CTRL     (RW) - enable, interrupt enable
 *   0x08: STATUS   (RW) - busy, ack, arb_lost, rx_ready, cmd_done,
 *                  cmd_rejected
 *   0x10: DATA     (RW) - write=TX, read=RX
 *   0x18: ADDR     (RW) - own address, slave mode only
 *   0x20: PRESCALE (RW) - clock prescaler
 *   0x28: CMD      (WO) - start/stop/read/write/nack triggers
 *
 * The slave address rides DATA as the first byte of the frame
 * (address << 1 | read), which is what the shift engine sends.
 *
 * CMD bits run as a sequence in one write, not independent triggers: START
 * (or a repeated START, if a transaction is already open) first, then the
 * WRITE or READ byte, then STOP once that byte's ACK/NACK bit is done. So
 * START|WRITE sends an address byte in one write, and a READ alone, or
 * READ|NACK, continues an open transaction. NACK only matters on a READ:
 * clear sends ACK after the byte, set sends NACK (the last byte of a read
 * must be NACKed so the slave releases SDA before STOP).
 *
 * A CMD write while busy, or before CTRL enable is set, is ignored and
 * only sets the sticky cmd_rejected status bit (any STATUS write clears
 * it, the same as cmd_done). This driver never does either, since it
 * always waits for cmd_done before the next CMD write.
 *
 * PRESCALE sets the SCL period: low = 2 x (PRESCALE + 1) input clock
 * cycles, high = low + 3 cycles (the fixed cost of the controller's own
 * input synchronizer seeing its released line read high), both outside
 * of a clock-stretched byte. harbor_i2c_prescale() below picks PRESCALE
 * from the slower side's minimum low time for the requested bus speed
 * (UM10204 Table 10), so low (and so high, always looser) clears its
 * minimum regardless of the input clock:
 *   standard mode (<=100 kHz): tLOW >= 4700 ns
 *   fast mode (<=400 kHz):     tLOW >= 1300 ns
 *   fast mode plus (>400 kHz): tLOW >= 500 ns
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/clk.h>
#include <linux/math64.h>
#include <linux/time64.h>

#define HARBOR_I2C_CTRL	    0x00
#define HARBOR_I2C_STATUS   0x08
#define HARBOR_I2C_DATA	    0x10
#define HARBOR_I2C_ADDR	    0x18
#define HARBOR_I2C_PRESCALE 0x20
#define HARBOR_I2C_CMD	    0x28

#define HARBOR_I2C_CTRL_ENABLE BIT(0)
#define HARBOR_I2C_CTRL_IRQ_EN BIT(1)

#define HARBOR_I2C_ST_BUSY         BIT(0)
#define HARBOR_I2C_ST_ACK          BIT(1)
#define HARBOR_I2C_ST_ARB_LOST     BIT(2)
#define HARBOR_I2C_ST_RX_READY     BIT(4)
#define HARBOR_I2C_ST_CMD_DONE     BIT(5)
#define HARBOR_I2C_ST_CMD_REJECTED BIT(6)

#define HARBOR_I2C_CMD_START BIT(0)
#define HARBOR_I2C_CMD_STOP  BIT(1)
#define HARBOR_I2C_CMD_WRITE BIT(2)
#define HARBOR_I2C_CMD_READ  BIT(3)
#define HARBOR_I2C_CMD_NACK  BIT(4)

struct harbor_i2c {
	void __iomem *base;
	struct i2c_adapter adap;
	unsigned int freq;
};

static int harbor_i2c_wait_done(struct harbor_i2c *hi)
{
	int timeout = 100000;
	u32 st;

	for (;;) {
		st = readl(hi->base + HARBOR_I2C_STATUS);
		if (st & HARBOR_I2C_ST_CMD_REJECTED) {
			writel(HARBOR_I2C_ST_CMD_REJECTED, hi->base + HARBOR_I2C_STATUS);
			return -EBUSY;
		}
		if (st & HARBOR_I2C_ST_CMD_DONE)
			break;
		if (--timeout == 0)
			return -ETIMEDOUT;
		cpu_relax();
	}
	/* Any STATUS write clears cmd_done and cmd_rejected. */
	writel(HARBOR_I2C_ST_CMD_DONE, hi->base + HARBOR_I2C_STATUS);
	return 0;
}

/*
 * PRESCALE from the input clock and the requested bus speed. See the
 * file header comment for the formula and the UM10204 minimums this
 * picks PRESCALE from.
 */
static u32 harbor_i2c_prescale(u32 input_clock_hz, u32 bus_freq_hz)
{
	u64 t_low_min_ns;
	u64 prescale;

	if (bus_freq_hz <= I2C_MAX_STANDARD_MODE_FREQ)
		t_low_min_ns = 4700;
	else if (bus_freq_hz <= I2C_MAX_FAST_MODE_FREQ)
		t_low_min_ns = 1300;
	else
		t_low_min_ns = 500;

	prescale = DIV_ROUND_UP_ULL(t_low_min_ns * (u64)input_clock_hz,
				     2ULL * NSEC_PER_SEC);
	return prescale ? (u32)prescale : 1;
}

/*
 * Checks STATUS after a completed WRITE (address byte included) and turns
 * a failure into an errno. is_addr_byte picks -ENXIO (no such device) over
 * -EIO for a NACK, matching the Linux I2C convention that only an
 * address-phase NACK means "nothing is there".
 */
static int harbor_i2c_check_write(struct harbor_i2c *hi, bool is_addr_byte)
{
	u32 st = readl(hi->base + HARBOR_I2C_STATUS);

	if (st & HARBOR_I2C_ST_ARB_LOST)
		return -EAGAIN;
	if (!(st & HARBOR_I2C_ST_ACK))
		return is_addr_byte ? -ENXIO : -EIO;
	return 0;
}

/*
 * Checks STATUS after a completed READ. ack_received is the master's own
 * ACK/NACK choice on a read, not a failure signal, so only arbitration
 * loss can turn a read into an error.
 */
static int harbor_i2c_check_read(struct harbor_i2c *hi)
{
	if (readl(hi->base + HARBOR_I2C_STATUS) & HARBOR_I2C_ST_ARB_LOST)
		return -EAGAIN;
	return 0;
}

static int harbor_i2c_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs,
			   int num)
{
	struct harbor_i2c *hi = i2c_get_adapdata(adap);
	int i, j, ret, stop_ret;

	for (i = 0; i < num; i++) {
		struct i2c_msg *msg = &msgs[i];
		u8 addr_byte =
		    (msg->addr << 1) | (msg->flags & I2C_M_RD ? 1 : 0);

		/*
		 * START + address in one CMD write. A repeated START between
		 * messages (no STOP in between) works the same way: the core
		 * runs START, then WRITE, as one sequence either way.
		 */
		writel(addr_byte, hi->base + HARBOR_I2C_DATA);
		writel(HARBOR_I2C_CMD_START | HARBOR_I2C_CMD_WRITE,
		       hi->base + HARBOR_I2C_CMD);

		ret = harbor_i2c_wait_done(hi);
		if (ret)
			goto out;

		ret = harbor_i2c_check_write(hi, true);
		if (ret)
			goto out;

		/* Data phase */
		for (j = 0; j < msg->len; j++) {
			if (msg->flags & I2C_M_RD) {
				bool last_byte = j == msg->len - 1;

				writel(HARBOR_I2C_CMD_READ |
					   (last_byte ? HARBOR_I2C_CMD_NACK :
							0),
				       hi->base + HARBOR_I2C_CMD);
				ret = harbor_i2c_wait_done(hi);
				if (ret)
					goto out;
				ret = harbor_i2c_check_read(hi);
				if (ret)
					goto out;
				msg->buf[j] =
				    readl(hi->base + HARBOR_I2C_DATA) & 0xFF;
			} else {
				writel(msg->buf[j], hi->base + HARBOR_I2C_DATA);
				writel(HARBOR_I2C_CMD_WRITE,
				       hi->base + HARBOR_I2C_CMD);
				ret = harbor_i2c_wait_done(hi);
				if (ret)
					goto out;
				ret = harbor_i2c_check_write(hi, false);
				if (ret)
					goto out;
			}
		}
	}

	ret = num;

out:
	/* STOP, even on an error path, so the bus is never left open. */
	writel(HARBOR_I2C_CMD_STOP, hi->base + HARBOR_I2C_CMD);
	stop_ret = harbor_i2c_wait_done(hi);
	/*
	 * A STOP that itself times out means the bus is wedged. Surface
	 * that rather than swallowing it, but only when the transfer had
	 * otherwise succeeded: an earlier error is the more useful one to
	 * report.
	 */
	if (ret >= 0 && stop_ret)
		ret = stop_ret;
	return ret;
}

static u32 harbor_i2c_functionality(struct i2c_adapter *adap)
{
	return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm harbor_i2c_algo = {
    .master_xfer = harbor_i2c_xfer,
    .functionality = harbor_i2c_functionality,
};

static int harbor_i2c_probe(struct platform_device *pdev)
{
	struct harbor_i2c *hi;
	struct clk *clk;
	u32 bus_freq = I2C_MAX_STANDARD_MODE_FREQ;
	int ret;

	hi = devm_kzalloc(&pdev->dev, sizeof(*hi), GFP_KERNEL);
	if (!hi)
		return -ENOMEM;

	hi->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hi->base))
		return PTR_ERR(hi->base);

	/*
	 * The controller input clock. Harbor's device tree states it directly in
	 * `harbor,input-clock-hz`, and NOT in `clock-frequency`: on an I2C node
	 * the standard binding gives `clock-frequency` the SCL bus rate, which is
	 * read separately below. Fall back to a `clocks` phandle.
	 */
	clk = devm_clk_get_optional_enabled(&pdev->dev, NULL);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	if (device_property_read_u32(&pdev->dev, "harbor,input-clock-hz",
				     &hi->freq))
		hi->freq = clk ? clk_get_rate(clk) : 0;

	device_property_read_u32(&pdev->dev, "clock-frequency", &bus_freq);

	/*
	 * harbor_i2c_prescale() picks PRESCALE straight from the UM10204
	 * minimum low time for bus_freq, so it is always a valid, timing-
	 * correct choice for any input clock, slow ones included (a slower
	 * clock only makes the achieved low/high time more generous, never
	 * short of the minimum).
	 */
	if (hi->freq && bus_freq)
		writel(harbor_i2c_prescale(hi->freq, bus_freq),
		       hi->base + HARBOR_I2C_PRESCALE);

	/* Enable controller */
	writel(HARBOR_I2C_CTRL_ENABLE, hi->base + HARBOR_I2C_CTRL);

	hi->adap.owner = THIS_MODULE;
	hi->adap.algo = &harbor_i2c_algo;
	hi->adap.dev.parent = &pdev->dev;
	/* Child enumeration follows this node, DT or ACPI alike. */
	device_set_node(&hi->adap.dev, dev_fwnode(&pdev->dev));
	strscpy(hi->adap.name, "harbor-i2c", sizeof(hi->adap.name));
	i2c_set_adapdata(&hi->adap, hi);

	ret = devm_i2c_add_adapter(&pdev->dev, &hi->adap);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, hi);
	return 0;
}

static const struct of_device_id harbor_i2c_of_match[] = {
    {.compatible = "harbor,i2c"}, {}};
MODULE_DEVICE_TABLE(of, harbor_i2c_of_match);

static struct platform_driver harbor_i2c_driver = {
    .probe = harbor_i2c_probe,
    .driver =
	{
	    .name = "harbor-i2c",
	    .of_match_table = harbor_i2c_of_match,
	},
};
module_platform_driver(harbor_i2c_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor I2C controller driver");
MODULE_LICENSE("GPL");
