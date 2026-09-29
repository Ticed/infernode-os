#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

/*
 * Drawing hardware: what memimagedraw can hand to a device, and the
 * waiting that keeps the CPU and the device from touching the same
 * pixels at once.  See memdraw.h.
 *
 * A Memhwop is chosen to draw exactly what the software path would:
 * each kind is taken only where the software path that would otherwise
 * run is the one it reproduces (memoptdraw's fill and copy, coverdraw,
 * blenddraw, and alphadraw's translucent fill, which is blenddraw's
 * arithmetic with a constant source).  aatest checks the choice, and a
 * device, against the software path, pixel for pixel.
 *
 * Every piece of image memory remembers the generation of queued work
 * that last read it and last wrote it (hwread, hwwrite in Memdata);
 * waiting for the device ends the generation.  The CPU waits before it
 * reads what queued work writes, and before it writes what queued work
 * reads or writes.
 */

Memhw	*memhw;		/* set by the platform, if it has a device */
int	memhwon = 1;	/* 0: draw everything on the CPU, for A/B tests */
int	memhwbusy;	/* work is queued */
ulong	memhwgen = 1;	/* the generation of queued work */

void
memhwsync(void)
{
	if(memhwbusy && memhw != nil){
		memhw->sync();
		memhwbusy = 0;
		memhwgen++;
	}
}

/* the CPU is about to write this memory */
void
memhwwrite(Memdata *d)
{
	if(memhwbusy && d != nil && (d->hwread == memhwgen || d->hwwrite == memhwgen))
		memhwsync();
}

/* the CPU is about to read it */
void
memhwread(Memdata *d)
{
	if(memhwbusy && d != nil && d->hwwrite == memhwgen)
		memhwsync();
}

/* byteaddr without waiting: the op's addresses, not a CPU access */
static uchar*
addr(Memimage *i, Point p)
{
	return i->data->bdata + i->zero + sizeof(ulong)*p.y*i->width + p.x*(i->depth/8);
}

static int
bytes32(Memimage *i)
{
	return (i->flags & (Fbytes|Fgrey|Fcmap)) == Fbytes && (i->depth == 32 || i->depth == 24);
}

static void
shifts(Memimage *i, int *s)
{
	s[0] = i->shift[CRed];
	s[1] = i->shift[CGreen];
	s[2] = i->shift[CBlue];
	s[3] = (i->flags & Falpha) ? i->shift[CAlpha] : -1;
}

int
_memhwdraw(Memdrawparam *par)
{
	Memhwop o;
	Memimage *dst, *src, *mask;
	int m;

	if(memhw == nil || !memhwon)
		return 0;
	dst = par->dst;
	src = par->src;
	mask = par->mask;
	if(!bytes32(dst) || dst->layer != nil)
		return 0;
	if(!memhwbusy && Dx(par->r)*Dy(par->r) < memhw->minpixels)
		return 0;

	memset(&o, 0, sizeof o);
	o.w = Dx(par->r);
	o.h = Dy(par->r);
	o.dst = addr(dst, par->r.min);
	o.dstride = dst->width*sizeof(ulong);
	o.dnb = dst->depth/8;
	o.ddata = dst->data;
	shifts(dst, o.dshift);

	m = Simplesrc|Simplemask|Fullmask;
	if((par->state&m) == m && (par->srgba&0xFF) == 0xFF && (par->op == S || par->op == SoverD)){
		/* memoptdraw's fill */
		o.kind = Hwfill;
		o.value = par->sdval;
	}else if((par->state&m) == m && par->op == SoverD){
		/* a translucent fill: alphadraw, whose alphacalc11 with the mask 255 is blenddraw's sum */
		o.kind = Hwblend;
		o.value = par->srgba;
	}else if((par->state&(Simplemask|Fullmask|Replsrc)) == (Simplemask|Fullmask)
	&& src->chan == dst->chan && src->data != dst->data
	&& (par->op == S || (par->op == SoverD && !(src->flags&Falpha)))){
		/* memoptdraw's copy */
		o.kind = Hwcopy;
		o.src = addr(src, par->sr.min);
		o.sstride = src->width*sizeof(ulong);
		o.sdata = src->data;
	}else if(par->op == SoverD && (par->state & Simplesrc)
	&& mask->chan == GREY8 && !(mask->flags & Frepl)){
		/* coverdraw */
		o.kind = Hwcover;
		o.value = par->srgba;
		o.mask = mask->data->bdata + mask->zero + sizeof(ulong)*par->mr.min.y*mask->width + par->mr.min.x;
		o.mstride = mask->width*sizeof(ulong);
		o.mdata = mask->data;
	}else if(par->op == SoverD && (par->state & Fullmask) && !(src->flags & Frepl)
	&& (src->flags & (Fbytes|Falpha|Fgrey|Fcmap)) == (Fbytes|Falpha) && src->depth == 32
	&& src->data != dst->data && src->layer == nil){
		/* blenddraw */
		o.kind = Hwblend;
		o.src = addr(src, par->sr.min);
		o.sstride = src->width*sizeof(ulong);
		o.sdata = src->data;
		shifts(src, o.sshift);
	}else
		return 0;

	/* the CPU must not be writing what this reads, or touching what it writes */
	memhwwrite(o.ddata);
	if(o.sdata != nil)
		memhwread(o.sdata);
	if(o.mdata != nil)
		memhwread(o.mdata);
	if(!memhw->run(&o))
		return 0;
	memhwbusy = 1;
	o.ddata->hwwrite = memhwgen;
	if(o.sdata != nil)
		o.sdata->hwread = memhwgen;
	if(o.mdata != nil)
		o.mdata->hwread = memhwgen;
	return 1;
}
