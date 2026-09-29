#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "memlayer.h"

/*
 * Anti-aliased rasterisation: the exact area of each pixel inside a
 * polygon, in integer arithmetic.
 *
 * Every edge adds, to each pixel cell it crosses, two numbers: cover,
 * the signed height it spans in the cell, and area, that height times
 * twice its mean distance from the cell's left side.  Walking a row
 * from the left, the running sum of cover is the winding of the space
 * to the right of the cells passed, and a pixel's covered area is
 *	(2*Aaone*cover so far - area of the cell) / (2*Aaone*Aaone),
 * signed by winding; the fill rule turns winding into coverage.  This
 * is the method of FreeType's grey rasteriser and of font-rs.
 *
 * Rows are accumulated a band at a time, and each band is drawn with
 * one memimagedraw through a GREY8 mask of its coverage, so what the
 * source does to the destination is exactly what it would do through
 * any mask: every op, every channel format.
 */

enum
{
	Band	= 16,		/* rows accumulated at once */
	Full	= 2*Aaone*Aaone,	/* the area of a whole pixel, doubled */
};

void
aapolyinit(Aapoly *p)
{
	memset(p, 0, sizeof *p);
	p->bb = Rect(Aamaxcoord, Aamaxcoord, -Aamaxcoord, -Aamaxcoord);
}

void
aapolyfree(Aapoly *p)
{
	free(p->e);
	aapolyinit(p);
}

/*
 * An edge of a closed polygon, from p to q.  The polygon's edges may
 * come in any order; only their directions matter.
 */
void
aapolyedge(Aapoly *p, Point a, Point b)
{
	Aaedge *e;
	int n;

	if(p->err || a.y == b.y)
		return;
	if(p->ne == p->nalloc){
		n = p->nalloc*2;
		if(n == 0)
			n = 64;
		e = realloc(p->e, n*sizeof(Aaedge));
		if(e == nil){
			p->err = 1;
			return;
		}
		p->e = e;
		p->nalloc = n;
	}
	e = &p->e[p->ne++];
	if(a.y < b.y){
		e->x0 = a.x; e->y0 = a.y;
		e->x1 = b.x; e->y1 = b.y;
		e->dir = 1;
	}else{
		e->x0 = b.x; e->y0 = b.y;
		e->x1 = a.x; e->y1 = a.y;
		e->dir = -1;
	}
	if(a.x < p->bb.min.x) p->bb.min.x = a.x;
	if(b.x < p->bb.min.x) p->bb.min.x = b.x;
	if(a.x > p->bb.max.x) p->bb.max.x = a.x;
	if(b.x > p->bb.max.x) p->bb.max.x = b.x;
	if(e->y0 < p->bb.min.y) p->bb.min.y = e->y0;
	if(e->y1 > p->bb.max.y) p->bb.max.y = e->y1;
}

/* The pixels the polygon touches. */
Rectangle
aapixels(Aapoly *p)
{
	Rectangle r;

	if(p->ne == 0)
		return Rect(0, 0, 0, 0);
	r.min.x = p->bb.min.x >> Aashift;
	r.min.y = p->bb.min.y >> Aashift;
	r.max.x = (p->bb.max.x + Aaone-1) >> Aashift;
	r.max.y = (p->bb.max.y + Aaone-1) >> Aashift;
	if(r.max.x == r.min.x)
		r.max.x++;
	return r;
}

typedef struct Acc Acc;
struct Acc
{
	int	*cover;
	int	*area;
	int	w;	/* cells in a row */
	int	x0;	/* the pixel x of cell 0 */
	int	y0;	/* the pixel y of the band's first row */
};

/*
 * Add a piece of an edge that lies in cell c of row r.  Cells left of
 * the clip only add cover: everything to their right, including the
 * first cell in the clip, is inside by the height they span.  Cells
 * right of the clip change nothing in it.
 */
static void
addcell(Acc *a, int r, int c, int cover, int area)
{
	int i;

	c -= a->x0;
	if(c >= a->w)
		return;
	i = (r - a->y0)*(a->w+1);
	if(c < 0){
		a->cover[i] += cover;
		return;
	}
	a->cover[i+c] += cover;
	a->area[i+c] += area;
}

/*
 * The piece of an edge within row r, from (xa, ya) to (xb, yb), the y
 * values relative to the top of the row, split at cell boundaries.
 */
static void
cells(Acc *a, int r, int xa, int ya, int xb, int yb, int dir)
{
	int c, cend, x, y, nx, ny, dx, dy, lx, h;

	dx = xb - xa;
	dy = yb - ya;
	if(dy == 0)
		return;
	if(dx == 0){
		c = xa >> Aashift;
		lx = xa - (c << Aashift);
		h = dy*dir;
		addcell(a, r, c, h, h*2*lx);
		return;
	}
	x = xa;
	y = ya;
	if(dx > 0){
		c = xa >> Aashift;
		cend = (xb-1) >> Aashift;
		for(; c <= cend; c++){
			nx = (c+1) << Aashift;
			if(nx >= xb){
				nx = xb;
				ny = yb;
			}else
				ny = ya + (vlong)(nx - xa)*dy/dx;
			h = (ny - y)*dir;
			lx = c << Aashift;
			addcell(a, r, c, h, h*((x - lx) + (nx - lx)));
			x = nx;
			y = ny;
		}
	}else{
		c = (xa-1) >> Aashift;
		cend = xb >> Aashift;
		for(; c >= cend; c--){
			nx = c << Aashift;
			if(nx <= xb){
				nx = xb;
				ny = yb;
			}else
				ny = ya + (vlong)(nx - xa)*dy/dx;
			h = (ny - y)*dir;
			lx = c << Aashift;
			addcell(a, r, c, h, h*((x - lx) + (nx - lx)));
			x = nx;
			y = ny;
		}
	}
}

/* Add the part of edge e in rows [r0, r1). */
static void
edgerows(Acc *a, Aaedge *e, int r0, int r1)
{
	int r, ya, yb, xa, xb, top;
	vlong dx, dy;

	dx = e->x1 - e->x0;
	dy = e->y1 - e->y0;
	r = e->y0 >> Aashift;
	if(r < r0)
		r = r0;
	if(((e->y1 - 1) >> Aashift) + 1 < r1)
		r1 = ((e->y1 - 1) >> Aashift) + 1;
	for(; r < r1; r++){
		top = r << Aashift;
		ya = e->y0;
		if(ya < top)
			ya = top;
		yb = e->y1;
		if(yb > top + Aaone)
			yb = top + Aaone;
		xa = e->x0 + (ya - e->y0)*dx/dy;
		xb = e->x0 + (yb - e->y0)*dx/dy;
		cells(a, r, xa, ya - top, xb, yb - top, e->dir);
	}
}

/*
 * Sort the edges by their tops: a merge sort, stable, through t (as
 * many as e).  The library qsort swaps a byte at a time.
 */
static void
sortedges(Aaedge *e, Aaedge *t, int n)
{
	int w, lo, mid, hi, i, j, k;
	Aaedge *s, *d, *x;

	s = e;
	d = t;
	for(w = 1; w < n; w *= 2){
		for(lo = 0; lo < n; lo += 2*w){
			mid = lo + w;
			if(mid > n)
				mid = n;
			hi = lo + 2*w;
			if(hi > n)
				hi = n;
			i = lo;
			j = mid;
			for(k = lo; k < hi; k++)
				if(i < mid && (j >= hi || s[i].y0 <= s[j].y0))
					d[k] = s[i++];
				else
					d[k] = s[j++];
		}
		x = s;
		s = d;
		d = x;
	}
	if(s != e)
		memmove(e, s, n*sizeof(Aaedge));
}

/*
 * Winding (as area) to coverage, 0 to 255: even-odd when wind is 1,
 * else non-zero, as fillpoly takes it.
 */
static int
alpha(vlong v, int evenodd)
{
	if(v < 0)
		v = -v;
	if(evenodd){
		v &= 2*Full - 1;
		if(v > Full)
			v = 2*Full - v;
	}else if(v > Full)
		v = Full;
	return (v*255 + Full/2) / Full;
}

/*
 * Draw src through the polygon's coverage onto dst, which is not a
 * layer.  The polygon is offset by off pixels; the source pixel for
 * the destination pixel p is p+d.  Only pixels in clipr change.
 * Wind is as for fillpoly: 1 is even-odd, anything else non-zero.
 */
void
_memaadraw(Memimage *dst, Aapoly *poly, Point off, int wind, Memimage *src, Point d, Rectangle clipr, int op)
{
	Rectangle r, br, oclipr;
	Memimage *mask;
	Acc a;
	Aaedge *e, **act, *sorted;
	int i, n, nact, next, row, x, y, y0, y1, v, bx0, bx1, evenodd;
	vlong acc;
	uchar *m;

	if(poly->err)
		return;
	if(rectclip(&clipr, dst->r) == 0 || rectclip(&clipr, dst->clipr) == 0)
		return;
	evenodd = wind == 1;
	r = clipr;
	if(poly->ne == 0 || rectclip(&r, rectaddpt(aapixels(poly), off)) == 0)
		return;
	if(off.x != 0 || off.y != 0){
		for(i = 0; i < poly->ne; i++){
			e = &poly->e[i];
			e->x0 += off.x << Aashift;
			e->x1 += off.x << Aashift;
			e->y0 += off.y << Aashift;
			e->y1 += off.y << Aashift;
		}
	}
	a.w = Dx(r);
	a.x0 = r.min.x;
	n = Band*(a.w+1);
	sorted = nil;
	act = nil;
	a.cover = malloc(n*sizeof(int));
	a.area = malloc(n*sizeof(int));
	act = malloc((poly->ne+1)*sizeof(Aaedge*));
	sorted = malloc((poly->ne+1)*sizeof(Aaedge));
	mask = allocmemimage(Rect(0, 0, a.w, Band), GREY8);
	if(a.cover == nil || a.area == nil || act == nil || sorted == nil || mask == nil)
		goto Out;
	sortedges(poly->e, sorted, poly->ne);

	oclipr = dst->clipr;
	dst->clipr = clipr;
	nact = 0;
	next = 0;
	for(y0 = r.min.y; y0 < r.max.y; y0 = y1){
		y1 = y0 + Band;
		if(y1 > r.max.y)
			y1 = r.max.y;
		a.y0 = y0;
		memset(a.cover, 0, n*sizeof(int));
		memset(a.area, 0, n*sizeof(int));

		/* edges that reach this band */
		while(next < poly->ne && poly->e[next].y0 < y1 << Aashift)
			act[nact++] = &poly->e[next++];
		for(i = 0; i < nact; ){
			if(act[i]->y1 <= y0 << Aashift){
				act[i] = act[--nact];
				continue;
			}
			edgerows(&a, act[i], y0, y1);
			i++;
		}

		bx0 = a.w;
		bx1 = 0;
		for(y = y0; y < y1; y++){
			row = (y - y0)*(a.w+1);
			m = byteaddr(mask, Pt(0, y - y0));
			acc = 0;
			for(x = 0; x < a.w; x++){
				acc += a.cover[row+x];
				v = alpha((acc << (Aashift+1)) - a.area[row+x], evenodd);
				m[x] = v;
				if(v != 0){
					if(x < bx0)
						bx0 = x;
					if(x >= bx1)
						bx1 = x+1;
				}
			}
		}
		if(bx0 < bx1){
			br = Rect(r.min.x+bx0, y0, r.min.x+bx1, y1);
			memimagedraw(dst, br, src, addpt(br.min, d), mask, Pt(bx0, 0), op);
		}
	}
	dst->clipr = oclipr;

    Out:
	if(off.x != 0 || off.y != 0){
		for(i = 0; i < poly->ne; i++){
			e = &poly->e[i];
			e->x0 -= off.x << Aashift;
			e->x1 -= off.x << Aashift;
			e->y0 -= off.y << Aashift;
			e->y1 -= off.y << Aashift;
		}
	}
	free(a.cover);
	free(a.area);
	free(act);
	free(sorted);
	freememimage(mask);
}

/*
 * The same, onto any image: a layer is drawn a visible piece at a
 * time, and into its backing store, as memline does.
 */
typedef struct Laa Laa;
struct Laa
{
	Aapoly	*poly;
	int	wind;
	Memimage	*src;
	Point	off;	/* polygon to screen */
	Point	d;	/* screen pixel to source pixel */
	Point	delta;	/* the layer's, screen to backing store */
	Memlayer	*dstlayer;
	int	op;
};

static void _laadraw(Memimage*, Aapoly*, Point, int, Memimage*, Point, Rectangle, int);

static void
laaop(Memimage *dst, Rectangle screenr, Rectangle clipr, void *etc, int insave)
{
	Laa *l;

	l = etc;
	if(insave && l->dstlayer->save == nil)
		return;
	if(!rectclip(&clipr, screenr))
		return;
	if(insave)
		_laadraw(dst, l->poly, subpt(l->off, l->delta), l->wind, l->src,
			addpt(l->d, l->delta), rectsubpt(clipr, l->delta), l->op);
	else
		_laadraw(dst, l->poly, l->off, l->wind, l->src, l->d, clipr, l->op);
}

/*
 * The polygon, offset by off, drawn on dst; src pixel p+d for dst
 * pixel p; only pixels in clipr change.
 */
static void
_laadraw(Memimage *dst, Aapoly *poly, Point off, int wind, Memimage *src, Point d, Rectangle clipr, int op)
{
	Memlayer *dl;
	Rectangle r;
	Laa l;

	if(src->layer)	/* as memline: no layered source */
		return;
    Top:
	dl = dst->layer;
	if(dl == nil){
		_memaadraw(dst, poly, off, wind, src, d, clipr, op);
		return;
	}
	off = addpt(off, dl->delta);
	d = subpt(d, dl->delta);
	clipr = rectaddpt(clipr, dl->delta);
	if(dl->clear){
		dst = dl->screen->image;
		goto Top;
	}
	r = clipr;
	if(rectclip(&r, rectaddpt(aapixels(poly), off)) == 0)
		return;
	l.poly = poly;
	l.wind = wind;
	l.src = src;
	l.off = off;
	l.d = d;
	l.delta = dl->delta;
	l.dstlayer = dl;
	l.op = op;
	_memlayerop(laaop, dst, r, r, &l);
}

void
memaadraw(Memimage *dst, Aapoly *poly, int wind, Memimage *src, Point d, int op)
{
	_laadraw(dst, poly, Pt(0, 0), wind, src, d, dst->clipr, op);
}
