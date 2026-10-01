implement Page;

#
# A web page.  See module/web/page.m.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "imagefile.m";
	imageremap: Imageremap;
include "encoding.m";
	base64: Encoding;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/html.m";
	html: Html;
include "web/css.m";
	css: Css;
include "web/style.m";
	style: Style;
	Styles, Env: import style;
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
	layout: Layout;
	Box: import layout;
include "web/page.m";

display: ref Display;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	dom = load Dom Dom->PATH;
	html = load Html Html->PATH;
	css = load Css Css->PATH;
	style = load Style Style->PATH;
	layout = load Layout Layout->PATH;
	imageremap = load Imageremap Imageremap->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	if(html == nil || css == nil || style == nil || layout == nil)
		return sys->sprint("cannot load modules: %r");
	display = d;
	html->init();
	css->init();
	if((err := style->init()) != nil)
		return err;
	if((err = layout->init(d)) != nil)
		return err;
	if(imageremap != nil)
		imageremap->init(d);
	return nil;
}

open(url: string, width, height: int): (ref Pg, string)
{
	return request(url, "GET", nil, nil, width, height);
}

request(url, method, reqctype: string, body: array of byte, width, height: int): (ref Pg, string)
{
	data: array of byte;
	ctype, err, final: string;
	if(method == "POST")
		(data, ctype, err, final) = webfs(url, method, reqctype, body);
	else
		(data, ctype, err, final) = fetchfinal(url);
	if(err != nil && data == nil)
		return (nil, err);
	url = final;	# a redirected page's links are relative to where it is
	charset := param(ctype, "charset");
	p := ref Pg(url, nil, Styles.new(), nil, nil,
		ref Env(width, height, 1.0, 0, 0, 0, 0, 0, 0), nil, width, height, nil);
	if(prefix(lower(ctype), "text/plain")) {
		p.doc = html->parsestring("<pre>" + escape(string data) + "</pre>", url);
	} else if(prefix(lower(ctype), "image/")) {
		p.doc = html->parsestring("<body style='margin:0'><img src=\"" + url + "\">", url);
	} else
		p.doc = html->parse(data, charset, url);
	d := p.doc;
	# <base href>
	if((b := d.find(1, Dom->Tbase)) != 0 && (h := d.attr(b, "href")) != nil) {
		d.url = style->resolveurl(url, h);
		p.url = d.url;
	}
	if((t := d.find(1, Dom->Ttitle)) != 0)
		p.title = squash(d.textof(t));
	loadsheets(p);
	p.computed = style->compute(d, p.styles, p.env);
	p.root = layout->build(d, p.computed);
	loadimages(p, p.root);
	layout->lay(p.root, width, height);
	inlinesvg(p, p.root);
	return (p, nil);
}

Pg.relayout(p: self ref Pg, width, height: int)
{
	if(width == p.width && height == p.height)
		return;
	p.width = width;
	p.height = height;
	p.env.width = width;
	p.env.height = height;
	p.update();
}

Pg.update(p: self ref Pg)
{
	p.computed = style->compute(p.doc, p.styles, p.env);
	old := p.root;
	p.root = layout->build(p.doc, p.computed);
	carryimages(old, p.root);
	layout->lay(p.root, p.width, p.height);
	inlinesvg(p, p.root);
}

Pg.paint(p: self ref Pg, dst: ref Image, scroll: Point)
{
	layout->paint(p.root, dst, dst.r.min.sub(scroll), dst.r);
}

Pg.pageheight(p: self ref Pg): int
{
	return layout->height(p.root);
}

# <style> and <link rel=stylesheet>, in document order, then @imports.
loadsheets(p: ref Pg)
{
	d := p.doc;
	# the sheets in document order: (inline text, nil) or (nil, url)
	sheets: list of (string, string);
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Element || nd.ns != Dom->HTML)
			continue;
		case nd.tag {
		Dom->Tstyle =>
			if(!style->mediamatch(css->tokenize(d.attr(n, "media")), p.env))
				continue;
			sheets = (d.textof(n), nil) :: sheets;
		Dom->Tlink =>
			rel := " " + lower(d.attr(n, "rel")) + " ";
			if(index(rel, " stylesheet ") < 0 || index(rel, " alternate ") >= 0)
				continue;
			if(d.hasattr(n, "disabled"))
				continue;
			if(!style->mediamatch(css->tokenize(d.attr(n, "media")), p.env))
				continue;
			href := d.attr(n, "href");
			if(href == nil)
				continue;
			sheets = (nil, style->resolveurl(d.url, href)) :: sheets;
		}
	}
	a := array[len sheets] of (string, string);
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd sheets;
		sheets = tl sheets;
	}
	urls: list of string;
	for(i = 0; i < len a; i++)
		if(a[i].t1 != nil)
			urls = a[i].t1 :: urls;
	got := fetchall(urls);
	for(i = 0; i < len a; i++) {
		(text, u) := a[i];
		if(u == nil) {
			p.styles.add(css->parse(text), Style->Author, d.url);
			continue;
		}
		(data, nil, err) := fetched(got, u);
		if(err != nil) {
			p.errors = u + ": " + err :: p.errors;
			continue;
		}
		p.styles.add(css->parse(string data), Style->Author, u);
	}
	# @import, to a depth of 4
	for(depth := 0; depth < 4; depth++) {
		urls = p.styles.imports(p.env);
		if(urls == nil)
			break;
		got = fetchall(urls);
		for(; urls != nil; urls = tl urls) {
			(data, nil, err) := fetched(got, hd urls);
			if(err != nil) {
				p.errors = hd urls + ": " + err :: p.errors;
				data = nil;
			}
			style->addimport(hd urls, css->parse(string data));
		}
		p.styles.idx = nil;
	}
}

# Images for replaced boxes, fetched once per URL.
loadimages(p: ref Pg, root: ref Box)
{
	cache: list of (string, ref Image);
	boxes := replacedboxes(root, nil);
	urls: list of string;
	for(l := boxes; l != nil; l = tl l)
		urls = (hd l).url :: urls;
	got := fetchall(urls);
	for(l = boxes; l != nil; l = tl l) {
		b := hd l;
		img: ref Image;
		found := 0;
		for(c := cache; c != nil; c = tl c)
			if((hd c).t0 == b.url) {
				img = (hd c).t1;
				found = 1;
			}
		if(!found) {
			(data, ctype, err) := fetched(got, b.url);
			if(err == nil)
				img = decodeimage(data, ctype, b.url);
			else
				p.errors = b.url + ": " + err :: p.errors;
			cache = (b.url, img) :: cache;
		}
		if(img != nil) {
			b.img = img;
			b.iw = img.r.dx();
			b.ih = img.r.dy();
			b.text = nil;
		}
	}
}

# Inline <svg>: the subtree as markup, rendered at the box's size.
inlinesvg(p: ref Pg, b: ref Box)
{
	if(b.kind == Layout->Kreplaced && b.url == nil && b.node != 0) {
		nd := p.doc.nodes[b.node];
		if(nd.ns == Dom->SVG && nd.name == "svg") {
			w := b.w - b.bl - b.br - b.pl - b.pr;
			h := b.h - b.bt - b.bb - b.pt - b.pb;
			if(w > 0 && h > 0 && (b.img == nil || b.img.r.dx() != w || b.img.r.dy() != h))
				b.img = decodeimage(array of byte svgmarkup(p.doc, b.node, w, h), "image/svg+xml", nil);
		}
	}
	for(i := 0; i < len b.kids; i++)
		inlinesvg(p, b.kids[i]);
	for(l := b.pos; l != nil; l = tl l)
		inlinesvg(p, hd l);
	for(i = 0; i < len b.lines; i++) {
		ln := b.lines[i];
		for(j := 0; j < len ln.frags; j++)
			if(ln.frags[j].kind == Layout->Fatomic)
				inlinesvg(p, ln.frags[j].box);
	}
}

svgmarkup(d: ref Doc, n, w, h: int): string
{
	s := "<svg xmlns=\"http://www.w3.org/2000/svg\"";
	s += sys->sprint(" width=\"%d\" height=\"%d\"", w, h);
	vb := 0;
	for(a := d.nodes[n].attrs; a != nil; a = tl a) {
		(k, v) := hd a;
		case k {
		"width" or "height" or "xmlns" =>
			continue;
		"viewBox" =>
			vb = 1;
		}
		s += " " + k + "=\"" + xmlesc(v) + "\"";
	}
	if(!vb) {
		# without a viewBox the drawing keeps its own units
		ow := d.attr(n, "width");
		oh := d.attr(n, "height");
		if(ow != nil && oh != nil)
			s += " viewBox=\"0 0 " + xmlesc(num(ow)) + " " + xmlesc(num(oh)) + "\"";
	}
	s += ">";
	for(c := d.nodes[n].first; c != 0; c = d.nodes[c].next)
		s += xmlnode(d, c);
	return s + "</svg>";
}

num(s: string): string
{
	i := 0;
	while(i < len s && (s[i] >= '0' && s[i] <= '9' || s[i] == '.'))
		i++;
	return s[0:i];
}

xmlnode(d: ref Doc, n: int): string
{
	nd := d.nodes[n];
	case nd.kind {
	Dom->Text =>
		return xmlesc(nd.text);
	Dom->Element =>
		s := "<" + nd.name;
		for(a := nd.attrs; a != nil; a = tl a)
			s += " " + (hd a).t0 + "=\"" + xmlesc((hd a).t1) + "\"";
		if(nd.first == 0)
			return s + "/>";
		s += ">";
		for(c := nd.first; c != 0; c = d.nodes[c].next)
			s += xmlnode(d, c);
		return s + "</" + nd.name + ">";
	}
	return "";
}

xmlesc(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'<' => r += "&lt;";
		'>' => r += "&gt;";
		'&' => r += "&amp;";
		'"' => r += "&quot;";
		* => r[len r] = s[i];
		}
	return r;
}

replacedboxes(b: ref Box, acc: list of ref Box): list of ref Box
{
	if(b.kind == Layout->Kreplaced && b.url != nil)
		acc = b :: acc;
	for(i := 0; i < len b.kids; i++)
		acc = replacedboxes(b.kids[i], acc);
	return acc;
}

carryimages(old, new: ref Box)
{
	imgs: list of (string, ref Image);
	for(l := replacedboxes(old, nil); l != nil; l = tl l)
		if((hd l).img != nil)
			imgs = ((hd l).url, (hd l).img) :: imgs;
	for(l = replacedboxes(new, nil); l != nil; l = tl l)
		for(i := imgs; i != nil; i = tl i)
			if((hd i).t0 == (hd l).url) {
				b := hd l;
				b.img = (hd i).t1;
				b.iw = b.img.r.dx();
				b.ih = b.img.r.dy();
				b.text = nil;
				break;
			}
}

decodeimage(data: array of byte, ctype, url: string): ref Image
{
	if(imageremap == nil || len data < 4)
		return nil;
	path := "";
	ct := lower(ctype);
	if(len data >= 8 && data[0] == byte 16r89 && data[1] == byte 'P' && data[2] == byte 'N' && data[3] == byte 'G')
		path = RImagefile->READPNGPATH;
	else if(data[0] == byte 16rFF && data[1] == byte 16rD8)
		path = RImagefile->READJPGPATH;
	else if(data[0] == byte 'G' && data[1] == byte 'I' && data[2] == byte 'F')
		path = RImagefile->READGIFPATH;
	else if(len data >= 12 && string data[0:4] == "RIFF" && string data[8:12] == "WEBP")
		path = RImagefile->READWEBPPATH;
	else if(len data >= 12 && string data[4:8] == "ftyp")
		path = RImagefile->READAVIFPATH;
	else if(prefix(ct, "image/svg") || suffix(lower(url), ".svg") || looksvg(data))
		path = RImagefile->READSVGPATH;
	if(path == "")
		return nil;
	rd := load RImagefile path;
	if(rd == nil)
		return nil;
	rd->init(bufio);
	(raw, err) := rd->read(bufio->aopen(data));
	if(raw == nil || err != nil)
		return nil;
	(img, nil) := imageremap->remap(raw, display, 0);
	return img;
}

looksvg(data: array of byte): int
{
	n := len data;
	if(n > 512)
		n = 512;
	return index(string data[0:n], "<svg") >= 0;
}

# ---- fetching ----

NFETCH: con 6;	# fetches at once, as browsers do per host

Got: adt {
	url:	string;
	data:	array of byte;
	ctype:	string;
	err:	string;
};

# Fetch urls concurrently, each distinct URL once.
fetchall(urls: list of string): list of ref Got
{
	todo: list of string;
	n := 0;
	for(; urls != nil; urls = tl urls) {
		u := hd urls;
		if(u == nil)
			continue;
		for(t := todo; t != nil; t = tl t)
			if(hd t == u)
				break;
		if(t == nil) {
			todo = u :: todo;
			n++;
		}
	}
	if(n == 0)
		return nil;
	work := chan[n] of string;
	for(; todo != nil; todo = tl todo)
		work <-= hd todo;
	res := chan of ref Got;
	nw := NFETCH;
	if(nw > n)
		nw = n;
	for(i := 0; i < nw; i++)
		spawn fetcher(work, res);
	got: list of ref Got;
	for(i = 0; i < n; i++)
		got = <-res :: got;
	return got;
}

fetcher(work: chan of string, res: chan of ref Got)
{
	for(;;) alt {
	u := <-work =>
		(data, ctype, err) := fetch(u);
		res <-= ref Got(u, data, ctype, err);
	* =>
		return;
	}
}

fetched(got: list of ref Got, url: string): (array of byte, string, string)
{
	for(; got != nil; got = tl got)
		if((hd got).url == url)
			return ((hd got).data, (hd got).ctype, (hd got).err);
	return (nil, nil, "not fetched");
}

fetch(url: string): (array of byte, string, string)
{
	(data, ctype, err, nil) := fetchfinal(url);
	return (data, ctype, err);
}

# fetch, and the URL the resource came from in the end
fetchfinal(url: string): (array of byte, string, string, string)
{
	(scheme, rest) := splitscheme(url);
	case scheme {
	"file" =>
		path := rest;
		if(prefix(path, "//")) {
			path = path[2:];
			i := 0;
			while(i < len path && path[i] != '/')
				i++;
			path = path[i:];	# file://host/path: the host is ignored
		}
		path = pctdecode(cutquery(cutfrag(path)));
		(d, c, e) := readfile(path);
		return (d, c, e, url);
	"data" =>
		(d, c, e) := dataurl(rest);
		return (d, c, e, url);
	"http" or "https" =>
		return webfs(url, "GET", nil, nil);
	"" =>
		(d, c, e) := readfile(url);
		return (d, c, e, url);
	}
	return (nil, nil, "unsupported scheme: " + scheme, url);
}

splitscheme(u: string): (string, string)
{
	for(i := 0; i < len u; i++) {
		c := u[i];
		if(c == ':')
			return (lower(u[0:i]), u[i+1:]);
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'))
			break;
	}
	return ("", u);
}

cutquery(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '?')
			return s[0:i];
	return s;
}

cutfrag(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '#' || s[i] == '?')
			return s[0:i];
	return s;
}

readfile(path: string): (array of byte, string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, nil, sys->sprint("%r"));
	data := readall(fd);
	return (data, mimetype(path, data), nil);
}

readall(fd: ref Sys->FD): array of byte
{
	buf := array[8192] of byte;
	n := 0;
	for(;;) {
		if(n == len buf) {
			nb := array[2*len buf] of byte;
			nb[0:] = buf;
			buf = nb;
		}
		k := sys->read(fd, buf[n:], len buf - n);
		if(k <= 0)
			break;
		n += k;
	}
	return buf[0:n];
}

mimetype(path: string, data: array of byte): string
{
	p := lower(path);
	if(suffix(p, ".html") || suffix(p, ".htm") || suffix(p, ".xhtml"))
		return "text/html";
	if(suffix(p, ".css"))
		return "text/css";
	if(suffix(p, ".txt") || suffix(p, ".b") || suffix(p, ".m"))
		return "text/plain";
	if(suffix(p, ".svg"))
		return "image/svg+xml";
	if(suffix(p, ".png") || suffix(p, ".jpg") || suffix(p, ".jpeg") || suffix(p, ".gif") || suffix(p, ".webp"))
		return "image/" + p[len p - 3:];
	return "text/html";
}

# data:[<mediatype>][;base64],<data>
dataurl(s: string): (array of byte, string, string)
{
	c := 0;
	while(c < len s && s[c] != ',')
		c++;
	if(c == len s)
		return (nil, nil, "malformed data: URL");
	meta := s[0:c];
	payload := s[c+1:];
	isb64 := 0;
	ctype := meta;
	if(suffix(lower(meta), ";base64")) {
		isb64 = 1;
		ctype = meta[0:len meta - 7];
	}
	if(ctype == "")
		ctype = "text/plain;charset=US-ASCII";
	if(isb64) {
		if(base64 == nil)
			return (nil, nil, "no base64 decoder");
		clean := "";
		for(i := 0; i < len payload; i++)
			if(payload[i] != ' ' && payload[i] != '\n' && payload[i] != '\t' && payload[i] != '\r')
				clean[len clean] = payload[i];
		return (base64->dec(pctdecode(clean)), ctype, nil);
	}
	return (array of byte pctdecode(payload), ctype, nil);
}

pctdecode(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '%')
			break;
	if(i == len s)
		return s;
	# decode to bytes, then to UTF-8
	b := array[len s * 3] of byte;
	n := 0;
	for(i = 0; i < len s; i++) {
		if(s[i] == '%' && i+2 < len s && hexv(s[i+1]) >= 0 && hexv(s[i+2]) >= 0) {
			b[n++] = byte (hexv(s[i+1])*16 + hexv(s[i+2]));
			i += 2;
		} else {
			u := array of byte s[i:i+1];
			b[n:] = u;
			n += len u;
		}
	}
	return string b[0:n];
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

# http and https through webfs (see webfs(4)): clone a connection,
# write its URL, read its body.
webfs(url, method, reqctype: string, body: array of byte): (array of byte, string, string, string)
{
	cfd := sys->open(WEBFS + "/clone", Sys->OREAD);
	if(cfd == nil)
		return (nil, nil, "no webfs at " + WEBFS + ": " + sys->sprint("%r"), url);
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return (nil, nil, sys->sprint("webfs clone: %r"), url);
	id := squash(string buf[0:n]);
	dir := WEBFS + "/" + id;
	ctl := sys->open(dir + "/ctl", Sys->OWRITE);
	if(ctl == nil || sys->fprint(ctl, "url %s", url) < 0)
		return (nil, nil, sys->sprint("webfs: %r"), url);
	if(method != "GET") {
		if(sys->fprint(ctl, "method %s", method) < 0 ||
		   reqctype != nil && sys->fprint(ctl, "header Content-Type: %s", reqctype) < 0)
			return (nil, nil, sys->sprint("webfs: %r"), url);
		pfd := sys->open(dir + "/postbody", Sys->OWRITE);
		if(pfd == nil || sys->write(pfd, body, len body) != len body)
			return (nil, nil, sys->sprint("webfs postbody: %r"), url);
	}
	bfd := sys->open(dir + "/body", Sys->OREAD);
	if(bfd == nil)
		return (nil, nil, sys->sprint("%s: %r", url), url);
	data := readall(bfd);
	final := readstr(dir + "/url");
	if(final == "")
		final = url;	# an older webfs
	ctype := readstr(dir + "/contenttype");
	# an error's body comes too: a page shows a 404's, nothing else does
	status := readstr(dir + "/status");
	if(status != "" && !prefix(status, "2"))
		return (data, ctype, status, final);
	return (data, ctype, nil, final);
}

readstr(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	return squash(string readall(fd));
}

# ---- small things ----

param(ctype, name: string): string
{
	(nil, l) := sys->tokenize(ctype, ";");
	for(; l != nil; l = tl l) {
		s := squash(hd l);
		if(prefix(lower(s), name + "=")) {
			v := s[len name + 1:];
			if(len v >= 2 && v[0] == '"')
				v = v[1:len v - 1];
			return v;
		}
	}
	return nil;
}

escape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'<' => r += "&lt;";
		'&' => r += "&amp;";
		* => r[len r] = s[i];
		}
	return r;
}

squash(s: string): string
{
	r := "";
	sp := 1;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r') {
			if(!sp)
				r[len r] = ' ';
			sp = 1;
		} else {
			r[len r] = c;
			sp = 0;
		}
	}
	if(len r > 0 && r[len r - 1] == ' ')
		r = r[0:len r - 1];
	return r;
}

lower(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

suffix(s, t: string): int
{
	return len s >= len t && s[len s - len t:] == t;
}

index(s, t: string): int
{
	for(i := 0; i+len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}
