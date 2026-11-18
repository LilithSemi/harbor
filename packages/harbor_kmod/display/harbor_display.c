// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor display controller driver (DRM/KMS)
 *
 * The controller scans a framebuffer from the sdram, through the scanout
 * port of the sdram controller, and sends it as DVI. It has one fixed mode.
 * Each register sits in its own 8-byte slot:
 *
 *   0x00: CTRL        (RW)  bit 0 enable
 *   0x08: STATUS      (RO)  0 running, 1 update pending, 2 underrun, 3 ready, 4 bus error
 *   0x10: FB_BASE     (RW)  framebuffer address, in use after the next frame
 *   0x18: FB_STRIDE   (RO)  bytes from one line to the next
 *   0x20: H_ACTIVE    (RO)  0x28: H_TIMING   (RO)
 *   0x30: V_ACTIVE    (RO)  0x38: V_TIMING   (RO)
 *   0x40: INT_STATUS  (W1C) bit 0 vblank, bit 1 underrun, bit 2 bus error
 *   0x48: INT_ENABLE  (RW)
 *   0x50: PIXEL_CLOCK (RO)  Hz
 *   0x58: FORMAT      (RW)  pixel format code in use
 *   0x60: FORMATS     (RO)  one bit for each supported format code
 *
 * H_TIMING and V_TIMING hold the front porch in bits 9:0, the sync width in
 * bits 19:10, the back porch in bits 29:20 and the sync polarity (1 is
 * high) in bit 30.
 *
 * A write to CTRL or FB_BASE starts an update. The controller takes CTRL,
 * FB_BASE and FORMAT together at the next frame start, so the driver writes
 * FORMAT before FB_BASE. The mode and the formats come from the
 * "harbor,*" properties. A node without them is read from the registers.
 *
 * The scanout port reaches only the sdram, so the framebuffers come from
 * the memory-region of the node, a shared-dma-pool inside the sdram. A node
 * without a memory-region uses the default DMA pool or the CMA area, which
 * must lie in the sdram. The driver takes over from a simple-framebuffer
 * node that uses the same region, or from any firmware framebuffer when the
 * node has no memory-region.
 */

#include <linux/aperture.h>
#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/of_reserved_mem.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/string.h>

#include <drm/clients/drm_client_setup.h>
#include <drm/drm_atomic_helper.h>
#include <drm/drm_connector.h>
#include <drm/drm_drv.h>
#include <drm/drm_fb_dma_helper.h>
#include <drm/drm_fbdev_dma.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_dma_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_mode_config.h>
#include <drm/drm_modes.h>
#include <drm/drm_print.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_simple_kms_helper.h>
#include <drm/drm_vblank.h>

#define HARBOR_DISP_CTRL	0x00
#define HARBOR_DISP_STATUS	0x08
#define HARBOR_DISP_FB_BASE	0x10
#define HARBOR_DISP_FB_STRIDE	0x18
#define HARBOR_DISP_H_ACTIVE	0x20
#define HARBOR_DISP_H_TIMING	0x28
#define HARBOR_DISP_V_ACTIVE	0x30
#define HARBOR_DISP_V_TIMING	0x38
#define HARBOR_DISP_INT_STATUS	0x40
#define HARBOR_DISP_INT_ENABLE	0x48
#define HARBOR_DISP_PIXEL_CLOCK 0x50
#define HARBOR_DISP_FORMAT	0x58
#define HARBOR_DISP_FORMATS	0x60

#define HARBOR_DISP_CTRL_ENABLE BIT(0)

#define HARBOR_DISP_STATUS_PENDING BIT(1)

#define HARBOR_DISP_INT_VBLANK	 BIT(0)
#define HARBOR_DISP_INT_UNDERRUN BIT(1)
#define HARBOR_DISP_INT_BUS_ERR	 BIT(2)

#define HARBOR_DISP_TIMING_FRONT GENMASK(9, 0)
#define HARBOR_DISP_TIMING_SYNC	 GENMASK(19, 10)
#define HARBOR_DISP_TIMING_BACK	 GENMASK(29, 20)
#define HARBOR_DISP_TIMING_HIGH	 BIT(30)

/* Format codes of the FORMAT and FORMATS registers. */
#define HARBOR_DISP_FMT_RGB565	 0
#define HARBOR_DISP_FMT_XRGB8888 2
#define HARBOR_DISP_FMT_ARGB8888 3

#define HARBOR_DISP_MAX_FORMATS 3

struct harbor_display {
	struct drm_device drm;
	struct drm_simple_display_pipe pipe;
	struct drm_connector connector;
	void __iomem *base;
	struct drm_display_mode mode;
	u32 formats[HARBOR_DISP_MAX_FORMATS];
	u32 strides[HARBOR_DISP_MAX_FORMATS];
	unsigned int num_formats;
	bool has_irq;
	spinlock_t lock; /* INT_ENABLE */
	u32 int_enable;
	struct drm_pending_vblank_event *event; /* event_lock */
};

static struct harbor_display *to_harbor_display(struct drm_device *drm)
{
	return container_of(drm, struct harbor_display, drm);
}

static u32 harbor_display_read(struct harbor_display *hd, unsigned int reg)
{
	return readl(hd->base + reg);
}

static void harbor_display_write(struct harbor_display *hd, unsigned int reg,
				 u32 val)
{
	writel(val, hd->base + reg);
}

static const struct {
	const char *name;
	u32 fourcc;
	u32 code;
} harbor_display_formats[] = {
    {"r5g6b5", DRM_FORMAT_RGB565, HARBOR_DISP_FMT_RGB565},
    {"x8r8g8b8", DRM_FORMAT_XRGB8888, HARBOR_DISP_FMT_XRGB8888},
    {"a8r8g8b8", DRM_FORMAT_ARGB8888, HARBOR_DISP_FMT_ARGB8888},
};

static int harbor_display_format_code(u32 fourcc)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(harbor_display_formats); i++)
		if (harbor_display_formats[i].fourcc == fourcc)
			return harbor_display_formats[i].code;

	return -EINVAL;
}

/* Bytes from line to line of a buffer in @fourcc, or 0 if not supported. */
static u32 harbor_display_stride(struct harbor_display *hd, u32 fourcc)
{
	unsigned int i;

	for (i = 0; i < hd->num_formats; i++)
		if (hd->formats[i] == fourcc)
			return hd->strides[i];

	return 0;
}

static u32 harbor_display_stride_for_bpp(struct harbor_display *hd, u32 bpp)
{
	unsigned int i;

	for (i = 0; i < hd->num_formats; i++)
		if (drm_format_info(hd->formats[i])->cpp[0] * 8 == bpp)
			return hd->strides[i];

	return 0;
}

static int harbor_display_mode_from_props(struct harbor_display *hd,
					  struct device *dev)
{
	struct drm_display_mode *m = &hd->mode;
	u32 hact, hfp, hsync, hbp, vact, vfp, vsync, vbp, clock, hpol, vpol;
	int ret = 0;

	ret |= device_property_read_u32(dev, "harbor,hactive", &hact);
	ret |= device_property_read_u32(dev, "harbor,hfront-porch", &hfp);
	ret |= device_property_read_u32(dev, "harbor,hsync-len", &hsync);
	ret |= device_property_read_u32(dev, "harbor,hback-porch", &hbp);
	ret |= device_property_read_u32(dev, "harbor,hsync-active", &hpol);
	ret |= device_property_read_u32(dev, "harbor,vactive", &vact);
	ret |= device_property_read_u32(dev, "harbor,vfront-porch", &vfp);
	ret |= device_property_read_u32(dev, "harbor,vsync-len", &vsync);
	ret |= device_property_read_u32(dev, "harbor,vback-porch", &vbp);
	ret |= device_property_read_u32(dev, "harbor,vsync-active", &vpol);
	ret |= device_property_read_u32(dev, "harbor,pixel-clock-hz", &clock);
	if (ret)
		return -ENODATA;

	m->hdisplay = hact;
	m->hsync_start = hact + hfp;
	m->hsync_end = m->hsync_start + hsync;
	m->htotal = m->hsync_end + hbp;
	m->vdisplay = vact;
	m->vsync_start = vact + vfp;
	m->vsync_end = m->vsync_start + vsync;
	m->vtotal = m->vsync_end + vbp;
	m->clock = clock / 1000;
	m->flags = (hpol ? DRM_MODE_FLAG_PHSYNC : DRM_MODE_FLAG_NHSYNC) |
		   (vpol ? DRM_MODE_FLAG_PVSYNC : DRM_MODE_FLAG_NVSYNC);

	return 0;
}

static void harbor_display_mode_from_regs(struct harbor_display *hd)
{
	struct drm_display_mode *m = &hd->mode;
	u32 h = harbor_display_read(hd, HARBOR_DISP_H_TIMING);
	u32 v = harbor_display_read(hd, HARBOR_DISP_V_TIMING);

	m->hdisplay = harbor_display_read(hd, HARBOR_DISP_H_ACTIVE);
	m->hsync_start = m->hdisplay + FIELD_GET(HARBOR_DISP_TIMING_FRONT, h);
	m->hsync_end = m->hsync_start + FIELD_GET(HARBOR_DISP_TIMING_SYNC, h);
	m->htotal = m->hsync_end + FIELD_GET(HARBOR_DISP_TIMING_BACK, h);
	m->vdisplay = harbor_display_read(hd, HARBOR_DISP_V_ACTIVE);
	m->vsync_start = m->vdisplay + FIELD_GET(HARBOR_DISP_TIMING_FRONT, v);
	m->vsync_end = m->vsync_start + FIELD_GET(HARBOR_DISP_TIMING_SYNC, v);
	m->vtotal = m->vsync_end + FIELD_GET(HARBOR_DISP_TIMING_BACK, v);
	m->clock = harbor_display_read(hd, HARBOR_DISP_PIXEL_CLOCK) / 1000;
	m->flags = ((h & HARBOR_DISP_TIMING_HIGH) ? DRM_MODE_FLAG_PHSYNC :
						    DRM_MODE_FLAG_NHSYNC) |
		   ((v & HARBOR_DISP_TIMING_HIGH) ? DRM_MODE_FLAG_PVSYNC :
						    DRM_MODE_FLAG_NVSYNC);
}

static int harbor_display_formats_from_props(struct harbor_display *hd,
					     struct device *dev)
{
	const char *names[HARBOR_DISP_MAX_FORMATS];
	int count, i, j;

	count = device_property_string_array_count(dev, "harbor,formats");
	if (count < 0)
		return count;
	if (count == 0 || count > HARBOR_DISP_MAX_FORMATS)
		return -EINVAL;
	if (device_property_read_string_array(dev, "harbor,formats", names,
					      count) < 0)
		return -EINVAL;
	if (device_property_read_u32_array(dev, "harbor,strides", hd->strides,
					   count))
		return -EINVAL;

	for (i = 0; i < count; i++) {
		for (j = 0; j < ARRAY_SIZE(harbor_display_formats); j++)
			if (!strcmp(names[i], harbor_display_formats[j].name))
				break;
		if (j == ARRAY_SIZE(harbor_display_formats))
			return -EINVAL;
		hd->formats[i] = harbor_display_formats[j].fourcc;
	}
	hd->num_formats = count;

	return 0;
}

/* Without properties, only a build with one format has a known stride. */
static int harbor_display_formats_from_regs(struct harbor_display *hd)
{
	u32 mask = harbor_display_read(hd, HARBOR_DISP_FORMATS);
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(harbor_display_formats); i++) {
		if (!(mask & BIT(harbor_display_formats[i].code)))
			continue;
		if (hd->num_formats)
			return -EINVAL;
		hd->formats[0] = harbor_display_formats[i].fourcc;
		hd->strides[0] = harbor_display_read(hd, HARBOR_DISP_FB_STRIDE);
		hd->num_formats = 1;
	}

	return hd->num_formats ? 0 : -EINVAL;
}

static void harbor_display_set_int_enable(struct harbor_display *hd, u32 set,
					  u32 clear)
{
	unsigned long flags;

	spin_lock_irqsave(&hd->lock, flags);
	hd->int_enable = (hd->int_enable | set) & ~clear;
	harbor_display_write(hd, HARBOR_DISP_INT_ENABLE, hd->int_enable);
	spin_unlock_irqrestore(&hd->lock, flags);
}

/* Sends the flip event once the controller took the new address. */
static void harbor_display_finish_flip(struct harbor_display *hd)
{
	struct drm_crtc *crtc = &hd->pipe.crtc;
	unsigned long flags;

	spin_lock_irqsave(&hd->drm.event_lock, flags);
	if (hd->event &&
	    !(harbor_display_read(hd, HARBOR_DISP_STATUS) &
	      HARBOR_DISP_STATUS_PENDING)) {
		drm_crtc_send_vblank_event(crtc, hd->event);
		hd->event = NULL;
		drm_crtc_vblank_put(crtc);
	}
	spin_unlock_irqrestore(&hd->drm.event_lock, flags);
}

static irqreturn_t harbor_display_irq(int irq, void *data)
{
	struct harbor_display *hd = data;
	u32 status = harbor_display_read(hd, HARBOR_DISP_INT_STATUS);

	/* A bit that is not enabled is not ours, it can be old. */
	status &= READ_ONCE(hd->int_enable);
	if (!status)
		return IRQ_NONE;

	harbor_display_write(hd, HARBOR_DISP_INT_STATUS, status);
	if (status & HARBOR_DISP_INT_UNDERRUN)
		drm_warn_once(&hd->drm, "scanout underrun\n");
	if (status & HARBOR_DISP_INT_BUS_ERR)
		drm_err_ratelimited(&hd->drm, "scanout bus error\n");
	if (status & HARBOR_DISP_INT_VBLANK) {
		drm_crtc_handle_vblank(&hd->pipe.crtc);
		harbor_display_finish_flip(hd);
	}

	return IRQ_HANDLED;
}

static int harbor_display_enable_vblank(struct drm_simple_display_pipe *pipe)
{
	struct harbor_display *hd = to_harbor_display(pipe->crtc.dev);

	/* An old vblank from before the enable is not a new one. */
	harbor_display_write(hd, HARBOR_DISP_INT_STATUS, HARBOR_DISP_INT_VBLANK);
	harbor_display_set_int_enable(hd, HARBOR_DISP_INT_VBLANK, 0);

	return 0;
}

static void harbor_display_disable_vblank(struct drm_simple_display_pipe *pipe)
{
	struct harbor_display *hd = to_harbor_display(pipe->crtc.dev);

	harbor_display_set_int_enable(hd, 0, HARBOR_DISP_INT_VBLANK);
}

static enum drm_mode_status
harbor_display_mode_valid(struct drm_simple_display_pipe *pipe,
			  const struct drm_display_mode *mode)
{
	struct harbor_display *hd = to_harbor_display(pipe->crtc.dev);

	if (mode->hdisplay != hd->mode.hdisplay ||
	    mode->vdisplay != hd->mode.vdisplay ||
	    mode->htotal != hd->mode.htotal || mode->vtotal != hd->mode.vtotal)
		return MODE_BAD;

	return MODE_OK;
}

static int harbor_display_pipe_check(struct drm_simple_display_pipe *pipe,
				     struct drm_plane_state *plane_state,
				     struct drm_crtc_state *crtc_state)
{
	struct harbor_display *hd = to_harbor_display(pipe->crtc.dev);
	struct drm_framebuffer *fb = plane_state->fb;

	crtc_state->no_vblank = !hd->has_irq;
	if (!fb)
		return 0;
	if (fb->pitches[0] != harbor_display_stride(hd, fb->format->format))
		return -EINVAL;

	return 0;
}

/* Gives the new format and address, and starts the update. */
static void harbor_display_set_fb(struct harbor_display *hd,
				  struct drm_plane_state *state)
{
	int code = harbor_display_format_code(state->fb->format->format);

	if (hd->num_formats > 1 && code >= 0)
		harbor_display_write(hd, HARBOR_DISP_FORMAT, code);
	harbor_display_write(hd, HARBOR_DISP_FB_BASE,
			     drm_fb_dma_get_gem_addr(state->fb, state, 0));
}

static void harbor_display_pipe_enable(struct drm_simple_display_pipe *pipe,
				       struct drm_crtc_state *crtc_state,
				       struct drm_plane_state *plane_state)
{
	struct harbor_display *hd = to_harbor_display(pipe->crtc.dev);

	harbor_display_set_fb(hd, plane_state);
	harbor_display_write(hd, HARBOR_DISP_CTRL, HARBOR_DISP_CTRL_ENABLE);
	if (hd->has_irq)
		drm_crtc_vblank_on(&pipe->crtc);
}

static void harbor_display_pipe_disable(struct drm_simple_display_pipe *pipe)
{
	struct harbor_display *hd = to_harbor_display(pipe->crtc.dev);

	if (hd->has_irq)
		drm_crtc_vblank_off(&pipe->crtc);
	harbor_display_write(hd, HARBOR_DISP_CTRL, 0);

	spin_lock_irq(&hd->drm.event_lock);
	if (hd->event) {
		drm_crtc_send_vblank_event(&pipe->crtc, hd->event);
		hd->event = NULL;
		drm_crtc_vblank_put(&pipe->crtc);
	}
	spin_unlock_irq(&hd->drm.event_lock);
}

static void harbor_display_pipe_update(struct drm_simple_display_pipe *pipe,
				       struct drm_plane_state *old_state)
{
	struct harbor_display *hd = to_harbor_display(pipe->crtc.dev);
	struct drm_plane_state *state = pipe->plane.state;
	struct drm_crtc *crtc = &pipe->crtc;
	struct drm_pending_vblank_event *event = crtc->state->event;

	if (state->fb && crtc->state->active)
		harbor_display_set_fb(hd, state);

	/* Without an interrupt, DRM sends a fake event. */
	if (!event || !hd->has_irq)
		return;
	crtc->state->event = NULL;

	spin_lock_irq(&crtc->dev->event_lock);
	/*
	 * The controller takes the new address at a frame start. The event
	 * goes out at the first vblank interrupt after STATUS shows no update
	 * pending, when the old buffer is not in use any more. DRM waits for
	 * the event of a commit before the next one, so a pending event here
	 * is a bug. Send it, to release its vblank reference.
	 */
	if (WARN_ON_ONCE(hd->event)) {
		drm_crtc_send_vblank_event(crtc, hd->event);
		hd->event = NULL;
		drm_crtc_vblank_put(crtc);
	}
	if (crtc->state->active && drm_crtc_vblank_get(crtc) == 0)
		hd->event = event;
	else
		drm_crtc_send_vblank_event(crtc, event);
	spin_unlock_irq(&crtc->dev->event_lock);
}

static const struct drm_simple_display_pipe_funcs harbor_display_pipe_funcs = {
    .mode_valid = harbor_display_mode_valid,
    .check = harbor_display_pipe_check,
    .enable = harbor_display_pipe_enable,
    .disable = harbor_display_pipe_disable,
    .update = harbor_display_pipe_update,
    .enable_vblank = harbor_display_enable_vblank,
    .disable_vblank = harbor_display_disable_vblank,
};

static int harbor_display_get_modes(struct drm_connector *conn)
{
	struct harbor_display *hd = to_harbor_display(conn->dev);
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(conn->dev, &hd->mode);
	if (!mode)
		return 0;

	drm_mode_set_name(mode);
	mode->type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;
	drm_mode_probed_add(conn, mode);

	return 1;
}

static const struct drm_connector_helper_funcs harbor_display_conn_helper = {
    .get_modes = harbor_display_get_modes,
};

static const struct drm_connector_funcs harbor_display_conn_funcs = {
    .fill_modes = drm_helper_probe_single_connector_modes,
    .destroy = drm_connector_cleanup,
    .reset = drm_atomic_helper_connector_reset,
    .atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
    .atomic_destroy_state = drm_atomic_helper_connector_destroy_state,
};

/* The buffer has the stride of the controller, so each line starts on a row. */
static int harbor_display_dumb_create(struct drm_file *file,
				      struct drm_device *drm,
				      struct drm_mode_create_dumb *args)
{
	struct harbor_display *hd = to_harbor_display(drm);
	struct drm_gem_dma_object *obj;
	u32 stride;
	int ret;

	stride = harbor_display_stride_for_bpp(hd, args->bpp);
	if (!stride || args->width != hd->mode.hdisplay ||
	    args->height != hd->mode.vdisplay)
		return -EINVAL;

	args->pitch = stride;
	args->size = PAGE_ALIGN((u64)stride * args->height);

	obj = drm_gem_dma_create(drm, args->size);
	if (IS_ERR(obj))
		return PTR_ERR(obj);

	ret = drm_gem_handle_create(file, &obj->base, &args->handle);
	drm_gem_object_put(&obj->base);

	return ret;
}

static struct drm_framebuffer *
harbor_display_fb_create(struct drm_device *drm, struct drm_file *file,
			 const struct drm_format_info *info,
			 const struct drm_mode_fb_cmd2 *cmd)
{
	struct harbor_display *hd = to_harbor_display(drm);

	if (cmd->pitches[0] != harbor_display_stride(hd, cmd->pixel_format))
		return ERR_PTR(-EINVAL);

	return drm_gem_fb_create(drm, file, info, cmd);
}

static const struct drm_mode_config_funcs harbor_display_mode_config_funcs = {
    .fb_create = harbor_display_fb_create,
    .atomic_check = drm_atomic_helper_check,
    .atomic_commit = drm_atomic_helper_commit,
};

DEFINE_DRM_GEM_DMA_FOPS(harbor_display_fops);

static const struct drm_driver harbor_display_drm_driver = {
    .driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
    .name = "harbor-display",
    .desc = "Harbor Display Controller",
    .major = 1,
    .minor = 0,
    .fops = &harbor_display_fops,
    DRM_GEM_DMA_DRIVER_OPS_WITH_DUMB_CREATE(harbor_display_dumb_create),
    DRM_FBDEV_DMA_DRIVER_OPS,
};

/* Takes the framebuffer region over from a simple-framebuffer device. */
static int harbor_display_remove_firmware_fb(struct device *dev)
{
	struct device_node *np;
	struct resource res;
	int ret;

	np = of_parse_phandle(dev->of_node, "memory-region", 0);
	if (!np)
		return aperture_remove_all_conflicting_devices("harbor-display");
	ret = of_address_to_resource(np, 0, &res);
	of_node_put(np);
	if (ret)
		return ret;

	return aperture_remove_conflicting_devices(res.start,
						   resource_size(&res),
						   "harbor-display");
}

static void harbor_display_release_pool(void *dev)
{
	of_reserved_mem_device_release(dev);
}

static int harbor_display_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct harbor_display *hd;
	struct drm_device *drm;
	int ret, irq;

	hd = devm_drm_dev_alloc(dev, &harbor_display_drm_driver,
				struct harbor_display, drm);
	if (IS_ERR(hd))
		return PTR_ERR(hd);

	drm = &hd->drm;
	spin_lock_init(&hd->lock);

	hd->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hd->base))
		return PTR_ERR(hd->base);

	if (harbor_display_mode_from_props(hd, dev))
		harbor_display_mode_from_regs(hd);
	if (harbor_display_formats_from_props(hd, dev)) {
		ret = harbor_display_formats_from_regs(hd);
		if (ret)
			return dev_err_probe(dev, ret, "no pixel format\n");
	}
	drm_mode_set_name(&hd->mode);
	hd->mode.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;
	if (!hd->mode.hdisplay || !hd->mode.vdisplay || !hd->mode.clock)
		return dev_err_probe(dev, -EINVAL, "no video mode\n");

	/*
	 * The buffers come from the reserved region in the sdram, because the
	 * scanout port reads nothing else.
	 */
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return ret;
	if (of_property_present(dev->of_node, "memory-region")) {
		ret = of_reserved_mem_device_init(dev);
		if (ret)
			return dev_err_probe(dev, ret,
					     "the memory-region is not a "
					     "shared-dma-pool\n");
		ret = devm_add_action_or_reset(dev, harbor_display_release_pool,
					       dev);
		if (ret)
			return ret;
	}

	ret = drmm_mode_config_init(drm);
	if (ret)
		return ret;
	drm->mode_config.min_width = hd->mode.hdisplay;
	drm->mode_config.max_width = hd->mode.hdisplay;
	drm->mode_config.min_height = hd->mode.vdisplay;
	drm->mode_config.max_height = hd->mode.vdisplay;
	drm->mode_config.preferred_depth =
	    drm_format_info(hd->formats[0])->depth;
	drm->mode_config.funcs = &harbor_display_mode_config_funcs;

	ret = drm_connector_init(drm, &hd->connector, &harbor_display_conn_funcs,
				 DRM_MODE_CONNECTOR_DVID);
	if (ret)
		return ret;
	drm_connector_helper_add(&hd->connector, &harbor_display_conn_helper);

	ret = drm_simple_display_pipe_init(drm, &hd->pipe,
					   &harbor_display_pipe_funcs,
					   hd->formats, hd->num_formats, NULL,
					   &hd->connector);
	if (ret)
		return ret;
	drm_mode_config_reset(drm);

	irq = platform_get_irq_optional(pdev, 0);
	if (irq == -EPROBE_DEFER)
		return irq;
	if (irq > 0) {
		ret = drm_vblank_init(drm, 1);
		if (ret)
			return ret;
		harbor_display_write(hd, HARBOR_DISP_INT_STATUS,
				     HARBOR_DISP_INT_VBLANK |
					 HARBOR_DISP_INT_UNDERRUN |
					 HARBOR_DISP_INT_BUS_ERR);
		harbor_display_set_int_enable(
		    hd, HARBOR_DISP_INT_UNDERRUN | HARBOR_DISP_INT_BUS_ERR, 0);
		ret = devm_request_irq(dev, irq, harbor_display_irq, 0,
				       dev_name(dev), hd);
		if (ret)
			return ret;
		hd->has_irq = true;
	}

	ret = harbor_display_remove_firmware_fb(dev);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, drm);
	ret = drm_dev_register(drm, 0);
	if (ret)
		return ret;

	drm_client_setup_with_fourcc(drm, hd->formats[0]);

	return 0;
}

static void harbor_display_remove(struct platform_device *pdev)
{
	struct drm_device *drm = platform_get_drvdata(pdev);

	drm_dev_unregister(drm);
	drm_atomic_helper_shutdown(drm);
}

static void harbor_display_shutdown(struct platform_device *pdev)
{
	drm_atomic_helper_shutdown(platform_get_drvdata(pdev));
}

static const struct of_device_id harbor_display_of_match[] = {
    {.compatible = "harbor,display"}, {}};
MODULE_DEVICE_TABLE(of, harbor_display_of_match);

static struct platform_driver harbor_display_driver = {
    .probe = harbor_display_probe,
    .remove = harbor_display_remove,
    .shutdown = harbor_display_shutdown,
    .driver =
	{
	    .name = "harbor-display",
	    .of_match_table = harbor_display_of_match,
	},
};
module_platform_driver(harbor_display_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor Display controller driver");
MODULE_LICENSE("GPL");
