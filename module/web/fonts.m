#
# fonts.m - faces for the web engine.
#
# face() maps a computed style's font-family list, weight, style and
# size to a face: one of the shipped TrueType families (DejaVu Sans,
# Serif and Sans Mono, in four styles each, under /fonts/ttf/dejavu),
# drawn from outlines at exactly the size asked for.  Characters a face
# lacks fall back to the bitmap Unicode font, which covers CJK and
# symbols.  Faces are cached; glyphs are cached by outlinefont(2).
#
Fonts: module
{
	PATH:	con "/dis/lib/web/fonts.dis";
	DIR:	con "/fonts/ttf/dejavu";

	init:	fn(d: ref Draw->Display): string;

	Typeface: adt {
		outline:	ref OutlineFont->Face;
		size:	real;		# px
		ascent, descent:	real;	# px, both positive
		normal:	real;		# line-height: normal, px
		space:	real;		# width of U+0020
		fallback:	ref Draw->Font;

		width:	fn(f: self ref Typeface, s: string): real;
		draw:	fn(f: self ref Typeface, dst: ref Draw->Image, p: Draw->Point, s: string, src: ref Draw->Image): real;	# p is on the baseline
	};

	face:	fn(family: list of string, weight, italic: int, size: real): ref Typeface;
};
