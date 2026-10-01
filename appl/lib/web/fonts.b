implement Fonts;

#
# Faces for the web engine.  See module/web/fonts.m.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;
include "outlinefont.m";
	ofont: OutlineFont;
	Face: import ofont;
include "web/fonts.m";

# bitmap fallbacks for what the outlines lack (CJK, symbols), by size
fallbacksizes := array[] of {12, 14, 18, 24, 32, 48};
FALLBACK: con "/fonts/combined/unicode.sans.%d.font";

display: ref Display;

# the twelve shipped faces: family * 4 + (bold?1:0) + (italic?2:0)
Sans, Serif, Mono: con iota;
files := array[] of {
	"DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans-Oblique.ttf", "DejaVuSans-BoldOblique.ttf",
	"DejaVuSerif.ttf", "DejaVuSerif-Bold.ttf", "DejaVuSerif-Italic.ttf", "DejaVuSerif-BoldItalic.ttf",
	"DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf", "DejaVuSansMono-Oblique.ttf", "DejaVuSansMono-BoldOblique.ttf",
};
loaded: array of ref OutlineFont->Face;
fallbacks: array of ref Font;

# faces made, by (file, size)
Nfaces: con 64;
cache: array of list of ref Typeface;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	ofont = load OutlineFont OutlineFont->PATH;
	if(ofont == nil)
		return sys->sprint("cannot load %s: %r", OutlineFont->PATH);
	display = d;
	ofont->init(d);
	loaded = array[len files] of ref OutlineFont->Face;
	cache = array[Nfaces] of list of ref Typeface;
	fallbacks = array[len fallbacksizes] of ref Font;
	return nil;
}

# the bitmap font nearest in size, opened on first use
fallback(size: real): ref Font
{
	if(display == nil)
		return nil;
	k := 0;
	for(i := 1; i < len fallbacksizes; i++)
		if(real fallbacksizes[i] <= size + 1.0)
			k = i;
	if(fallbacks[k] == nil)
		fallbacks[k] = Font.open(display, sys->sprint(FALLBACK, fallbacksizes[k]));
	return fallbacks[k];
}

loadface(i: int): ref OutlineFont->Face
{
	if(loaded[i] != nil)
		return loaded[i];
	fd := sys->open(DIR + "/" + files[i], Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, dir) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	data := array[int dir.length] of byte;
	n := 0;
	while(n < len data) {
		k := sys->read(fd, data[n:], len data - n);
		if(k <= 0)
			break;
		n += k;
	}
	(f, nil) := ofont->open(data[0:n], "ttf");
	loaded[i] = f;
	return f;
}

# which shipped family stands in for a CSS family name, or -1
family(nm: string): int
{
	case nm {
	"serif" or "ui-serif" or "times" or "times new roman" or "georgia" or "garamond" or
	"cambria" or "palatino" or "palatino linotype" or "book antiqua" or "baskerville" or
	"linux libertine" or "libertinus serif" or "noto serif" or "dejavu serif" or
	"liberation serif" or "source serif pro" or "merriweather" or "charter" or "iowan old style" =>
		return Serif;
	"monospace" or "ui-monospace" or "courier" or "courier new" or "consolas" or "menlo" or
	"monaco" or "sf mono" or "sfmono-regular" or "dejavu sans mono" or "liberation mono" or
	"source code pro" or "fira code" or "fira mono" or "jetbrains mono" or "roboto mono" or
	"ubuntu mono" or "lucida console" or "andale mono" or "cascadia code" or "ibm plex mono" =>
		return Mono;
	"sans-serif" or "system-ui" or "ui-sans-serif" or "-apple-system" or "blinkmacsystemfont" or
	"segoe ui" or "roboto" or "helvetica" or "helvetica neue" or "arial" or "verdana" or
	"tahoma" or "trebuchet ms" or "open sans" or "inter" or "noto sans" or "ubuntu" or
	"cantarell" or "fira sans" or "liberation sans" or "dejavu sans" or "lato" or "montserrat" or
	"source sans pro" or "pt sans" or "lucida grande" or "geneva" or "ibm plex sans" or
	"cursive" or "fantasy" or "math" or "emoji" =>
		return Sans;
	}
	return -1;
}

face(families: list of string, weight, italic: int, size: real): ref Typeface
{
	fam := Serif;
	for(l := families; l != nil; l = tl l)
		if((fi := family(hd l)) >= 0) {
			fam = fi;
			break;
		}
	i := fam*4;
	if(weight >= 600)
		i += 1;
	if(italic)
		i += 2;
	if(size < 1.0)
		size = 1.0;
	h := (i*131 + int (size*4.0)) % Nfaces;
	for(cl := cache[h]; cl != nil; cl = tl cl) {
		c := hd cl;
		if(c.size == size && c.outline == loaded[i])
			return c;
	}
	o := loadface(i);
	if(o == nil)
		o = loadface(fam*4);
	if(o == nil)
		return nil;
	asc := real o.ascent * size / real o.upem;
	desc := real -o.descent * size / real o.upem;
	f := ref Typeface(o, size, asc, desc, asc + desc, 0.0, fallback(size));
	f.space = advance(f, ' ');
	cache[h] = f :: cache[h];
	return f;
}

advance(f: ref Typeface, c: int): real
{
	g := f.outline.lookup(c);
	if(g < 0) {
		if(f.fallback != nil) {
			s := "";
			s[0] = c;
			return real f.fallback.width(s);
		}
		g = 0;
	}
	return f.outline.advance(g, f.size);
}

Typeface.width(f: self ref Typeface, s: string): real
{
	w := 0.0;
	for(i := 0; i < len s; i++)
		w += advance(f, s[i]);
	return w;
}

Typeface.draw(f: self ref Typeface, dst: ref Image, p: Point, s: string, src: ref Image): real
{
	x := real p.x;
	for(i := 0; i < len s; i++) {
		c := s[i];
		g := f.outline.lookup(c);
		if(g < 0 && f.fallback != nil) {
			t := "";
			t[0] = c;
			# bitmap fallback: align its baseline with ours
			dst.text(Point(int x, p.y - f.fallback.ascent), src, Point(0, 0), f.fallback, t);
			x += real f.fallback.width(t);
			continue;
		}
		if(c != ' ' && c != ' ')
			f.outline.drawglyph(g, f.size, dst, Point(int x, p.y), src);
		x += f.outline.advance(g, f.size);
	}
	return x - real p.x;
}
