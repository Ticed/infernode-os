include "tk.m";
include "wmlib.m";

Samterm: module
{

	PATH:		con "/dis/wm/sam.dis";

	Section: adt
	{
		nrunes:	int;
		text:	string;		# if null, we haven't got it
	};

	Range: adt {
		first, last: int;
	};

	# A layer: one window on a file, inside sam's single toplevel.
	# As in Plan 9 sam, layers overlap; the current one is on top.
	Flayer: adt {
		tag:		int;
		t:		ref Tk->Toplevel;	# sam's toplevel; nil once closed
		tkwin:		string;	# file name the layer shows
		scope:		Range;	# part of file in range
		dot:		Range;	# cursor position wrt file, not scope
		width:		int;	# window width (not used yet)
		lineheigth:	int;	# height of a single line (for resize)
		lines:		int;	# window height in lines
		scrollbar:	Range;	# current position of scrollbar
		typepoint:	int;	# -1, or pos of first unsent char typed
		id:		int;	# unique; names the layer's widgets and channels
		w:		string;	# its frame, .c.f<id>, embedded in the canvas
		r:		Draw->Rect;	# where it sits, in canvas coordinates
	};

	Text: adt {
		tag:		int;
		lock:		int;
		flayers:	list of ref Flayer;	# hd flayers is current
		nrunes:		int;
		sects:		list of ref Section;
		state:		int;
	};

	Dirty:	con 1;
	LDirty:	con 2;

	Menu: adt {
		tag:		int;
		name:		string;
		text:		ref Text;
	};

	Context: adt {
		ctxt:		ref Draw->Context;
		tag:		int;	# globally unique tag generator
		lock:		int;	# global lock

		keysel:		array of chan of string;
		scrollsel:	array of chan of string;
		buttonsel:	array of chan of string;
		menu2sel:	array of chan of string;
		menu3sel:	array of chan of string;
		flayers:	array of ref Flayer;

		menus:		array of ref Menu;
		texts:		array of ref Text;

		cmd:		ref Text;	# sam command window
		which:		ref Flayer;	# current flayer (sam or work)
		work:		ref Flayer;	# current work flayer

		pgrp:		int;		# process group
		logfd:		ref FD;

		# sam is one window.  sam.b and samstub.b each load their own
		# Samtk, so what the layers share lives here, not in Samtk.
		top:		ref Tk->Toplevel;	# the window; .c holds the layers
		wmctl:		chan of string;	# window manager, and canvas resizes
		sweepc:		chan of string;	# button 3 while sweeping a layer
		nextid:		int;		# next Flayer.id
		size:		Draw->Point;	# canvas size the layers were laid out in
	};

	init:		fn(ctxt: ref Draw->Context, args: list of string);
};
