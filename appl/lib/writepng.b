implement WImagefile;

#
# writepng — write a Draw image as a PNG (8-bit RGB, or RGBA when the
# image has any transparency).
#
# Any channel layout is accepted: the image is first drawn into an
# RGBA32 scratch image, so the encoder reads one pixel format.  Draw's
# pixels are premultiplied by alpha and PNG's are not; translucent
# pixels are divided back out.  IDAT is compressed with the deflate
# filter (zlib framing), the chunk CRCs with lib/crc — no new
# compression code.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "imagefile.m";
include "filter.m";
	deflate: Filter;
include "crc.m";
	crcm: Crc;

init(b: Bufio)
{
	bufio = b;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	deflate = load Filter Filter->DEFLATEPATH;
	if(deflate != nil)
		deflate->init();
	crcm = load Crc Crc->PATH;
}

writeimage(fd: ref Iobuf, im: ref Image): string
{
	if(deflate == nil || crcm == nil)
		return "writepng: cannot load deflate or crc";
	if(im == nil)
		return "writepng: nil image";
	w := im.r.dx();
	h := im.r.dy();
	if(w <= 0 || h <= 0)
		return "writepng: empty image";

	# normalise to RGBA32; stored little-endian as A B G R per pixel
	rgba := im.display.newimage(Rect((0, 0), (w, h)), Draw->RGBA32, 0, Draw->Transparent);
	if(rgba == nil)
		return sys->sprint("writepng: newimage: %r");
	rgba.draw(rgba.r, im, nil, im.r.min);
	px := array[w * h * 4] of byte;
	if(rgba.readpixels(rgba.r, px) != len px)
		return sys->sprint("writepng: readpixels: %r");

	alpha := 0;
	for(i := 0; i < len px; i += 4)
		if(px[i] != byte 16rFF) {
			alpha = 1;
			break;
		}
	bpp := 3;
	ctype := 2;	# truecolour
	if(alpha) {
		bpp = 4;
		ctype = 6;	# truecolour with alpha
	}

	# scanlines, each prefixed with filter type 0 (none)
	stride := 1 + w * bpp;
	raw := array[h * stride] of byte;
	o := 0;
	for(y := 0; y < h; y++) {
		raw[o++] = byte 0;
		s := y * w * 4;
		for(x := 0; x < w; x++) {
			a := int px[s];
			b := int px[s+1];
			g := int px[s+2];
			r := int px[s+3];
			if(alpha && a > 0 && a < 255) {
				r = r * 255 / a; if(r > 255) r = 255;
				g = g * 255 / a; if(g > 255) g = 255;
				b = b * 255 / a; if(b > 255) b = 255;
			}
			raw[o++] = byte r;
			raw[o++] = byte g;
			raw[o++] = byte b;
			if(alpha)
				raw[o++] = byte a;
			s += 4;
		}
	}
	(z, err) := zlib(raw);
	if(err != nil)
		return "writepng: " + err;

	fd.write(array[] of {byte 137, byte 'P', byte 'N', byte 'G',
		byte 13, byte 10, byte 26, byte 10}, 8);
	ihdr := array[13] of byte;
	put32(ihdr, 0, w);
	put32(ihdr, 4, h);
	ihdr[8] = byte 8;	# bit depth
	ihdr[9] = byte ctype;
	ihdr[10] = byte 0;	# compression: deflate
	ihdr[11] = byte 0;	# filter method 0
	ihdr[12] = byte 0;	# no interlace
	chunk(fd, "IHDR", ihdr);
	chunk(fd, "IDAT", z);
	chunk(fd, "IEND", array[0] of byte);
	if(fd.flush() < 0)
		return sys->sprint("writepng: write: %r");
	return nil;
}

chunk(fd: ref Iobuf, typ: string, data: array of byte)
{
	hdr := array[8] of byte;
	put32(hdr, 0, len data);
	t := array of byte typ;
	hdr[4:] = t[0:4];
	st := crcm->init(0, int 16rFFFFFFFF);
	crcm->crc(st, t, 4);
	c := crcm->crc(st, data, len data);
	tail := array[4] of byte;
	put32(tail, 0, c);
	fd.write(hdr, 8);
	if(len data > 0)
		fd.write(data, len data);
	fd.write(tail, 4);
}

put32(b: array of byte, o, v: int)
{
	b[o] = byte (v >> 24);
	b[o+1] = byte (v >> 16);
	b[o+2] = byte (v >> 8);
	b[o+3] = byte v;
}

zlib(input: array of byte): (array of byte, string)
{
	rq := deflate->start("z6");
	out: list of array of byte;
	total := 0;
	inoff := 0;
	for(;;) {
		pick m := <-rq {
		Start =>
			;
		Fill =>
			n := len input - inoff;
			if(n > len m.buf)
				n = len m.buf;
			m.buf[0:] = input[inoff:inoff+n];
			inoff += n;
			m.reply <-= n;
		Result =>
			if(len m.buf > 0) {
				c := array[len m.buf] of byte;
				c[0:] = m.buf;
				out = c :: out;
				total += len c;
			}
			m.reply <-= 0;
		Finished =>
			b := array[total] of byte;
			for(o := total; out != nil; out = tl out) {
				o -= len hd out;
				b[o:] = hd out;
			}
			return (b, nil);
		Error =>
			return (nil, "deflate: " + m.e);
		}
	}
}
