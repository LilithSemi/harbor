// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor LED engine driver
 *
 * Every register sits in an 8-byte slot. The engine has up to 6 channels.
 * A serial channel drives a WS2812 string and a pwm channel drives board
 * LEDs. Both read the pixel window, so a brightness change writes the pixel
 * word and starts a frame with SEND. A SEND while BUSY starts one more frame
 * when BUSY drops, so the driver does not poll.
 *
 * Global registers:
 *   0x000: INFO  0x008: DIV  0x010: IRQ_STATUS (W1C)  0x018: IRQ_ENABLE
 *
 * Channel ch registers at 0x100 + ch * 0x80:
 *   +0x00: CTRL  +0x08: STATUS  +0x10: T0H  +0x18: T0L  +0x20: T1H
 *   +0x28: T1L   +0x30: RESET   +0x38: PIXEL_COUNT  +0x50: REFRESH
 *
 * The item window is at 0x400 and the pixel window at 0x800, 4 bytes per
 * entry.
 */

#include <linux/atomic.h>
#include <linux/bitfield.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/led-class-multicolor.h>
#include <linux/leds.h>
#include <linux/math64.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/sysfs.h>
#include <linux/unaligned.h>

#define HLED_INFO		0x000
#define HLED_DIV		0x008
#define HLED_IRQ_STATUS		0x010
#define HLED_IRQ_ENABLE		0x018
#define HLED_CH_BASE		0x100
#define HLED_CH_STRIDE		0x80
#define HLED_ITEMS		0x400
#define HLED_PIXELS		0x800

#define HLED_INFO_CHANNELS	GENMASK(3, 0)
#define HLED_INFO_SOURCE	GENMASK(7, 4)
#define HLED_INFO_ITEM_LOG2	GENMASK(15, 8)
#define HLED_INFO_PIXELS	GENMASK(27, 16)

#define HLED_SRC_RAM		1

#define HLED_CTRL		0x00
#define HLED_STATUS		0x08
#define HLED_T0H		0x10
#define HLED_T0L		0x18
#define HLED_T1H		0x20
#define HLED_T1L		0x28
#define HLED_RESET		0x30
#define HLED_PIXEL_COUNT	0x38
#define HLED_REFRESH		0x50

#define HLED_CTRL_SEND		BIT(0)
#define HLED_CTRL_MODE_PIXEL	BIT(1)

#define HLED_ST_BUSY		BIT(0)
#define HLED_ST_UNDERRUN	BIT(1)
#define HLED_ST_DMA_ERR		BIT(2)
#define HLED_ST_KIND_PWM	BIT(3)
#define HLED_ST_STALL		BIT(4)
#define HLED_ST_FRAMES		GENMASK(23, 16)

#define HLED_MAX_CHANNELS	6
#define HLED_ITEM_MAX		256

/* WS2812 timing in nanoseconds and the tick the driver aims for. */
#define HLED_T0H_NS		400
#define HLED_T0L_NS		850
#define HLED_T1H_NS		800
#define HLED_T1L_NS		450
#define HLED_RESET_NS		80000
#define HLED_SERIAL_TICK_HZ	20000000
/* One pwm period is 256 ticks. 1 kHz needs a 256 kHz tick. */
#define HLED_PWM_TICK_HZ	256000

struct harbor_led;

struct harbor_led_pixel {
	struct harbor_led *hl;
	unsigned int index;
	u32 max;
	bool mono;
	struct led_classdev mono_cdev;
	struct led_classdev_mc mc_cdev;
	struct mc_subled subled[3];
};

struct harbor_led {
	struct device *dev;
	void __iomem *base;
	unsigned int channels;
	unsigned int pixel_source;
	unsigned int item_depth;
	unsigned int max_pixels;
	unsigned int npixels;
	unsigned long clk_rate;
	u32 refresh_hz;
	u32 ctrl[HLED_MAX_CHANNELS];
	bool serial[HLED_MAX_CHANNELS];
	bool has_serial;
	bool raw;
	atomic_t frames[HLED_MAX_CHANNELS];
	struct mutex lock;
	struct harbor_led_pixel *pixels;
};

static void __iomem *hled_ch(struct harbor_led *hl, unsigned int ch,
			     unsigned int off)
{
	return hl->base + HLED_CH_BASE + ch * HLED_CH_STRIDE + off;
}

/* Called with hl->lock held. */
static void hled_send_all(struct harbor_led *hl)
{
	unsigned int ch;

	for (ch = 0; ch < hl->channels; ch++)
		writel(hl->ctrl[ch] | HLED_CTRL_SEND, hled_ch(hl, ch, HLED_CTRL));
}

static int hled_write_pixel(struct harbor_led_pixel *p, u32 word)
{
	struct harbor_led *hl = p->hl;

	mutex_lock(&hl->lock);
	writel(word, hl->base + HLED_PIXELS + 4 * p->index);
	hled_send_all(hl);
	mutex_unlock(&hl->lock);

	return 0;
}

static int hled_mono_set(struct led_classdev *cdev, enum led_brightness b)
{
	struct harbor_led_pixel *p =
		container_of(cdev, struct harbor_led_pixel, mono_cdev);

	return hled_write_pixel(p, min_t(u32, b, p->max));
}

static int hled_mc_set(struct led_classdev *cdev, enum led_brightness b)
{
	struct led_classdev_mc *mc = lcdev_to_mccdev(cdev);
	struct harbor_led_pixel *p =
		container_of(mc, struct harbor_led_pixel, mc_cdev);
	u32 r, g, bl;

	led_mc_calc_color_components(mc, b);
	r = min_t(u32, p->subled[0].brightness, p->max);
	g = min_t(u32, p->subled[1].brightness, p->max);
	bl = min_t(u32, p->subled[2].brightness, p->max);

	return hled_write_pixel(p, r << 16 | g << 8 | bl);
}

static int hled_register_pixel(struct harbor_led *hl, unsigned int index,
			       bool mono, u32 max)
{
	struct harbor_led_pixel *p = &hl->pixels[index];
	struct led_classdev *cdev;
	const char *name;

	p->hl = hl;
	p->index = index;
	p->mono = mono;
	p->max = min_t(u32, max, 255);
	if (!p->max)
		p->max = 255;

	if (mono) {
		name = devm_kasprintf(hl->dev, GFP_KERNEL, "%s:mono:pixel%u",
				      dev_name(hl->dev), index);
		if (!name)
			return -ENOMEM;
		cdev = &p->mono_cdev;
		cdev->name = name;
		cdev->max_brightness = p->max;
		cdev->brightness_set_blocking = hled_mono_set;
		return devm_led_classdev_register(hl->dev, cdev);
	}

	name = devm_kasprintf(hl->dev, GFP_KERNEL, "%s:rgb:pixel%u",
			      dev_name(hl->dev), index);
	if (!name)
		return -ENOMEM;
	p->subled[0].color_index = LED_COLOR_ID_RED;
	p->subled[0].channel = 0;
	p->subled[1].color_index = LED_COLOR_ID_GREEN;
	p->subled[1].channel = 1;
	p->subled[2].color_index = LED_COLOR_ID_BLUE;
	p->subled[2].channel = 2;
	p->subled[0].intensity = p->max;
	p->subled[1].intensity = p->max;
	p->subled[2].intensity = p->max;
	p->mc_cdev.subled_info = p->subled;
	p->mc_cdev.num_colors = 3;
	cdev = &p->mc_cdev.led_cdev;
	cdev->name = name;
	cdev->max_brightness = p->max;
	cdev->brightness_set_blocking = hled_mc_set;

	return devm_led_classdev_multicolor_register(hl->dev, &p->mc_cdev);
}

/* DIV and the pulse timing, from the clock. */
static void hled_setup_timing(struct harbor_led *hl)
{
	unsigned long tick_hz;
	unsigned int div, ch;

	if (!hl->clk_rate) {
		dev_warn(hl->dev,
			 "no clock-frequency, the pulse timing keeps the hardware reset values\n");
		return;
	}

	if (hl->has_serial)
		div = max_t(unsigned long, hl->clk_rate / HLED_SERIAL_TICK_HZ, 1);
	else
		div = max_t(unsigned long, hl->clk_rate / HLED_PWM_TICK_HZ, 1);
	div = min_t(unsigned int, div, 0x10000);
	writel(div - 1, hl->base + HLED_DIV);
	tick_hz = hl->clk_rate / div;

#define HLED_TICKS(ns) \
	min_t(u64, DIV_ROUND_CLOSEST_ULL((u64)(ns) * tick_hz, NSEC_PER_SEC), 0x7fff)

	for (ch = 0; ch < hl->channels; ch++) {
		if (!hl->serial[ch])
			continue;
		writel(HLED_TICKS(HLED_T0H_NS), hled_ch(hl, ch, HLED_T0H));
		writel(HLED_TICKS(HLED_T0L_NS), hled_ch(hl, ch, HLED_T0L));
		writel(HLED_TICKS(HLED_T1H_NS), hled_ch(hl, ch, HLED_T1H));
		writel(HLED_TICKS(HLED_T1L_NS), hled_ch(hl, ch, HLED_T1L));
		writel(min_t(u64, DIV_ROUND_CLOSEST_ULL((u64)HLED_RESET_NS * tick_hz,
							NSEC_PER_SEC),
			     0xfffff),
		       hled_ch(hl, ch, HLED_RESET));
	}
#undef HLED_TICKS
}

static irqreturn_t hled_irq(int irq, void *data)
{
	struct harbor_led *hl = data;
	u32 st = readl(hl->base + HLED_IRQ_STATUS);
	unsigned int ch;

	if (!st)
		return IRQ_NONE;

	writel(st, hl->base + HLED_IRQ_STATUS);
	for (ch = 0; ch < hl->channels; ch++)
		if (st & BIT(8 + ch))
			atomic_inc(&hl->frames[ch]);

	return IRQ_HANDLED;
}

static ssize_t refresh_hz_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct harbor_led *hl = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", hl->refresh_hz);
}

static ssize_t refresh_hz_store(struct device *dev,
				struct device_attribute *attr, const char *buf,
				size_t len)
{
	struct harbor_led *hl = dev_get_drvdata(dev);
	unsigned int ch;
	u32 hz, period = 0;
	int ret;

	ret = kstrtou32(buf, 0, &hz);
	if (ret)
		return ret;

	if (!hl->clk_rate) {
		dev_warn_once(dev, "refresh_hz needs the clock-frequency property\n");
		return -EINVAL;
	}
	if (hz) {
		period = hl->clk_rate / hz;
		if (!period)
			return -EINVAL;
	}

	mutex_lock(&hl->lock);
	for (ch = 0; ch < hl->channels; ch++)
		writel(period, hled_ch(hl, ch, HLED_REFRESH));
	hl->refresh_hz = hz;
	mutex_unlock(&hl->lock);

	return len;
}
static DEVICE_ATTR_RW(refresh_hz);

static ssize_t send_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t len)
{
	struct harbor_led *hl = dev_get_drvdata(dev);
	bool v;
	int ret;

	ret = kstrtobool(buf, &v);
	if (ret)
		return ret;

	if (v) {
		mutex_lock(&hl->lock);
		hled_send_all(hl);
		mutex_unlock(&hl->lock);
	}

	return len;
}
static DEVICE_ATTR_WO(send);

/* "raw" runs the item window on the serial channels, "pixel" runs pixels. */
static ssize_t mode_show(struct device *dev, struct device_attribute *attr,
			 char *buf)
{
	struct harbor_led *hl = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%s\n", hl->raw ? "raw" : "pixel");
}

static ssize_t mode_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t len)
{
	struct harbor_led *hl = dev_get_drvdata(dev);
	unsigned int ch;
	bool raw;

	if (sysfs_streq(buf, "raw"))
		raw = true;
	else if (sysfs_streq(buf, "pixel"))
		raw = false;
	else
		return -EINVAL;

	mutex_lock(&hl->lock);
	for (ch = 0; ch < hl->channels; ch++) {
		if (!hl->serial[ch])
			continue;
		if (raw)
			hl->ctrl[ch] &= ~HLED_CTRL_MODE_PIXEL;
		else
			hl->ctrl[ch] |= HLED_CTRL_MODE_PIXEL;
		writel(hl->ctrl[ch], hled_ch(hl, ch, HLED_CTRL));
	}
	hl->raw = raw;
	mutex_unlock(&hl->lock);

	return len;
}
static DEVICE_ATTR_RW(mode);

static ssize_t status_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct harbor_led *hl = dev_get_drvdata(dev);
	ssize_t n = 0;
	unsigned int ch;

	for (ch = 0; ch < hl->channels; ch++) {
		u32 st = readl(hled_ch(hl, ch, HLED_STATUS));

		n += sysfs_emit_at(buf, n,
				   "ch%u kind=%s status=0x%08x busy=%u underrun=%u dma_err=%u stall=%u hw_frames=%lu irq_frames=%d\n",
				   ch, (st & HLED_ST_KIND_PWM) ? "pwm" : "serial",
				   st, !!(st & HLED_ST_BUSY),
				   !!(st & HLED_ST_UNDERRUN),
				   !!(st & HLED_ST_DMA_ERR),
				   !!(st & HLED_ST_STALL),
				   FIELD_GET(HLED_ST_FRAMES, st),
				   atomic_read(&hl->frames[ch]));
	}

	return n;
}
static DEVICE_ATTR_RO(status);

/* The items are packed 16 bit little endian values. */
static ssize_t items_write(struct file *file, struct kobject *kobj,
			   const struct bin_attribute *attr, char *buf,
			   loff_t off, size_t count)
{
	struct device *dev = kobj_to_dev(kobj);
	struct harbor_led *hl = dev_get_drvdata(dev);
	size_t i;

	if ((off | count) & 1)
		return -EINVAL;
	if (off + count > hl->item_depth * 2)
		return -EFBIG;

	mutex_lock(&hl->lock);
	for (i = 0; i < count; i += 2)
		writel(get_unaligned_le16(buf + i),
		       hl->base + HLED_ITEMS + 4 * ((off + i) / 2));
	mutex_unlock(&hl->lock);

	return count;
}
static const struct bin_attribute items_attr = {
	.attr = { .name = "items", .mode = 0200 },
	.size = HLED_ITEM_MAX * 2,
	.write = items_write,
};

static struct attribute *hled_attrs[] = {
	&dev_attr_refresh_hz.attr,
	&dev_attr_send.attr,
	&dev_attr_mode.attr,
	&dev_attr_status.attr,
	NULL,
};

static const struct bin_attribute *const hled_bin_attrs[] = {
	&items_attr,
	NULL,
};

static umode_t hled_bin_visible(struct kobject *kobj,
				const struct bin_attribute *attr, int n)
{
	struct harbor_led *hl = dev_get_drvdata(kobj_to_dev(kobj));

	return hl->has_serial ? attr->attr.mode : 0;
}

static const struct attribute_group hled_group = {
	.attrs = hled_attrs,
	.bin_attrs = hled_bin_attrs,
	.is_bin_visible = hled_bin_visible,
};

static const struct attribute_group *hled_groups[] = {
	&hled_group,
	NULL,
};

static int harbor_led_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct harbor_led *hl;
	u32 info, clk = 0;
	u32 *colors = NULL, *maxb = NULL;
	unsigned int ch, i, n_colors;
	const char *kinds[HLED_MAX_CHANNELS];
	int irq, ret, count, nkinds;

	hl = devm_kzalloc(dev, sizeof(*hl), GFP_KERNEL);
	if (!hl)
		return -ENOMEM;
	hl->dev = dev;
	mutex_init(&hl->lock);
	platform_set_drvdata(pdev, hl);

	hl->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hl->base))
		return PTR_ERR(hl->base);

	info = readl(hl->base + HLED_INFO);
	hl->channels = FIELD_GET(HLED_INFO_CHANNELS, info);
	hl->pixel_source = FIELD_GET(HLED_INFO_SOURCE, info);
	hl->item_depth = 1U << FIELD_GET(HLED_INFO_ITEM_LOG2, info);
	hl->max_pixels = FIELD_GET(HLED_INFO_PIXELS, info);
	if (!hl->channels || hl->channels > HLED_MAX_CHANNELS)
		return dev_err_probe(dev, -ENODEV, "bad channel count %u\n",
				     hl->channels);
	hl->item_depth = min_t(unsigned int, hl->item_depth, HLED_ITEM_MAX);

	device_property_read_u32(dev, "clock-frequency", &clk);
	hl->clk_rate = clk;
	nkinds = device_property_read_string_array(dev, "harbor,kinds", kinds,
						   HLED_MAX_CHANNELS);
	if (nkinds < 0)
		nkinds = 0;

	for (ch = 0; ch < hl->channels; ch++) {
		u32 st = readl(hled_ch(hl, ch, HLED_STATUS));

		hl->serial[ch] = !(st & HLED_ST_KIND_PWM);
		hl->has_serial |= hl->serial[ch];
		/* Keep the reset value of POLARITY and IDLE. */
		hl->ctrl[ch] = (readl(hled_ch(hl, ch, HLED_CTRL)) &
				~HLED_CTRL_SEND) | HLED_CTRL_MODE_PIXEL;
		if (ch < nkinds && !strcmp(kinds[ch], "serial") != !hl->serial[ch])
			dev_warn(dev, "harbor,kinds of channel %u disagrees with STATUS\n",
				 ch);
	}

	if (hl->pixel_source == HLED_SRC_RAM) {
		count = device_property_count_u32(dev, "harbor,pixel-colors");
		n_colors = count > 0 ? count : hl->max_pixels;
		n_colors = min(n_colors, hl->max_pixels);
		hl->npixels = n_colors;

		colors = devm_kcalloc(dev, n_colors, sizeof(*colors), GFP_KERNEL);
		maxb = devm_kcalloc(dev, n_colors, sizeof(*maxb), GFP_KERNEL);
		hl->pixels = devm_kcalloc(dev, n_colors, sizeof(*hl->pixels),
					  GFP_KERNEL);
		if (!colors || !maxb || !hl->pixels)
			return -ENOMEM;
		if (count > 0)
			device_property_read_u32_array(dev, "harbor,pixel-colors",
						       colors, n_colors);
		count = device_property_count_u32(dev, "harbor,pixel-max-brightness");
		if (count > 0)
			device_property_read_u32_array(dev,
						       "harbor,pixel-max-brightness",
						       maxb, min_t(unsigned int, count, n_colors));
	}

	hled_setup_timing(hl);
	for (ch = 0; ch < hl->channels; ch++) {
		if (hl->serial[ch])
			writel(hl->npixels, hled_ch(hl, ch, HLED_PIXEL_COUNT));
		writel(hl->ctrl[ch], hled_ch(hl, ch, HLED_CTRL));
	}

	irq = platform_get_irq_optional(pdev, 0);
	if (irq == -EPROBE_DEFER)
		return irq;
	if (irq > 0) {
		ret = devm_request_irq(dev, irq, hled_irq, 0, dev_name(dev), hl);
		if (ret)
			return ret;
		writel(GENMASK(8 + hl->channels - 1, 8),
		       hl->base + HLED_IRQ_ENABLE);
	}

	for (i = 0; i < hl->npixels; i++) {
		ret = hled_register_pixel(hl, i, colors[i] == 1,
					  maxb[i] ? maxb[i] : 255);
		if (ret)
			return dev_err_probe(dev, ret, "pixel %u\n", i);
	}

	return 0;
}

static void harbor_led_remove(struct platform_device *pdev)
{
	struct harbor_led *hl = platform_get_drvdata(pdev);
	unsigned int ch;

	/* The class devices and sysfs files are removed by the device core. */
	writel(0, hl->base + HLED_IRQ_ENABLE);
	for (ch = 0; ch < hl->channels; ch++)
		writel(0, hled_ch(hl, ch, HLED_REFRESH));
}

static const struct of_device_id harbor_led_of_match[] = {
	{ .compatible = "harbor,led-engine" },
	{ }
};
MODULE_DEVICE_TABLE(of, harbor_led_of_match);

static struct platform_driver harbor_led_driver = {
	.probe = harbor_led_probe,
	.remove = harbor_led_remove,
	.driver = {
		.name = "harbor-led",
		.of_match_table = harbor_led_of_match,
		.dev_groups = hled_groups,
	},
};
module_platform_driver(harbor_led_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor LED engine driver");
MODULE_LICENSE("GPL");
