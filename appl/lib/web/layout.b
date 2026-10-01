implement Layout;

#
# Boxes.  See module/web/layout.m.
#
# The three passes are build (document to box tree), lay (box tree to
# geometry) and paint (geometry to pixels).  Each is a recursive walk;
# none keeps state between calls beyond the font and colour caches.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Path: import draw;
include "math.m";
	math: Math;
include "web/dom.m";
	dom: Dom;
	Doc, Node: import dom;
include "web/css.m";
	css: Css;
	Tok: import css;
include "web/style.m";
	style: Style;
	St, Len, Computed: import style;
include "outlinefont.m";
include "web/fonts.m";
	fonts: Fonts;
	Typeface: import fonts;
include "web/layout.m";

display: ref Display;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	dom = load Dom Dom->PATH;
	css = load Css Css->PATH;
	style = load Style Style->PATH;
	fonts = load Fonts Fonts->PATH;
	if(dom == nil || css == nil || style == nil || fonts == nil || math == nil)
		return sys->sprint("cannot load modules: %r");
	display = d;
	if((err := style->init()) != nil)
		return err;
	if((err = fonts->init(d)) != nil)
		return err;
	colors = array[Ncolors] of list of (int, ref Image);
	faces = array[Nfacecache] of list of (int, ref Typeface);
	return nil;
}

# ---- building the box tree ----

B: adt {
	d:	ref Doc;
	c:	ref Computed;
	counters:	list of (string, int);	# list-item numbering, innermost first
};

newbox(kind, inl, node: int, st: ref St): ref Box
{
	return ref Box(kind, inl, node, st, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, nil, nil, nil, 0, 0, nil, nil);
}

build(d: ref Doc, c: ref Computed): ref Box
{
	root := d.root();
	if(root == 0 || c.st[root] == nil)
		return newbox(Kblock, 0, 0, style->anon(nil, Style->Dblock));
	b := ref B(d, c, nil);
	l := element(b, root);
	if(l == nil)
		return newbox(Kblock, 0, 0, style->anon(nil, Style->Dblock));
	return hd l;
}

isblocklevel(x: ref Box): int
{
	return !x.inl;
}

# The boxes an element generates (usually one; none for display:none,
# several for display:contents or an inline split around a block).
element(b: ref B, n: int): list of ref Box
{
	st := b.c.st[n];
	if(st == nil || st.display == Style->Dnone)
		return nil;
	nd := b.d.nodes[n];
	if(st.display == Style->Dcontents)
		return children(b, n, st);
	if((r := replaced(b, n, st)) != nil)
		return r :: nil;
	kind := Kblock;
	inl := 0;
	case st.display {
	Style->Dinline =>
		kind = Kinline;
		inl = 1;
	Style->Dinlineblock =>
		inl = 1;
	Style->Dflex =>
		kind = Kflex;
	Style->Dinlineflex =>
		kind = Kflex;
		inl = 1;
	Style->Dgrid =>
		kind = Kgrid;
	Style->Dinlinegrid =>
		kind = Kgrid;
		inl = 1;
	Style->Dtable =>
		kind = Ktable;
	Style->Dinlinetable =>
		kind = Ktable;
		inl = 1;
	Style->Dtablerow =>
		kind = Krow;
	Style->Dtablecell =>
		kind = Kcell;
	}
	if(nd.tag == Dom->Tbr && nd.ns == Dom->HTML)
		return newbox(Kbr, 1, n, st) :: nil;
	box := newbox(kind, inl, n, st);
	pushed := 0;
	if(st.counterreset != nil || nd.tag == Dom->Tol || nd.tag == Dom->Tul || nd.tag == Dom->Tmenu) {
		start := 1;
		if(nd.tag == Dom->Tol && (s := b.d.attr(n, "start")) != nil)
			start = int s;
		b.counters = ("list-item", start - 1) :: b.counters;
		pushed = 1;
	}
	kids: list of ref Box;
	if(st.display == Style->Dlistitem)
		kids = marker(b, n, st) :: nil;
	if((bs := b.c.before[n]) != nil)
		kids = generated(b, n, bs) :: kids;
	for(l := children(b, n, st); l != nil; l = tl l)
		kids = hd l :: kids;
	if((as := b.c.after[n]) != nil)
		kids = generated(b, n, as) :: kids;
	if(pushed)
		b.counters = tl b.counters;
	kids = rev(kids);
	if(kind == Kinline) {
		# an inline box around blocks is split into inline pieces
		# either side of them (CSS 2.2 §9.2.1.1)
		hasblock := 0;
		for(l = kids; l != nil; l = tl l)
			if(isblocklevel(hd l))
				hasblock = 1;
		if(hasblock)
			return splitinline(box, kids);
	}
	box.kids = fixkids(box, kids);
	return box :: nil;
}

children(b: ref B, n: int, st: ref St): list of ref Box
{
	r: list of ref Box;
	for(c := b.d.nodes[n].first; c != 0; c = b.d.nodes[c].next) {
		cn := b.d.nodes[c];
		case cn.kind {
		Dom->Text =>
			t := newbox(Ktext, 1, c, st);
			t.text = cn.text;
			r = t :: r;
		Dom->Element =>
			for(l := element(b, c); l != nil; l = tl l)
				r = hd l :: r;
		}
	}
	return rev(r);
}

splitinline(box: ref Box, kids: list of ref Box): list of ref Box
{
	r: list of ref Box;
	run: list of ref Box;
	for(; kids != nil; kids = tl kids) {
		k := hd kids;
		if(isblocklevel(k)) {
			if(run != nil) {
				p := ref *box;
				p.kids = toarray(rev(run));
				r = p :: r;
				run = nil;
			}
			r = k :: r;
		} else
			run = k :: run;
	}
	if(run != nil) {
		p := ref *box;
		p.kids = toarray(rev(run));
		r = p :: r;
	}
	return rev(r);
}

# Children of a block container are all block-level or all inline-level:
# runs of inline-level boxes beside blocks go in anonymous blocks, and
# runs of nothing but collapsible white space are dropped.
fixkids(box: ref Box, kids: list of ref Box): array of ref Box
{
	if(box.kind == Kinline)
		return toarray(kids);
	nblock := 0;
	ninline := 0;
	for(l := kids; l != nil; l = tl l)
		if(isblocklevel(hd l))
			nblock++;
		else
			ninline++;
	# flex and grid items are blockified already; their text is wrapped
	if(nblock == 0 && box.kind != Kflex && box.kind != Kgrid)
		return toarray(kids);
	if(ninline == 0)
		return toarray(kids);
	r: list of ref Box;
	run: list of ref Box;
	for(l = kids; l != nil; l = tl l) {
		k := hd l;
		if(isblocklevel(k)) {
			if(run != nil && !blankrun(run))
				r = anonblock(box, rev(run)) :: r;
			run = nil;
			r = k :: r;
		} else
			run = k :: run;
	}
	if(run != nil && !blankrun(run))
		r = anonblock(box, rev(run)) :: r;
	return toarray(rev(r));
}

anonblock(parent: ref Box, kids: list of ref Box): ref Box
{
	a := newbox(Kblock, 0, 0, style->anon(parent.st, Style->Dblock));
	a.kids = toarray(kids);
	return a;
}

blankrun(l: list of ref Box): int
{
	for(; l != nil; l = tl l) {
		k := hd l;
		if(k.kind != Ktext)
			return 0;
		case k.st.whitespace {
		Style->Wpre or Style->Wprewrap or Style->Wbreakspaces =>
			return 0;
		}
		for(i := 0; i < len k.text; i++)
			if(!iswhite(k.text[i]))
				return 0;
	}
	return 1;
}

iswhite(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

# ::before and ::after: an inline box (or a block, per its display) holding
# the generated content.
generated(b: ref B, n: int, st: ref St): ref Box
{
	kind := Kinline;
	inl := 1;
	case st.display {
	Style->Dblock or Style->Dlistitem or Style->Dflowroot =>
		kind = Kblock;
		inl = 0;
	Style->Dinlineblock =>
		kind = Kblock;
	Style->Dflex =>
		kind = Kflex;
		inl = 0;
	}
	g := newbox(kind, inl, n, st);
	t := newbox(Ktext, 1, n, st);
	t.text = content(b, n, st);
	g.kids = array[] of {t};
	return g;
}

# The text of a content property.
content(b: ref B, n: int, st: ref St): string
{
	s := "";
	v := st.content;
	for(i := 0; i < len v; i++) {
		t := v[i];
		case t.kind {
		Css->Kstring =>
			s += t.s;
		Css->Kfunction =>
			case t.s {
			"attr" =>
				if(len t.kids > 0 && t.kids[0].kind == Css->Kident)
					s += b.d.attr(n, lower(t.kids[0].s));
			"counter" or "counters" =>
				if(len t.kids > 0 && t.kids[0].kind == Css->Kident) {
					v := counter(b, t.kids[0].s);
					sty := "decimal";
					for(k := 1; k < len t.kids; k++)
						if(t.kids[k].kind == Css->Kident)
							sty = lower(t.kids[k].s);
					s += markertext(sty, v);
				}
			}
		Css->Kident =>
			case lower(t.s) {
			"open-quote" =>
				s += "“";
			"close-quote" =>
				s += "”";
			}
		}
	}
	return s;
}

counter(b: ref B, nm: string): int
{
	for(l := b.counters; l != nil; l = tl l)
		if((hd l).t0 == nm)
			return (hd l).t1;
	return 0;
}

bumplistitem(b: ref B, n: int): int
{
	v := 1;
	if((s := b.d.attr(n, "value")) != nil) {
		v = int s;
		if(b.counters != nil && (hd b.counters).t0 == "list-item")
			b.counters = ("list-item", v) :: tl b.counters;
		return v;
	}
	if(b.counters != nil && (hd b.counters).t0 == "list-item") {
		v = (hd b.counters).t1 + 1;
		b.counters = ("list-item", v) :: tl b.counters;
	}
	return v;
}

marker(b: ref B, n: int, st: ref St): ref Box
{
	v := bumplistitem(b, n);
	m := newbox(Kmarker, 1, n, st);
	ms := b.c.marker[n];
	if(ms != nil && ms.content != nil)
		m.text = content(b, n, ms);
	else
		m.text = markertext(st.liststyle, v);
	if(ms != nil)
		m.st = ms;
	return m;
}

markertext(ls: string, v: int): string
{
	if(len ls > 0 && ls[0] == '"')
		return ls[1:];
	case ls {
	"none" =>
		return "";
	"disc" =>
		return "• ";
	"circle" =>
		return "◦ ";
	"square" =>
		return "▪ ";
	"disclosure-closed" =>
		return "▸ ";
	"disclosure-open" =>
		return "▾ ";
	"decimal-leading-zero" =>
		if(v < 10 && v >= 0)
			return "0" + string v + ". ";
		return string v + ". ";
	"lower-alpha" or "lower-latin" =>
		return alpha(v, 'a') + ". ";
	"upper-alpha" or "upper-latin" =>
		return alpha(v, 'A') + ". ";
	"lower-roman" =>
		return lower(roman(v)) + ". ";
	"upper-roman" =>
		return roman(v) + ". ";
	"lower-greek" =>
		return alpha(v, 16r3b1) + ". ";
	}
	return string v + ". ";
}

alpha(v, base: int): string
{
	if(v <= 0)
		return string v;
	s := "";
	while(v > 0) {
		v--;
		c := "";
		c[0] = base + v % 26;
		s = c + s;
		v /= 26;
	}
	return s;
}

roman(v: int): string
{
	if(v <= 0 || v >= 4000)
		return string v;
	vals := array[] of {1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1};
	syms := array[] of {"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"};
	s := "";
	for(i := 0; i < len vals; i++)
		while(v >= vals[i]) {
			s += syms[i];
			v -= vals[i];
		}
	return s;
}

# Replaced and form-control elements.
replaced(b: ref B, n: int, st: ref St): ref Box
{
	nd := b.d.nodes[n];
	inl := 1;
	case st.display {
	Style->Dblock or Style->Dlistitem or Style->Dflowroot or Style->Dflex or Style->Dgrid or Style->Dtable =>
		inl = 0;
	}
	if(nd.ns == Dom->SVG && nd.name == "svg") {
		r := newbox(Kreplaced, inl, n, st);
		r.iw = dimattr(b.d.attr(n, "width"), 300);
		r.ih = dimattr(b.d.attr(n, "height"), 150);
		return r;
	}
	if(nd.ns != Dom->HTML)
		return nil;
	case nd.tag {
	Dom->Timg =>
		r := newbox(Kreplaced, inl, n, st);
		src := b.d.attr(n, "src");
		if(src != nil)
			r.url = style->resolveurl(b.d.url, src);
		r.text = b.d.attr(n, "alt");
		return r;
	Dom->Tvideo or Dom->Tcanvas or Dom->Tiframe or Dom->Tembed or Dom->Tobject =>
		r := newbox(Kreplaced, inl, n, st);
		r.iw = 300;
		r.ih = 150;
		if(nd.tag == Dom->Tvideo && (p := b.d.attr(n, "poster")) != nil)
			r.url = style->resolveurl(b.d.url, p);
		return r;
	Dom->Tinput =>
		t := lower(b.d.attr(n, "type"));
		r := newbox(Kreplaced, inl, n, st);
		case t {
		"checkbox" or "radio" =>
			r.iw = r.ih = 13;
		"submit" or "reset" or "button" =>
			r.text = b.d.attr(n, "value");
			if(r.text == nil)
				case t {
				"submit" => r.text = "Submit";
				"reset" => r.text = "Reset";
				}
		"image" =>
			if((src := b.d.attr(n, "src")) != nil)
				r.url = style->resolveurl(b.d.url, src);
		"range" =>
			r.iw = 129;
			r.ih = 16;
		"color" =>
			r.iw = 50;
			r.ih = 27;
		* =>
			r.text = b.d.attr(n, "value");
			if(r.text == "")
				r.text = b.d.attr(n, "placeholder");
			r.iw = int (st.fontsize * 10.0);	# about 20 characters
		}
		return r;
	Dom->Ttextarea =>
		r := newbox(Kreplaced, inl, n, st);
		r.text = b.d.textof(n);
		r.iw = int (st.fontsize * 10.0);
		r.ih = int (st.fontsize * 2.4);
		return r;
	Dom->Tselect =>
		r := newbox(Kreplaced, inl, n, st);
		# the first selected option, else the first
		sel := "";
		for(o := nd.first; o != 0; o = next(b.d, o, n))
			if(b.d.nodes[o].tag == Dom->Toption) {
				if(sel == "" || b.d.hasattr(o, "selected"))
					sel = b.d.textof(o);
				if(b.d.hasattr(o, "selected"))
					break;
			}
		r.text = squash(sel) + " ▾";
		return r;
	}
	return nil;
}

next(d: ref Doc, n, top: int): int
{
	if(d.nodes[n].first != 0)
		return d.nodes[n].first;
	while(n != top && n != 0) {
		if(d.nodes[n].next != 0)
			return d.nodes[n].next;
		n = d.nodes[n].parent;
	}
	return 0;
}

dimattr(s: string, dflt: int): int
{
	if(s == nil)
		return dflt;
	v := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		v = v*10 + s[i] - '0';
	if(i == 0 || i < len s && s[i] == '%')
		return dflt;
	return v;
}

squash(s: string): string
{
	r := "";
	sp := 1;
	for(i := 0; i < len s; i++)
		if(iswhite(s[i])) {
			if(!sp)
				r[len r] = ' ';
			sp = 1;
		} else {
			r[len r] = s[i];
			sp = 0;
		}
	if(len r > 0 && r[len r - 1] == ' ')
		r = r[0:len r - 1];
	return r;
}

rev(l: list of ref Box): list of ref Box
{
	r: list of ref Box;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

toarray(l: list of ref Box): array of ref Box
{
	a := array[len l] of ref Box;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			break;
	if(i == len s)
		return s;
	r := s;
	for(; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

# ---- geometry ----

L: adt {
	vw, vh:	int;		# viewport, for fixed boxes (and the root)
	root:	ref Box;
};

Margin: adt {
	pos, neg:	int;	# largest positive, most negative
};

collapse(a, b: Margin): Margin
{
	if(b.pos > a.pos)
		a.pos = b.pos;
	if(b.neg < a.neg)
		a.neg = b.neg;
	return a;
}

mval(m: int): Margin
{
	if(m < 0)
		return Margin(0, m);
	return Margin(m, 0);
}

msum(m: Margin): int
{
	return m.pos + m.neg;
}

lay(root: ref Box, width, height: int)
{
	l := ref L(width, height, root);
	edges(root, width);
	sizew(root, width);
	layblock(l, root, width, height);
	root.x = root.ml;
	root.y = root.mt;
}

ir(x: real): int
{
	return int x;	# rounds
}

res(v: Len, basis: int): int
{
	return ir(v.resolve(real basis));
}

# used padding, borders and margins (auto margins as 0, for now)
edges(b: ref Box, cbw: int)
{
	st := b.st;
	b.bt = st.bt;
	b.br = st.br;
	b.bb = st.bb;
	b.bl = st.bl;
	b.pt = res(st.pt, cbw);
	b.pr = res(st.pr, cbw);
	b.pb = res(st.pb, cbw);
	b.pl = res(st.pl, cbw);
	b.mt = res(st.mt, cbw);
	b.mr = res(st.mr, cbw);
	b.mb = res(st.mb, cbw);
	b.ml = res(st.ml, cbw);
	if(b.kind == Kinline || b.kind == Ktext) {
		# vertical margins of inline boxes have no effect on layout
		b.mt = b.mb = 0;
	}
}

hextra(b: ref Box): int
{
	return b.bl + b.br + b.pl + b.pr;
}

vextra(b: ref Box): int
{
	return b.bt + b.bb + b.pt + b.pb;
}

# a specified width as a border-box width, or -1 for auto
specw(b: ref Box, v: Len, cbw: int): int
{
	case v.kind {
	Style->Lpx or Style->Lcalc =>
		if(cbw < 0 && v.kind == Style->Lpx && v.pct != 0.0)
			return -1;
		w := res(v, cbw);
		if(!b.st.borderbox)
			w += hextra(b);
		return w;
	Style->Lmin or Style->Lmax or Style->Lfit =>
		(mn, mx) := intrinsic(b);
		case v.kind {
		Style->Lmin => return mn;
		Style->Lmax => return mx;
		}
		return fit(mn, mx, cbw - b.ml - b.mr);
	}
	return -1;
}

spech(b: ref Box, v: Len, cbh: int): int
{
	case v.kind {
	Style->Lpx or Style->Lcalc =>
		if(cbh < 0 && (v.kind == Style->Lcalc || v.pct != 0.0))
			return -1;
		h := res(v, cbh);
		if(!b.st.borderbox)
			h += vextra(b);
		return h;
	}
	return -1;
}

fit(mn, mx, avail: int): int
{
	w := avail;
	if(w > mx)
		w = mx;
	if(w < mn)
		w = mn;
	return w;
}

# Clamp a border-box width by min-width and max-width.
clampw(b: ref Box, w, cbw: int): int
{
	if(b.st.maxwidth.kind != Style->Lnone) {
		mx := specw(b, b.st.maxwidth, cbw);
		if(mx >= 0 && w > mx)
			w = mx;
	}
	mn := specw(b, b.st.minwidth, cbw);
	if(mn >= 0 && w < mn)
		w = mn;
	if(w < hextra(b))
		w = hextra(b);
	return w;
}

clamph(b: ref Box, h, cbh: int): int
{
	if(b.st.maxheight.kind != Style->Lnone) {
		mx := spech(b, b.st.maxheight, cbh);
		if(mx >= 0 && h > mx)
			h = mx;
	}
	mn := spech(b, b.st.minheight, cbh);
	if(mn >= 0 && h < mn)
		h = mn;
	if(h < vextra(b))
		h = vextra(b);
	return h;
}

# Does b establish a new block formatting context?
isbfc(b: ref Box): int
{
	st := b.st;
	if(b.inl || b.kind != Kblock)
		return 1;
	if(st.float != Style->Fnone || st.position == Style->Pabsolute || st.position == Style->Pfixed)
		return 1;
	if(st.overflowx != Style->Ovisible || st.overflowy != Style->Ovisible)
		return 1;
	case st.display {
	Style->Dflowroot or Style->Dtablecell or Style->Dtablecaption or Style->Dinlineblock =>
		return 1;
	}
	return 0;
}

# The used width of a block-level box in a containing block cbw wide
# (CSS 2.2 §10.3.3): auto fills, auto margins centre.
sizew(b: ref Box, cbw: int)
{
	st := b.st;
	w := specw(b, st.width, cbw);
	if(w < 0) {
		if(b.kind == Kreplaced) {
			(iw, nil) := replacedsize(b, cbw, -1);
			w = iw + hextra(b);
		} else if(b.kind == Ktable && st.width.kind == Style->Lauto) {
			(mn, mx) := intrinsic(b);
			w = fit(mn, mx, cbw - b.ml - b.mr);
		} else {
			# auto: fill, but if min/max-width step in, auto
			# margins take up the difference
			w = cbw - b.ml - b.mr;
			cw := clampw(b, w, cbw);
			b.w = cw;
			if(cw == w)
				return;
			w = cw;
		}
	}
	w = clampw(b, w, cbw);
	b.w = w;
	# auto margins share what is left over
	free := cbw - w - b.ml - b.mr;
	lauto := st.ml.kind == Style->Lauto;
	rauto := st.mr.kind == Style->Lauto;
	if(lauto && rauto) {
		b.ml = free/2;
		if(b.ml < 0)
			b.ml = 0;
		b.mr = cbw - w - b.ml;
	} else if(lauto)
		b.ml += free;
	else if(rauto)
		b.mr += free;
}

# Lay out a block-level box whose width is settled; set its height and
# its children's geometry.  Returns its top and bottom margins, collapsed
# with any of its children's that adjoin them, and whether its own
# margins collapse through it.
layblock(l: ref L, b: ref Box, cbw, cbh: int): (Margin, Margin, int)
{
	case b.kind {
	Kreplaced =>
		(nil, ih) := replacedsize(b, cbw, cbh);
		h := spech(b, b.st.height, cbh);
		if(h < 0)
			h = ih + vextra(b);
		b.h = clamph(b, h, cbh);
		return (mval(b.mt), mval(b.mb), 0);
	}
	cw := b.w - hextra(b);
	if(cw < 0)
		cw = 0;
	sh := spech(b, b.st.height, cbh);
	ch := -1;		# content height for percentages inside
	if(sh >= 0)
		ch = sh - vextra(b);
	bfc := isbfc(b) || b == l.root;	# the root holds the initial formatting context
	passtop := !bfc && b.bt == 0 && b.pt == 0;
	passbot := !bfc && b.bb == 0 && b.pb == 0 && sh < 0;
	top := mval(b.mt);
	bot := mval(b.mb);
	contenth := 0;
	empty := 0;
	if(haslines(b)) {
		contenth = layinline(l, b, cw);
		passtop = passbot = 0;
	} else {
		pending := Margin(0, 0);
		cury := 0;
		adjoining := passtop;	# still at the top, margins adjoin ours
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			edges(k, cw);
			sizew(k, cw);
			(kt, kb, kempty) := layblock(l, k, cw, ch);
			k.x = b.bl + b.pl + k.ml;
			if(kempty) {
				# margins collapse through an empty box
				m := collapse(kt, kb);
				if(adjoining)
					top = collapse(top, m);
				else
					pending = collapse(pending, m);
				k.y = b.bt + b.pt + cury;
				continue;
			}
			if(adjoining) {
				top = collapse(top, kt);
				k.y = b.bt + b.pt + cury;
				adjoining = 0;
			} else {
				m := collapse(pending, kt);
				k.y = b.bt + b.pt + cury + msum(m);
			}
			cury = k.y - b.bt - b.pt + k.h;
			pending = kb;
		}
		if(adjoining) {
			# no in-flow content at all
			if(passbot && sh <= 0 && b.st.minheight.kind == Style->Lpx && b.st.minheight.px == 0.0 &&
			   b.st.minheight.pct == 0.0 && b.kind == Kblock) {
				empty = 1;
				top = collapse(top, pending);
			}
		} else if(passbot)
			bot = collapse(bot, pending);
		else
			cury += msum(pending);
		contenth = cury;
	}
	h := sh;
	if(h < 0)
		h = contenth + vextra(b);
	b.h = clamph(b, h, cbh);
	if(empty && b.h != 0)
		empty = 0;
	return (top, bot, empty);
}

haslines(b: ref Box): int
{
	if(b.kind != Kblock && b.kind != Kcell && b.kind != Kflex && b.kind != Kgrid && b.kind != Ktable && b.kind != Krow)
		return 0;
	for(i := 0; i < len b.kids; i++)
		if(b.kids[i].inl)
			return 1;
	return 0;
}

# A replaced element's content size: (width, height).
replacedsize(b: ref Box, cbw, cbh: int): (int, int)
{
	iw := b.iw;
	ih := b.ih;
	if(b.img != nil && iw == 0 && ih == 0) {
		iw = b.img.r.dx();
		ih = b.img.r.dy();
	}
	if(b.text != nil && b.iw == 0 && b.img == nil && b.node != 0) {
		# a form control or an image's alt text: size to the text
		f := face(b.st);
		iw = ir(f.width(b.text)) + 2;
		ih = ir(lineheight(b.st, f));
	}
	st := b.st;
	w := -1;
	h := -1;
	if(st.width.kind == Style->Lpx || st.width.kind == Style->Lcalc) {
		if(!(cbw < 0 && st.width.pct != 0.0)) {
			w = res(st.width, cbw);
			if(st.borderbox)
				w -= hextra(b);
		}
	}
	if(st.height.kind == Style->Lpx && (st.height.pct == 0.0 || cbh >= 0)) {
		h = res(st.height, cbh);
		if(st.borderbox)
			h -= vextra(b);
	}
	ratio := st.aspect;
	if(ratio == 0.0 && iw > 0 && ih > 0)
		ratio = real iw / real ih;
	if(w < 0 && h < 0) {
		w = iw;
		h = ih;
	} else if(w < 0) {
		if(ratio > 0.0)
			w = ir(real h * ratio);
		else
			w = iw;
	} else if(h < 0) {
		if(ratio > 0.0)
			h = ir(real w / ratio);
		else
			h = ih;
	}
	if(w < 0)
		w = 0;
	if(h < 0)
		h = 0;
	return (w, h);
}

# ---- intrinsic widths (CSS Sizing 3) ----

# (min-content, max-content) border-box widths, plus margins.
intrinsic(b: ref Box): (int, int)
{
	ex := hextra(b) + nz(b.ml) + nz(b.mr);
	st := b.st;
	if(st.width.kind == Style->Lpx && st.width.pct == 0.0) {
		w := ir(st.width.px);
		if(!st.borderbox)
			w += hextra(b);
		return (w + nz(b.ml) + nz(b.mr), w + nz(b.ml) + nz(b.mr));
	}
	if(b.kind == Kreplaced) {
		(w, nil) := replacedsize(b, -1, -1);
		return (w + ex, w + ex);
	}
	mn := 0;
	mx := 0;
	if(haslines(b) || b.kind == Kinline) {
		(mn, mx) = inlineintrinsic(b);
	} else if(b.kind == Kflex && b.st.flexdir < 2 || b.kind == Krow) {
		# a row: maxima add up
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			edges(k, 0);
			(kmn, kmx) := intrinsic(k);
			if(b.st.flexwrap != 0) {
				if(kmn > mn)
					mn = kmn;
			} else
				mn += kmn;
			mx += kmx;
		}
	} else {
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			edges(k, 0);
			(kmn, kmx) := intrinsic(k);
			if(kmn > mn)
				mn = kmn;
			if(kmx > mx)
				mx = kmx;
		}
	}
	return (mn + ex, mx + ex);
}

nz(m: int): int
{
	if(m < 0)
		return 0;
	return m;
}

inlineintrinsic(b: ref Box): (int, int)
{
	items := flatten(b);
	mn := 0.0;
	mx := 0.0;
	line := 0.0;
	word := 0.0;
	for(l := items; l != nil; l = tl l) {
		it := hd l;
		case it.kind {
		Iword =>
			w := it.w;
			if(it.nowrap)
				word += w;
			else
				word = w;
			if(word > mn)
				mn = word;
			line += w;
		Ispace =>
			if(!it.nowrap)
				word = 0.0;
			line += it.w;
		Iopen or Iclose =>
			line += it.w;
			word += it.w;
		Iatomic =>
			(kmn, kmx) := intrinsic(it.box);
			if(real kmn > mn)
				mn = real kmn;
			line += real kmx;
			word = 0.0;
		Ibreak =>
			if(line > mx)
				mx = line;
			line = 0.0;
			word = 0.0;
		}
	}
	if(line > mx)
		mx = line;
	return (ir(mn + 0.49), ir(mx + 0.49));
}

# ---- inline formatting (CSS 2.2 §9.4.2, §10.8; CSS Text 3) ----

Iword, Ispace, Iopen, Iclose, Iatomic, Ibreak: con iota;

Item: adt {
	kind:	int;
	text:	string;
	w:	real;
	box:	ref Box;	# text run, inline box or atomic box
	face:	ref Typeface;
	nowrap:	int;		# no soft wrap here
	deco:	int;
	decocolor:	int;
};

Fl: adt {
	items:	list of ref Item;	# reversed
	space:	int;		# the last thing emitted was a collapsible space
	deco:	int;
	decocolor:	int;
};

# The inline content of b as a list of items, white space processed.
flatten(b: ref Box): list of ref Item
{
	f := ref Fl(nil, 1, b.st.decoration, b.st.decorationcolor);
	for(i := 0; i < len b.kids; i++)
		flat(f, b.kids[i]);
	r: list of ref Item;
	for(l := f.items; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

emit(f: ref Fl, it: ref Item)
{
	f.items = it :: f.items;
}

flat(f: ref Fl, b: ref Box)
{
	case b.kind {
	Ktext =>
		text(f, b);
	Kmarker =>
		markeritem(f, b);
	Kbr =>
		emit(f, ref Item(Ibreak, nil, 0.0, b, nil, 0, 0, 0));
		f.space = 1;
	Kinline =>
		edges(b, 0);
		odeco := f.deco;
		ocol := f.decocolor;
		if(b.st.decoration != 0) {
			f.deco |= b.st.decoration;
			f.decocolor = b.st.decorationcolor;
		}
		emit(f, ref Item(Iopen, nil, real (b.ml + b.bl + b.pl), b, nil, 0, 0, 0));
		for(i := 0; i < len b.kids; i++)
			flat(f, b.kids[i]);
		emit(f, ref Item(Iclose, nil, real (b.mr + b.br + b.pr), b, nil, 0, 0, 0));
		f.deco = odeco;
		f.decocolor = ocol;
	* =>
		emit(f, ref Item(Iatomic, nil, 0.0, b, nil, 0, 0, 0));
		f.space = 0;
	}
}

# A list marker is one unbreakable piece; outside the content it takes
# no room on the line.
markeritem(f: ref Fl, b: ref Box)
{
	if(b.text == "")
		return;
	fc := face(b.st);
	emit(f, ref Item(Iword, b.text, fc.width(b.text), b, fc, 1, 0, 0));
	f.space = 1;
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

# CJK and the like break between any two characters
isideo(c: int): int
{
	return (c >= 16r2E80 && c <= 16r9FFF) || (c >= 16rAC00 && c <= 16rD7AF) ||
		(c >= 16rF900 && c <= 16rFAFF) || (c >= 16rFF00 && c <= 16rFFEF) || c >= 16r20000;
}

transform(s: string, t: int, first: int): string
{
	case t {
	Style->TTupper =>
		for(i := 0; i < len s; i++)
			if(s[i] >= 'a' && s[i] <= 'z' || s[i] >= 16rE0 && s[i] <= 16rFE && s[i] != 16rF7)
				s[i] -= 32;
	Style->TTlower =>
		for(i := 0; i < len s; i++)
			if(s[i] >= 'A' && s[i] <= 'Z' || s[i] >= 16rC0 && s[i] <= 16rDE && s[i] != 16rD7)
				s[i] += 32;
	Style->TTcap =>
		at := first;
		for(i := 0; i < len s; i++) {
			if(at && s[i] >= 'a' && s[i] <= 'z')
				s[i] -= 32;
			at = isspace(s[i]) || s[i] == '-';
		}
	}
	return s;
}

text(f: ref Fl, b: ref Box)
{
	st := b.st;
	fc := face(st);
	s := b.text;
	if(st.transform != Style->TTnone)
		s = transform(s, st.transform, f.space);
	ws := st.whitespace;
	collapsesp := ws == Style->Wnormal || ws == Style->Wnowrap || ws == Style->Wpreline;
	keepnl := !(ws == Style->Wnormal || ws == Style->Wnowrap);
	nowrap := ws == Style->Wnowrap || ws == Style->Wpre;
	ls := st.letterspacing;
	i := 0;
	while(i < len s) {
		c := s[i];
		if(c == '\n' && keepnl) {
			emit(f, ref Item(Ibreak, nil, 0.0, b, fc, 0, 0, 0));
			f.space = 1;
			i++;
			continue;
		}
		if(isspace(c) && collapsesp) {
			while(i < len s && isspace(s[i]) && !(s[i] == '\n' && keepnl))
				i++;
			if(!f.space) {
				emit(f, ref Item(Ispace, " ", fc.space + st.wordspacing + ls, b, fc, nowrap, f.deco, f.decocolor));
				f.space = 1;
			}
			continue;
		}
		if(c == ' ' || c == '\t' || c == '　') {
			# preserved spaces: each is a break opportunity (unless nowrap)
			w := fc.space + st.wordspacing + ls;
			t := " ";
			if(c == '\t') {
				w = fc.space * st.tabsize;
				t = "\t";
			} else if(c == '　')
				w = fc.width("　");
			emit(f, ref Item(Ispace, t, w, b, fc, nowrap, f.deco, f.decocolor));
			f.space = 0;
			i++;
			continue;
		}
		# a word: up to the next space or break opportunity
		st0 := i;
		while(i < len s && !isspace(s[i]) && !(isideo(s[i]) && i > st0)) {
			i++;
			if(s[i-1] == '-' && i < len s && !isspace(s[i]) && i - st0 > 2)
				break;	# break after a hyphen inside a word
			if(isideo(s[i-1]))
				break;
		}
		word := s[st0:i];
		if(word == "­")	# soft hyphen alone
			continue;
		w := fc.width(word) + ls * real len word;
		if(st.breakall && !nowrap) {
			# every character is a break opportunity
			for(k := 0; k < len word; k++) {
				ch := word[k:k+1];
				emit(f, ref Item(Iword, ch, fc.width(ch) + ls, b, fc, 0, f.deco, f.decocolor));
			}
		} else
			emit(f, ref Item(Iword, word, w, b, fc, nowrap, f.deco, f.decocolor));
		f.space = 0;
	}
}

# a line under construction
Ln: adt {
	frags:	list of ref Frag;	# reversed
	x:	real;			# where the next thing goes
	avail:	int;
	content:	int;		# something has been placed
	open:	list of (ref Box, real, int);	# inline boxes open on this line: (box, start x, first?)
	spaces:	int;		# expansion opportunities, for justify
};

layinline(l: ref L, b: ref Box, cw: int): int
{
	items := flatten(b);
	st := b.st;
	lines: list of ref Line;
	y := b.bt + b.pt;
	x0 := b.bl + b.pl;
	ln := ref Ln(nil, 0.0, cw, 0, nil, 0);
	indent := res(st.indent, cw);
	ln.x = real indent;
	first := 1;
	opened: list of ref Box;	# inline boxes open, outermost last
	for(il := items; il != nil; il = tl il) {
		it := hd il;
		case it.kind {
		Iopen =>
			ln.open = (it.box, ln.x, 1) :: ln.open;
			opened = it.box :: opened;
			ln.x += it.w;
		Iclose =>
			ln.x += it.w;
			ln.frags = span(ln, it.box, 1) :: ln.frags;
			opened = removebox(opened, it.box);
		Ispace =>
			if(!ln.content && it.text == " " && collapsible(it.box.st))
				continue;
			ln.frags = textfrag(ln, it) :: ln.frags;
			ln.x += it.w;
			ln.spaces++;
		Iword =>
			if(it.box.kind == Kmarker && !it.box.st.listinside) {
				fr := textfrag(ln, it);
				fr.x = ir(ln.x - it.w);
				ln.frags = fr :: ln.frags;
				ln.content = 1;
				continue;
			}
			if(ln.content && ln.x + it.w > real ln.avail + 0.01 && !it.nowrap && !prevnowrap(ln)) {
				lines = finish(l, b, ln, y, x0, first, 0) :: lines;
				y += (hd lines).h;
				first = 0;
				ln = newline(ln, cw, opened);
			}
			if(!ln.content && ln.x + it.w > real ln.avail && it.box.st.anywhere && len it.text > 1) {
				# overflow-wrap: break the word where it must
				(head, tail) := splitword(it, real ln.avail - ln.x);
				if(head != nil) {
					ln.frags = textfrag(ln, head) :: ln.frags;
					ln.x += head.w;
					ln.content = 1;
					lines = finish(l, b, ln, y, x0, first, 0) :: lines;
					y += (hd lines).h;
					first = 0;
					ln = newline(ln, cw, opened);
					il = it :: tail :: tl il;	# the loop steps on to the rest
					continue;
				}
			}
			ln.frags = textfrag(ln, it) :: ln.frags;
			ln.x += it.w;
			ln.content = 1;
		Iatomic =>
			k := it.box;
			layatomic(l, k, cw);
			w := k.ml + k.w + k.mr;
			if(ln.content && ln.x + real w > real ln.avail + 0.01)  {
				lines = finish(l, b, ln, y, x0, first, 0) :: lines;
				y += (hd lines).h;
				first = 0;
				ln = newline(ln, cw, opened);
			}
			fr := ref Frag(Fatomic, ir(ln.x) + k.ml, 0, k.w, k.h, 0, k, nil, nil, 0, 0, 0, 0);
			ln.frags = fr :: ln.frags;
			ln.x += real w;
			ln.content = 1;
		Ibreak =>
			ln.content = 1;
			lines = finish(l, b, ln, y, x0, first, 1) :: lines;
			y += (hd lines).h;
			first = 0;
			ln = newline(ln, cw, opened);
			ln.content = 0;
		}
	}
	if(ln.content || ln.frags != nil && hascontent(ln)) {
		lines = finish(l, b, ln, y, x0, first, 1) :: lines;
		y += (hd lines).h;
	}
	a := array[len lines] of ref Line;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd lines;
		lines = tl lines;
	}
	b.lines = a;
	return y - b.bt - b.pt;
}

hascontent(ln: ref Ln): int
{
	for(l := ln.frags; l != nil; l = tl l)
		if((hd l).kind == Fspan)
			return 1;
	return 0;
}

collapsible(st: ref St): int
{
	ws := st.whitespace;
	return ws == Style->Wnormal || ws == Style->Wnowrap || ws == Style->Wpreline;
}

prevnowrap(ln: ref Ln): int
{
	# no break between two pieces of nowrap text with no space between
	if(ln.frags == nil)
		return 0;
	f := hd ln.frags;
	return f.kind == Ftext && f.box != nil && f.box.kind != Kinline && f.text != " " &&
		(f.box.st.whitespace == Style->Wnowrap || f.box.st.whitespace == Style->Wpre) && f.text[len f.text-1] != ' ';
}

removebox(l: list of ref Box, b: ref Box): list of ref Box
{
	r: list of ref Box;
	for(; l != nil; l = tl l)
		if(hd l != b)
			r = hd l :: r;
	o: list of ref Box;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

newline(old: ref Ln, cw: int, opened: list of ref Box): ref Ln
{
	ln := ref Ln(nil, 0.0, cw, 0, nil, 0);
	# inline boxes still open continue on the new line
	r: list of ref Box;
	for(l := opened; l != nil; l = tl l)
		r = hd l :: r;
	for(; r != nil; r = tl r)
		ln.open = (hd r, 0.0, 0) :: ln.open;
	return ln;
}

splitword(it: ref Item, avail: real): (ref Item, ref Item)
{
	s := it.text;
	w := 0.0;
	for(k := 0; k < len s - 1; k++) {
		cw := it.face.width(s[k:k+1]);
		if(w + cw > avail && k > 0)
			break;
		w += cw;
	}
	if(k == 0)
		k = 1;
	h := ref *it;
	h.text = s[0:k];
	h.w = it.face.width(h.text);
	t := ref *it;
	t.text = s[k:];
	t.w = it.face.width(t.text);
	return (h, t);
}

textfrag(ln: ref Ln, it: ref Item): ref Frag
{
	return ref Frag(Ftext, ir(ln.x), 0, ir(it.w), 0, 0, it.box, it.text, it.face, 0, 0, it.deco, it.decocolor);
}

# close an inline box's fragment on this line
span(ln: ref Ln, b: ref Box, last: int): ref Frag
{
	x := 0.0;
	first := 0;
	r: list of (ref Box, real, int);
	for(l := ln.open; l != nil; l = tl l) {
		(ob, ox, ofirst) := hd l;
		if(ob == b) {
			x = ox;
			first = ofirst;
		} else
			r = hd l :: r;
	}
	ln.open = nil;
	for(; r != nil; r = tl r)
		ln.open = hd r :: ln.open;
	return ref Frag(Fspan, ir(x), 0, ir(ln.x - x), 0, 0, b, nil, nil, first, last, 0, 0);
}

lineheight(st: ref St, f: ref Typeface): real
{
	case st.lineheight.kind {
	Style->Lnum =>
		return st.lineheight.px * st.fontsize;
	Style->Lpx =>
		return st.lineheight.px;
	}
	return f.normal;
}

# Finish a line: drop trailing spaces, close open inline boxes, then
# align vertically (baselines, line-height) and horizontally.
finish(l: ref L, b: ref Box, ln: ref Ln, y, x0, first, forced: int): ref Line
{
	# trailing collapsible white space hangs
	for(fl := ln.frags; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.kind == Fspan)
			continue;
		if(f.kind == Ftext && f.text == " " && collapsible(f.box.st)) {
			ln.x -= real f.w;
			f.w = 0;
			ln.spaces--;
			continue;
		}
		break;
	}
	for(; ln.open != nil; )
		ln.frags = span(ln, (hd ln.open).t0, 0) :: ln.frags;
	frags := array[len ln.frags] of ref Frag;
	i := len frags - 1;
	for(fl = ln.frags; fl != nil; fl = tl fl)
		frags[i--] = hd fl;

	# vertical: each fragment's extent above and below the baseline
	sf := face(b.st);
	slh := lineheight(b.st, sf);
	shl := (slh - sf.ascent - sf.descent)/2.0;
	above := sf.ascent + shl;
	below := sf.descent + shl;
	if(!ln.content && !forced) {
		above = 0.0;
		below = 0.0;
	}
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		(a, d, shift) := fragmetrics(f, sf);
		f.base = ir(shift);
		va := f.box.st.valign;
		if(f.kind == Ftext && f.box.kind == Ktext)
			va = Style->VAbaseline;	# a text run aligns as its inline box does
		if(va == Style->VAtop || va == Style->VAbottom)
			continue;
		if(a - shift > above)
			above = a - shift;
		if(d + shift > below)
			below = d + shift;
	}
	h := ir(above + below);
	# top- and bottom-aligned things may make the line taller
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		va := f.box.st.valign;
		if(f.kind == Ftext && f.box.kind == Ktext)
			va = Style->VAbaseline;
		if(va == Style->VAtop || va == Style->VAbottom) {
			(a, d, nil) := fragmetrics(f, sf);
			if(ir(a + d) > h)
				h = ir(a + d);
		}
	}
	base := ir(above);
	line := ref Line(y, h, y + base, frags);
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		(a, d, shift) := fragmetrics(f, sf);
		va := f.box.st.valign;
		if(f.kind == Ftext && f.box.kind == Ktext)
			va = Style->VAbaseline;
		fb := real line.base + shift;
		case va {
		Style->VAtop =>
			fb = real y + a;
		Style->VAbottom =>
			fb = real (y + h) - d;
		}
		case f.kind {
		Ftext =>
			f.base = ir(fb);
			f.y = ir(fb - f.face.ascent);
			f.h = ir(f.face.ascent + f.face.descent);
		Fatomic =>
			k := f.box;
			f.y = ir(fb) - k.base + k.mt;
			k.y = f.y;
		Fspan =>
			k := f.box;
			fc := face(k.st);
			f.base = ir(fb);
			f.y = ir(fb - fc.ascent) - k.pt - k.bt;
			f.h = ir(fc.ascent + fc.descent) + k.pt + k.bt + k.pb + k.bb;
		}
	}
	# horizontal alignment
	extra := real ln.avail - ln.x;
	align := b.st.align;
	if(forced && align == Style->Ajustify)
		align = b.st.alignlast;
	off := 0.0;
	case align {
	Style->Aright or Style->Aend =>
		off = extra;
	Style->Acenter =>
		off = extra/2.0;
	Style->Ajustify =>
		if(!forced && ln.spaces > 0 && extra > 0.0) {
			per := extra / real ln.spaces;
			acc := 0.0;
			for(i = 0; i < len frags; i++) {
				f := frags[i];
				f.x += ir(acc);
				if(f.kind == Ftext && f.text == " ") {
					acc += per;
					f.w += ir(per);
				}
			}
		}
	}
	if(b.st.dirrtl && align == Style->Astart)
		off = extra;
	if(off < 0.0)
		off = 0.0;
	for(i = 0; i < len frags; i++) {
		f := frags[i];
		f.x += x0 + ir(off);
		if(f.kind == Fatomic)
			f.box.x = f.x;
	}
	return line;
}

# A fragment's ascent and descent around its baseline, half-leading
# included, and how far its baseline is shifted down from the line's.
fragmetrics(f: ref Frag, parent: ref Typeface): (real, real, real)
{
	st := f.box.st;
	a, d: real;
	case f.kind {
	Ftext or Fspan =>
		fc := f.face;
		if(fc == nil)
			fc = face(st);
		lh := lineheight(st, fc);
		hl := (lh - fc.ascent - fc.descent)/2.0;
		a = fc.ascent + hl;
		d = fc.descent + hl;
	Fatomic =>
		k := f.box;
		a = real (k.base);
		d = real (k.mt + k.h + k.mb - k.base);
	}
	shift := 0.0;
	va := st.valign;
	if(f.kind == Ftext && f.box.kind == Ktext)
		return (a, d, 0.0);
	case va {
	Style->VAsub =>
		shift = parent.size * 0.2;
	Style->VAsuper =>
		shift = -parent.size * 0.35;
	Style->VAmiddle =>
		# the middle of the box at half the parent's x-height
		shift = (a - d)/2.0 - parent.size * 0.27;
	Style->VAtexttop =>
		shift = a - parent.ascent;
	Style->VAtextbottom =>
		shift = parent.descent - d;
	Style->VAlen =>
		shift = -st.valignlen.px;
	}
	return (a, d, shift);
}

# Lay out an atomic inline (inline-block, inline replaced, inline flex...).
layatomic(l: ref L, k: ref Box, cbw: int)
{
	edges(k, cbw);
	w := specw(k, k.st.width, cbw);
	if(w < 0) {
		if(k.kind == Kreplaced) {
			(rw, nil) := replacedsize(k, cbw, -1);
			w = rw + hextra(k);
		} else {
			(mn, mx) := intrinsic(k);
			w = fit(mn, mx, cbw) - nz(k.ml) - nz(k.mr);
		}
	}
	k.w = clampw(k, w, cbw);
	if(k.st.ml.kind == Style->Lauto)
		k.ml = 0;
	if(k.st.mr.kind == Style->Lauto)
		k.mr = 0;
	layblock(l, k, cbw, -1);
	# baseline: the last line box's, else the bottom margin edge
	k.base = k.mt + k.h;
	if(k.kind != Kreplaced && k.st.overflowy == Style->Ovisible) {
		(ok, by) := lastbaseline(k);
		if(ok)
			k.base = k.mt + by;
	}
}

lastbaseline(b: ref Box): (int, int)
{
	if(b.lines != nil && len b.lines > 0)
		return (1, b.lines[len b.lines - 1].base);
	for(i := len b.kids - 1; i >= 0; i--) {
		k := b.kids[i];
		if(k.inl)
			continue;
		(ok, by) := lastbaseline(k);
		if(ok)
			return (1, k.y + by);
	}
	return (0, 0);
}

# ---- caches ----

Nfacecache: con 256;
faces: array of list of (int, ref Typeface);

face(st: ref St): ref Typeface
{
	h := st.sid % Nfacecache;
	if(h < 0)
		h = -h;
	for(l := faces[h]; l != nil; l = tl l)
		if((hd l).t0 == st.sid)
			return (hd l).t1;
	f := fonts->face(st.family, st.weight, st.fontstyle != Style->FSnormal, st.fontsize);
	faces[h] = (st.sid, f) :: faces[h];
	return f;
}

# ---- painting (CSS 2.2 Appendix E, simplified to tree order) ----

Ncolors: con 256;
colors: array of list of (int, ref Image);

# An image of one colour, for filling.  Colours with alpha become
# premultiplied, as draw(3) composites.
colorimg(c: int): ref Image
{
	h := (c ^ (c >> 13)) & (Ncolors-1);
	if(h < 0)
		h = -h;
	for(l := colors[h]; l != nil; l = tl l)
		if((hd l).t0 == c)
			return (hd l).t1;
	a := c & 255;
	pc := c;
	if(a != 255) {
		r := ((c >> 24) & 255) * a / 255;
		g := ((c >> 16) & 255) * a / 255;
		b := ((c >> 8) & 255) * a / 255;
		pc = (r << 24) | (g << 16) | (b << 8) | a;
	}
	img := display.newimage(Rect((0, 0), (1, 1)), Draw->RGBA32, 1, pc);
	colors[h] = (c, img) :: colors[h];
	return img;
}

visible(c: int): int
{
	return (c & 255) != 0;
}

height(root: ref Box): int
{
	return root.y + root.h + root.mb;
}

paint(root: ref Box, dst: ref Image, origin: Point, clip: Rect)
{
	oclip := dst.clipr;
	dst.clipr = clip;
	# the canvas takes the root's background, or else the body's
	bg := root.st.bgcolor;
	bgbox := root;
	if(!visible(bg) && root.st.bg == nil) {
		for(i := 0; i < len root.kids; i++)
			if(root.kids[i].node != 0) {
				bgbox = root.kids[i];
				bg = bgbox.st.bgcolor;
				break;
			}
	}
	dst.draw(clip, display.white, nil, (0, 0));
	if(visible(bg))
		dst.draw(clip, colorimg(bg), nil, (0, 0));
	paintbox(dst, root, origin, clip, bgbox);
	dst.clipr = oclip;
}

# canvasbg: the box whose background went to the canvas
paintbox(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	st := b.st;
	if(st.opacity < 1.0 && st.opacity > 0.0 && b.kind != Ktext) {
		layer(dst, b, o, clip, canvasbg);
		return;
	}
	if(st.opacity == 0.0)
		return;
	vis := st.visibility == Style->Vvisible;
	if(vis) {
		if(b != canvasbg)
			paintbackground(dst, b, r);
		paintborders(dst, b, r);
	}
	inner := clip;
	if(st.overflowx != Style->Ovisible || st.overflowy != Style->Ovisible) {
		pr := Rect((r.min.x + b.bl, r.min.y + b.bt), (r.max.x - b.br, r.max.y - b.bb));
		(inner, nil) = clip.clip(pr);
		if(!rectok(inner))
			return;
	}
	oclip := dst.clipr;
	dst.clipr = inner;
	if(b.kind == Kreplaced) {
		if(vis)
			paintreplaced(dst, b, r);
	} else if(b.lines != nil)
		paintlines(dst, b, Point(r.min.x, r.min.y), inner, canvasbg);
	else
		for(i := 0; i < len b.kids; i++) {
			k := b.kids[i];
			if(!k.inl)
				paintbox(dst, k, r.min, inner, canvasbg);
		}
	if(vis && st.outlinew > 0 && st.outlines != Style->Bnone) {
		dst.clipr = clip;
		w := st.outlinew;
		off := st.outlineoff;
		orect := r.inset(-(off + w));
		edge(dst, orect, w, st.outlinec, st.outlines);
	}
	dst.clipr = oclip;
}

rectok(r: Rect): int
{
	return r.dx() > 0 && r.dy() > 0;
}

# Paint b into a layer and composite it with its opacity.
layer(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	(lr, ok) := clip.clip(inkbounds(b, r));
	if(!ok || !rectok(lr))
		return;
	img := display.newimage(lr, Draw->RGBA32, 0, Draw->Transparent);
	if(img == nil)
		return;
	op := b.st.opacity;
	b.st.opacity = 1.0;	# shared styles: restore below
	{
		paintbox(img, b, o, lr, canvasbg);
	} exception {
	* =>
		;
	}
	b.st.opacity = op;
	a := int (op * 255.0);
	mask := display.newimage(Rect((0, 0), (1, 1)), Draw->GREY8, 1, (a << 24) | (a << 16) | (a << 8) | 255);
	dst.draw(lr, img, mask, lr.min);
}

# a generous bound on what b paints: its box, its descendants' boxes
inkbounds(b: ref Box, r: Rect): Rect
{
	return r.inset(-64);
}

paintbackground(dst: ref Image, b: ref Box, r: Rect)
{
	st := b.st;
	for(i := len st.shadows - 1; i >= 0; i--) {
		s := st.shadows[i];
		if(s.inset || !visible(s.color))
			continue;
		sr := Rect((r.min.x + int s.x - int s.spread, r.min.y + int s.y - int s.spread),
			(r.max.x + int s.x + int s.spread, r.max.y + int s.y + int s.spread));
		blur := int s.blur;
		if(blur <= 0)
			fillbox(dst, b, sr, s.color);
		else {
			# approximate the blur with a few widening translucent layers
			steps := 4;
			c := s.color;
			a := (c & 255) / (steps + 1);
			for(k := steps; k >= 1; k--) {
				fillbox(dst, b, sr.inset(-blur*k/steps), (c & int 16rFFFFFF00) | a);
			}
			fillbox(dst, b, sr.inset(blur/2), (c & int 16rFFFFFF00) | a);
		}
	}
	if(visible(st.bgcolor)) {
		br := r;
		case bgclip(st) {
		Style->BOXpadding =>
			br = Rect((r.min.x + b.bl, r.min.y + b.bt), (r.max.x - b.br, r.max.y - b.bb));
		Style->BOXcontent =>
			br = Rect((r.min.x + b.bl + b.pl, r.min.y + b.bt + b.pt), (r.max.x - b.br - b.pr, r.max.y - b.bb - b.pb));
		}
		fillbox(dst, b, br, st.bgcolor);
	}
	for(i = len st.bg - 1; i >= 0; i--)
		if(st.bg[i].img != nil)
			paintgradient(dst, b, r, st.bg[i]);
}

bgclip(st: ref St): int
{
	if(st.bg != nil && len st.bg > 0)
		return st.bg[len st.bg - 1].clip;
	return Style->BOXborder;
}

radii(b: ref Box): (int, int, int, int)
{
	st := b.st;
	return (res(st.rtl, b.w), res(st.rtr, b.w), res(st.rbr, b.w), res(st.rbl, b.w));
}

hasradius(b: ref Box): int
{
	(a, c, d, e) := radii(b);
	return a > 0 || c > 0 || d > 0 || e > 0;
}

fillbox(dst: ref Image, b: ref Box, r: Rect, c: int)
{
	if(!rectok(r))
		return;
	if(hasradius(b)) {
		(rtl, rtr, rbr, rbl) := radii(b);
		dst.fillpath(rrect(r, rtl, rtr, rbr, rbl), ~0, colorimg(c), (0, 0));
	} else
		dst.draw(r, colorimg(c), nil, (0, 0));
}

K: con 0.5522847498;	# cubic approximation of a quarter circle

# a rounded rectangle path
rrect(r: Rect, rtl, rtr, rbr, rbl: int): ref Path
{
	return addrrect(Path.new(), r, rtl, rtr, rbr, rbl);
}

addrrect(p: ref Path, r: Rect, rtl, rtr, rbr, rbl: int): ref Path
{
	w := r.dx();
	h := r.dy();
	# scale radii down if they overlap (CSS Backgrounds 3 §5.5)
	f := 1.0;
	f = minf(f, real w / real nz1(rtl + rtr));
	f = minf(f, real w / real nz1(rbl + rbr));
	f = minf(f, real h / real nz1(rtl + rbl));
	f = minf(f, real h / real nz1(rtr + rbr));
	x0 := real r.min.x;
	y0 := real r.min.y;
	x1 := real r.max.x;
	y1 := real r.max.y;
	a := real rtl * f;
	bb := real rtr * f;
	c := real rbr * f;
	d := real rbl * f;
	p.moveto(x0 + a, y0);
	p.lineto(x1 - bb, y0);
	if(bb > 0.0)
		p.curveto(x1 - bb + bb*K, y0, x1, y0 + bb - bb*K, x1, y0 + bb);
	p.lineto(x1, y1 - c);
	if(c > 0.0)
		p.curveto(x1, y1 - c + c*K, x1 - c + c*K, y1, x1 - c, y1);
	p.lineto(x0 + d, y1);
	if(d > 0.0)
		p.curveto(x0 + d - d*K, y1, x0, y1 - d + d*K, x0, y1 - d);
	p.lineto(x0, y0 + a);
	if(a > 0.0)
		p.curveto(x0, y0 + a - a*K, x0 + a - a*K, y0, x0 + a, y0);
	p.close();
	return p;
}

nz1(x: int): int
{
	if(x <= 0)
		return 1;
	return x;
}

minf(a, b: real): real
{
	if(b < a)
		return b;
	return a;
}

paintborders(dst: ref Image, b: ref Box, r: Rect)
{
	st := b.st;
	if(b.bt == 0 && b.br == 0 && b.bb == 0 && b.bl == 0)
		return;
	if(hasradius(b) && b.bt == b.br && b.bt == b.bb && b.bt == b.bl && st.bct == st.bcr && st.bct == st.bcb && st.bct == st.bcl) {
		# a uniform rounded border: outer path minus inner path
		(rtl, rtr, rbr, rbl) := radii(b);
		w := b.bt;
		p := rrect(r, rtl, rtr, rbr, rbl);
		irect := r.inset(w);
		if(rectok(irect)) {
			addrrect(p, irect, nz(rtl-w), nz(rtr-w), nz(rbr-w), nz(rbl-w));
		}
		dst.fillpath(p, 1, colorimg(st.bct), (0, 0));
		return;
	}
	side(dst, Rect(r.min, (r.max.x, r.min.y + b.bt)), b.bt, st.bct, st.bst, 0, 1);
	side(dst, Rect((r.min.x, r.max.y - b.bb), r.max), b.bb, st.bcb, st.bsb, 0, 0);
	side(dst, Rect((r.min.x, r.min.y + b.bt), (r.min.x + b.bl, r.max.y - b.bb)), b.bl, st.bcl, st.bsl, 1, 1);
	side(dst, Rect((r.max.x - b.br, r.min.y + b.bt), (r.max.x, r.max.y - b.bb)), b.br, st.bcr, st.bsr, 1, 0);
}

# One border side as a rectangle, in its style.
# vert: a left/right side; topleft: the top or left side (for 3-D styles)
side(dst: ref Image, r: Rect, w, c, sty, vert, topleft: int)
{
	if(w <= 0 || !rectok(r) || !visible(c))
		return;
	case sty {
	Style->Bnone or Style->Bhidden =>
		return;
	Style->Bdotted or Style->Bdashed =>
		seg := w;
		if(sty == Style->Bdashed)
			seg = 3*w;
		img := colorimg(c);
		if(vert) {
			for(y := r.min.y; y < r.max.y; y += 2*seg)
				dst.draw(Rect((r.min.x, y), (r.max.x, min(y + seg, r.max.y))), img, nil, (0, 0));
		} else {
			for(x := r.min.x; x < r.max.x; x += 2*seg)
				dst.draw(Rect((x, r.min.y), (min(x + seg, r.max.x), r.max.y)), img, nil, (0, 0));
		}
		return;
	Style->Bdouble =>
		if(w >= 3) {
			t := (w + 1)/3;
			img := colorimg(c);
			if(vert) {
				dst.draw(Rect(r.min, (r.min.x + t, r.max.y)), img, nil, (0, 0));
				dst.draw(Rect((r.max.x - t, r.min.y), r.max), img, nil, (0, 0));
			} else {
				dst.draw(Rect(r.min, (r.max.x, r.min.y + t)), img, nil, (0, 0));
				dst.draw(Rect((r.min.x, r.max.y - t), r.max), img, nil, (0, 0));
			}
			return;
		}
	Style->Binset or Style->Bgroove =>
		if(topleft)
			c = shade(c, 0.6);
	Style->Boutset or Style->Bridge =>
		if(!topleft)
			c = shade(c, 0.6);
	}
	dst.draw(r, colorimg(c), nil, (0, 0));
}

shade(c: int, f: real): int
{
	r := int (real ((c >> 24) & 255) * f);
	g := int (real ((c >> 16) & 255) * f);
	b := int (real ((c >> 8) & 255) * f);
	return (r << 24) | (g << 16) | (b << 8) | (c & 255);
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

edge(dst: ref Image, r: Rect, w, c, sty: int)
{
	side(dst, Rect(r.min, (r.max.x, r.min.y + w)), w, c, sty, 0, 1);
	side(dst, Rect((r.min.x, r.max.y - w), r.max), w, c, sty, 0, 0);
	side(dst, Rect((r.min.x, r.min.y + w), (r.min.x + w, r.max.y - w)), w, c, sty, 1, 1);
	side(dst, Rect((r.max.x - w, r.min.y + w), (r.max.x, r.max.y - w)), w, c, sty, 1, 0);
}

# linear-gradient() and radial-gradient() backgrounds, as bands of colour
paintgradient(dst: ref Image, b: ref Box, r: Rect, bg: ref Style->Bg)
{
	t := bg.img;
	if(t.kind != Css->Kfunction)
		return;
	lin := t.s == "linear-gradient" || t.s == "-webkit-linear-gradient" || t.s == "repeating-linear-gradient";
	if(!lin && t.s != "radial-gradient")
		return;
	args := commas(t.kids);
	if(args == nil)
		return;
	angle := 180.0;	# to bottom
	if(lin) {
		a := nows(hd args);
		if(len a > 0 && a[0].kind == Css->Kdimension) {
			case a[0].s {
			"deg" => angle = a[0].n;
			"turn" => angle = a[0].n * 360.0;
			"rad" => angle = a[0].n * 180.0 / Math->Pi;
			}
			args = tl args;
		} else if(len a > 0 && a[0].kind == Css->Kident && lower(a[0].s) == "to") {
			dir := "";
			for(k := 1; k < len a; k++)
				if(a[k].kind == Css->Kident)
					dir += lower(a[k].s);
			case dir {
			"top" => angle = 0.0;
			"right" => angle = 90.0;
			"bottom" => angle = 180.0;
			"left" => angle = 270.0;
			"topright" or "righttop" => angle = 45.0;
			"bottomright" or "rightbottom" => angle = 135.0;
			"bottomleft" or "leftbottom" => angle = 225.0;
			"topleft" or "lefttop" => angle = 315.0;
			}
			args = tl args;
		}
	} else {
		a := nows(hd args);
		if(len a > 0 && a[0].kind == Css->Kident) {
			(ok, nil) := style->color(a[0:1]);
			if(!ok)
				args = tl args;	# shape and position: drawn centred, circular
		}
	}
	# colour stops
	n := len args;
	if(n < 1)
		return;
	cols := array[n] of int;
	pos := array[n] of real;
	k := 0;
	for(; args != nil; args = tl args) {
		a := nows(hd args);
		if(len a == 0)
			continue;
		(ok, c) := style->color(a[0:1]);
		if(!ok)
			continue;
		cols[k] = c;
		pos[k] = -1.0;
		if(len a > 1 && a[1].kind == Css->Kpercent)
			pos[k] = a[1].n / 100.0;
		k++;
	}
	if(k == 0)
		return;
	cols = cols[0:k];
	pos = pos[0:k];
	if(pos[0] < 0.0)
		pos[0] = 0.0;
	if(pos[k-1] < 0.0)
		pos[k-1] = 1.0;
	for(i := 1; i < k-1; i++)
		if(pos[i] < 0.0) {
			j := i;
			while(pos[j] < 0.0)
				j++;
			for(m := i; m < j; m++)
				pos[m] = pos[i-1] + (pos[j] - pos[i-1]) * real (m - i + 1) / real (j - i + 1);
		}
	oclip := dst.clipr;
	(cr, ok) := oclip.clip(r);
	if(!ok)
		return;
	dst.clipr = cr;
	if(lin) {
		# bands perpendicular to the gradient line
		rad := angle * Math->Pi / 180.0;
		dx := math->sin(rad);
		dy := -math->cos(rad);
		w := real r.dx();
		h := real r.dy();
		glen := math->fabs(w*dx) + math->fabs(h*dy);
		cx := real r.min.x + w/2.0;
		cy := real r.min.y + h/2.0;
		steps := int glen;
		if(steps < 1)
			steps = 1;
		if(steps > 512)
			steps = 512;
		for(s := 0; s < steps; s++) {
			t0 := real s / real steps;
			t1 := real (s+1) / real steps;
			c := gradcolor(cols, pos, (t0 + t1)/2.0);
			# the band from t0 to t1 along the line, as a polygon
			p := Path.new();
			ext := w + h;
			px := cx + dx*glen*(t0 - 0.5);
			py := cy + dy*glen*(t0 - 0.5);
			qx := cx + dx*glen*(t1 - 0.5) + dx*0.6;
			qy := cy + dy*glen*(t1 - 0.5) + dy*0.6;
			p.moveto(px - dy*ext, py + dx*ext);
			p.lineto(px + dy*ext, py - dx*ext);
			p.lineto(qx + dy*ext, qy - dx*ext);
			p.lineto(qx - dy*ext, qy + dx*ext);
			p.close();
			dst.fillpath(p, ~0, colorimg(c), (0, 0));
		}
	} else {
		cx := real (r.min.x + r.max.x)/2.0;
		cy := real (r.min.y + r.max.y)/2.0;
		rr := math->sqrt(real (r.dx()*r.dx() + r.dy()*r.dy()))/2.0;
		steps := int rr;
		if(steps > 256)
			steps = 256;
		dst.draw(r, colorimg(cols[k-1]), nil, (0, 0));
		for(s := steps; s > 0; s--) {
			t := real s / real steps;
			p := Path.new();
			p.ellipse(cx, cy, rr*t, rr*t);
			dst.fillpath(p, ~0, colorimg(gradcolor(cols, pos, t)), (0, 0));
		}
	}
	dst.clipr = oclip;
}

gradcolor(cols: array of int, pos: array of real, t: real): int
{
	if(t <= pos[0])
		return cols[0];
	for(i := 1; i < len cols; i++)
		if(t <= pos[i]) {
			span := pos[i] - pos[i-1];
			f := 1.0;
			if(span > 0.0)
				f = (t - pos[i-1]) / span;
			return mix(cols[i-1], cols[i], f);
		}
	return cols[len cols - 1];
}

mix(a, b: int, f: real): int
{
	r := 0;
	for(sh := 24; sh >= 0; sh -= 8) {
		x := real ((a >> sh) & 255) * (1.0 - f) + real ((b >> sh) & 255) * f;
		r |= (int x & 255) << sh;
	}
	return r;
}

commas(v: array of ref Tok): list of array of ref Tok
{
	r: list of array of ref Tok;
	st := 0;
	for(i := 0; i <= len v; i++)
		if(i == len v || v[i].kind == Css->Kcomma) {
			r = v[st:i] :: r;
			st = i+1;
		}
	o: list of array of ref Tok;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

nows(v: array of ref Tok): array of ref Tok
{
	n := 0;
	for(i := 0; i < len v; i++)
		if(v[i].kind != Css->Kws)
			n++;
	r := array[n] of ref Tok;
	n = 0;
	for(i = 0; i < len v; i++)
		if(v[i].kind != Css->Kws)
			r[n++] = v[i];
	return r;
}

paintreplaced(dst: ref Image, b: ref Box, r: Rect)
{
	cr := Rect((r.min.x + b.bl + b.pl, r.min.y + b.bt + b.pt), (r.max.x - b.br - b.pr, r.max.y - b.bb - b.pb));
	if(b.img != nil) {
		img := b.img;
		if(img.r.dx() != cr.dx() || img.r.dy() != cr.dy())
			img = scale(img, cr.dx(), cr.dy());
		if(img != nil)
			dst.draw(cr, img, nil, img.r.min);
		return;
	}
	if(b.text != nil && b.iw == 0) {
		# alt text, or a form control's label
		f := face(b.st);
		f.draw(dst, Point(cr.min.x + 1, cr.min.y + ir(f.ascent)), b.text, colorimg(b.st.color));
	}
}

# nearest-neighbour scaling, for images drawn at other than their size
scale(src: ref Image, w, h: int): ref Image
{
	if(w <= 0 || h <= 0)
		return nil;
	dst := display.newimage(Rect((0, 0), (w, h)), src.chans, 0, Draw->Transparent);
	if(dst == nil)
		return nil;
	sw := src.r.dx();
	sh := src.r.dy();
	# columns first into a strip, then rows
	strip := display.newimage(Rect((0, 0), (w, sh)), src.chans, 0, Draw->Transparent);
	if(strip == nil)
		return nil;
	for(x := 0; x < w; x++) {
		sx := src.r.min.x + x * sw / w;
		strip.draw(Rect((x, 0), (x+1, sh)), src, nil, (sx, src.r.min.y));
	}
	for(y := 0; y < h; y++) {
		sy := y * sh / h;
		dst.draw(Rect((0, y), (w, y+1)), strip, nil, (0, sy));
	}
	return dst;
}

paintlines(dst: ref Image, b: ref Box, o: Point, clip: Rect, canvasbg: ref Box)
{
	for(i := 0; i < len b.lines; i++) {
		ln := b.lines[i];
		if(o.y + ln.y > clip.max.y)
			break;
		if(o.y + ln.y + ln.h < clip.min.y && !hasatomic(ln))
			continue;
		# inline box backgrounds and borders first, outermost first
		for(k := 0; k < len ln.frags; k++) {
			f := ln.frags[k];
			if(f.kind == Fspan && f.box.st.visibility == Style->Vvisible)
				paintspan(dst, f, o);
		}
		for(k = 0; k < len ln.frags; k++) {
			f := ln.frags[k];
			case f.kind {
			Ftext =>
				if(f.box.st.visibility == Style->Vvisible)
					painttext(dst, f, o);
			Fatomic =>
				paintbox(dst, f.box, o, clip, canvasbg);
			}
		}
	}
}

hasatomic(ln: ref Line): int
{
	for(k := 0; k < len ln.frags; k++)
		if(ln.frags[k].kind == Fatomic)
			return 1;
	return 0;
}

paintspan(dst: ref Image, f: ref Frag, o: Point)
{
	b := f.box;
	st := b.st;
	x0 := o.x + f.x;
	if(f.first)
		x0 += b.ml;
	x1 := o.x + f.x + f.w;
	if(f.last)
		x1 -= b.mr;
	r := Rect((x0, o.y + f.y), (x1, o.y + f.y + f.h));
	if(visible(st.bgcolor))
		dst.draw(r, colorimg(st.bgcolor), nil, (0, 0));
	for(i := len st.bg - 1; i >= 0; i--)
		if(st.bg[i].img != nil)
			paintgradient(dst, b, r, st.bg[i]);
	side(dst, Rect(r.min, (r.max.x, r.min.y + b.bt)), b.bt, st.bct, st.bst, 0, 1);
	side(dst, Rect((r.min.x, r.max.y - b.bb), r.max), b.bb, st.bcb, st.bsb, 0, 0);
	if(f.first)
		side(dst, Rect(r.min, (r.min.x + b.bl, r.max.y)), b.bl, st.bcl, st.bsl, 1, 1);
	if(f.last)
		side(dst, Rect((r.max.x - b.br, r.min.y), r.max), b.br, st.bcr, st.bsr, 1, 0);
}

painttext(dst: ref Image, f: ref Frag, o: Point)
{
	st := f.box.st;
	if(f.text == " " || f.text == "\t")
		return paintdeco(dst, f, o);
	fc := f.face;
	p := Point(o.x + f.x, o.y + f.base);
	for(i := 0; i < len st.textshadows; i++) {
		s := st.textshadows[i];
		if(visible(s.color))
			drawtext(dst, fc, p.add(Point(int s.x, int s.y)), f.text, colorimg(s.color), st.letterspacing);
	}
	if(visible(st.color))
		drawtext(dst, fc, p, f.text, colorimg(st.color), st.letterspacing);
	paintdeco(dst, f, o);
}

drawtext(dst: ref Image, fc: ref Typeface, p: Point, s: string, c: ref Image, ls: real)
{
	if(ls == 0.0) {
		fc.draw(dst, p, s, c);
		return;
	}
	x := real p.x;
	for(i := 0; i < len s; i++) {
		x += fc.draw(dst, Point(int x, p.y), s[i:i+1], c) + ls;
	}
}

paintdeco(dst: ref Image, f: ref Frag, o: Point)
{
	d := f.deco | f.box.st.decoration;
	if(f.box.kind == Ktext)
		d = f.deco;
	if(d == 0 || f.w <= 0)
		return;
	fc := f.face;
	c := f.decocolor;
	if(c == Style->Ccurrent || c == 0)
		c = f.box.st.color;
	t := int (fc.size / 14.0);
	if(t < 1)
		t = 1;
	x0 := o.x + f.x;
	x1 := x0 + f.w;
	img := colorimg(c);
	if(d & Style->TDunder) {
		y := o.y + f.base + int (fc.descent * 0.35) + 1;
		dst.draw(Rect((x0, y), (x1, y + t)), img, nil, (0, 0));
	}
	if(d & Style->TDover) {
		y := o.y + f.base - int fc.ascent;
		dst.draw(Rect((x0, y), (x1, y + t)), img, nil, (0, 0));
	}
	if(d & Style->TDthrough) {
		y := o.y + f.base - int (fc.size * 0.3);
		dst.draw(Rect((x0, y), (x1, y + t)), img, nil, (0, 0));
	}
}

# ---- finding things ----

boxat(root: ref Box, p: Point): (int, ref Box)
{
	return findin(root, p, Point(0, 0));
}

findin(b: ref Box, p, o: Point): (int, ref Box)
{
	r := Rect((o.x + b.x, o.y + b.y), (o.x + b.x + b.w, o.y + b.y + b.h));
	org := r.min;
	if(b.lines != nil) {
		for(i := 0; i < len b.lines; i++) {
			ln := b.lines[i];
			for(k := len ln.frags - 1; k >= 0; k--) {
				f := ln.frags[k];
				fr := Rect((org.x + f.x, org.y + f.y), (org.x + f.x + f.w, org.y + f.y + f.h));
				if(f.kind == Fatomic) {
					(n, x) := findin(f.box, p, org);
					if(x != nil)
						return (n, x);
					continue;
				}
				if(p.in(fr))
					return (f.box.node, f.box);
			}
		}
	} else
		for(i := len b.kids - 1; i >= 0; i--) {
			(n, x) := findin(b.kids[i], p, org);
			if(x != nil)
				return (n, x);
		}
	if(p.in(r))
		return (b.node, b);
	return (0, nil);
}

boxes(root: ref Box, n: int): list of ref Box
{
	return collect(root, n, nil);
}

collect(b: ref Box, n: int, acc: list of ref Box): list of ref Box
{
	if(b.node == n && b.kind != Ktext)
		acc = b :: acc;
	for(i := 0; i < len b.kids; i++)
		acc = collect(b.kids[i], n, acc);
	return acc;
}

kindnames := array[] of {"block", "inline", "text", "br", "replaced", "flex", "grid", "table", "row", "cell", "marker"};

dump(root: ref Box): string
{
	return dumpbox(root, "", Point(0, 0));
}

dumpbox(b: ref Box, ind: string, o: Point): string
{
	x := o.x + b.x;
	y := o.y + b.y;
	k := kindnames[b.kind];
	if(b.inl && b.kind != Kinline && b.kind != Ktext && b.kind != Kbr)
		k = "inline-" + k;
	s := sys->sprint("%s%s %d %d %d %d %d\n", ind, k, b.node, x, y, b.w, b.h);
	if(b.lines != nil) {
		for(i := 0; i < len b.lines; i++) {
			ln := b.lines[i];
			s += sys->sprint("%s  line %d %d\n", ind, y + ln.y, ln.h);
			for(j := 0; j < len ln.frags; j++) {
				f := ln.frags[j];
				case f.kind {
				Ftext =>
					s += sys->sprint("%s    text %d %d %d %d \"%s\"\n", ind, x + f.x, y + f.y, f.w, f.h, f.text);
				Fatomic =>
					s += dumpbox(f.box, ind + "    ", Point(x, y));
				}
			}
		}
	} else
		for(i := 0; i < len b.kids; i++)
			s += dumpbox(b.kids[i], ind + "  ", Point(x, y));
	return s;
}
