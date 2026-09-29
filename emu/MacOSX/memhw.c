#include	"dat.h"
#include	"fns.h"
#include	<draw.h>
#include	<memdraw.h>
#include	"memhw-metal.h"

/*
 * The GPU as libmemdraw's drawing hardware (memhw in memdraw.h), by way
 * of memhw-metal.m.  Off unless DRAWHW=1 is in the environment: the CPU
 * draws by default until the GPU is shown to be faster
 * (benchmarks/bench-draw.sh), and with it off nothing changes.
 */

extern	void	(*imagarenahook)(void*, ulong);
extern	void	imagarenaeach(void (*)(void*, ulong));

static void
arena(void *base, ulong len)
{
	mtlarena(base, len);
}

static int
run(Memhwop *o)
{
	Mtlop m;
	int i;

	m.kind = o->kind;
	m.w = o->w;
	m.h = o->h;
	m.dst = o->dst;
	m.dstride = o->dstride;
	m.dnb = o->dnb;
	m.src = o->src;
	m.sstride = o->sstride;
	m.mask = o->mask;
	m.mstride = o->mstride;
	m.value = o->value;
	for(i = 0; i < 4; i++){
		m.dshift[i] = o->dshift[i];
		m.sshift[i] = o->sshift[i];
	}
	return mtlrun(&m);
}

/*
 * Below 1024 pixels, drawing is cheaper on the CPU than as a dispatch
 * (benchmarks/bench-draw.sh, M-series): see _memhwdraw in hw.c.
 */
static Memhw metal = {
	"metal",
	run,
	mtlsync,
	1024,
};

void
memhwinit(void)
{
	char *e;

	e = getenv("DRAWHW");
	if(e == nil || strcmp(e, "1") != 0)
		return;
	if(!mtlinit()){
		print("memhw: no Metal device with unified memory; drawing on the CPU\n");
		return;
	}
	imagarenaeach(arena);
	imagarenahook = arena;
	memhw = &metal;
}
