implement Scenerender;

#
# scenerender — draw a scene, without a window system, as an image on
# standard output (the Inferno image format: display it, cp it,
# convert it at the edge of the system if it must leave).
#
#	scenerender [-w width] [-h height] [-t time] [-v view] [-F font] [-n] [-l] dir
#	scenerender [...] -r recording
#
# The scene is a directory (docs/scene-design.md §2: a scenefs mount or
# plain files) or, with -r, a recording of records (§3.2), replayed up
# to -t (default: the end) with every entity's trail built from the
# whole history.  -v adopts a view line ("center A B zoom Z sel ID");
# otherwise the camera fits the data.  -n drops the HUD, -l the default
# grid.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Rect: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "arg.m";
include "scene.m";
	scene: Scene;
	Model, Cam, Trails: import scene;

Scenerender: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	stderr = sys->fildes(2);
	scene = load Scene Scene->PATH;
	if(scene == nil)
		fatal(sys->sprint("cannot load %s: %r", Scene->PATH));
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("scenerender [-w width] [-h height] [-t time] [-v view] [-F font] [-n] [-l] [-r recording | dir]");
	w := 1024;
	h := 768;
	t := -1.0;
	hast := 0;
	view, rec: string;
	fontname := "/fonts/combined/unicode.sans.14.font";
	flags := Scene->RHUD | Scene->RGRID;
	while((c := arg->opt()) != 0)
		case c {
		'w' =>	w = int arg->earg();
		'h' =>	h = int arg->earg();
		't' =>	t = real arg->earg(); hast = 1;
		'v' =>	view = arg->earg();
		'F' =>	fontname = arg->earg();
		'r' =>	rec = arg->earg();
		'n' =>	flags &= ~Scene->RHUD;
		'l' =>	flags &= ~Scene->RGRID;
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(rec == nil && len argv != 1 || rec != nil && argv != nil)
		arg->usage();
	if(w <= 0 || h <= 0 || w > 16384 || h > 16384)
		fatal("bad size");

	m: ref Model;
	tr: ref Trails;
	if(rec != nil) {
		(m, tr) = replay(rec, t, hast);
	} else
		m = Model.read(hd argv);

	display := Display.allocate(nil);
	if(display == nil)
		fatal(sys->sprint("cannot allocate display: %r"));
	font := Font.open(display, fontname);
	if(font == nil)
		font = Font.open(display, "*default*");
	scene->init(display, font);
	r := Rect((0, 0), (w, h));
	img := display.newimage(r, Draw->RGB24, 0, Draw->Black);
	if(img == nil)
		fatal(sys->sprint("cannot allocate image: %r"));
	cam := Cam.new(r);
	cam.fit(m);
	if(view != nil)
		cam.parse(view);
	if(cam.follow != nil && (e := m.find(Scene->ENT, cam.follow)) != nil && e.haspos) {
		cam.ca = e.a;
		cam.cb = e.b;
	}
	scene->render(img, m, cam, tr, flags, nil);

	if(display.writeimage(sys->fildes(1), img) < 0)
		fatal(sys->sprint("writeimage: %r"));
}

# Apply a recording up to time t (all of it if !hast), noting trail
# positions at every clock tick so trails are the real trajectories.
replay(file: string, t: real, hast: int): (ref Model, ref Trails)
{
	b := bufio->open(file, Bufio->OREAD);
	if(b == nil)
		fatal(sys->sprint("cannot open %s: %r", file));
	m := Model.new();
	tr := Trails.new();
	n := 0;
	while((line := b.gets('\n')) != nil) {
		n++;
		if(len line > 5 && line[0:5] == "time ") {
			if(hast && real line[5:] > t)
				break;
			tr.note(m);	# the state as it stood until this tick
		}
		if(len line >= 5 && line[0:5] == "clear")
			tr.reset();
		if((err := m.apply(line)) != nil)
			sys->fprint(stderr, "scenerender: %s:%d: %s\n", file, n, err);
	}
	tr.note(m);
	return (m, tr);
}

fatal(s: string)
{
	sys->fprint(stderr, "scenerender: %s\n", s);
	raise "fail:error";
}
