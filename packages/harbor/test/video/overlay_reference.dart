/// `round(v / 255)` for v from 0 to 65025, as the display computes it.
int div255(int v) => (v + 128 + ((v + 128) >> 8)) >> 8;

/// One channel of the overlay blend.
int blend255(int ov, int pri, int alpha) =>
    div255(ov * alpha + pri * (255 - alpha));
