#
# page.m - a web page: fetched, parsed, styled, laid out, painted.
#
# The pipeline glued together.  open() fetches a document and what it
# needs (style sheets, @imports, images), and lays it out for a
# viewport; paint() draws any part of it.  Fetching goes through
# fetch(): file: and data: URLs directly, http: and https: through
# webfs at /mnt/web, so what a page can reach is what the namespace
# has mounted there.
#
Page: module
{
	PATH:	con "/dis/lib/web/page.dis";
	WEBFS:	con "/mnt/web";

	init:	fn(d: ref Draw->Display): string;

	Pg: adt {
		url:	string;		# after redirects and <base>
		doc:	ref Dom->Doc;
		styles:	ref Style->Styles;
		computed:	ref Style->Computed;
		root:	ref Layout->Box;
		env:	ref Style->Env;
		title:	string;
		width, height:	int;	# viewport
		errors:	list of string;	# what could not be fetched, most recent first

		relayout:	fn(p: self ref Pg, width, height: int);
		paint:	fn(p: self ref Pg, dst: ref Draw->Image, scroll: Draw->Point);
		pageheight:	fn(p: self ref Pg): int;
	};

	open:	fn(url: string, width, height: int): (ref Pg, string);
	fetch:	fn(url: string): (array of byte, string, string);	# (data, content type, error)
	decodeimage:	fn(data: array of byte, ctype, url: string): ref Draw->Image;
};
