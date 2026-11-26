// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor GPIO controller driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 *   0x00: INPUT      (RO) - Current pin values
 *   0x08: OUTPUT     (RW) - Output values
 *   0x10: DIR        (RW) - Direction (1=output, 0=input)
 *   0x18: IRQ_EN     (RW) - Interrupt enable per pin
 *   0x20: IRQ_STATUS (W1C) - Interrupt status
 *   0x28: IRQ_EDGE   (RW) - 0=level, 1=edge triggered
 *   0x30: IRQ_FALL   (RW) - 1=falling edge triggered
 *
 * A pin triggers on a high level when both IRQ_EDGE and IRQ_FALL are 0, on a
 * rising edge for IRQ_EDGE only, on a falling edge for IRQ_FALL only and on
 * both edges when both are 1.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/gpio/driver.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/of.h>

#define HARBOR_GPIO_INPUT      0x00
#define HARBOR_GPIO_OUTPUT     0x08
#define HARBOR_GPIO_DIR	       0x10
#define HARBOR_GPIO_IRQ_EN     0x18
#define HARBOR_GPIO_IRQ_STATUS 0x20
#define HARBOR_GPIO_IRQ_EDGE   0x28
#define HARBOR_GPIO_IRQ_FALL   0x30

struct harbor_gpio {
	void __iomem *base;
	struct gpio_chip gc;
	raw_spinlock_t lock;
};

static int harbor_gpio_get(struct gpio_chip *gc, unsigned int offset)
{
	struct harbor_gpio *hg = gpiochip_get_data(gc);

	return !!(readl(hg->base + HARBOR_GPIO_INPUT) & BIT(offset));
}

static int harbor_gpio_set(struct gpio_chip *gc, unsigned int offset, int val)
{
	struct harbor_gpio *hg = gpiochip_get_data(gc);
	unsigned long flags;
	u32 reg;

	raw_spin_lock_irqsave(&hg->lock, flags);
	reg = readl(hg->base + HARBOR_GPIO_OUTPUT);
	if (val)
		reg |= BIT(offset);
	else
		reg &= ~BIT(offset);
	writel(reg, hg->base + HARBOR_GPIO_OUTPUT);
	raw_spin_unlock_irqrestore(&hg->lock, flags);

	return 0;
}

static int harbor_gpio_direction_input(struct gpio_chip *gc,
				       unsigned int offset)
{
	struct harbor_gpio *hg = gpiochip_get_data(gc);
	unsigned long flags;
	u32 reg;

	raw_spin_lock_irqsave(&hg->lock, flags);
	reg = readl(hg->base + HARBOR_GPIO_DIR);
	reg &= ~BIT(offset);
	writel(reg, hg->base + HARBOR_GPIO_DIR);
	raw_spin_unlock_irqrestore(&hg->lock, flags);

	return 0;
}

static int harbor_gpio_direction_output(struct gpio_chip *gc,
					unsigned int offset, int val)
{
	struct harbor_gpio *hg = gpiochip_get_data(gc);
	unsigned long flags;
	u32 reg;

	raw_spin_lock_irqsave(&hg->lock, flags);

	reg = readl(hg->base + HARBOR_GPIO_OUTPUT);
	if (val)
		reg |= BIT(offset);
	else
		reg &= ~BIT(offset);
	writel(reg, hg->base + HARBOR_GPIO_OUTPUT);

	reg = readl(hg->base + HARBOR_GPIO_DIR);
	reg |= BIT(offset);
	writel(reg, hg->base + HARBOR_GPIO_DIR);

	raw_spin_unlock_irqrestore(&hg->lock, flags);

	return 0;
}

static void harbor_gpio_irq_mask(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct harbor_gpio *hg = gpiochip_get_data(gc);
	irq_hw_number_t hwirq = irqd_to_hwirq(d);
	unsigned long flags;
	u32 reg;

	raw_spin_lock_irqsave(&hg->lock, flags);
	reg = readl(hg->base + HARBOR_GPIO_IRQ_EN);
	reg &= ~BIT(hwirq);
	writel(reg, hg->base + HARBOR_GPIO_IRQ_EN);
	raw_spin_unlock_irqrestore(&hg->lock, flags);

	gpiochip_disable_irq(gc, hwirq);
}

static void harbor_gpio_irq_unmask(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct harbor_gpio *hg = gpiochip_get_data(gc);
	irq_hw_number_t hwirq = irqd_to_hwirq(d);
	unsigned long flags;
	u32 reg;

	gpiochip_enable_irq(gc, hwirq);

	raw_spin_lock_irqsave(&hg->lock, flags);
	reg = readl(hg->base + HARBOR_GPIO_IRQ_EN);
	reg |= BIT(hwirq);
	writel(reg, hg->base + HARBOR_GPIO_IRQ_EN);
	raw_spin_unlock_irqrestore(&hg->lock, flags);
}

static void harbor_gpio_irq_ack(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct harbor_gpio *hg = gpiochip_get_data(gc);

	writel(BIT(irqd_to_hwirq(d)), hg->base + HARBOR_GPIO_IRQ_STATUS);
}

static int harbor_gpio_irq_set_type(struct irq_data *d, unsigned int type)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct harbor_gpio *hg = gpiochip_get_data(gc);
	u32 bit = BIT(irqd_to_hwirq(d));
	bool edge, fall;
	unsigned long flags;
	u32 reg;

	switch (type & IRQ_TYPE_SENSE_MASK) {
	case IRQ_TYPE_LEVEL_HIGH:
		edge = false;
		fall = false;
		break;
	case IRQ_TYPE_EDGE_RISING:
		edge = true;
		fall = false;
		break;
	case IRQ_TYPE_EDGE_FALLING:
		edge = false;
		fall = true;
		break;
	case IRQ_TYPE_EDGE_BOTH:
		edge = true;
		fall = true;
		break;
	default:
		return -EINVAL;
	}

	raw_spin_lock_irqsave(&hg->lock, flags);
	reg = readl(hg->base + HARBOR_GPIO_IRQ_EDGE);
	reg = edge ? reg | bit : reg & ~bit;
	writel(reg, hg->base + HARBOR_GPIO_IRQ_EDGE);
	reg = readl(hg->base + HARBOR_GPIO_IRQ_FALL);
	reg = fall ? reg | bit : reg & ~bit;
	writel(reg, hg->base + HARBOR_GPIO_IRQ_FALL);
	/* The two writes pass through another trigger, so drop what it caught. */
	writel(bit, hg->base + HARBOR_GPIO_IRQ_STATUS);
	raw_spin_unlock_irqrestore(&hg->lock, flags);

	if (type & IRQ_TYPE_LEVEL_MASK)
		irq_set_handler_locked(d, handle_level_irq);
	else
		irq_set_handler_locked(d, handle_edge_irq);

	return 0;
}

static const struct irq_chip harbor_gpio_irqchip = {
    .name = "harbor-gpio",
    .irq_mask = harbor_gpio_irq_mask,
    .irq_unmask = harbor_gpio_irq_unmask,
    .irq_ack = harbor_gpio_irq_ack,
    .irq_set_type = harbor_gpio_irq_set_type,
    .flags = IRQCHIP_IMMUTABLE,
    GPIOCHIP_IRQ_RESOURCE_HELPERS,
};

static irqreturn_t harbor_gpio_irq_handler(int irq, void *dev_id)
{
	struct harbor_gpio *hg = dev_id;
	u32 status;
	int i;

	status = readl(hg->base + HARBOR_GPIO_IRQ_STATUS);
	if (!status)
		return IRQ_NONE;

	for_each_set_bit(i, (unsigned long *)&status, hg->gc.ngpio)
	    generic_handle_domain_irq(hg->gc.irq.domain, i);

	return IRQ_HANDLED;
}

static int harbor_gpio_probe(struct platform_device *pdev)
{
	struct harbor_gpio *hg;
	struct gpio_irq_chip *girq;
	int ret, irq;

	hg = devm_kzalloc(&pdev->dev, sizeof(*hg), GFP_KERNEL);
	if (!hg)
		return -ENOMEM;

	hg->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hg->base))
		return PTR_ERR(hg->base);

	raw_spin_lock_init(&hg->lock);

	hg->gc.label = dev_name(&pdev->dev);
	hg->gc.parent = &pdev->dev;
	hg->gc.owner = THIS_MODULE;
	hg->gc.base = -1;
	hg->gc.ngpio = 32;
	hg->gc.get = harbor_gpio_get;
	hg->gc.set = harbor_gpio_set;
	hg->gc.direction_input = harbor_gpio_direction_input;
	hg->gc.direction_output = harbor_gpio_direction_output;

	{
		u32 ngpios = 32;
		device_property_read_u32(&pdev->dev, "ngpios", &ngpios);
		hg->gc.ngpio = ngpios;
	}

	irq = platform_get_irq_optional(pdev, 0);
	if (irq > 0) {
		girq = &hg->gc.irq;
		gpio_irq_chip_set_chip(girq, &harbor_gpio_irqchip);
		girq->handler = handle_edge_irq;
		girq->default_type = IRQ_TYPE_EDGE_RISING;
		girq->parent_handler = NULL;
		girq->num_parents = 0;

		ret = devm_request_irq(&pdev->dev, irq, harbor_gpio_irq_handler,
				       IRQF_SHARED, dev_name(&pdev->dev), hg);
		if (ret)
			return ret;
	}

	/* Clear any pending interrupts */
	writel(0xFFFFFFFF, hg->base + HARBOR_GPIO_IRQ_STATUS);
	writel(0, hg->base + HARBOR_GPIO_IRQ_EN);

	return devm_gpiochip_add_data(&pdev->dev, &hg->gc, hg);
}

static const struct of_device_id harbor_gpio_of_match[] = {
    {.compatible = "harbor,gpio"}, {}};
MODULE_DEVICE_TABLE(of, harbor_gpio_of_match);

static struct platform_driver harbor_gpio_driver = {
    .probe = harbor_gpio_probe,
    .driver =
	{
	    .name = "harbor-gpio",
	    .of_match_table = harbor_gpio_of_match,
	},
};
module_platform_driver(harbor_gpio_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor GPIO controller driver");
MODULE_LICENSE("GPL");
