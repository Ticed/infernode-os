implement AAdraw;

#
# aadraw — anti-aliased geometry for Limbo Draw clients (see aadraw.m),
# now a thin layer over Draw's paths (Image.fillpath, Image.strokepath),
# which the draw device rasterises.  Points are pixel centres, as for
# Draw's line and ellipse.
#

include "sys.m";
include "draw.m";
	draw: Draw;
	Display, Image, Path, Point: import draw;
include "aadraw.m";

init(nil: ref Display)
{
	draw = load Draw Draw->PATH;
}

c(v: int): real
{
	return real v + 0.5;
}

line(dst: ref Image, p0, p1: Point, w: int, src: ref Image)
{
	polyline(dst, array[] of {p0, p1}, w, src);
}

polyline(dst: ref Image, pts: array of Point, w: int, src: ref Image)
{
	if(len pts < 2)
		return;
	if(w < 1)
		w = 1;
	p := Path.new().moveto(c(pts[0].x), c(pts[0].y));
	for(i := 1; i < len pts; i++)
		p.lineto(c(pts[i].x), c(pts[i].y));
	dst.strokepath(p, real w, Draw->Capround, Draw->Joinround, src, pts[0]);
}

ring(dst: ref Image, ctr: Point, a, b, w: int, src: ref Image)
{
	if(a < 1 || b < 1)
		return;
	if(w < 1)
		w = 1;
	p := Path.new().ellipse(c(ctr.x), c(ctr.y), real a, real b);
	dst.strokepath(p, real w, Draw->Capbutt, Draw->Joinround, src, ctr);
}

disc(dst: ref Image, ctr: Point, a, b: int, src: ref Image)
{
	if(a < 1 || b < 1)
		return;
	p := Path.new().ellipse(c(ctr.x), c(ctr.y), real a, real b);
	dst.fillpath(p, ~0, src, ctr);
}

fillpoly(dst: ref Image, pts: array of Point, src: ref Image)
{
	if(len pts < 3)
		return;
	p := Path.new().moveto(c(pts[0].x), c(pts[0].y));
	for(i := 1; i < len pts; i++)
		p.lineto(c(pts[i].x), c(pts[i].y));
	dst.fillpath(p.close(), 1, src, pts[0]);
}
