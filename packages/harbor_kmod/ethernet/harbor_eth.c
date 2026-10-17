// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor Ethernet MAC driver
 *
 * The MAC moves frames through two descriptor rings in system memory. The
 * hardware owns a descriptor while OWN is set. It writes word 3 before it
 * clears OWN, so OWN clear means that the data and the status are in memory.
 */

#include <linux/bitfield.h>
#include <linux/clk.h>
#include <linux/crc32.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/of.h>
#include <linux/of_mdio.h>
#include <linux/of_net.h>
#include <linux/phy.h>
#include <linux/platform_device.h>
#include <linux/rtnetlink.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>

#define HETH_ID		0x000
#define HETH_HW_CAPS	0x004
#define HETH_CTRL	0x008
#define HETH_STATUS	0x00c
#define HETH_INT_STATUS 0x010
#define HETH_INT_ENABLE 0x014
#define HETH_MAC_LO	0x018
#define HETH_MAC_HI	0x01c
#define HETH_MC_HASH_LO 0x020
#define HETH_MC_HASH_HI 0x024
#define HETH_TX_RING	0x030
#define HETH_RX_RING	0x050
#define HETH_RING_LO	0x00
#define HETH_RING_HI	0x04
#define HETH_RING_SIZE	0x08
#define HETH_RING_TAIL	0x0c
#define HETH_RING_HEAD	0x10
#define HETH_MDIO_CTRL	0x070
#define HETH_MDIO_DATA	0x074
#define HETH_MDIO_DIV	0x078
#define HETH_CNT_BASE	0x080

#define HETH_ID_VALUE 0x45544831

#define HETH_CAPS_MII	    BIT(0)
#define HETH_CAPS_RMII	    BIT(1)
#define HETH_CAPS_RGMII	    BIT(2)
#define HETH_CAPS_GIGABIT   BIT(3)
#define HETH_CAPS_MC_HASH   BIT(4)
#define HETH_CAPS_PROMISC   BIT(5)
#define HETH_CAPS_PAUSE	    BIT(6)
#define HETH_CAPS_MDIO_C45  BIT(9)
#define HETH_CAPS_DESC_LOG2 GENMASK(15, 12)

#define HETH_CTRL_TX_EN	      BIT(0)
#define HETH_CTRL_RX_EN	      BIT(1)
#define HETH_CTRL_PROMISC     BIT(2)
#define HETH_CTRL_KEEP_BAD    BIT(3)
#define HETH_CTRL_SPEED	      GENMASK(5, 4)
#define HETH_CTRL_FULL_DUPLEX BIT(6)
#define HETH_CTRL_SOFT_RESET  BIT(7)

#define HETH_SPEED_10	0
#define HETH_SPEED_100	1
#define HETH_SPEED_1000 2

#define HETH_ST_TX_RUNNING  BIT(0)
#define HETH_ST_RX_RUNNING  BIT(1)
#define HETH_ST_TX_RING_ERR BIT(2)
#define HETH_ST_RX_RING_ERR BIT(3)
#define HETH_ST_RX_CLK_LOST BIT(4)
#define HETH_ST_TX_CLK_LOST BIT(5)

#define HETH_INT_TX_DONE   BIT(0)
#define HETH_INT_RX_DONE   BIT(1)
#define HETH_INT_TX_ERR	   BIT(2)
#define HETH_INT_RX_ERR	   BIT(3)
#define HETH_INT_RX_MISSED BIT(4)
#define HETH_INT_ALL	   GENMASK(4, 0)

#define HETH_MDIO_REG	    GENMASK(4, 0)
#define HETH_MDIO_PHY	    GENMASK(9, 5)
#define HETH_MDIO_WRITE	    BIT(10)
#define HETH_MDIO_C45	    BIT(11)
#define HETH_MDIO_START	    BIT(12)
#define HETH_MDIO_BUSY	    BIT(13)
#define HETH_MDIO_DEVAD	    GENMASK(20, 16)
#define HETH_MDIO_DATA_VAL  GENMASK(15, 0)
#define HETH_MDIO_DATA_ADDR GENMASK(31, 16)
#define HETH_MDC_MAX_HZ	    2500000

/* Descriptor word 2. */
#define HETH_DESC_LEN GENMASK(15, 0)
#define HETH_DESC_SOP BIT(16)
#define HETH_DESC_EOP BIT(17)
#define HETH_DESC_IRQ BIT(18)
#define HETH_DESC_OWN BIT(31)

/* TX descriptor word 3. */
#define HETH_TXS_DONE BIT(0)
#define HETH_TXS_ERR  GENMASK(3, 1)

/* RX descriptor word 3. */
#define HETH_RXS_LEN GENMASK(15, 0)
#define HETH_RXS_SOP BIT(16)
#define HETH_RXS_EOP BIT(17)
#define HETH_RXS_ERR GENMASK(24, 22)

#define HETH_TX_ERR_CLK_LOST 4

#define HETH_RX_ERR_FCS	     1
#define HETH_RX_ERR_RUNT     2
#define HETH_RX_ERR_OVERSIZE 3
#define HETH_RX_ERR_CUT	     6
#define HETH_RX_ERR_PHY	     7

#define HETH_TX_ORDER	     8
#define HETH_RX_ORDER	     8
#define HETH_RX_BUF_SIZE     2048
#define HETH_MAX_FRAME	     1518
#define HETH_STOP_TIMEOUT_US 50000

static const char *const heth_counter_names[] = {
    "hw_tx_frames",   "hw_rx_frames",	"hw_rx_fcs_err",
    "hw_rx_missed",   "hw_rx_overflow", "hw_rx_runt",
    "hw_rx_oversize", "hw_tx_pause",	"hw_rx_pause",
};

enum {
	HETH_CNT_TX_FRAMES,
	HETH_CNT_RX_FRAMES,
	HETH_CNT_RX_FCS_ERR,
	HETH_CNT_RX_MISSED,
	HETH_CNT_RX_OVERFLOW,
	HETH_CNT_RX_RUNT,
	HETH_CNT_RX_OVERSIZE,
	HETH_CNT_TX_PAUSE,
	HETH_CNT_RX_PAUSE,
	HETH_NUM_COUNTERS,
};

struct heth_desc {
	__le32 addr_lo;
	__le32 addr_hi;
	__le32 ctrl;
	__le32 status;
};

struct heth_tx_slot {
	struct sk_buff *skb;
	dma_addr_t dma;
	unsigned int len;
	bool page;
};

struct heth_rx_slot {
	void *buf;
	dma_addr_t dma;
};

struct heth_priv {
	void __iomem *base;
	struct device *dev;
	struct net_device *ndev;
	struct napi_struct napi;
	struct mii_bus *mii;
	struct work_struct reset_work;
	phy_interface_t phy_iface;
	u32 caps;
	unsigned int desc_size;
	int irq;

	/* CTRL is shared by rx_mode, adjust_link and the up and down paths. */
	spinlock_t ctrl_lock;
	u32 ctrl;
	int speed;

	spinlock_t tx_lock;
	void *tx_ring;
	dma_addr_t tx_ring_dma;
	struct heth_tx_slot *tx_slot;
	unsigned int tx_count;
	unsigned int tx_next;
	unsigned int tx_clean;
	/* A frame with a ring stopping error was counted. */
	bool tx_err_seen;
	/* Error code of the frame that tx_clean has not reached the end of. */
	unsigned int tx_frame_err;

	void *rx_ring;
	dma_addr_t rx_ring_dma;
	struct heth_rx_slot *rx_slot;
	unsigned int rx_count;
	unsigned int rx_next;

	spinlock_t stats_lock;
	u32 cnt_last[HETH_NUM_COUNTERS];
	u64 cnt_total[HETH_NUM_COUNTERS];
};

static inline u32 heth_rd(struct heth_priv *p, u32 off)
{
	return readl(p->base + off);
}

static inline void heth_wr(struct heth_priv *p, u32 off, u32 val)
{
	writel(val, p->base + off);
}

static struct heth_desc *heth_desc(void *ring, struct heth_priv *p,
				   unsigned int i)
{
	return ring + i * p->desc_size;
}

static unsigned int heth_num_counters(struct heth_priv *p)
{
	return (p->caps & HETH_CAPS_PAUSE) ? HETH_NUM_COUNTERS
					   : HETH_CNT_TX_PAUSE;
}

/* The counters wrap at 32 bits. Each read adds the change since the last. */
static void heth_update_counters(struct heth_priv *p)
{
	unsigned long flags;
	unsigned int i;

	spin_lock_irqsave(&p->stats_lock, flags);
	for (i = 0; i < heth_num_counters(p); i++) {
		u32 v = heth_rd(p, HETH_CNT_BASE + 4 * i);

		p->cnt_total[i] += (u32)(v - p->cnt_last[i]);
		p->cnt_last[i] = v;
	}
	spin_unlock_irqrestore(&p->stats_lock, flags);
}

static void heth_write_ctrl(struct heth_priv *p, u32 set, u32 clear)
{
	unsigned long flags;

	spin_lock_irqsave(&p->ctrl_lock, flags);
	p->ctrl = (p->ctrl & ~clear) | set;
	heth_wr(p, HETH_CTRL, p->ctrl);
	/* soft_reset clears itself in the hardware. */
	p->ctrl &= ~HETH_CTRL_SOFT_RESET;
	spin_unlock_irqrestore(&p->ctrl_lock, flags);
}

/*
 * Wait until the TX and RX paths stop. A side whose PHY clock is lost
 * keeps its running bit, so its clk_lost bit counts as stopped. A stale
 * clk_lost is cleared first. The clock watch sets it again if the clock is
 * still lost.
 */
static int heth_wait_stopped(struct heth_priv *p, u32 mask)
{
	u32 st;

	heth_wr(p, HETH_STATUS, HETH_ST_TX_CLK_LOST | HETH_ST_RX_CLK_LOST);
	return readl_poll_timeout(
	    p->base + HETH_STATUS, st,
	    (!(mask & HETH_ST_TX_RUNNING) || !(st & HETH_ST_TX_RUNNING) ||
	     (st & HETH_ST_TX_CLK_LOST)) &&
		(!(mask & HETH_ST_RX_RUNNING) || !(st & HETH_ST_RX_RUNNING) ||
		 (st & HETH_ST_RX_CLK_LOST)),
	    10, HETH_STOP_TIMEOUT_US);
}

/* MDIO */

static int heth_mdio_wait(struct heth_priv *p)
{
	u32 v;

	return readl_poll_timeout(p->base + HETH_MDIO_CTRL, v,
				  !(v & (HETH_MDIO_BUSY | HETH_MDIO_START)), 10,
				  10000);
}

static int heth_mdio_xfer(struct heth_priv *p, u32 ctrl, u32 data)
{
	int ret;

	ret = heth_mdio_wait(p);
	if (ret)
		return ret;
	heth_wr(p, HETH_MDIO_DATA, data);
	heth_wr(p, HETH_MDIO_CTRL, ctrl | HETH_MDIO_START);
	ret = heth_mdio_wait(p);
	if (ret)
		return ret;
	if (ctrl & HETH_MDIO_WRITE)
		return 0;
	return FIELD_GET(HETH_MDIO_DATA_VAL, heth_rd(p, HETH_MDIO_DATA));
}

static int heth_mdio_read(struct mii_bus *bus, int addr, int reg)
{
	return heth_mdio_xfer(bus->priv,
			      FIELD_PREP(HETH_MDIO_PHY, addr) |
				  FIELD_PREP(HETH_MDIO_REG, reg),
			      0);
}

static int heth_mdio_write(struct mii_bus *bus, int addr, int reg, u16 val)
{
	return heth_mdio_xfer(bus->priv,
			      FIELD_PREP(HETH_MDIO_PHY, addr) |
				  FIELD_PREP(HETH_MDIO_REG, reg) |
				  HETH_MDIO_WRITE,
			      val);
}

static int heth_mdio_read_c45(struct mii_bus *bus, int addr, int devad, int reg)
{
	return heth_mdio_xfer(bus->priv,
			      FIELD_PREP(HETH_MDIO_PHY, addr) |
				  FIELD_PREP(HETH_MDIO_DEVAD, devad) |
				  HETH_MDIO_C45,
			      FIELD_PREP(HETH_MDIO_DATA_ADDR, reg));
}

static int heth_mdio_write_c45(struct mii_bus *bus, int addr, int devad,
			       int reg, u16 val)
{
	return heth_mdio_xfer(bus->priv,
			      FIELD_PREP(HETH_MDIO_PHY, addr) |
				  FIELD_PREP(HETH_MDIO_DEVAD, devad) |
				  HETH_MDIO_C45 | HETH_MDIO_WRITE,
			      FIELD_PREP(HETH_MDIO_DATA_ADDR, reg) | val);
}

static int heth_mdio_init(struct heth_priv *p, struct clk *clk)
{
	struct device_node *np;
	struct mii_bus *bus;
	unsigned long rate = 0;
	u32 freq;
	int ret;

	if (clk)
		rate = clk_get_rate(clk);
	if (!rate &&
	    !device_property_read_u32(p->dev, "clock-frequency", &freq))
		rate = freq;
	if (rate)
		heth_wr(p, HETH_MDIO_DIV,
			DIV_ROUND_UP(rate, 2 * HETH_MDC_MAX_HZ) - 1);
	else
		dev_warn(p->dev, "no clock rate, MDC uses the reset divider\n");

	bus = devm_mdiobus_alloc(p->dev);
	if (!bus)
		return -ENOMEM;
	bus->name = "harbor-eth-mdio";
	snprintf(bus->id, MII_BUS_ID_SIZE, "%s", dev_name(p->dev));
	bus->parent = p->dev;
	bus->priv = p;
	bus->read = heth_mdio_read;
	bus->write = heth_mdio_write;
	if (p->caps & HETH_CAPS_MDIO_C45) {
		bus->read_c45 = heth_mdio_read_c45;
		bus->write_c45 = heth_mdio_write_c45;
	}

	/* With no PHY child node, a NULL node makes the bus scan all addresses. */
	np = of_get_child_by_name(p->dev->of_node, "mdio");
	if (np && !of_get_available_child_count(np)) {
		of_node_put(np);
		np = NULL;
	}
	ret = devm_of_mdiobus_register(p->dev, bus, np);
	of_node_put(np);
	if (ret)
		return ret;
	p->mii = bus;
	return 0;
}

/* Address filter */

static void heth_write_mac(struct heth_priv *p, const u8 *a)
{
	heth_wr(p, HETH_MAC_LO,
		a[0] | (a[1] << 8) | (a[2] << 16) | ((u32)a[3] << 24));
	heth_wr(p, HETH_MAC_HI, a[4] | (a[5] << 8));
}

static void heth_set_rx_mode(struct net_device *ndev)
{
	struct heth_priv *p = netdev_priv(ndev);
	bool hash = p->caps & HETH_CAPS_MC_HASH;
	bool promisc = ndev->flags & IFF_PROMISC;
	struct netdev_hw_addr *ha;
	u64 mc = 0;

	if (ndev->flags & IFF_ALLMULTI) {
		mc = ~0ULL;
	} else {
		netdev_for_each_mc_addr(ha, ndev) mc |=
		    1ULL << (ether_crc(ETH_ALEN, ha->addr) >> 26);
	}
	/* With no hash filter, multicast needs promiscuous mode. */
	if (mc && !hash)
		promisc = true;
	if (hash) {
		heth_wr(p, HETH_MC_HASH_LO, lower_32_bits(mc));
		heth_wr(p, HETH_MC_HASH_HI, upper_32_bits(mc));
	}
	if (promisc && !(p->caps & HETH_CAPS_PROMISC)) {
		netdev_warn_once(ndev, "MAC has no promiscuous mode\n");
		promisc = false;
	}
	heth_write_ctrl(p, promisc ? HETH_CTRL_PROMISC : 0,
			promisc ? 0 : HETH_CTRL_PROMISC);
}

/*
 * The RX filter reads the address bit by bit, so RX must be stopped. The
 * PHY lock keeps adjust_link from changing the enables at the same time.
 */
static int heth_set_mac_address(struct net_device *ndev, void *addr)
{
	struct heth_priv *p = netdev_priv(ndev);
	struct phy_device *phy = ndev->phydev;
	struct sockaddr *sa = addr;
	bool rx_on;

	if (!is_valid_ether_addr(sa->sa_data))
		return -EADDRNOTAVAIL;

	if (!netif_running(ndev) || !phy) {
		eth_hw_addr_set(ndev, sa->sa_data);
		heth_write_mac(p, ndev->dev_addr);
		return 0;
	}

	mutex_lock(&phy->lock);
	rx_on = p->ctrl & HETH_CTRL_RX_EN;
	if (rx_on) {
		heth_write_ctrl(p, 0, HETH_CTRL_RX_EN);
		if (heth_wait_stopped(p, HETH_ST_RX_RUNNING))
			netdev_warn(ndev, "RX did not stop\n");
	}
	eth_hw_addr_set(ndev, sa->sa_data);
	heth_write_mac(p, ndev->dev_addr);
	if (rx_on)
		heth_write_ctrl(p, HETH_CTRL_RX_EN, 0);
	mutex_unlock(&phy->lock);
	return 0;
}

/* Rings */

/* A ring register write clears TAIL and resets the ring, so TAIL is last. */
static void heth_ring_regs(struct heth_priv *p, u32 off, dma_addr_t base,
			   unsigned int order, unsigned int tail)
{
	heth_wr(p, off + HETH_RING_LO, lower_32_bits(base));
	heth_wr(p, off + HETH_RING_HI, upper_32_bits(base));
	heth_wr(p, off + HETH_RING_SIZE, order);
	heth_wr(p, off + HETH_RING_TAIL, tail);
}

static unsigned int heth_tx_free(struct heth_priv *p)
{
	return (p->tx_clean - p->tx_next - 1) & (p->tx_count - 1);
}

static void heth_tx_unmap(struct heth_priv *p, struct heth_tx_slot *s)
{
	if (!s->len)
		return;
	if (s->page)
		dma_unmap_page(p->dev, s->dma, s->len, DMA_TO_DEVICE);
	else
		dma_unmap_single(p->dev, s->dma, s->len, DMA_TO_DEVICE);
	s->len = 0;
}

/*
 * Drop every frame the hardware did not send. With first_err, the oldest
 * frame is the one that stopped the ring and counts as a TX error.
 */
static void heth_tx_drop_all(struct heth_priv *p, bool first_err)
{
	unsigned int n, i;

	if (!p->tx_slot)
		return;
	for (n = 0; n < p->tx_count; n++) {
		struct heth_tx_slot *s;

		i = (p->tx_clean + n) & (p->tx_count - 1);
		s = &p->tx_slot[i];
		heth_tx_unmap(p, s);
		if (!s->skb)
			continue;
		dev_kfree_skb_any(s->skb);
		s->skb = NULL;
		if (first_err) {
			p->ndev->stats.tx_errors++;
			first_err = false;
		} else {
			p->ndev->stats.tx_dropped++;
		}
	}
	if (p->tx_ring)
		memset(p->tx_ring, 0, p->tx_count * p->desc_size);
	p->tx_next = 0;
	p->tx_clean = 0;
}

static void heth_rx_arm(struct heth_priv *p, unsigned int i)
{
	struct heth_desc *d = heth_desc(p->rx_ring, p, i);
	dma_addr_t dma = p->rx_slot[i].dma;

	d->addr_lo = cpu_to_le32(lower_32_bits(dma));
	d->addr_hi = cpu_to_le32(upper_32_bits(dma));
	d->status = 0;
	dma_wmb();
	d->ctrl = cpu_to_le32(HETH_DESC_OWN |
			      FIELD_PREP(HETH_DESC_LEN, HETH_RX_BUF_SIZE));
}

static void heth_rx_arm_all(struct heth_priv *p)
{
	unsigned int i;

	for (i = 0; i < p->rx_count; i++)
		heth_rx_arm(p, i);
	p->rx_next = 0;
}

static void heth_free_rings(struct heth_priv *p)
{
	unsigned int i;

	if (p->rx_slot) {
		for (i = 0; i < p->rx_count; i++) {
			struct heth_rx_slot *s = &p->rx_slot[i];

			if (!s->buf)
				continue;
			dma_unmap_single(p->dev, s->dma, HETH_RX_BUF_SIZE,
					 DMA_FROM_DEVICE);
			kfree(s->buf);
		}
		kfree(p->rx_slot);
		p->rx_slot = NULL;
	}
	if (p->tx_slot) {
		heth_tx_drop_all(p, false);
		kfree(p->tx_slot);
		p->tx_slot = NULL;
	}
	if (p->rx_ring)
		dma_free_coherent(p->dev, p->rx_count * p->desc_size,
				  p->rx_ring, p->rx_ring_dma);
	if (p->tx_ring)
		dma_free_coherent(p->dev, p->tx_count * p->desc_size,
				  p->tx_ring, p->tx_ring_dma);
	p->rx_ring = NULL;
	p->tx_ring = NULL;
}

static int heth_alloc_rings(struct heth_priv *p)
{
	unsigned int i;

	p->tx_count = 1 << HETH_TX_ORDER;
	p->rx_count = 1 << HETH_RX_ORDER;
	p->tx_ring = dma_alloc_coherent(p->dev, p->tx_count * p->desc_size,
					&p->tx_ring_dma, GFP_KERNEL);
	p->rx_ring = dma_alloc_coherent(p->dev, p->rx_count * p->desc_size,
					&p->rx_ring_dma, GFP_KERNEL);
	p->tx_slot = kcalloc(p->tx_count, sizeof(*p->tx_slot), GFP_KERNEL);
	p->rx_slot = kcalloc(p->rx_count, sizeof(*p->rx_slot), GFP_KERNEL);
	if (!p->tx_ring || !p->rx_ring || !p->tx_slot || !p->rx_slot)
		goto err;

	for (i = 0; i < p->rx_count; i++) {
		struct heth_rx_slot *s = &p->rx_slot[i];

		s->buf = kmalloc(HETH_RX_BUF_SIZE, GFP_KERNEL);
		if (!s->buf)
			goto err;
		s->dma = dma_map_single(p->dev, s->buf, HETH_RX_BUF_SIZE,
					DMA_FROM_DEVICE);
		if (dma_mapping_error(p->dev, s->dma)) {
			kfree(s->buf);
			s->buf = NULL;
			goto err;
		}
	}
	p->tx_next = 0;
	p->tx_clean = 0;
	p->tx_err_seen = false;
	p->tx_frame_err = 0;
	return 0;
err:
	heth_free_rings(p);
	return -ENOMEM;
}

/* TX */

/* Give the MAC every descriptor up to tx_next. Call with tx_lock held. */
static void heth_tx_kick(struct heth_priv *p)
{
	/* The descriptors must be in memory before the MAC sees TAIL. */
	dma_wmb();
	heth_wr(p, HETH_TX_RING + HETH_RING_TAIL, p->tx_next);
}

/* A dropped skb must still kick descriptors that an earlier xmit_more held. */
static netdev_tx_t heth_tx_drop(struct heth_priv *p, struct sk_buff *skb)
{
	unsigned long flags;

	if (!netdev_xmit_more()) {
		spin_lock_irqsave(&p->tx_lock, flags);
		heth_tx_kick(p);
		spin_unlock_irqrestore(&p->tx_lock, flags);
	}
	dev_kfree_skb_any(skb);
	p->ndev->stats.tx_dropped++;
	return NETDEV_TX_OK;
}

static netdev_tx_t heth_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct heth_priv *p = netdev_priv(ndev);
	unsigned int nfrags = skb_shinfo(skb)->nr_frags;
	unsigned int head = skb_headlen(skb);
	unsigned int first, last, i, idx;
	unsigned long flags;
	bool kick;

	if (!skb->len || skb->len > HETH_MAX_FRAME)
		return heth_tx_drop(p, skb);

	spin_lock_irqsave(&p->tx_lock, flags);
	if (heth_tx_free(p) < nfrags + 1) {
		netif_stop_queue(ndev);
		spin_unlock_irqrestore(&p->tx_lock, flags);
		return NETDEV_TX_BUSY;
	}

	/* An empty head gets no descriptor. */
	first = p->tx_next;
	idx = first;
	last = nfrags;
	for (i = head ? 0 : 1; i <= nfrags; i++) {
		struct heth_tx_slot *s = &p->tx_slot[idx];
		struct heth_desc *d = heth_desc(p->tx_ring, p, idx);
		unsigned int len;
		dma_addr_t dma;
		u32 ctrl;

		if (i == 0) {
			len = head;
			dma = dma_map_single(p->dev, skb->data, len,
					     DMA_TO_DEVICE);
		} else {
			skb_frag_t *f = &skb_shinfo(skb)->frags[i - 1];

			len = skb_frag_size(f);
			dma =
			    skb_frag_dma_map(p->dev, f, 0, len, DMA_TO_DEVICE);
		}
		if (dma_mapping_error(p->dev, dma))
			goto unmap;
		s->dma = dma;
		s->len = len;
		s->page = i != 0;
		s->skb = NULL;

		ctrl = HETH_DESC_OWN | FIELD_PREP(HETH_DESC_LEN, len);
		if (idx == first)
			ctrl |= HETH_DESC_SOP;
		if (i == last) {
			ctrl |= HETH_DESC_EOP | HETH_DESC_IRQ;
			s->skb = skb;
		}
		d->addr_lo = cpu_to_le32(lower_32_bits(dma));
		d->addr_hi = cpu_to_le32(upper_32_bits(dma));
		d->status = 0;
		d->ctrl = cpu_to_le32(ctrl);
		idx = (idx + 1) & (p->tx_count - 1);
	}

	skb_tx_timestamp(skb);
	p->tx_next = idx;
	kick = __netdev_sent_queue(ndev, skb->len, netdev_xmit_more());
	if (heth_tx_free(p) < MAX_SKB_FRAGS + 1) {
		netif_stop_queue(ndev);
		kick = true;
	}
	if (kick)
		heth_tx_kick(p);
	spin_unlock_irqrestore(&p->tx_lock, flags);
	return NETDEV_TX_OK;

unmap:
	while (idx != first) {
		idx = (idx - 1) & (p->tx_count - 1);
		heth_tx_unmap(p, &p->tx_slot[idx]);
		heth_desc(p->tx_ring, p, idx)->ctrl = 0;
	}
	spin_unlock_irqrestore(&p->tx_lock, flags);
	return heth_tx_drop(p, skb);
}

/*
 * Error codes 1 to 3 stop the ring and come back through tx_ring_err.
 * Code 4 means that the TX clock was lost and the frame was dropped. A frame
 * that was already in the TX FIFO at the clock loss is done with no error,
 * but is also lost.
 */
static void heth_tx_clean(struct heth_priv *p)
{
	struct net_device *ndev = p->ndev;
	unsigned int pkts = 0, bytes = 0;
	unsigned long flags;

	spin_lock_irqsave(&p->tx_lock, flags);
	while (p->tx_clean != p->tx_next) {
		unsigned int i = p->tx_clean;
		struct heth_desc *d = heth_desc(p->tx_ring, p, i);
		struct heth_tx_slot *s = &p->tx_slot[i];
		u32 st;

		if (le32_to_cpu(READ_ONCE(d->ctrl)) & HETH_DESC_OWN)
			break;
		dma_rmb();
		st = le32_to_cpu(d->status);
		if (!p->tx_frame_err)
			p->tx_frame_err = FIELD_GET(HETH_TXS_ERR, st);
		heth_tx_unmap(p, s);
		if (s->skb) {
			if (p->tx_frame_err) {
				ndev->stats.tx_errors++;
				if (p->tx_frame_err != HETH_TX_ERR_CLK_LOST)
					p->tx_err_seen = true;
			} else {
				ndev->stats.tx_packets++;
				ndev->stats.tx_bytes += s->skb->len;
			}
			pkts++;
			bytes += s->skb->len;
			dev_consume_skb_any(s->skb);
			s->skb = NULL;
			p->tx_frame_err = 0;
		}
		p->tx_clean = (i + 1) & (p->tx_count - 1);
	}
	netdev_completed_queue(ndev, pkts, bytes);
	if (netif_queue_stopped(ndev) && heth_tx_free(p) >= MAX_SKB_FRAGS + 1)
		netif_wake_queue(ndev);
	spin_unlock_irqrestore(&p->tx_lock, flags);
}

/* RX */

static void heth_rx_error(struct net_device *ndev, unsigned int err)
{
	ndev->stats.rx_errors++;
	switch (err) {
	case HETH_RX_ERR_FCS:
		ndev->stats.rx_crc_errors++;
		break;
	case HETH_RX_ERR_RUNT:
	case HETH_RX_ERR_OVERSIZE:
		ndev->stats.rx_length_errors++;
		break;
	case HETH_RX_ERR_PHY:
		ndev->stats.rx_frame_errors++;
		break;
	default:
		break;
	}
}

static int heth_rx(struct heth_priv *p, int budget)
{
	struct net_device *ndev = p->ndev;
	int done = 0;

	while (done < budget) {
		unsigned int i = p->rx_next;
		struct heth_desc *d = heth_desc(p->rx_ring, p, i);
		struct heth_rx_slot *s = &p->rx_slot[i];
		unsigned int len, err;
		struct sk_buff *skb;
		u32 st;

		if (le32_to_cpu(READ_ONCE(d->ctrl)) & HETH_DESC_OWN)
			break;
		dma_rmb();
		st = le32_to_cpu(d->status);
		len = FIELD_GET(HETH_RXS_LEN, st);
		err = FIELD_GET(HETH_RXS_ERR, st);
		if (!err && ((st & (HETH_RXS_SOP | HETH_RXS_EOP)) !=
				 (HETH_RXS_SOP | HETH_RXS_EOP) ||
			     len < ETH_HLEN || len > HETH_RX_BUF_SIZE))
			err = HETH_RX_ERR_OVERSIZE;

		/*
		 * Bad frames come only with keep_bad, except err 3. Its buffer
		 * holds only a part of the frame, so it never goes up.
		 */
		if (err) {
			heth_rx_error(ndev, err);
			if (err == HETH_RX_ERR_OVERSIZE || len < ETH_HLEN ||
			    !(ndev->features & NETIF_F_RXALL))
				goto next;
		}

		dma_sync_single_for_cpu(p->dev, s->dma, len, DMA_FROM_DEVICE);
		skb = napi_alloc_skb(&p->napi, len);
		if (skb)
			skb_put_data(skb, s->buf, len);
		dma_sync_single_for_device(p->dev, s->dma, len,
					   DMA_FROM_DEVICE);
		if (!skb) {
			ndev->stats.rx_dropped++;
			goto next;
		}
		skb->protocol = eth_type_trans(skb, ndev);
		ndev->stats.rx_packets++;
		ndev->stats.rx_bytes += len;
		napi_gro_receive(&p->napi, skb);
	next:
		heth_rx_arm(p, i);
		p->rx_next = (i + 1) & (p->rx_count - 1);
		done++;
	}
	if (done) {
		/* The given window ends at the last slot the driver took. */
		dma_wmb();
		heth_wr(p, HETH_RX_RING + HETH_RING_TAIL,
			(p->rx_next - 1) & (p->rx_count - 1));
	}
	return done;
}

static int heth_poll(struct napi_struct *napi, int budget)
{
	struct heth_priv *p = container_of(napi, struct heth_priv, napi);
	u32 ints, st;
	int done;

	ints = heth_rd(p, HETH_INT_STATUS);
	heth_wr(p, HETH_INT_STATUS, ints);

	heth_tx_clean(p);
	done = heth_rx(p, budget);
	if (ints & HETH_INT_RX_MISSED)
		heth_update_counters(p);

	/*
	 * After a ring error the interrupts stay masked until the reset work
	 * starts the MAC again. A poll that used the whole budget must not
	 * complete, so NAPI polls again.
	 */
	st = heth_rd(p, HETH_STATUS);
	if (st & (HETH_ST_TX_RING_ERR | HETH_ST_RX_RING_ERR)) {
		if (net_ratelimit())
			netdev_err(p->ndev, "ring error, status %#x\n", st);
		schedule_work(&p->reset_work);
		if (done < budget)
			napi_complete_done(napi, done);
		return done;
	}

	if (done < budget && napi_complete_done(napi, done))
		heth_wr(p, HETH_INT_ENABLE, HETH_INT_ALL);
	return done;
}

static irqreturn_t heth_isr(int irq, void *data)
{
	struct heth_priv *p = data;

	if (!(heth_rd(p, HETH_INT_STATUS) & heth_rd(p, HETH_INT_ENABLE)))
		return IRQ_NONE;
	heth_wr(p, HETH_INT_ENABLE, 0);
	napi_schedule(&p->napi);
	return IRQ_HANDLED;
}

/* Bring up and down */

static u32 heth_speed_bits(int speed)
{
	switch (speed) {
	case SPEED_1000:
		return FIELD_PREP(HETH_CTRL_SPEED, HETH_SPEED_1000);
	case SPEED_10:
		return FIELD_PREP(HETH_CTRL_SPEED, HETH_SPEED_10);
	default:
		return FIELD_PREP(HETH_CTRL_SPEED, HETH_SPEED_100);
	}
}

/* Soft reset clears both rings, INT_STATUS and the ring errors. */
static int heth_soft_reset(struct heth_priv *p)
{
	u32 v;

	heth_write_ctrl(p, HETH_CTRL_SOFT_RESET,
			HETH_CTRL_TX_EN | HETH_CTRL_RX_EN);
	return readl_poll_timeout(p->base + HETH_CTRL, v,
				  !(v & HETH_CTRL_SOFT_RESET), 10,
				  HETH_STOP_TIMEOUT_US);
}

static void heth_hw_stop(struct heth_priv *p)
{
	heth_wr(p, HETH_INT_ENABLE, 0);
	heth_write_ctrl(p, 0, HETH_CTRL_TX_EN | HETH_CTRL_RX_EN);
	if (heth_wait_stopped(p, HETH_ST_TX_RUNNING | HETH_ST_RX_RUNNING))
		netdev_warn(p->ndev, "DMA did not stop\n");
	if (heth_soft_reset(p))
		netdev_warn(p->ndev, "soft reset timed out\n");
}

static void heth_hw_start(struct heth_priv *p)
{
	struct net_device *ndev = p->ndev;

	heth_wr(p, HETH_STATUS,
		HETH_ST_TX_RING_ERR | HETH_ST_RX_RING_ERR |
		    HETH_ST_TX_CLK_LOST | HETH_ST_RX_CLK_LOST);
	heth_wr(p, HETH_INT_STATUS, HETH_INT_ALL);
	heth_write_mac(p, ndev->dev_addr);
	heth_set_rx_mode(ndev);

	heth_rx_arm_all(p);
	dma_wmb();
	heth_ring_regs(p, HETH_TX_RING, p->tx_ring_dma, HETH_TX_ORDER, 0);
	heth_ring_regs(p, HETH_RX_RING, p->rx_ring_dma, HETH_RX_ORDER,
		       p->rx_count - 1);

	heth_wr(p, HETH_INT_ENABLE, HETH_INT_ALL);
	heth_write_ctrl(
	    p,
	    HETH_CTRL_TX_EN | HETH_CTRL_RX_EN | HETH_CTRL_FULL_DUPLEX |
		heth_speed_bits(p->speed) |
		((ndev->features & NETIF_F_RXALL) ? HETH_CTRL_KEEP_BAD : 0),
	    HETH_CTRL_SPEED | HETH_CTRL_KEEP_BAD);
}

static void heth_adjust_link(struct net_device *ndev)
{
	struct heth_priv *p = netdev_priv(ndev);
	struct phy_device *phy = ndev->phydev;
	u32 en;

	if (!phy->link || phy->speed == p->speed) {
		if (phy->link)
			heth_wr(p, HETH_STATUS,
				HETH_ST_TX_CLK_LOST | HETH_ST_RX_CLK_LOST);
		phy_print_status(phy);
		return;
	}

	/* Speed changes only with TX and RX stopped. */
	en = p->ctrl & (HETH_CTRL_TX_EN | HETH_CTRL_RX_EN);
	heth_write_ctrl(p, 0, HETH_CTRL_TX_EN | HETH_CTRL_RX_EN);
	if (heth_wait_stopped(p, HETH_ST_TX_RUNNING | HETH_ST_RX_RUNNING)) {
		netdev_err(ndev, "MAC did not stop for speed change\n");
		heth_write_ctrl(p, en, 0);
		schedule_work(&p->reset_work);
		return;
	}
	p->speed = phy->speed;
	heth_write_ctrl(p, heth_speed_bits(p->speed), HETH_CTRL_SPEED);
	/* The PHY clocks changed, so a clk_lost from the change is stale. */
	heth_wr(p, HETH_STATUS, HETH_ST_TX_CLK_LOST | HETH_ST_RX_CLK_LOST);
	heth_write_ctrl(p, en, 0);
	phy_print_status(phy);
}

static int heth_phy_connect(struct heth_priv *p)
{
	struct net_device *ndev = p->ndev;
	struct device_node *np;
	struct phy_device *phy;

	np = of_parse_phandle(p->dev->of_node, "phy-handle", 0);
	if (np) {
		phy =
		    of_phy_connect(ndev, np, heth_adjust_link, 0, p->phy_iface);
		of_node_put(np);
	} else {
		phy = phy_find_first(p->mii);
		if (phy && phy_connect_direct(ndev, phy, heth_adjust_link,
					      p->phy_iface))
			phy = NULL;
	}
	if (!phy) {
		netdev_err(ndev, "no PHY found\n");
		return -ENODEV;
	}

	if (!(p->caps & HETH_CAPS_GIGABIT))
		phy_set_max_speed(phy, SPEED_100);
	/* The MAC is full duplex only. */
	phy_remove_link_mode(phy, ETHTOOL_LINK_MODE_10baseT_Half_BIT);
	phy_remove_link_mode(phy, ETHTOOL_LINK_MODE_100baseT_Half_BIT);
	phy_remove_link_mode(phy, ETHTOOL_LINK_MODE_1000baseT_Half_BIT);
	phy_attached_info(phy);
	return 0;
}

static int heth_open(struct net_device *ndev)
{
	struct heth_priv *p = netdev_priv(ndev);
	int ret;

	ret = heth_alloc_rings(p);
	if (ret)
		return ret;

	ret = heth_phy_connect(p);
	if (ret)
		goto err_rings;

	heth_hw_stop(p);
	p->speed = SPEED_UNKNOWN;
	netdev_reset_queue(ndev);
	/* NAPI must be ready before the MAC enables its interrupts. */
	napi_enable(&p->napi);
	heth_hw_start(p);
	phy_start(ndev->phydev);
	netif_start_queue(ndev);
	return 0;

err_rings:
	heth_free_rings(p);
	return ret;
}

static int heth_stop(struct net_device *ndev)
{
	struct heth_priv *p = netdev_priv(ndev);

	netif_tx_disable(ndev);
	phy_stop(ndev->phydev);
	heth_wr(p, HETH_INT_ENABLE, 0);
	napi_disable(&p->napi);
	heth_hw_stop(p);
	heth_update_counters(p);
	phy_disconnect(ndev->phydev);
	heth_free_rings(p);
	return 0;
}

/* Reset both rings after a ring error, a stuck stop or a TX timeout. */
static void heth_reset_work(struct work_struct *work)
{
	struct heth_priv *p = container_of(work, struct heth_priv, reset_work);
	struct net_device *ndev = p->ndev;
	u32 st;

	rtnl_lock();
	if (!netif_running(ndev))
		goto out;

	/* adjust_link runs under the PHY lock and also writes CTRL. */
	mutex_lock(&ndev->phydev->lock);
	netif_tx_disable(ndev);
	heth_wr(p, HETH_INT_ENABLE, 0);
	napi_disable(&p->napi);
	st = heth_rd(p, HETH_STATUS);
	heth_hw_stop(p);
	heth_tx_clean(p);
	/* The frame that stopped the ring counts once. */
	heth_tx_drop_all(p, (st & HETH_ST_TX_RING_ERR) && !p->tx_err_seen);
	p->tx_err_seen = false;
	p->tx_frame_err = 0;
	netdev_reset_queue(ndev);
	if (ndev->phydev->link)
		p->speed = ndev->phydev->speed;
	napi_enable(&p->napi);
	heth_hw_start(p);
	mutex_unlock(&ndev->phydev->lock);
	netif_wake_queue(ndev);
out:
	rtnl_unlock();
}

static void heth_tx_timeout(struct net_device *ndev, unsigned int txqueue)
{
	struct heth_priv *p = netdev_priv(ndev);

	netdev_err(ndev, "TX timeout, head %u tail %u\n",
		   heth_rd(p, HETH_TX_RING + HETH_RING_HEAD), p->tx_next);
	ndev->stats.tx_errors++;
	schedule_work(&p->reset_work);
}

static int heth_set_features(struct net_device *ndev,
			     netdev_features_t features)
{
	struct heth_priv *p = netdev_priv(ndev);
	bool all = features & NETIF_F_RXALL;

	heth_write_ctrl(p, all ? HETH_CTRL_KEEP_BAD : 0,
			all ? 0 : HETH_CTRL_KEEP_BAD);
	return 0;
}

static void heth_get_stats64(struct net_device *ndev,
			     struct rtnl_link_stats64 *s)
{
	struct heth_priv *p = netdev_priv(ndev);

	netdev_stats_to_stats64(s, &ndev->stats);
	heth_update_counters(p);
	s->rx_missed_errors = p->cnt_total[HETH_CNT_RX_MISSED];
	s->rx_fifo_errors = p->cnt_total[HETH_CNT_RX_OVERFLOW];
	s->rx_errors += s->rx_missed_errors + s->rx_fifo_errors;
}

static const struct net_device_ops heth_netdev_ops = {
    .ndo_open = heth_open,
    .ndo_stop = heth_stop,
    .ndo_start_xmit = heth_start_xmit,
    .ndo_set_rx_mode = heth_set_rx_mode,
    .ndo_set_mac_address = heth_set_mac_address,
    .ndo_validate_addr = eth_validate_addr,
    .ndo_eth_ioctl = phy_do_ioctl_running,
    .ndo_tx_timeout = heth_tx_timeout,
    .ndo_set_features = heth_set_features,
    .ndo_get_stats64 = heth_get_stats64,
};

/* ethtool */

static void heth_get_drvinfo(struct net_device *ndev,
			     struct ethtool_drvinfo *info)
{
	strscpy(info->driver, KBUILD_MODNAME, sizeof(info->driver));
	strscpy(info->bus_info, dev_name(ndev->dev.parent),
		sizeof(info->bus_info));
}

static int heth_get_sset_count(struct net_device *ndev, int sset)
{
	struct heth_priv *p = netdev_priv(ndev);

	return sset == ETH_SS_STATS ? heth_num_counters(p) : -EOPNOTSUPP;
}

static void heth_get_strings(struct net_device *ndev, u32 sset, u8 *data)
{
	struct heth_priv *p = netdev_priv(ndev);
	unsigned int i;

	if (sset != ETH_SS_STATS)
		return;
	for (i = 0; i < heth_num_counters(p); i++)
		ethtool_puts(&data, heth_counter_names[i]);
}

static void heth_get_ethtool_stats(struct net_device *ndev,
				   struct ethtool_stats *stats, u64 *data)
{
	struct heth_priv *p = netdev_priv(ndev);
	unsigned long flags;
	unsigned int i;

	heth_update_counters(p);
	spin_lock_irqsave(&p->stats_lock, flags);
	for (i = 0; i < heth_num_counters(p); i++)
		data[i] = p->cnt_total[i];
	spin_unlock_irqrestore(&p->stats_lock, flags);
}

static const struct ethtool_ops heth_ethtool_ops = {
    .get_drvinfo = heth_get_drvinfo,
    .get_link = ethtool_op_get_link,
    .get_link_ksettings = phy_ethtool_get_link_ksettings,
    .set_link_ksettings = phy_ethtool_set_link_ksettings,
    .nway_reset = phy_ethtool_nway_reset,
    .get_sset_count = heth_get_sset_count,
    .get_strings = heth_get_strings,
    .get_ethtool_stats = heth_get_ethtool_stats,
};

/* Probe */

/*
 * The ring base drops the bits at or above the DMA address width, so the
 * width shows in the value that a write of all ones leaves.
 */
static unsigned int heth_dma_width(struct heth_priv *p)
{
	u32 lo, hi;

	heth_wr(p, HETH_TX_RING + HETH_RING_LO, ~0u);
	heth_wr(p, HETH_TX_RING + HETH_RING_HI, ~0u);
	lo = heth_rd(p, HETH_TX_RING + HETH_RING_LO);
	hi = heth_rd(p, HETH_TX_RING + HETH_RING_HI);
	heth_wr(p, HETH_TX_RING + HETH_RING_LO, 0);
	heth_wr(p, HETH_TX_RING + HETH_RING_HI, 0);
	return hi ? 32 + fls(hi) : fls(lo);
}

static void heth_cancel_work(void *data)
{
	struct heth_priv *p = data;

	cancel_work_sync(&p->reset_work);
}

static int heth_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct net_device *ndev;
	struct heth_priv *p;
	struct clk *clk;
	unsigned int width;
	u32 id;
	int ret;

	ndev = devm_alloc_etherdev(dev, sizeof(*p));
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, dev);
	platform_set_drvdata(pdev, ndev);

	p = netdev_priv(ndev);
	p->dev = dev;
	p->ndev = ndev;
	spin_lock_init(&p->ctrl_lock);
	spin_lock_init(&p->tx_lock);
	spin_lock_init(&p->stats_lock);
	INIT_WORK(&p->reset_work, heth_reset_work);

	p->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(p->base))
		return PTR_ERR(p->base);

	id = heth_rd(p, HETH_ID);
	if (id != HETH_ID_VALUE)
		return dev_err_probe(dev, -ENODEV, "bad ID %#x\n", id);
	p->caps = heth_rd(p, HETH_HW_CAPS);
	p->desc_size = 1 << FIELD_GET(HETH_CAPS_DESC_LOG2, p->caps);
	if (p->desc_size < sizeof(struct heth_desc))
		return dev_err_probe(dev, -ENODEV, "bad HW_CAPS %#x\n",
				     p->caps);

	/* Stop the MAC that a boot loader can leave running. */
	p->ctrl = 0;
	heth_wr(p, HETH_INT_ENABLE, 0);
	heth_wr(p, HETH_CTRL, 0);
	if (heth_wait_stopped(p, HETH_ST_TX_RUNNING | HETH_ST_RX_RUNNING) ||
	    heth_soft_reset(p))
		dev_warn(dev, "MAC did not stop\n");

	width = heth_dma_width(p);
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(width));
	if (ret)
		return dev_err_probe(dev, ret, "no %u-bit DMA\n", width);

	clk = devm_clk_get_optional_enabled(dev, NULL);
	if (IS_ERR(clk))
		return PTR_ERR(clk);

	ret = of_get_phy_mode(dev->of_node, &p->phy_iface);
	if (ret) {
		if (p->caps & HETH_CAPS_RGMII)
			p->phy_iface = PHY_INTERFACE_MODE_RGMII;
		else if (p->caps & HETH_CAPS_RMII)
			p->phy_iface = PHY_INTERFACE_MODE_RMII;
		else
			p->phy_iface = PHY_INTERFACE_MODE_MII;
	}

	ret = heth_mdio_init(p, clk);
	if (ret)
		return dev_err_probe(dev, ret, "MDIO bus\n");

	p->irq = platform_get_irq(pdev, 0);
	if (p->irq < 0)
		return p->irq;
	ret = devm_request_irq(dev, p->irq, heth_isr, 0, dev_name(dev), p);
	if (ret)
		return ret;

	ret = device_get_ethdev_address(dev, ndev);
	if (ret)
		eth_hw_addr_random(ndev);

	ndev->netdev_ops = &heth_netdev_ops;
	ndev->ethtool_ops = &heth_ethtool_ops;
	ndev->watchdog_timeo = 5 * HZ;
	ndev->hw_features = NETIF_F_SG | NETIF_F_RXALL;
	ndev->features = NETIF_F_SG;
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = ETH_DATA_LEN;
	netif_napi_add(ndev, &p->napi, heth_poll);

	ret = devm_add_action_or_reset(dev, heth_cancel_work, p);
	if (ret)
		return ret;
	return devm_register_netdev(dev, ndev);
}

static const struct of_device_id heth_of_match[] = {
    {.compatible = "harbor,ethernet-1"}, {}};
MODULE_DEVICE_TABLE(of, heth_of_match);

static struct platform_driver heth_driver = {
    .probe = heth_probe,
    .driver =
	{
	    .name = "harbor-ethernet",
	    .of_match_table = heth_of_match,
	},
};
module_platform_driver(heth_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor Ethernet MAC driver");
MODULE_LICENSE("GPL");
