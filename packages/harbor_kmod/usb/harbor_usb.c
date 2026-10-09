// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor USB full-speed device controller driver (gadget mode)
 *
 * Each register sits in its own 8-byte slot, byte offsets from the base
 * given below. Endpoint n (n = 0..num_ep-1) has its own block at
 * 0x200 + n*0x40. See the HARBOR_USB_EP_* offsets below for its layout.
 *
 * A SETUP packet always lands on a type-control endpoint, and clears
 * that endpoint's stall bits the moment it is held. Clearing a stall on
 * a non-control endpoint resets that direction's data toggle in
 * hardware, so this driver never writes the toggle-reset bits on a
 * clear. EP_CFG's action bits (stall set/clear, toggle reset) act on a
 * write of 1 and do nothing on 0, but every write also stores the
 * enable and type bits as given, with no read-modify-write on the
 * hardware side. So every write this driver makes to EP_CFG must carry
 * the endpoint's current enable and type, or it turns the endpoint into
 * type control.
 *
 * After popping OUT_DATA this driver re-reads OUT_STAT before trusting
 * the bytes, because a SETUP can preempt an unread OUT and change the
 * tag or drop ready to 0.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/usb/gadget.h>
#include <linux/usb/ch9.h>
#include <linux/usb/composite.h>

#include <linux/io.h>
#include <linux/of.h>
#include <linux/interrupt.h>
#include <linux/spinlock.h>
#include <linux/slab.h>
#include <linux/minmax.h>

#define HARBOR_USB_CTRL	      0x000
#define HARBOR_USB_STATUS     0x008
#define HARBOR_USB_ADDR	      0x010
#define HARBOR_USB_INT_STATUS 0x018
#define HARBOR_USB_INT_ENABLE 0x020
#define HARBOR_USB_FRAME      0x028

#define HARBOR_USB_CTRL_ENABLE	BIT(0)
#define HARBOR_USB_CTRL_CONNECT BIT(1)

#define HARBOR_USB_INT_RESET  BIT(0)
#define HARBOR_USB_INT_SOF    BIT(1)
/* The controller's USB side was reset on its own. Hardware drops the
 * pullup for a short time, so the host sees a detach.
 */
#define HARBOR_USB_INT_LOCAL_RESET BIT(2)
#define HARBOR_USB_INT_OUT(n) BIT(8 + (n))
#define HARBOR_USB_INT_IN(n)  BIT(16 + (n))

#define HARBOR_USB_EP_BASE   0x200
#define HARBOR_USB_EP_STRIDE 0x40

#define HARBOR_USB_EP_CFG	0x00
#define HARBOR_USB_EP_OUT_STAT	0x08
#define HARBOR_USB_EP_OUT_DATA	0x10
#define HARBOR_USB_EP_OUT_ACK	0x18
#define HARBOR_USB_EP_IN_DATA	0x20
#define HARBOR_USB_EP_IN_COMMIT 0x28
#define HARBOR_USB_EP_IN_STAT	0x30
#define HARBOR_USB_EP_IN_FLUSH	0x38

#define HARBOR_USB_EP_CFG_ENABLE     BIT(0)
#define HARBOR_USB_EP_CFG_TYPE_SHIFT 1
#define HARBOR_USB_EP_CFG_STALL_OUT  BIT(3)
#define HARBOR_USB_EP_CFG_STALL_IN   BIT(4)
#define HARBOR_USB_EP_CFG_TOGGLE_OUT BIT(5)
#define HARBOR_USB_EP_CFG_TOGGLE_IN  BIT(6)
#define HARBOR_USB_EP_CFG_CLEAR_OUT  BIT(7)
#define HARBOR_USB_EP_CFG_CLEAR_IN   BIT(8)

#define HARBOR_USB_OUT_STAT_READY     BIT(0)
#define HARBOR_USB_OUT_STAT_SETUP     BIT(1)
#define HARBOR_USB_OUT_STAT_TAG_MASK  GENMASK(7, 4)
#define HARBOR_USB_OUT_STAT_LEN_SHIFT 8
#define HARBOR_USB_OUT_STAT_LEN_MASK  GENMASK(15, 8)

#define HARBOR_USB_IN_STAT_FREE  BIT(0)
#define HARBOR_USB_IN_STAT_ACKED BIT(1)

#define HARBOR_USB_TYPE_CONTROL 0
#define HARBOR_USB_TYPE_BULK	2
#define HARBOR_USB_TYPE_INT	3

#define HARBOR_USB_MAX_PACKET 64
#define HARBOR_USB_MAX_EP     8

struct harbor_usb_req {
	struct usb_request req;
	struct list_head queue;
};

struct harbor_usb_ep {
	struct usb_ep ep;
	struct harbor_usb *hu;
	struct list_head queue;
	u8 idx;
	bool is_in;		/* non-zero endpoints only. EP0 uses ep0_dir_in */
	bool halted;
	bool wedged;		/* halted, and a host CLEAR_FEATURE(HALT) must not clear it */
	bool in_armed;		 /* IN direction: a packet is committed, no IN-done yet */
	bool in_last_committed; /* IN direction: this commit finishes the request */
	unsigned int in_last_chunk; /* bytes in the armed commit, unconfirmed until IN-done */
};

struct harbor_usb {
	void __iomem *base;
	struct usb_gadget gadget;
	struct usb_gadget_driver *driver;
	struct device *dev;
	spinlock_t lock;
	int irq;
	unsigned int num_ep;

	struct harbor_usb_ep ep0;
	struct harbor_usb_ep *ep_in;  /* index 1..num_ep-1 */
	struct harbor_usb_ep *ep_out; /* index 1..num_ep-1 */
	unsigned int *ep_enable_count; /* shared per hw index, IN+OUT together */
	u8 *ep_type;			/* last type applied to a hw index */

	u8 setup_buf[8];
	bool ep0_dir_in;
	bool ep0_internal_status; /* a status ZLP this driver armed itself */
	bool ep0_delayed_status;  /* setup() returned USB_GADGET_DELAYED_STATUS */
	bool addr_pending;
	u8 pending_addr;
};

static inline struct harbor_usb_req *to_harbor_req(struct usb_request *req)
{
	return container_of(req, struct harbor_usb_req, req);
}

static inline struct harbor_usb_ep *to_harbor_ep(struct usb_ep *ep)
{
	return container_of(ep, struct harbor_usb_ep, ep);
}

static inline struct harbor_usb *gadget_to_harbor(struct usb_gadget *g)
{
	return container_of(g, struct harbor_usb, gadget);
}

static inline void __iomem *harbor_ep_base(struct harbor_usb *hu,
					   unsigned int idx)
{
	return hu->base + HARBOR_USB_EP_BASE + idx * HARBOR_USB_EP_STRIDE;
}

/* EP0's direction changes per control transfer. The others are fixed. */
static inline bool harbor_ep_is_in(struct harbor_usb_ep *ep)
{
	return ep->idx == 0 ? ep->hu->ep0_dir_in : ep->is_in;
}

static void harbor_usb_in_push(struct harbor_usb *hu, struct harbor_usb_ep *ep);
static void harbor_usb_in_kick(struct harbor_usb *hu, struct harbor_usb_ep *ep);
static void harbor_usb_out_advance(struct harbor_usb *hu,
				   struct harbor_usb_ep *ep);
static void harbor_usb_ep0_status(struct harbor_usb *hu);
static void harbor_usb_ep_halt(struct harbor_usb_ep *ep, bool halt);

/* Writes EP_CFG with this driver's remembered enable and type for the
 * index, plus one-shot action bits (stall set/clear, toggle reset).
 * The hardware stores enable and type on every write, so every write
 * must carry them to keep the endpoint's type.
 */
static void harbor_usb_ep_cfg_write(struct harbor_usb *hu, unsigned int idx,
				    u32 extra)
{
	u32 cfg = extra | (hu->ep_type[idx] << HARBOR_USB_EP_CFG_TYPE_SHIFT);

	if (hu->ep_enable_count[idx])
		cfg |= HARBOR_USB_EP_CFG_ENABLE;
	writel(cfg, harbor_ep_base(hu, idx) + HARBOR_USB_EP_CFG);
}

/* Drops an armed IN packet and its pushed bytes for a request being
 * dequeued or disabled away. The write blocks until the FIFO drains
 * and any in-flight transaction ends, then acks. Once acked, IN-done
 * for this endpoint cannot land later, so the stale packet is never
 * credited to whatever is queued next.
 */
static void harbor_usb_in_flush_armed(struct harbor_usb *hu,
				      struct harbor_usb_ep *ep)
{
	writel(1, harbor_ep_base(hu, ep->idx) + HARBOR_USB_EP_IN_FLUSH);
	ep->in_armed = false;
	ep->in_last_committed = false;
}

/* Fails every queued request on one endpoint. Called with hu->lock held.
 * flush is false from a bus reset, which has already discarded the
 * packet in hardware and made the IN_FLUSH write redundant.
 */
static void harbor_usb_nuke(struct harbor_usb *hu, struct harbor_usb_ep *ep,
			    int status, bool flush)
{
	struct harbor_usb_req *req;

	if (flush && !list_empty(&ep->queue) && harbor_ep_is_in(ep) && ep->in_armed)
		harbor_usb_in_flush_armed(hu, ep);

	while (!list_empty(&ep->queue)) {
		req = list_first_entry(&ep->queue, struct harbor_usb_req, queue);
		list_del_init(&req->queue);
		req->req.status = status;
		spin_unlock(&hu->lock);
		usb_gadget_giveback_request(&ep->ep, &req->req);
		spin_lock(&hu->lock);
	}
}

/* Completes the head request and starts the next one, if any. */
static void harbor_usb_done(struct harbor_usb_ep *ep, struct usb_request *_req,
			    int status)
{
	struct harbor_usb_req *req = to_harbor_req(_req);
	struct harbor_usb *hu = ep->hu;
	bool was_in = harbor_ep_is_in(ep);
	bool ep0_out_done = ep->idx == 0 && !was_in && status == 0;

	list_del_init(&req->queue);
	_req->status = status;

	/* The status stage of a control write is IN. Flip this before the
	 * completion callback below so a function that queues its own
	 * zero-length status request from that callback sends it the
	 * right way round.
	 */
	if (ep0_out_done)
		hu->ep0_dir_in = true;

	spin_unlock(&hu->lock);
	usb_gadget_giveback_request(&ep->ep, _req);
	spin_lock(&hu->lock);

	if (ep0_out_done) {
		/* Send the status ZLP ourselves, unless the function already
		 * queued it from the completion callback just above (ep0's
		 * queue would be non-empty again), or setup() asked to send
		 * it itself later with USB_GADGET_DELAYED_STATUS.
		 */
		if (list_empty(&ep->queue) && !hu->ep0_delayed_status)
			harbor_usb_ep0_status(hu);
		return;
	}

	if (was_in)
		harbor_usb_in_kick(hu, ep);
	else
		harbor_usb_out_advance(hu, ep);
}

/* Pushes the next chunk (<= maxpacket) of the head IN request and commits
 * it. in_last_committed tells the next IN-done interrupt whether this was
 * the request's last packet. in_last_chunk records how many of req.actual's
 * bytes this commit added, unconfirmed until that IN-done lands.
 */
static void harbor_usb_in_push(struct harbor_usb *hu, struct harbor_usb_ep *ep)
{
	void __iomem *base = harbor_ep_base(hu, ep->idx);
	struct harbor_usb_req *req;
	const u8 *buf;
	unsigned int remaining, chunk, i;
	bool more, zlp;

	if (list_empty(&ep->queue))
		return;
	req = list_first_entry(&ep->queue, struct harbor_usb_req, queue);

	remaining = req->req.length - req->req.actual;
	chunk = min_t(unsigned int, remaining, ep->ep.maxpacket);
	buf = req->req.buf;
	for (i = 0; i < chunk; i++)
		writel(buf[req->req.actual + i], base + HARBOR_USB_EP_IN_DATA);
	writel(1, base + HARBOR_USB_EP_IN_COMMIT);
	req->req.actual += chunk;
	ep->in_last_chunk = chunk;

	more = remaining > chunk;
	zlp = !more && req->req.zero && chunk == ep->ep.maxpacket && chunk != 0;
	ep->in_armed = true;
	ep->in_last_committed = !more && !zlp;
}

/* Starts an IN push only when the endpoint is idle: nothing already
 * armed. This is the only path that starts a push, so a request queued
 * while something else is in flight waits for that packet's IN-done
 * instead of racing it onto the bus.
 */
static void harbor_usb_in_kick(struct harbor_usb *hu, struct harbor_usb_ep *ep)
{
	if (ep->in_armed)
		return;
	harbor_usb_in_push(hu, ep);
}

/* Pops a held OUT packet into the head request. Re-reads OUT_STAT before
 * trusting the bytes, since a SETUP can preempt the read. A late OUT_ACK
 * for the old tag is then a no-op in hardware.
 */
static void harbor_usb_out_advance(struct harbor_usb *hu,
				   struct harbor_usb_ep *ep)
{
	void __iomem *base = harbor_ep_base(hu, ep->idx);
	struct harbor_usb_req *req;
	u32 stat0, stat1, len, full_len, room, i;

	if (list_empty(&ep->queue))
		return;

	stat0 = readl(base + HARBOR_USB_EP_OUT_STAT);
	if (!(stat0 & HARBOR_USB_OUT_STAT_READY))
		return;

	req = list_first_entry(&ep->queue, struct harbor_usb_req, queue);
	full_len = (stat0 & HARBOR_USB_OUT_STAT_LEN_MASK) >> HARBOR_USB_OUT_STAT_LEN_SHIFT;
	room = req->req.length - req->req.actual;
	len = min(full_len, room);

	for (i = 0; i < len; i++)
		((u8 *)req->req.buf)[req->req.actual + i] =
		    (u8)readl(base + HARBOR_USB_EP_OUT_DATA);

	stat1 = readl(base + HARBOR_USB_EP_OUT_STAT);
	writel(stat0, base + HARBOR_USB_EP_OUT_ACK);

	if (!(stat1 & HARBOR_USB_OUT_STAT_READY) ||
	    (stat1 & HARBOR_USB_OUT_STAT_TAG_MASK) !=
		(stat0 & HARBOR_USB_OUT_STAT_TAG_MASK))
		return;

	req->req.actual += len;
	if (full_len > room) {
		/* The wire-level ACK already went out above. Stall ep0 so the
		 * host learns the request failed instead of running on into
		 * a status stage nothing is waiting for.
		 */
		if (ep->idx == 0)
			harbor_usb_ep_halt(ep, true);
		harbor_usb_done(ep, &req->req, -EOVERFLOW);
		return;
	}
	if (len < ep->ep.maxpacket || req->req.actual >= req->req.length)
		harbor_usb_done(ep, &req->req, 0);
}

/* Pushes an internal EP0 IN packet that the gadget driver never sees,
 * such as a SET_ADDRESS or control-write status ZLP, or an endpoint
 * GET_STATUS reply. The next IN-done consumes it with no request
 * completion.
 */
static void harbor_usb_ep0_in_internal(struct harbor_usb *hu, const u8 *data,
				       unsigned int len)
{
	void __iomem *base = harbor_ep_base(hu, 0);
	unsigned int i;

	for (i = 0; i < len; i++)
		writel(data[i], base + HARBOR_USB_EP_IN_DATA);
	hu->ep0_internal_status = true;
	hu->ep0.in_armed = true;
	writel(1, base + HARBOR_USB_EP_IN_COMMIT);
}

static void harbor_usb_ep0_status(struct harbor_usb *hu)
{
	harbor_usb_ep0_in_internal(hu, NULL, 0);
}

/* Applies a stall or stall-clear straight to the hardware, bypassing the
 * queued-request check in the ep_ops.set_halt path. Used for a host
 * SET_FEATURE/CLEAR_FEATURE(ENDPOINT_HALT), which must take effect
 * regardless of what the endpoint's own queue holds.
 */
static void harbor_usb_ep_halt(struct harbor_usb_ep *ep, bool halt)
{
	struct harbor_usb *hu = ep->hu;
	u32 cfg;

	if (ep->idx == 0)
		cfg = halt ? (HARBOR_USB_EP_CFG_STALL_OUT | HARBOR_USB_EP_CFG_STALL_IN)
			   : (HARBOR_USB_EP_CFG_CLEAR_OUT | HARBOR_USB_EP_CFG_CLEAR_IN);
	else if (harbor_ep_is_in(ep))
		cfg = halt ? HARBOR_USB_EP_CFG_STALL_IN : HARBOR_USB_EP_CFG_CLEAR_IN;
	else
		cfg = halt ? HARBOR_USB_EP_CFG_STALL_OUT : HARBOR_USB_EP_CFG_CLEAR_OUT;
	harbor_usb_ep_cfg_write(hu, ep->idx, cfg);
	ep->halted = halt;
}

/* GET_STATUS and CLEAR_FEATURE(DEVICE_REMOTE_WAKEUP) for the device
 * recipient are not handled by the gadget core, so the UDC answers
 * them itself. This hardware has no resume signaling, so remote
 * wakeup always reports disabled, and SET_FEATURE(DEVICE_REMOTE_WAKEUP)
 * stalls (USB 2.0 9.4.9). Returns true if this call owned the request.
 */
static bool harbor_usb_dev_std_request(struct harbor_usb *hu,
					const struct usb_ctrlrequest *ctrl)
{
	u8 data[2];
	unsigned int len;

	if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_STANDARD ||
	    (ctrl->bRequestType & USB_RECIP_MASK) != USB_RECIP_DEVICE)
		return false;

	switch (ctrl->bRequest) {
	case USB_REQ_GET_STATUS:
		data[0] = hu->gadget.is_selfpowered << USB_DEVICE_SELF_POWERED;
		data[1] = 0;
		len = min_t(unsigned int, le16_to_cpu(ctrl->wLength), sizeof(data));
		harbor_usb_ep0_in_internal(hu, data, len);
		return true;
	case USB_REQ_CLEAR_FEATURE:
		if (le16_to_cpu(ctrl->wValue) != USB_DEVICE_REMOTE_WAKEUP)
			return false;
		harbor_usb_ep0_status(hu);
		return true;
	case USB_REQ_SET_FEATURE:
		if (le16_to_cpu(ctrl->wValue) != USB_DEVICE_REMOTE_WAKEUP)
			return false;
		harbor_usb_ep_halt(&hu->ep0, true);
		return true;
	default:
		return false;
	}
}

/* Interface-recipient GET_STATUS has no interface feature to report, so
 * this always answers two zero bytes, matching dwc2/dwc3. There is no
 * interface-recipient SET/CLEAR_FEATURE in USB 2.0 full speed.
 */
static bool harbor_usb_iface_std_request(struct harbor_usb *hu,
					  const struct usb_ctrlrequest *ctrl)
{
	static const u8 data[2] = { 0, 0 };
	unsigned int len;

	if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_STANDARD ||
	    (ctrl->bRequestType & USB_RECIP_MASK) != USB_RECIP_INTERFACE ||
	    ctrl->bRequest != USB_REQ_GET_STATUS)
		return false;

	len = min_t(unsigned int, le16_to_cpu(ctrl->wLength), sizeof(data));
	harbor_usb_ep0_in_internal(hu, data, len);
	return true;
}

/* GET_STATUS and SET/CLEAR_FEATURE(ENDPOINT_HALT) for the endpoint
 * recipient are not handled by the gadget core. A UDC answers them
 * itself. A disabled endpoint stalls instead of answering (USB 2.0
 * 9.4.5). Returns true if this call owned the request.
 */
static bool harbor_usb_ep0_std_request(struct harbor_usb *hu,
					const struct usb_ctrlrequest *ctrl)
{
	struct harbor_usb_ep *ep;
	unsigned int idx = le16_to_cpu(ctrl->wIndex) & USB_ENDPOINT_NUMBER_MASK;
	bool in = le16_to_cpu(ctrl->wIndex) & USB_DIR_IN;
	u8 data[2];
	unsigned int len;

	if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_STANDARD ||
	    (ctrl->bRequestType & USB_RECIP_MASK) != USB_RECIP_ENDPOINT ||
	    idx >= hu->num_ep)
		return false;

	ep = idx == 0 ? &hu->ep0 : (in ? &hu->ep_in[idx] : &hu->ep_out[idx]);

	if (idx != 0 && !ep->ep.desc) {
		harbor_usb_ep_halt(&hu->ep0, true);
		return true;
	}

	switch (ctrl->bRequest) {
	case USB_REQ_GET_STATUS:
		data[0] = ep->halted ? 1 : 0;
		data[1] = 0;
		len = min_t(unsigned int, le16_to_cpu(ctrl->wLength), sizeof(data));
		harbor_usb_ep0_in_internal(hu, data, len);
		return true;
	case USB_REQ_SET_FEATURE:
	case USB_REQ_CLEAR_FEATURE:
		if (le16_to_cpu(ctrl->wValue) != USB_ENDPOINT_HALT || idx == 0)
			return false;
		if (ctrl->bRequest == USB_REQ_SET_FEATURE)
			harbor_usb_ep_halt(ep, true);
		else if (!ep->wedged)
			harbor_usb_ep_halt(ep, false);
		harbor_usb_ep0_status(hu);
		return true;
	default:
		return false;
	}
}

static void harbor_usb_handle_setup(struct harbor_usb *hu,
				    struct harbor_usb_ep *ep, u32 stat0)
{
	void __iomem *base = harbor_ep_base(hu, ep->idx);
	struct usb_gadget_driver *driver;
	struct usb_ctrlrequest ctrl;
	u32 stat1;
	int i, ret;

	for (i = 0; i < 8; i++)
		hu->setup_buf[i] = (u8)readl(base + HARBOR_USB_EP_OUT_DATA);

	stat1 = readl(base + HARBOR_USB_EP_OUT_STAT);
	writel(stat0, base + HARBOR_USB_EP_OUT_ACK);
	if (!(stat1 & HARBOR_USB_OUT_STAT_READY) ||
	    (stat1 & HARBOR_USB_OUT_STAT_TAG_MASK) !=
		(stat0 & HARBOR_USB_OUT_STAT_TAG_MASK))
		return; /* a second SETUP preempted this one */

	memcpy(&ctrl, hu->setup_buf, sizeof(ctrl));

	/* The hardware already dropped any armed EP0 IN packet when this
	 * SETUP was held. Drop the matching software state so a stale
	 * request or a lost status stage cannot be mistaken for this one.
	 */
	harbor_usb_nuke(hu, &hu->ep0, -ECONNRESET, false);
	hu->ep0.in_armed = false;
	hu->ep0.in_last_committed = false;
	hu->ep0.halted = false;
	hu->ep0_internal_status = false;
	hu->ep0_delayed_status = false;
	hu->addr_pending = false;

	hu->ep0_dir_in = ctrl.wLength == 0 || (ctrl.bRequestType & USB_DIR_IN);

	/* SET_ADDRESS never reaches the gadget driver: the address itself is
	 * written only once the status stage IN completes, below.
	 */
	if ((ctrl.bRequestType & USB_TYPE_MASK) == USB_TYPE_STANDARD &&
	    (ctrl.bRequestType & USB_RECIP_MASK) == USB_RECIP_DEVICE &&
	    ctrl.bRequest == USB_REQ_SET_ADDRESS) {
		hu->pending_addr = le16_to_cpu(ctrl.wValue) & 0x7f;
		hu->addr_pending = true;
		harbor_usb_ep0_status(hu);
		return;
	}

	if (harbor_usb_dev_std_request(hu, &ctrl))
		return;

	if (harbor_usb_iface_std_request(hu, &ctrl))
		return;

	if (harbor_usb_ep0_std_request(hu, &ctrl))
		return;

	driver = hu->driver;
	if (!driver)
		return;

	spin_unlock(&hu->lock);
	ret = driver->setup(&hu->gadget, &ctrl);
	spin_lock(&hu->lock);

	if (ret == USB_GADGET_DELAYED_STATUS) {
		/* The function will send the status stage itself, later,
		 * with its own usb_ep_queue(ep0, ...). Arm nothing now.
		 */
		hu->ep0_delayed_status = true;
	} else if (ret < 0) {
		harbor_usb_ep_halt(&hu->ep0, true);
	}
}

static void harbor_usb_handle_out_ready(struct harbor_usb *hu,
					struct harbor_usb_ep *ep)
{
	void __iomem *base = harbor_ep_base(hu, ep->idx);
	u32 stat0 = readl(base + HARBOR_USB_EP_OUT_STAT);

	if (!(stat0 & HARBOR_USB_OUT_STAT_READY))
		return;
	if (stat0 & HARBOR_USB_OUT_STAT_SETUP) {
		harbor_usb_handle_setup(hu, ep, stat0);
		return;
	}
	if (ep->idx == 0 && hu->ep0_dir_in) {
		/* The status-stage ZLP after a control read. A lost host
		 * ACK on the last IN data packet can leave it still
		 * committed here with no IN-done ever landing. The status
		 * OUT arriving means the host did get the data, so finish
		 * the request now instead of waiting for an IN-done that
		 * will not come.
		 */
		if (ep->in_last_committed && !list_empty(&ep->queue)) {
			struct harbor_usb_req *req =
			    list_first_entry(&ep->queue, struct harbor_usb_req, queue);

			ep->in_armed = false;
			ep->in_last_committed = false;
			harbor_usb_done(ep, &req->req, 0);
		}
		return;
	}
	harbor_usb_out_advance(hu, ep);
}

static void harbor_usb_handle_in_done(struct harbor_usb *hu,
				      struct harbor_usb_ep *ep)
{
	void __iomem *base = harbor_ep_base(hu, ep->idx);
	struct harbor_usb_req *req;
	u32 stat;

	/* A flush or a SETUP nuke can clear the hardware IN-done between the
	 * INT_STATUS snapshot and here. Trust IN_STAT instead of the
	 * snapshot: it reads 0 once a flush applies, and cannot read 1
	 * again until a later real commit is acked.
	 */
	stat = readl(base + HARBOR_USB_EP_IN_STAT);
	if (!(stat & HARBOR_USB_IN_STAT_ACKED))
		return;

	ep->in_armed = false;

	if (ep->idx == 0 && hu->ep0_internal_status) {
		hu->ep0_internal_status = false;
		if (hu->addr_pending) {
			writel(hu->pending_addr, hu->base + HARBOR_USB_ADDR);
			hu->addr_pending = false;
			usb_gadget_set_state(&hu->gadget,
					     hu->pending_addr ? USB_STATE_ADDRESS :
								 USB_STATE_DEFAULT);
		}
		return;
	}

	if (list_empty(&ep->queue))
		return;

	req = list_first_entry(&ep->queue, struct harbor_usb_req, queue);
	if (ep->in_last_committed) {
		ep->in_last_committed = false;
		harbor_usb_done(ep, &req->req, 0);
		return;
	}
	harbor_usb_in_kick(hu, ep);
}

/* Fails every queued request and forgets endpoint state. Hardware has
 * already cleared stall bits and FIFOs.
 */
static void harbor_usb_reset_eps(struct harbor_usb *hu)
{
	unsigned int i;

	harbor_usb_nuke(hu, &hu->ep0, -ESHUTDOWN, false);
	hu->ep0.in_armed = false;
	hu->ep0.in_last_committed = false;
	hu->ep0.halted = false;
	hu->ep0.wedged = false;
	for (i = 1; i < hu->num_ep; i++) {
		harbor_usb_nuke(hu, &hu->ep_in[i], -ESHUTDOWN, false);
		harbor_usb_nuke(hu, &hu->ep_out[i], -ESHUTDOWN, false);
		hu->ep_in[i].in_armed = false;
		hu->ep_in[i].in_last_committed = false;
		hu->ep_in[i].halted = false;
		hu->ep_in[i].wedged = false;
		hu->ep_out[i].halted = false;
		hu->ep_out[i].wedged = false;
	}
	hu->addr_pending = false;
	hu->ep0_internal_status = false;
	hu->ep0_dir_in = true;
}

static void harbor_usb_handle_bus_reset(struct harbor_usb *hu)
{
	struct usb_gadget_driver *driver = hu->driver;

	harbor_usb_reset_eps(hu);
	hu->gadget.speed = USB_SPEED_FULL;

	if (!driver)
		return;

	spin_unlock(&hu->lock);
	usb_gadget_udc_reset(&hu->gadget, driver);
	spin_lock(&hu->lock);
}

/* The host sees a detach, then a new attach, and enumerates again. That
 * enumeration starts with a host bus reset, which arrives as its own
 * HARBOR_USB_INT_RESET.
 */
static void harbor_usb_handle_local_reset(struct harbor_usb *hu)
{
	struct usb_gadget_driver *driver = hu->driver;

	harbor_usb_reset_eps(hu);
	hu->gadget.speed = USB_SPEED_UNKNOWN;
	usb_gadget_set_state(&hu->gadget, USB_STATE_NOTATTACHED);

	if (!driver || !driver->disconnect)
		return;

	spin_unlock(&hu->lock);
	driver->disconnect(&hu->gadget);
	spin_lock(&hu->lock);
}

static irqreturn_t harbor_usb_irq(int irq, void *data)
{
	struct harbor_usb *hu = data;
	unsigned long flags;
	u32 status;
	unsigned int i;

	spin_lock_irqsave(&hu->lock, flags);

	/* Read and W1C-clear under the lock, so a flush or a SETUP nuke
	 * running on another CPU cannot drop a stale event into a snapshot
	 * taken before it ran.
	 */
	status = readl(hu->base + HARBOR_USB_INT_STATUS);
	if (!status) {
		spin_unlock_irqrestore(&hu->lock, flags);
		return IRQ_NONE;
	}
	writel(status, hu->base + HARBOR_USB_INT_STATUS);

	if (status & HARBOR_USB_INT_LOCAL_RESET) {
		harbor_usb_handle_local_reset(hu);
	} else if (status & HARBOR_USB_INT_RESET) {
		harbor_usb_handle_bus_reset(hu);
	} else {
		for (i = 0; i < hu->num_ep; i++) {
			struct harbor_usb_ep *out_ep =
			    i == 0 ? &hu->ep0 : &hu->ep_out[i];
			struct harbor_usb_ep *in_ep =
			    i == 0 ? &hu->ep0 : &hu->ep_in[i];

			/* IN before OUT: on EP0 a data IN-done and the
			 * status OUT ZLP can land in the same pass, and the
			 * IN-done has to be handled first to catch it.
			 */
			if (status & HARBOR_USB_INT_IN(i))
				harbor_usb_handle_in_done(hu, in_ep);
			if (status & HARBOR_USB_INT_OUT(i))
				harbor_usb_handle_out_ready(hu, out_ep);
		}
	}

	spin_unlock_irqrestore(&hu->lock, flags);
	return IRQ_HANDLED;
}

static struct usb_request *harbor_usb_ep_alloc_request(struct usb_ep *_ep,
							gfp_t gfp)
{
	struct harbor_usb_req *req;

	req = kzalloc(sizeof(*req), gfp);
	if (!req)
		return NULL;
	INIT_LIST_HEAD(&req->queue);
	return &req->req;
}

static void harbor_usb_ep_free_request(struct usb_ep *_ep,
				       struct usb_request *_req)
{
	kfree(to_harbor_req(_req));
}

static int harbor_usb_ep_enable(struct usb_ep *_ep,
				const struct usb_endpoint_descriptor *desc)
{
	struct harbor_usb_ep *ep = to_harbor_ep(_ep);
	struct harbor_usb *hu = ep->hu;
	unsigned long flags;
	unsigned int maxp;
	u32 type;

	if (!desc || (!usb_endpoint_xfer_bulk(desc) && !usb_endpoint_xfer_int(desc)))
		return -EINVAL;

	type = usb_endpoint_xfer_bulk(desc) ? HARBOR_USB_TYPE_BULK :
					      HARBOR_USB_TYPE_INT;
	ep->is_in = usb_endpoint_dir_in(desc);
	ep->halted = false;
	_ep->desc = desc;
	maxp = usb_endpoint_maxp(desc);
	if (!maxp || maxp > HARBOR_USB_MAX_PACKET)
		maxp = HARBOR_USB_MAX_PACKET;
	_ep->maxpacket = maxp;

	spin_lock_irqsave(&hu->lock, flags);
	hu->ep_type[ep->idx] = type;
	hu->ep_enable_count[ep->idx]++;
	/* SET_CONFIGURATION/SET_INTERFACE expect DATA0 on a freshly enabled
	 * endpoint even without a bus reset, so reset this direction's
	 * toggle together with the enable and type write.
	 */
	harbor_usb_ep_cfg_write(hu, ep->idx,
				ep->is_in ? HARBOR_USB_EP_CFG_TOGGLE_IN :
					    HARBOR_USB_EP_CFG_TOGGLE_OUT);
	spin_unlock_irqrestore(&hu->lock, flags);
	return 0;
}

static int harbor_usb_ep_disable(struct usb_ep *_ep)
{
	struct harbor_usb_ep *ep = to_harbor_ep(_ep);
	struct harbor_usb *hu = ep->hu;
	void __iomem *base = harbor_ep_base(hu, ep->idx);
	unsigned long flags;
	u32 stat;

	spin_lock_irqsave(&hu->lock, flags);
	harbor_usb_nuke(hu, ep, -ESHUTDOWN, true);
	ep->in_armed = false;
	ep->in_last_committed = false;
	ep->halted = false;
	ep->wedged = false;

	/* Release a packet still held on the OUT side so it does not NAK
	 * forever once nothing will ever pop it. Only for an OUT endpoint:
	 * ep1in and ep1out can share one hardware index, so disabling the
	 * IN side must not drop a packet the host already saw ACKed on OUT.
	 */
	if (!harbor_ep_is_in(ep)) {
		stat = readl(base + HARBOR_USB_EP_OUT_STAT);
		if (stat & HARBOR_USB_OUT_STAT_READY)
			writel(stat, base + HARBOR_USB_EP_OUT_ACK);
	}

	if (hu->ep_enable_count[ep->idx])
		hu->ep_enable_count[ep->idx]--;
	harbor_usb_ep_cfg_write(hu, ep->idx, 0);
	spin_unlock_irqrestore(&hu->lock, flags);
	_ep->desc = NULL;
	return 0;
}

/* Drops whatever this endpoint holds: an armed IN packet, or a held
 * OUT packet, matching fifo_flush usage like f_mass_storage's BOT
 * reset recovery. A held OUT packet is dropped with nothing to
 * complete. An armed IN packet's chunk has no confirmed IN-done, so
 * the head request completes with -ECONNRESET at its last confirmed
 * actual, and the next request, if any, is kicked fresh.
 */
static void harbor_usb_ep_fifo_flush(struct usb_ep *_ep)
{
	struct harbor_usb_ep *ep = to_harbor_ep(_ep);
	struct harbor_usb *hu = ep->hu;
	void __iomem *base = harbor_ep_base(hu, ep->idx);
	unsigned long flags;
	u32 stat;

	spin_lock_irqsave(&hu->lock, flags);
	if (harbor_ep_is_in(ep)) {
		if (ep->in_armed) {
			unsigned int chunk = ep->in_last_chunk;
			bool acked;

			stat = readl(base + HARBOR_USB_EP_IN_STAT);
			acked = stat & HARBOR_USB_IN_STAT_ACKED;
			harbor_usb_in_flush_armed(hu, ep);
			if (!list_empty(&ep->queue)) {
				struct harbor_usb_req *req = list_first_entry(
				    &ep->queue, struct harbor_usb_req, queue);

				/* An ACK landing during the flush wait still
				 * counts as sent and the driver cannot see it.
				 */
				if (!acked)
					req->req.actual -= chunk;
				harbor_usb_done(ep, &req->req, -ECONNRESET);
			}
		}
	} else {
		stat = readl(base + HARBOR_USB_EP_OUT_STAT);
		if (stat & HARBOR_USB_OUT_STAT_READY)
			writel(stat, base + HARBOR_USB_EP_OUT_ACK);
	}
	spin_unlock_irqrestore(&hu->lock, flags);
}

static int harbor_usb_ep_queue(struct usb_ep *_ep, struct usb_request *_req,
			       gfp_t gfp)
{
	struct harbor_usb_ep *ep = to_harbor_ep(_ep);
	struct harbor_usb_req *req = to_harbor_req(_req);
	struct harbor_usb *hu = ep->hu;
	unsigned long flags;
	bool kick;
	int ret = 0;

	_req->actual = 0;
	_req->status = -EINPROGRESS;

	spin_lock_irqsave(&hu->lock, flags);
	if (!hu->driver) {
		ret = -ESHUTDOWN;
		goto out;
	}
	if (ep->idx != 0 && !_ep->desc) {
		ret = -ESHUTDOWN;
		goto out;
	}
	if (!list_empty(&req->queue)) {
		ret = -EINVAL;
		goto out;
	}

	kick = list_empty(&ep->queue);
	list_add_tail(&req->queue, &ep->queue);
	if (kick) {
		if (harbor_ep_is_in(ep))
			harbor_usb_in_kick(hu, ep);
		else
			harbor_usb_out_advance(hu, ep);
	}
out:
	spin_unlock_irqrestore(&hu->lock, flags);
	return ret;
}

static int harbor_usb_ep_dequeue(struct usb_ep *_ep, struct usb_request *_req)
{
	struct harbor_usb_ep *ep = to_harbor_ep(_ep);
	struct harbor_usb *hu = ep->hu;
	struct harbor_usb_req *req;
	unsigned long flags;
	int ret = -EINVAL;

	spin_lock_irqsave(&hu->lock, flags);
	list_for_each_entry(req, &ep->queue, queue) {
		if (&req->req == _req) {
			bool is_head = req == list_first_entry(&ep->queue,
								struct harbor_usb_req,
								queue);
			bool was_armed = is_head && harbor_ep_is_in(ep) && ep->in_armed;

			if (was_armed)
				harbor_usb_in_flush_armed(hu, ep);
			list_del_init(&req->queue);
			/* The flush left the endpoint idle. Start whatever is
			 * now at the head fresh instead of waiting on an
			 * IN-done that the flush already guaranteed is gone.
			 */
			if (was_armed && !list_empty(&ep->queue))
				harbor_usb_in_kick(hu, ep);
			ret = 0;
			break;
		}
	}
	if (!ret) {
		_req->status = -ECONNRESET;
		spin_unlock(&hu->lock);
		usb_gadget_giveback_request(_ep, _req);
		spin_lock(&hu->lock);
	}
	spin_unlock_irqrestore(&hu->lock, flags);

	return ret;
}

static int harbor_usb_ep_set_halt(struct usb_ep *_ep, int halt)
{
	struct harbor_usb_ep *ep = to_harbor_ep(_ep);
	struct harbor_usb *hu = ep->hu;
	unsigned long flags;
	int ret = 0;

	spin_lock_irqsave(&hu->lock, flags);
	if (halt && ep->idx != 0 && harbor_ep_is_in(ep) && !list_empty(&ep->queue)) {
		ret = -EAGAIN;
		goto out;
	}
	harbor_usb_ep_halt(ep, halt);
	if (!halt)
		ep->wedged = false;
out:
	spin_unlock_irqrestore(&hu->lock, flags);
	return ret;
}

/* Halts the endpoint and marks it wedged: a host CLEAR_FEATURE(HALT) will
 * not clear it. Only harbor_usb_ep_set_halt(ep, 0) or a bus reset does.
 */
static int harbor_usb_ep_set_wedge(struct usb_ep *_ep)
{
	struct harbor_usb_ep *ep = to_harbor_ep(_ep);
	struct harbor_usb *hu = ep->hu;
	unsigned long flags;
	int ret = 0;

	spin_lock_irqsave(&hu->lock, flags);
	if (ep->idx != 0 && harbor_ep_is_in(ep) && !list_empty(&ep->queue)) {
		ret = -EAGAIN;
		goto out;
	}
	harbor_usb_ep_halt(ep, true);
	ep->wedged = true;
out:
	spin_unlock_irqrestore(&hu->lock, flags);
	return ret;
}

static const struct usb_ep_ops harbor_usb_ep_ops = {
    .enable = harbor_usb_ep_enable,
    .disable = harbor_usb_ep_disable,
    .alloc_request = harbor_usb_ep_alloc_request,
    .free_request = harbor_usb_ep_free_request,
    .queue = harbor_usb_ep_queue,
    .dequeue = harbor_usb_ep_dequeue,
    .set_wedge = harbor_usb_ep_set_wedge,
    .fifo_flush = harbor_usb_ep_fifo_flush,
    .set_halt = harbor_usb_ep_set_halt,
};

static int harbor_usb_pullup(struct usb_gadget *gadget, int is_on)
{
	struct harbor_usb *hu = gadget_to_harbor(gadget);
	unsigned long flags;
	u32 ctrl;

	spin_lock_irqsave(&hu->lock, flags);
	ctrl = readl(hu->base + HARBOR_USB_CTRL);
	if (is_on)
		ctrl |= HARBOR_USB_CTRL_CONNECT;
	else
		ctrl &= ~HARBOR_USB_CTRL_CONNECT;
	writel(ctrl, hu->base + HARBOR_USB_CTRL);
	spin_unlock_irqrestore(&hu->lock, flags);
	return 0;
}

static int harbor_usb_udc_start(struct usb_gadget *gadget,
				struct usb_gadget_driver *driver)
{
	struct harbor_usb *hu = gadget_to_harbor(gadget);
	unsigned long flags;
	unsigned int i;
	u32 int_en = HARBOR_USB_INT_RESET | HARBOR_USB_INT_LOCAL_RESET;

	for (i = 0; i < hu->num_ep; i++)
		int_en |= HARBOR_USB_INT_OUT(i) | HARBOR_USB_INT_IN(i);

	spin_lock_irqsave(&hu->lock, flags);
	hu->driver = driver;
	writel(HARBOR_USB_CTRL_ENABLE, hu->base + HARBOR_USB_CTRL);
	writel(int_en, hu->base + HARBOR_USB_INT_ENABLE);
	spin_unlock_irqrestore(&hu->lock, flags);
	return 0;
}

static int harbor_usb_udc_stop(struct usb_gadget *gadget)
{
	struct harbor_usb *hu = gadget_to_harbor(gadget);
	unsigned long flags;

	spin_lock_irqsave(&hu->lock, flags);
	writel(0, hu->base + HARBOR_USB_INT_ENABLE);
	writel(0, hu->base + HARBOR_USB_CTRL);
	hu->driver = NULL;
	spin_unlock_irqrestore(&hu->lock, flags);
	return 0;
}

static const struct usb_gadget_ops harbor_usb_gadget_ops = {
    .udc_start = harbor_usb_udc_start,
    .udc_stop = harbor_usb_udc_stop,
    .pullup = harbor_usb_pullup,
};

static int harbor_usb_probe(struct platform_device *pdev)
{
	struct harbor_usb *hu;
	u32 num_ep = 4;
	unsigned int i;
	int ret;

	hu = devm_kzalloc(&pdev->dev, sizeof(*hu), GFP_KERNEL);
	if (!hu)
		return -ENOMEM;

	hu->dev = &pdev->dev;
	hu->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hu->base))
		return PTR_ERR(hu->base);

	hu->irq = platform_get_irq(pdev, 0);
	if (hu->irq < 0)
		return hu->irq;

	device_property_read_u32(&pdev->dev, "harbor,num-endpoints", &num_ep);
	if (num_ep < 1)
		num_ep = 1;
	if (num_ep > HARBOR_USB_MAX_EP)
		num_ep = HARBOR_USB_MAX_EP;
	hu->num_ep = num_ep;

	spin_lock_init(&hu->lock);
	hu->ep0_dir_in = true;

	hu->ep_in = devm_kcalloc(&pdev->dev, num_ep, sizeof(*hu->ep_in), GFP_KERNEL);
	hu->ep_out = devm_kcalloc(&pdev->dev, num_ep, sizeof(*hu->ep_out), GFP_KERNEL);
	hu->ep_enable_count = devm_kcalloc(&pdev->dev, num_ep,
					   sizeof(*hu->ep_enable_count), GFP_KERNEL);
	hu->ep_type = devm_kcalloc(&pdev->dev, num_ep, sizeof(*hu->ep_type),
				  GFP_KERNEL);
	if (!hu->ep_in || !hu->ep_out || !hu->ep_enable_count || !hu->ep_type)
		return -ENOMEM;

	ret = devm_request_irq(&pdev->dev, hu->irq, harbor_usb_irq, 0,
			       "harbor-usb", hu);
	if (ret)
		return ret;

	hu->gadget.ops = &harbor_usb_gadget_ops;
	hu->gadget.name = "harbor-usb";
	hu->gadget.max_speed = USB_SPEED_FULL;
	hu->gadget.speed = USB_SPEED_UNKNOWN;
	INIT_LIST_HEAD(&hu->gadget.ep_list);

	INIT_LIST_HEAD(&hu->ep0.queue);
	hu->ep0.hu = hu;
	hu->ep0.idx = 0;
	hu->ep0.ep.ops = &harbor_usb_ep_ops;
	hu->ep0.ep.name = "ep0";
	hu->ep0.ep.caps.type_control = true;
	hu->ep0.ep.caps.dir_in = true;
	hu->ep0.ep.caps.dir_out = true;
	usb_ep_set_maxpacket_limit(&hu->ep0.ep, HARBOR_USB_MAX_PACKET);
	hu->gadget.ep0 = &hu->ep0.ep;
	/* EP0 stays enabled and control-typed for the controller's whole
	 * life, so its shadow state never changes after this.
	 */
	hu->ep_enable_count[0] = 1;
	hu->ep_type[0] = HARBOR_USB_TYPE_CONTROL;
	harbor_usb_ep_cfg_write(hu, 0, 0);

	for (i = 1; i < num_ep; i++) {
		struct harbor_usb_ep *in = &hu->ep_in[i];
		struct harbor_usb_ep *out = &hu->ep_out[i];

		INIT_LIST_HEAD(&in->queue);
		in->hu = hu;
		in->idx = i;
		in->is_in = true;
		in->ep.ops = &harbor_usb_ep_ops;
		in->ep.name = devm_kasprintf(&pdev->dev, GFP_KERNEL, "ep%uin", i);
		if (!in->ep.name)
			return -ENOMEM;
		in->ep.caps.type_bulk = true;
		in->ep.caps.type_int = true;
		in->ep.caps.dir_in = true;
		usb_ep_set_maxpacket_limit(&in->ep, HARBOR_USB_MAX_PACKET);
		list_add_tail(&in->ep.ep_list, &hu->gadget.ep_list);

		INIT_LIST_HEAD(&out->queue);
		out->hu = hu;
		out->idx = i;
		out->is_in = false;
		out->ep.ops = &harbor_usb_ep_ops;
		out->ep.name = devm_kasprintf(&pdev->dev, GFP_KERNEL, "ep%uout", i);
		if (!out->ep.name)
			return -ENOMEM;
		out->ep.caps.type_bulk = true;
		out->ep.caps.type_int = true;
		out->ep.caps.dir_out = true;
		usb_ep_set_maxpacket_limit(&out->ep, HARBOR_USB_MAX_PACKET);
		list_add_tail(&out->ep.ep_list, &hu->gadget.ep_list);
	}

	platform_set_drvdata(pdev, hu);
	return usb_add_gadget_udc(&pdev->dev, &hu->gadget);
}

static void harbor_usb_remove(struct platform_device *pdev)
{
	struct harbor_usb *hu = platform_get_drvdata(pdev);

	usb_del_gadget_udc(&hu->gadget);
}

static const struct of_device_id harbor_usb_of_match[] = {
    {.compatible = "harbor,usb"}, {}};
MODULE_DEVICE_TABLE(of, harbor_usb_of_match);

static struct platform_driver harbor_usb_driver = {
    .probe = harbor_usb_probe,
    .remove = harbor_usb_remove,
    .driver =
	{
	    .name = "harbor-usb",
	    .of_match_table = harbor_usb_of_match,
	},
};
module_platform_driver(harbor_usb_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor USB controller driver");
MODULE_LICENSE("GPL");
