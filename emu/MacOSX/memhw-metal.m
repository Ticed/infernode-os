/*
 * Metal drawing hardware: memimagedraw's fills, copies, coverage and
 * blends (memhw in memdraw.h) as compute kernels, on image memory the
 * GPU shares with the CPU.  Each arena of image memory is wrapped, once,
 * in a Metal buffer without copying (Apple silicon's memory is unified),
 * so an image is a buffer and an offset.
 *
 * The kernels are Draw's arithmetic, operation for operation — MUL is
 * libmemdraw's rounding multiply — so what they draw is what the CPU
 * would, bit for bit.  Work is encoded as it arrives, submitted every
 * Nbatch operations so the GPU starts on it, and waited for only in
 * mtlsync, when the CPU must touch pixels the work touches.
 */

#import <Metal/Metal.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include "memhw-metal.h"

enum
{
	Nregion	= 256,
	Nbatch	= 256,	/* operations to a command buffer */
};

/* the operation as the kernels see it: this matches Op in the source below */
typedef struct Kop Kop;
struct Kop
{
	uint32_t	w, h;
	uint32_t	doff, dstride, dnb;
	int32_t	dsh[4];
	uint32_t	soff, sstride;
	int32_t	ssh[4];
	uint32_t	hassrc;
	uint32_t	moff, mstride;
	uint32_t	value;
};

static const char source[] =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Op {\n"
"	uint w, h;\n"
"	uint doff, dstride, dnb;\n"
"	int dsh[4];\n"
"	uint soff, sstride;\n"
"	int ssh[4];\n"
"	uint hassrc;\n"
"	uint moff, mstride;\n"
"	uint value;\n"
"};\n"
"/* libmemdraw's MUL: a*b/255, rounded */\n"
"static inline uint mul(uint a, uint b) { uint t = a*b + 128; return (t + (t >> 8)) >> 8; }\n"
"static inline uint ld(device uchar *p, uint nb) {\n"
"	uint u = uint(p[0]) | uint(p[1]) << 8 | uint(p[2]) << 16;\n"
"	if(nb == 4) u |= uint(p[3]) << 24;\n"
"	return u;\n"
"}\n"
"static inline void st(device uchar *p, uint nb, uint u) {\n"
"	p[0] = uchar(u); p[1] = uchar(u >> 8); p[2] = uchar(u >> 16);\n"
"	if(nb == 4) p[3] = uchar(u >> 24);\n"
"}\n"
"static inline uint ch(uint u, int sh) { return (u >> uint(sh)) & 255; }\n"
"/* a pixel from its channels; the unused byte of a 32-bit pixel is cleared, as writebyte does */\n"
"static inline uint px(constant Op &o, uint r, uint g, uint b, uint a) {\n"
"	uint u = r << uint(o.dsh[0]) | g << uint(o.dsh[1]) | b << uint(o.dsh[2]);\n"
"	if(o.dsh[3] >= 0) u |= a << uint(o.dsh[3]);\n"
"	return u;\n"
"}\n"
"kernel void kfill(device uchar *d [[buffer(0)]], constant Op &o [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
"	if(g.x >= o.w || g.y >= o.h) return;\n"
"	device uchar *p = d + o.doff + g.y*o.dstride + g.x*o.dnb;\n"
"	for(uint k = 0; k < o.dnb; k++) p[k] = uchar(o.value >> (8*k));\n"
"}\n"
"kernel void kcopy(device uchar *d [[buffer(0)]], device uchar *s [[buffer(1)]], constant Op &o [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
"	if(g.x >= o.w || g.y >= o.h) return;\n"
"	device uchar *p = d + o.doff + g.y*o.dstride + g.x*o.dnb;\n"
"	device uchar *q = s + o.soff + g.y*o.sstride + g.x*o.dnb;\n"
"	for(uint k = 0; k < o.dnb; k++) p[k] = q[k];\n"
"}\n"
"kernel void kcover(device uchar *d [[buffer(0)]], device uchar *m [[buffer(2)]], constant Op &o [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
"	if(g.x >= o.w || g.y >= o.h) return;\n"
"	device uchar *p = d + o.doff + g.y*o.dstride + g.x*o.dnb;\n"
"	uint u = ld(p, o.dnb);\n"
"	uint dr = ch(u, o.dsh[0]), dg = ch(u, o.dsh[1]), db = ch(u, o.dsh[2]);\n"
"	uint da = o.dsh[3] >= 0 ? ch(u, o.dsh[3]) : 0;\n"
"	uint ma = m[o.moff + g.y*o.mstride + g.x];\n"
"	if(ma != 0){\n"
"		uint sr = (o.value >> 24) & 255, sg = (o.value >> 16) & 255, sb = (o.value >> 8) & 255, sa = o.value & 255;\n"
"		uint fd = 255 - mul(sa, ma);\n"
"		dr = mul(ma, sr) + mul(fd, dr);\n"
"		dg = mul(ma, sg) + mul(fd, dg);\n"
"		db = mul(ma, sb) + mul(fd, db);\n"
"		da = mul(ma, sa) + mul(fd, da);\n"
"	}\n"
"	st(p, o.dnb, px(o, dr, dg, db, da));\n"
"}\n"
"kernel void kblend(device uchar *d [[buffer(0)]], device uchar *s [[buffer(1)]], constant Op &o [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
"	if(g.x >= o.w || g.y >= o.h) return;\n"
"	device uchar *p = d + o.doff + g.y*o.dstride + g.x*o.dnb;\n"
"	uint u = ld(p, o.dnb);\n"
"	uint dr = ch(u, o.dsh[0]), dg = ch(u, o.dsh[1]), db = ch(u, o.dsh[2]);\n"
"	uint da = o.dsh[3] >= 0 ? ch(u, o.dsh[3]) : 0;\n"
"	uint sr, sg, sb, sa;\n"
"	if(o.hassrc){\n"
"		uint v = ld(s + o.soff + g.y*o.sstride + g.x*4, 4);\n"
"		sr = ch(v, o.ssh[0]); sg = ch(v, o.ssh[1]); sb = ch(v, o.ssh[2]); sa = ch(v, o.ssh[3]);\n"
"	}else{\n"
"		sr = (o.value >> 24) & 255; sg = (o.value >> 16) & 255; sb = (o.value >> 8) & 255; sa = o.value & 255;\n"
"	}\n"
"	uint fd = 255 - sa;\n"
"	dr = sr + mul(fd, dr);\n"
"	dg = sg + mul(fd, dg);\n"
"	db = sb + mul(fd, db);\n"
"	da = sa + mul(fd, da);\n"
"	st(p, o.dnb, px(o, dr, dg, db, da));\n"
"}\n";

static id<MTLDevice>	dev;
static id<MTLCommandQueue>	queue;
static id<MTLComputePipelineState>	pipes[5];	/* by kind */
static id<MTLCommandBuffer>	cmd;		/* being encoded */
static id<MTLComputeCommandEncoder>	enc;
static id<MTLCommandBuffer>	last;		/* the last submitted */
static int	nenc;

static unsigned char	*rbase[Nregion];
static unsigned long	rlen[Nregion];
static id<MTLBuffer>	rbuf[Nregion];
static int	nregion;

static pthread_mutex_t	lk = PTHREAD_MUTEX_INITIALIZER;

int
mtlinit(void)
{
	static const char *names[] = {nil, "kfill", "kcopy", "kcover", "kblend"};
	NSError *err;
	id<MTLLibrary> lib;
	id<MTLFunction> fn;
	int i;

	@autoreleasepool {
		dev = MTLCreateSystemDefaultDevice();
		if(dev == nil)
			return 0;
		/* drawing in place needs memory the CPU and GPU share */
		if(!dev.hasUnifiedMemory){
			dev = nil;
			return 0;
		}
		err = nil;
		lib = [dev newLibraryWithSource:@(source) options:nil error:&err];
		if(lib == nil){
			fprintf(stderr, "memhw: metal: %s\n", err.localizedDescription.UTF8String);
			dev = nil;
			return 0;
		}
		for(i = 1; i <= 4; i++){
			fn = [lib newFunctionWithName:@(names[i])];
			pipes[i] = [dev newComputePipelineStateWithFunction:fn error:&err];
			if(pipes[i] == nil){
				fprintf(stderr, "memhw: metal: %s: %s\n", names[i], err.localizedDescription.UTF8String);
				dev = nil;
				return 0;
			}
		}
		queue = [dev newCommandQueue];
	}
	return 1;
}

void
mtlarena(void *base, unsigned long len)
{
	unsigned long page;

	pthread_mutex_lock(&lk);
	@autoreleasepool {
		if(dev != nil && nregion < Nregion){
			page = getpagesize();
			len = (len + page-1) & ~(page-1);	/* the mapping is whole pages */
			rbuf[nregion] = [dev newBufferWithBytesNoCopy:base length:len
				options:MTLResourceStorageModeShared deallocator:nil];
			if(rbuf[nregion] != nil){
				rbase[nregion] = base;
				rlen[nregion++] = len;
			}
		}
	}
	pthread_mutex_unlock(&lk);
}

/* the buffer holding [p, p+n), and p's offset in it */
static id<MTLBuffer>
region(unsigned char *p, unsigned long n, uint32_t *off)
{
	int i;

	for(i = 0; i < nregion; i++)
		if(p >= rbase[i] && p + n <= rbase[i] + rlen[i]){
			*off = p - rbase[i];
			return rbuf[i];
		}
	return nil;
}

static void
submit(void)
{
	if(enc != nil){
		[enc endEncoding];
		[cmd commit];
		last = cmd;
		enc = nil;
		cmd = nil;
		nenc = 0;
	}
}

int
mtlrun(Mtlop *o)
{
	Kop k;
	id<MTLBuffer> db, sb, mb;
	int i;

	if(o->kind < 1 || o->kind > 4 || o->w <= 0 || o->h <= 0)
		return 0;
	memset(&k, 0, sizeof k);
	k.w = o->w;
	k.h = o->h;
	k.dstride = o->dstride;
	k.dnb = o->dnb;
	for(i = 0; i < 4; i++){
		k.dsh[i] = o->dshift[i];
		k.ssh[i] = o->sshift[i];
	}
	k.sstride = o->sstride;
	k.mstride = o->mstride;
	k.value = o->value;
	k.hassrc = o->src != nil;

	pthread_mutex_lock(&lk);
	@autoreleasepool {
		sb = mb = nil;
		db = region(o->dst, (o->h-1)*o->dstride + o->w*o->dnb, &k.doff);
		if(o->src != nil)
			sb = region(o->src, (o->h-1)*o->sstride + o->w*(o->kind == 2 ? o->dnb : 4), &k.soff);
		if(o->mask != nil)
			mb = region(o->mask, (o->h-1)*o->mstride + o->w, &k.moff);
		if(db == nil || (o->src != nil && sb == nil) || (o->mask != nil && mb == nil)){
			pthread_mutex_unlock(&lk);
			return 0;
		}
		if(enc == nil){
			cmd = [queue commandBuffer];
			enc = [cmd computeCommandEncoder];	/* serial: each dispatch sees the last's writes */
		}
		[enc setComputePipelineState:pipes[o->kind]];
		[enc setBuffer:db offset:0 atIndex:0];
		[enc setBuffer:(sb != nil ? sb : db) offset:0 atIndex:1];
		[enc setBuffer:(mb != nil ? mb : db) offset:0 atIndex:2];
		[enc setBytes:&k length:sizeof k atIndex:3];
		[enc dispatchThreads:MTLSizeMake(o->w, o->h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		if(++nenc >= Nbatch)
			submit();
	}
	pthread_mutex_unlock(&lk);
	return 1;
}

void
mtlsync(void)
{
	pthread_mutex_lock(&lk);
	@autoreleasepool {
		submit();
		if(last != nil){
			[last waitUntilCompleted];
			last = nil;
		}
	}
	pthread_mutex_unlock(&lk);
}
