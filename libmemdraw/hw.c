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
enum
{
	Smallrun	= 32,	/* small work that follows queued work to the device, at most, in a row */
};
static int	smallrun;	/* small work handed over since the last large */
int	memhwbusy;	/* work is queued */
ulong	memhwgen = 1;	/* the generation of queued work */

/* images freed while queued work used them, to free once it is done */
static Memimage	**retired;
static int	nretired, aretired;

void
memhwsync(void)
{
	int i;

	if(memhwbusy && memhw != nil){
		memhw->sync();
		memhwbusy = 0;
		memhwgen++;
		for(i = 0; i < nretired; i++)
			freememimage(retired[i]);
		nretired = 0;
	}
}

/*
 * Whether queued work uses this memory: if not, the CPU may touch it
 * without waiting.
 */
int
memhwinuse(Memdata *d)
{
	return memhwbusy && d != nil && (d->hwread == memhwgen || d->hwwrite == memhwgen);
}

/*
 * Free an image that queued work may still use, without waiting for
 * it: it is freed at the next wait.
 */
void
memhwfree(Memimage *i)
{
	Memimage **r;

	if(i == nil)
		return;
	if(!memhwinuse(i->data)){
		freememimage(i);
		return;
	}
	if(nretired == aretired){
		aretired = 2*aretired + 16;
		r = realloc(retired, aretired*sizeof(Memimage*));
		if(r == nil){
			memhwsync();
			freememimage(i);
			return;
		}
		retired = r;
	}
	retired[nretired++] = i;
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
	/*
	 * Small work is cheaper on the CPU than as a dispatch of its own,
	 * except that the CPU must first wait for queued work on the same
	 * image.  So while the device has work, a few small things in a
	 * row (among large ones) follow it there; a long run of them (text)
	 * waits once and stays on the CPU.
	 */
	if(Dx(par->r)*Dy(par->r) < memhw->minpixels){
		if(!memhwbusy || smallrun >= Smallrun)
			return 0;
		smallrun++;
	}else
		smallrun = 0;

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
		/*
		 * memoptdraw's copy.  Moving memory is what a CPU does as fast
		 * as a GPU, so a copy goes to the device only to save waiting
		 * for it: when the destination has work queued.
		 */
		if(!memhwinuse(dst->data))
			return 0;
		o.kind = Hwcopy;
		o.src = addr(src, par->sr.min);
		o.sstride = src->width*sizeof(ulong);
		o.sdata = src->data;
	}else if(par->op == SoverD && (par->state & Simplesrc)
	&& mask->chan == GREY8 && !(mask->flags & Frepl)){
		/*
		 * coverdraw.  Coverage comes a band of a shape or a glyph at a
		 * time, small, and the CPU draws it about as fast as a
		 * dispatch is made; it goes to the device only to save
		 * waiting for it.
		 */
		if(!memhwinuse(dst->data))
			return 0;
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

	/*
	 * No waiting here: the device does its work in the order it was
	 * queued, and the CPU waits where it touches pixels.
	 */
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
