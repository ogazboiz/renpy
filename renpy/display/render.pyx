#cython: profile=False
# Copyright 2004-2025 Tom Rothamel <pytom@bishoujo.us>
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software,
# and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

from __future__ import print_function

from renpy.display.matrix import Matrix, Matrix2D
from renpy.display.matrix cimport Matrix, Matrix2D

# This is required to get these to re-export despite having been defined
# in cython.
globals()["Matrix"] = Matrix
globals()["Matrix2D"] = Matrix2D

import collections
import pygame_sdl2 as pygame
import threading
import renpy
import gc
import math

# We grab the blit lock each time it is necessary to blit
# something. This allows call to the pygame.transform functions to
# disable blitting, should it prove necessary.
blit_lock = threading.Condition()

# This is a dictionary containing all the renders that we know of. It's a
# map from displayable to dictionaries containing the render of that
# displayable.
render_cache = collections.defaultdict(dict)

# The queue of redraws. A list of (time, displayable) pairs.
redraw_queue = [ ]

# The render returned from render_screen.
screen_render = None

# A list of renders the system knows about, and thinks are still alive.
cdef list live_renders
live_renders = [ ]

# A copy of renpy.display.interface.frame_time, for speed reasons.
cdef double frame_time
frame_time = 0

# Are we doing a per_frame update?
per_frame = False

# Are we rendering for the purpose of sizing something.
sizing = False

# This is true if we're using a renderer that supports models,
# false otherwise.
models = False

def adjust_render_cache_times(old_time, new_time):
    """
    This adjusts the render cache such that if a render starts at
    old_time, it really started at new_time.
    """

    for id_d, renders in (<dict> render_cache).iteritems():

        # Check to see if we have a render with st_base = old_time. If so,
        # we need to rebase it.
        for k in renders:
            if k[2] == old_time:
                break
        else:
            continue

        new_renders = { }

        for k, v in (<dict> renders).iteritems():
            w, h, st_base, at_base = k

            if st_base == old_time:
                st_base = new_time

            if at_base == old_time:
                at_base = new_time

            new_renders[(w, h, st_base, at_base)] = v

        render_cache[id_d] = new_renders


def free_memory():
    """
    Frees memory used by the render system.
    """

    global screen_render
    screen_render = None

    mark_sweep()

    render_cache.clear()

    # This can hang onto a render.
    renpy.display.interface.surftree = None


def check_at_shutdown():
    """
    This is called at shutdown time to check that everything went okay.
    The big thing it checks for is memory leaks.
    """

    if not renpy.config.developer:
        return

    free_memory()

    gc.collect()

    if gc.garbage:
        del gc.garbage[:]

    l = gc.get_objects()

    count = 0
    objects = gc.get_objects()

    for i in objects:
        if isinstance(i, Render):
            count += 1

    if count:
        raise Exception("%d Renders are alive at shutdown. This is probably a memory leak bug in Ren'Py." % count)


# The number of things being rendered at the moment.
cdef int rendering
rendering = 0

# The st and at of the current call to render.
render_st = 0.0
render_at = 0.0

cdef bint render_is_ready
render_is_ready = 0

def render_ready():
    global render_is_ready
    render_is_ready = 1

# These are good until the next call to render.
render_width = 0
render_height = 0

cpdef render(d, object widtho, object heighto, double st, double at):
    """
    :doc: udd_utility
    :args: (d, width, height, /, st, at)

    Causes a displayable to be rendered, and a renpy.Render object to
    be returned.

    `d`
        The displayable to render.

    `width`, `height`
        The width and height available for the displayable to render into.

    `st`, `at`
        The shown and animation timebases.

    Renders returned by this object may be cached, and should not be modified
    once they have been retrieved.
    """

    global rendering
    global render_width
    global render_height
    global render_st
    global render_at

    cdef float width, height
    cdef float orig_width, orig_height
    cdef tuple orig_wh, wh
    cdef dict render_cache_d
    cdef Render rv

    if not render_is_ready:
        if renpy.config.developer:
            raise Exception("Displayables may not be rendered during the init phase.")

    orig_wh = (widtho, heighto, frame_time-st, frame_time-at)

    render_width = widtho
    render_height = heighto

    id_d = id(d)
    render_cache_d = render_cache[id_d]
    rv = render_cache_d.get(orig_wh, None)

    if rv is not None:
        return rv

    orig_width = width = widtho
    orig_height = height = heighto

    style = d.style
    xmaximum = style.xmaximum
    ymaximum = style.ymaximum

    if d._offer_size is not None:
        width, height = d._offer_size

    if xmaximum is not None:
        width = min(renpy.display.core.absolute.compute_raw(xmaximum, width), width)

    if ymaximum is not None:
        height = min(renpy.display.core.absolute.compute_raw(ymaximum, height), height)

    if width < 0:
        width = 0
    if height < 0:
        height = 0

    if orig_width != width or orig_height != height:
        widtho = width
        heighto = height
        wh = (widtho, heighto, frame_time-st, frame_time-at)
        rv = render_cache_d.get(wh, None)

        if rv is not None:
            return rv

    else:
        wh = orig_wh

    renpy.plog(2, "start render {!r}", d)

    try:
        rendering += 1
        old_st = render_st
        old_at = render_at
        render_st = st
        render_at = at
        rv = d.render(widtho, heighto, st, at)
    finally:
        rendering -= 1
        render_st = old_st
        render_at = old_at

    if rv.__class__ is not Render:
        raise Exception("{!r}.render() must return a Render.".format(d))

    rv.render_of.append(d)
    rv.cache_killed = False

    if d._clipping:
        renpy.plog(4, "before clipping")
        rv = rv.subsurface((0, 0, rv.width, rv.height), focus=True)
        rv.render_of.append(d)
        renpy.plog(4, "after clipping")

    rv.debug = style.debug or rv.debug

    if not sizing:

        # This lookup is needed because invalidations are possible.
        render_cache_d = render_cache[id_d]
        render_cache_d[wh] = rv

        if wh is not orig_wh:
            render_cache_d[orig_wh] = rv

    renpy.plog(2, "end render {!r}", d)

    return rv

def render_for_size(d, width, height, st, at):
    """
    This returns a render of `d`  that's useful for getting the size or
    screen location, but not for actual rendering.
    """

    global sizing

    id_d = id(d)
    orig_wh = (width, height, frame_time-st, frame_time-at)
    render_cache_d = render_cache[id_d]
    rv = render_cache_d.get(orig_wh, None)

    if rv is not None:
        return rv

    old_sizing = sizing
    sizing = True

    try:
        return render(d, width, height, st, at)
    finally:
        sizing = old_sizing


def invalidate(d):
    """
    Removes d from the render cache. If we're not in a redraw, triggers
    a redraw to start.
    """

    if (not rendering) and (not per_frame) and (not sizing):
        redraw(d, 0)
        return

    for v in list(render_cache[id(d)].values()):
        v.kill_cache()

def check_redraws():
    """
    Returns true if a redraw is required, and False otherwise.
    """

    redraw_queue.sort(key=lambda a : a[0])

    now = renpy.display.core.get_time()

    for when, d in redraw_queue:

        id_d = id(d)

        if id_d not in render_cache:
            continue

        if when <= now:
            return True

    return False

def process_redraws():
    """
    Removes any pending redraws from the redraw queue.
    """

    global redraw_queue

    redraw_queue.sort(key=lambda a : a[0])

    now = renpy.display.core.get_time()
    rv = False

    new_redraw_queue = [ ]
    seen = set()

    for t in redraw_queue:
        when, d = t

        id_d = id(d)

        if id_d in seen:
            continue

        seen.add(id_d)

        if id_d not in render_cache:
            continue

        if when <= now:

            # Remove this displayable and all its parents from the
            # render cache. But don't kill them yet, as that will kill the
            # children that we want to reuse.

            for v in list(render_cache[id_d].values()):
                v.kill_cache()

            rv = True

        else:
            new_redraw_queue.append(t)

    redraw_queue = new_redraw_queue

    return rv


def redraw_time():
    """
    Returns the time at which the next redraw is scheduled.
    """

    if redraw_queue:
        return redraw_queue[0][0]

    return None


def redraw(d, when):
    """
    Documented in cdd.rst.
    """

    if not renpy.game.interface:
        return

    if per_frame:
        invalidate(d)
        return

    redraw_queue.append((when + renpy.game.interface.frame_time, d))


IDENTITY = renpy.display.matrix.IDENTITY


def take_focuses(focuses):
    """
    Adds a list of rectangular focus regions to the focuses list.
    """

    screen_render.take_focuses(
        0, 0,
        screen_render.width, screen_render.height,
        IDENTITY,
        None,
        focuses)

# The result of focus_at_point for a modal render. This overrides any
# specific focus from below us.
Modal = renpy.object.Sentinel("Modal")

def focus_at_point(x, y):
    """
    Returns a focus object corresponding to the uppermost displayable
    at point, or None if nothing focusable is at point.
    """

    if screen_render is None:
        return None

    cf = screen_render.focus_at_point(x, y, None)
    if cf is None or cf is Modal:
        return None
    else:
        d, arg, screen = cf
        return renpy.display.focus.Focus(d, arg, None, None, None, None, screen)


def mutated_surface(surf):
    """
    Called to indicate that the given surface has changed.
    """

    renpy.display.draw.mutated_surface(surf)


def render_screen(root, width, height):
    """
    Renders `root` (a displayable) as the root of a screen with the given
    `width` and `height`.
    """

    global screen_render
    global invalidated
    global frame_time

    interact_time = renpy.display.interface.interact_time
    frame_time = renpy.display.interface.frame_time

    if interact_time is None:
        st = 0
    else:
        st = frame_time  - interact_time

    rv = render(root, width, height, st, st)
    screen_render = rv

    invalidated = False

    return rv

def mark_sweep():
    """
    This performs mark-and-sweep garbage collection on the live_renders
    list.
    """

    global live_renders

    cdef list worklist
    cdef int i
    cdef Render r, j
    cdef object o

    worklist = [ ]

    if screen_render is not None:
        worklist.append(screen_render)

    worklist.extend(renpy.display.im.cache.get_renders())

    for r in worklist:
        r.mark = True

    i = 0

    while i < len(worklist):
        r = worklist[i]

        for j in r.depends_on_list:
            if not j.mark:
                j.mark = True
                worklist.append(j)

        i += 1

    if renpy.emscripten:
        # Do not kill Renders that cache the last video frame
        for o in renpy.display.video.texture.values():
            if isinstance(o, Render):
                o.mark = True

    for r in live_renders:
        if not r.mark:
            r.kill()
        else:
            r.mark = False

    live_renders = worklist


# Possible operations that can be done as part of a render. Not used anymore, but kept
# for compatibility.
BLIT = 0
DISSOLVE = 1
IMAGEDISSOLVE = 2
PIXELLATE = 3
FLATTEN = 4

# Possible matrix kinds.
MATRIX_VIEW = 0
MATRIX_MODEL = 1
MATRIX_PROJECTION = 2

cdef class Render:

    def __init__(Render self, float width, float height, layer_name=None): #@DuplicatedSignature
        """
        Creates a new render corresponding to the given widget with
        the specified width and height.

        If `layer_name` is given, then this render corresponds to a
        layer.
        """

        # The mark bit, used for mark/sweep-style garbage collection of
        # renders.
        self.mark = False

        # Is has this render been removed from the cache?
        self.cache_killed = False

        # Has this render been completely killed?
        self.killed = False

        self.width = width
        self.height = height

        self.layer_name = layer_name

        # A list of (surface/render, xoffset, yoffset, focus, main) tuples, ordered from
        # back to front.
        self.children = [ ]

        # Forward is used to transform from screen coordinates to child
        # coordinates.
        # Reverse is used to transform from child coordinates to screen
        # coordinates.
        #
        # For performance reasons, these aren't used to transform the
        # x and y offsets found in self.children. Those offsets should
        # be of the (0, 0) point in the child coordinate space.
        self.forward = None
        self.reverse = None

        # The kind of matrix that is being updated by this displayable.
        self.matrix_kind = MATRIX_MODEL

        # This is used to adjust the alpha of children of this render.
        self.alpha = 1

        # The over blending factor. When this is 1.0, blends only use the
        # over operation. When set to 0.0, we get additive blending.
        self.over = 1.0

        # If true, children of this render use nearest-neighbor texture
        # lookup. If false, bilinear, if None, from the parent.
        self.nearest = None

        # A list of focus regions in this displayable.
        self.focuses = None

        # Other renders that we should pass focus onto.
        self.pass_focuses = None

        # The ScreenDisplayable this is a render of.
        self.focus_screen = None

        # The displayable(s) that this is a render of. (Set by render)
        self.render_of = [ ]

        # Should children be clipped to a rectangle?
        self.xclipping = False
        self.yclipping = False

        # Are we modal?
        self.modal = False

        # Are we a text input?
        self.text_input = False

        # gl, sw

        # The set of renders that either have us as children, or depend on
        # us.
        self.parents = set()

        # The renders we depend on, including our children.
        self.depends_on_list = [ ]

        # The operation we're performing. (BLIT, DISSOLVE, OR IMAGE_DISSOLVE)
        self.operation = BLIT

        # The fraction of the operation that is complete.
        self.operation_complete = 0.0

        # Should the dissolve operations preserve alpha?
        self.operation_alpha = False

        # The parameter to the operation.
        self.operation_parameter = 0

        # Caches of the texture created by rendering this surface.
        self.surface = None
        self.alpha_surface = None

        # Cache of the texture created by rendering this surface at half size.
        # (This is set in gldraw.)
        self.half_cache = None

        # gl2

        # The mesh. If this is not None, the children are all rendered to Textures,
        # and used to form a model. If this is True, the Mesh is taken from the first
        # child's Texture, otherwise this must be a Mesh.
        self.mesh = None

        # A tuple of shaders that will be used when rendering, or None.
        self.shaders = None

        # A dictionary containing uniforms that will be used when rendering, or
        # None.
        self.uniforms = None

        # Properties that are used for rendering.
        self.properties = None

        # Used to cache the result of rendering this Render to a texture.
        self.cached_texture = None

        # Used to cache the model.
        self.cached_model = None

        # Have the textures been loaded?
        self.loaded = False

        # Do the uniforms have a render in them?
        self.uniforms_has_render = False

        live_renders.append(self)

    _types = """\
        mark: bool
        cache_killed: bool
        killed: bool
        width: int
        height: int
        layer_name: str
        children : list[tuple[Render, int, int, bool, bool]]
        forward: renpy.display.matrix.Matrix
        reverse: renpy.display.matrix.Matrix
        alpha: float
        over: float
        nearest: bool
        focuses: list[renpy.display.focus.Focus]
        pass_focuses: list[Render]
        focus_screen: renpy.display.screen.ScreenDisplayable
        render_of: list[renpy.display.core.Displayable]
        xclipping: bool
        yclipping: bool
        modal: bool
        text_input: bool
        parents: set[Render]
        depends_on_list: list[Render]
        operation: int
        operation_complete: float
        operation_alpha: bool
        operation_parameter: float
        surface: Any
        alpha_surface: Any
        half_cache: Any
        mesh: Any
        shaders: tuple
        uniforms: dict
        properties: dict
        cached_texture: Any
        cached_model: Any
        loaded: bool
        uniforms_has_render: bool
        """

    def __repr__(self): #@DuplicatedSignature
        if self.killed:
            live = "dead "
        elif self.cache_killed:
            live = "cache-killed "
        else:
            live = ""

        return "<{}Render {:x} of {!r}>".format(
            live,
            id(self),
            self.render_of)

    def __getstate__(self): #@DuplicatedSignature
        if renpy.config.developer:
            raise Exception("Can't pickle a Render.")
        else:
            return { }

    def __setstate__(self, state): #@DuplicatedSignature
        return

    cpdef int blit(Render self, source, tuple pos, object focus=True, object main=True, object index=None):
        """
        Blits `source` (a Render, Surface, or GL2Model) to this Render, offset by
        xo and yo.

        If `focus` is true, then focuses are added from the child to the
        parent.

        This will only blit on integer pixel boundaries.
        """

        if source is self:
            raise Exception("Blitting to self.")

        if models:
            if isinstance(source, pygame.Surface):
                source = renpy.display.draw.load_texture(source)

        (xo, yo) = pos

        xo = int(xo)
        yo = int(yo)

        if index is None:
            self.children.append((source, xo, yo, focus, main))
        else:
            self.children.insert(index, (source, xo, yo, focus, main))

        if isinstance(source, Render):
            self.depends_on_list.append(source)
            source.parents.add(self)

        return 0

    cpdef int subpixel_blit(Render self, source, tuple pos, object focus=True, object main=True, object index=None):
        """
        Blits `source` (a Render, Surface, or GL2Model) to this Render, offset by
        xo and yo.

        If `focus` is true, then focuses are added from the child to the
        parent.

        This blits at fractional pixel boundaries.
        """

        if source is self:
            raise Exception("Blitting to self.")

        if models:
            if isinstance(source, pygame.Surface):
                source = renpy.display.draw.load_texture(source)

        (xo, yo) = pos

        xo = float(xo)
        yo = float(yo)

        if index is None:
            self.children.append((source, xo, yo, focus, main))
        else:
            self.children.insert(index, (source, xo, yo, focus, main))

        if isinstance(source, Render):
            self.depends_on_list.append(source)
            source.parents.add(self)

        return 0

    cpdef int absolute_blit(Render self, source, tuple pos, object focus=True, object main=True, object index=None):
        """
        Blits `source` (a Render or Surface) to this Render, offset by
        xo and yo.

        If `focus` is true, then focuses are added from the child to the
        parent.

        This blits at fractional pixel boundaries.
        """

        if source is self:
            raise Exception("Blitting to self.")

        if models:
            if isinstance(source, pygame.Surface):
                source = renpy.display.draw.load_texture(source)

        (xo, yo) = pos

        xo = renpy.display.core.absolute(xo)
        yo = renpy.display.core.absolute(yo)

        if index is None:
            self.children.append((source, xo, yo, focus, main))
        else:
            self.children.insert(index, (source, xo, yo, focus, main))

        if isinstance(source, Render):
            self.depends_on_list.append(source)
            source.parents.add(self)

        return 0


    def get_size(self):
        """
        Returns the size of this Render, a mostly fictitious value
        that's taken from the inputs to the constructor. (As in, we
        don't clip to this size.)
        """

        return self.width, self.height


    def render_to_texture(self, alpha=True):
        """
        Returns a texture constructed from this render. This may return
        a cached texture, if one has already been rendered.

        `alpha` is a hint that controls if the surface should have
        alpha or not.

        This returns a texture that's at the drawable resolution, which
        may be bigger than the virtual resolution. Use renpy.display.draw.draw_to_virt
        and draw.virt_to_draw to convert between the two resolutions. (For example,
        multiply reverse by draw_to_virt to scale this down for blitting.)
        """

        if alpha:
            if self.alpha_surface is not None:
                return self.alpha_surface
        else:
            if self.surface is not None:
                return self.surface

        rv = renpy.display.draw.render_to_texture(self, alpha)

        # Stash and return the surface.
        if alpha:
            self.alpha_surface = rv
        else:
            self.surface = rv

        return rv

    pygame_surface = render_to_texture


    def compute_subline(self, sx, sw, cx, cw, bx, bw):
        """
        Given a source line (start sx0, width sw) and a crop line (cx0, cw),
        return three things:

        * The offset of the portion of the source line that overlaps with
        the crop line, relative to the crop line.
        * The offset of the portion of the source line that overlaps with the
        the crop line, relative to the source line.
        * The length of the overlap in pixels. (can be <= 0)
        """


        s_end = sx + sw
        c_end = cx + cw

        start = max(sx, cx)

        offset = start - cx
        crop = start - sx

        end = min(s_end, c_end)
        width = end - start

        bsx = max(sx, bx)

        if bsx < 0:
            offset += bsx
            crop += bsx
            width -= bsx

        return offset, crop, width


    def subsurface(self, rect, focus=False, subpixel=False, bounds=None):
        """
        Returns a subsurface of this render. If `focus` is true, then
        the focuses are copied from this render to the child.
        """

        (x, y, w, h) = rect

        if not subpixel:
            x = int(x)
            y = int(y)
            w = int(w)
            h = int(h)

        if bounds is not None:
            bx, by, bw, bh = bounds
        else:
            bx = x
            by = y
            bw = w
            bh = h

        rv = Render(w, h)

        reverse = self.reverse

        this = self

        if (reverse is not None) and (reverse.wdw != 1.0):
            this = Render(self.width, self.height)
            this.mesh = True
            this.add_shader("renpy.texture")
            this.blit(self, (0, 0), focus=focus, main=True)
            reverse = None

        if ((reverse is not None) and
            (reverse.xdx != 1.0 or
            reverse.xdy != 0.0 or
            reverse.ydx != 0.0 or
            reverse.ydy != 1.0) or
            this.mesh):

            # This doesn't actually make a subsurface, as we can't easily do
            # so for non-rectangle-aligned renders.

            rv.xclipping = True
            rv.yclipping = True

            # Try to avoid clipping if a surface fits entirely inside the
            # rectangle.

            if subpixel:
                rv.subpixel_blit(this, (-x, -y), focus=focus, main=True)
            else:
                rv.blit(this, (-x, -y), focus=focus, main=True)

            return rv

        # This is the path that executes for rectangle-aligned surfaces,
        # making an actual subsurface.

        for child, cx, cy, cfocus, cmain in self.children:

            child_subpixel = subpixel or not isinstance(cx, int) or not isinstance(cy, int)

            childw, childh = child.get_size()
            xo, cx, cw = self.compute_subline(cx, childw, x, w, bx, bw)
            yo, cy, ch = self.compute_subline(cy, childh, y, h, by, bh)

            cbx = bx - xo
            cby = by - yo

            if cw <= 0 or ch <= 0 or w - xo <= 0 or h - yo <= 0:
                continue

            if cx < 0 or cx >= childw or cy < 0 or cy >= childh:
                continue

            offset = (xo, yo)
            crop = None

            try:
                if isinstance(child, Render):

                    if child.xclipping:
                        end = min(cw, cbx+bw)
                        cbx = max(0, cbx)
                        cbw = end - cbx

                        cropw = cw
                    else:
                        cropw = w - xo
                        cbw = bw

                    if child.yclipping:
                        end = min(ch, cby+bh)
                        cby = max(0, cby)
                        cbh = end - cby

                        croph = ch
                    else:
                        croph = h - yo
                        cbh = bh

                    crop = (cx, cy, cropw, croph)
                    newchild = child.subsurface(crop, focus=focus, subpixel=child_subpixel, bounds=(cbx, cby, cbw, cbh))
                    newchild.render_of = child.render_of[:]
                    newchild.xclipping = child.xclipping or newchild.xclipping
                    newchild.yclipping = child.yclipping or newchild.yclipping

                else:

                    crop = (cx, cy, cw, ch)
                    newchild = child.subsurface(crop)
                    renpy.display.draw.mutated_surface(newchild)

            except Exception:
                raise Exception("Creating subsurface failed. child size = ({}, {}), crop = {!r}".format(childw, childh, crop))

            if child_subpixel:
                rv.subpixel_blit(newchild, offset, focus=cfocus, main=cmain)
            else:
                rv.blit(newchild, offset, focus=cfocus, main=cmain)

        if focus and self.focuses:

            for (d, arg, xo, yo, fw, fh, mx, my, mask) in self.focuses:

                if xo is None:
                    rv.add_focus(d, arg, xo, yo, fw, fh, mx, my, mask)
                    continue

                xo, cx, fw = self.compute_subline(xo, fw, x, w, bx, bw)
                yo, cy, fh = self.compute_subline(yo, fh, y, h, by, bh)

                if fw <= 0 or fh <= 0:
                    continue

                if mx is not None:

                    mw, mh = mask.get_size()

                    mx, mcx, mw = self.compute_subline(mx, mw, x, w, bx, bw)
                    my, mcy, mh = self.compute_subline(my, mh, y, h, by, bh)

                    if mw <= 0 or mh <= 0:
                        mx = None
                        my = None
                        mask = None
                    else:
                        mask = mask.subsurface((mcx, mcy, mw, mh))

                rv.add_focus(d, arg, xo, yo, fw, fh, mx, my, mask)

        rv.depends_on(self)
        rv.alpha = self.alpha
        rv.over = self.over
        rv.operation = self.operation
        rv.operation_alpha = self.operation_alpha
        rv.operation_complete = self.operation_complete
        rv.nearest = self.nearest

        rv.mesh = self.mesh
        rv.shaders = self.shaders
        rv.uniforms = self.uniforms
        rv.properties = self.properties

        rv.text_input = self.text_input

        return rv


    def depends_on(self, source, focus=False):
        """
        Used to indicate that this render depends on another
        render. Useful, for example, if we use pygame_surface to make
        a surface, and then blit that surface into another render.
        """

        if source is self:
            raise Exception("Render depends on itself.")

        self.depends_on_list.append(source)
        source.parents.add(self)

        if focus:
            if self.pass_focuses is None:
                self.pass_focuses = [ source ]
            else:
                self.pass_focuses.append(source)


    def kill_cache(self):
        """
        Removes this render and its transitive parents from the cache.
        """

        if self.cache_killed:
            return

        self.cache_killed = True

        for i in list(self.parents):
            i.kill_cache()

        for ro in self.render_of:
            id_ro = id(ro)

            cache = render_cache[id_ro]
            for k, v in list(cache.items()):
                if v is self:
                    del cache[k]

            if not cache:
                del render_cache[id_ro]

    def kill(self):
        """
        Prepares this render and its parents for deallocation.
        """

        if self.killed:
            return

        self.killed = True

        for i in list(self.parents):
            i.kill()

        self.parents.clear()

        for i in list(self.depends_on_list):
            i.parents.discard(self)

        for ro in self.render_of:
            id_ro = id(ro)

            cache = render_cache[id_ro]
            for k, v in list(cache.items()):
                if v is self:
                    del cache[k]

            if not cache:
                del render_cache[id_ro]

        # Break references to other Renders.
        #
        # This is conditional, as there is a special case that needs to be
        # dealt with. GL2 breaks large surfaces into multiple textures combined
        # by a Render. These should not be changed on a cache kill, but since
        # these can't depend on a Render, can't cause cycles.
        if self.depends_on_list:
            del self.depends_on_list[:]
            del self.render_of[:]
            del self.children[:]

        self.focuses = None
        self.pass_focuses = None

        self.cached_texture = None
        self.cached_model = None

    NO_MOUSE_FOCUS = renpy.object.Sentinel("NO_MOUSE_FOCUS")

    def add_focus(self, d, arg=None, x=0, y=0, w=None, h=None, mx=None, my=None, mask=None):
        """
        This is called to indicate a region of the screen that can be
        focused.

        `d` - the displayable that is being focused.
        `arg` - an argument.

        The rest of the parameters are a rectangle giving the portion of
        this region corresponding to the focus.


        If they are all None, than this focus is assumed to be the singular full-screen focus.
        If they are all False, this focus can be grabbed, but will not be focused by mouse
        or keyboard focus.
        """

        if isinstance(mask, Render) and mask is not self:
            self.depends_on(mask)

        t = (d, arg, x, y, w, h, mx, my, mask)

        if self.focuses is None:
            self.focuses = [ t ]
        else:
            self.focuses.append(t)

    def take_focuses(self, cminx, cminy, cmaxx, cmaxy, transform, screen, focuses): #@DuplicatedSignature
        """
        This adds to focuses Focus objects corresponding to the focuses
        added to this object and its children, transformed into screen
        coordinates.

        `cminx`, `cminy`, `cmaxx`, `cmaxy`
            The clipping rectangle.

        `reverse`
            The transform from render to screen coordinates.

        `screen`
            The screen this is a render of, or None if this is not part of
            a screen.

        `focuses`
            The list of focuses to add to.
        """

        if self.focus_screen is not None:
            screen = self.focus_screen

        if self.modal:

            if self.modal == "window":

                x1, y1 = transform.transform(0, 0)
                x2, y2 = transform.transform(self.width, self.height)

                minx = min(x1, x2)
                maxx = max(x1, x2)
                miny = min(y1, y2)
                maxy = max(y1, y2)

                new_focuses = [ ]

                rect = (minx, miny, maxx - minx, maxy - miny)

                for f in focuses:

                    if f.inside(rect):
                        continue

                    new_focuses.append(f)

                focuses[:] = new_focuses

            elif not callable(self.modal):

                focuses[:] = [ ]

        if self.focuses:

            for (d, arg, xo, yo, w, h, mx, my, mask) in self.focuses:

                if xo is None or xo is False:
                    focuses.append(renpy.display.focus.Focus(d, arg, xo, yo, w, h, screen))
                    continue

                x1, y1 = transform.transform(xo, yo)
                x2, y2 = transform.transform(xo + w, yo + h)

                minx = min(x1, x2)
                maxx = max(x1, x2)
                miny = min(y1, y2)
                maxy = max(y1, y2)

                minx = max(minx, cminx)
                maxx = min(maxx, cmaxx)
                miny = max(miny, cminy)
                maxy = min(maxy, cmaxy)

                if maxx <= minx:
                    continue
                if maxy <= miny:
                    continue

                focuses.append(renpy.display.focus.Focus(d, arg, minx, miny, maxx - minx, maxy - miny, screen))

        if self.xclipping or self.yclipping:

            x1, y1 = transform.transform(0, 0)
            x2, y2 = transform.transform(self.width, self.height)

            if self.xclipping:
                minx = min(x1, x2)
                maxx = max(x1, x2)
                cminx = max(minx, cminx)
                cmaxx = min(maxx, cmaxx)

            if self.yclipping:
                miny = min(y1, y2)
                maxy = max(y1, y2)
                cminy = max(miny, cminy)
                cmaxy = min(maxy, cmaxy)

        for child, cx, cy, focus, main in self.children:

            if not focus:
                continue

            if not isinstance(child, Render):
                continue

            child_transform = transform

            if (cx or cy):
                child_transform = child_transform * Matrix.coffset(cx, cy, 0)

            if (self.reverse is not None) and (self.reverse is not IDENTITY):
                child_transform = child_transform * self.reverse

            child.take_focuses(cminx, cminy, cmaxx, cmaxy, child_transform, screen, focuses)

        if self.pass_focuses:
            for child in self.pass_focuses:
                child.take_focuses(cminx, cminy, cmaxx, cmaxy, transform, screen, focuses)

    def focus_at_point(self, x, y, screen): #@DuplicatedSignature
        """
        This returns the focus of this object at the given point.
        """

        if self.focus_screen is not None:
            screen = self.focus_screen

        if self.xclipping:
            if x < 0 or x >= self.width:
                return None

        if self.yclipping:
            if y < 0 or y >= self.height:
                return None

        if self.forward and self.forward.is_2d_null():
            return None

        rv = None

        if self.pass_focuses:
            for child in reversed(self.pass_focuses):
                rv = child.focus_at_point(x, y, screen)
                if rv is not None:
                    break

        if rv is None:

            for child, xo, yo, focus, main in reversed(self.children):

                if not focus or not isinstance(child, Render):
                    continue

                cx = x - xo
                cy = y - yo

                if self.forward:
                    cx, cy = self.forward.transform(cx, cy)

                rv = child.focus_at_point(cx, cy, screen)
                if rv is not None:
                    break

        if (rv is None) and (self.focuses):
            for (d, arg, xo, yo, w, h, mx, my, mask) in reversed(self.focuses):

                if xo is None or xo is False:
                    continue

                if arg is self.NO_MOUSE_FOCUS:
                    continue

                elif mx is not None:
                    cx = x - mx
                    cy = y - my

                    if self.forward:
                        cx, cy = self.forward.transform(cx, cy)

                    if isinstance(mask, Render):
                        if cx < 0 or cx >= mask.width:
                            continue
                        if cy < 0 or cy >= mask.height:
                            continue

                        if mask.is_pixel_opaque(cx, cy):
                            rv = d, arg, screen
                    else:
                        mask_result = mask(cx, cy)

                        if callable(mask_result):
                            mask_result = mask_result(cx, cy, w - mx, w - my)

                        if mask_result:
                            rv = d, arg, screen

                elif xo <= x < xo + w and yo <= y < yo + h:
                    rv = d, arg, screen

                if rv is not None:
                    break

        if rv is not None:
            if self.operation == IMAGEDISSOLVE:
                if not self.children[0][0].is_pixel_opaque(x, y):
                    rv = None

        if (rv is None) and self.modal:
            w = self.width
            h = self.height

            if self.modal == "default":
                w = None
                h = None

            if renpy.display.layout.check_modal(self.modal, None, x, y, w, h):
                return Modal

        return rv


    def main_displayables_at_point(self, x, y, layers, depth=None):
        """
        Returns the displayable at `x`, `y` on one of the layers in
        the set or list `layers`.
        """

        rv = [ ]

        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return rv

        is_screen = False

        if depth is not None:
            for d in self.render_of:
                rv.append((depth, self.width, self.height, d))
                depth += 1

                if isinstance(d, renpy.display.screen.ScreenDisplayable):
                    is_screen = True

        elif self.layer_name in layers:
            depth = 0

        for (child, xo, yo, focus, main) in self.children:
            if not main or not isinstance(child, Render):
                continue

            cx = x - xo
            cy = y - yo

            if self.forward:
                cx, cy = self.forward.transform(cx, cy)

            if is_screen:
                # Ignore the fixed at the root of every screen.
                cf = child.main_displayables_at_point(cx, cy, layers, depth - 1)
                rv.extend(cf[1:])
            else:
                cf = child.main_displayables_at_point(cx, cy, layers, depth)
                rv.extend(cf)

        return rv


    def is_pixel_opaque(self, x, y):
        """
        Determine if the pixel at x and y is opaque or not.
        """

        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return False

        what = self.subsurface((x, y, 1, 1))

        if what.is_fully_transparent():
            return False

        return renpy.display.draw.is_pixel_opaque(what)

    def is_fully_transparent(self):
        """
        Returns true if we are sure this pixel is fully transparent.

        This is intended to help optimize is_pixel_opaque, by making
        the draw unnecessary if there is no child render at the given
        location. It can be wrong, so long as it errs by returning
        False.
        """

        if self.alpha == 0:
            return True

        for (child, xo, yo, focus, main) in self.children:
            if isinstance(child, Render):
                if not child.is_fully_transparent():
                    return False
            else:
                return False

        return True


    def fill(self, color):
        """
        Fills this Render with the given color.
        """

        color = renpy.easy.color(color)
        solid = renpy.display.imagelike.Solid(color)
        surf = render(solid, self.width, self.height, 0, 0)
        self.blit(surf, (0, 0), focus=False, main=False)


    def canvas(self):
        """
        Returns a canvas object that draws to this Render.
        """

        surf = renpy.display.pgrender.surface((self.width, self.height), True)

        mutated_surface(surf)

        self.blit(surf, (0, 0))

        return Canvas(surf)

    def screen_rect(self, double sx, double sy, Matrix transform):
        """
        Returns the rectangle, in screen-space coordinates, that will be covered
        by this render when it's drawn to the screen at sx, sy, with the transform
        `transform`.
        """

        if transform is None:
            transform = IDENTITY

        cdef double w = self.width
        cdef double h = self.height

        cdef double xdx = transform.xdx
        cdef double xdy = transform.xdy
        cdef double ydx = transform.ydx
        cdef double ydy = transform.ydy

        # Transform the vertex coordinates to screen-space.
        cdef double x0 = sx
        cdef double y0 = sy

        cdef double x1 = w * xdx + sx
        cdef double y1 = w * ydx + sy

        cdef double x2 = h * xdy + sx
        cdef double y2 = h * ydy + sy

        cdef double x3 = w * xdx + h * xdy + sx
        cdef double y3 = w * ydx + h * ydy + sy

        cdef double minx = min(x0, x1, x2, x3)
        cdef double maxx = max(x0, x1, x2, x3)
        cdef double miny = min(y0, y1, y2, y3)
        cdef double maxy = max(y0, y1, y2, y3)

        return (
            int(minx),
            int(miny),
            int(math.ceil(maxx - minx)),
            int(math.ceil(maxy - miny)),
            )

    def place(self, d, x=0, y=0, width=None, height=None, st=None, at=None, render=None, main=True):
        """
        Documented in udd.rst.
        """

        if width is None:
            width = self.width
        if height is None:
            height = self.height

        if render is None:
            if st is None:
                st = render_st
            if at is None:
                at = render_at

            render = renpy.display.render.render(d, width, height, st, at)

        return d.place(self, x, y, width, height, render, main=main)

    def zoom(self, xzoom, yzoom):
        """
        Sets the zoom factor applied to this displayable's children.
        """
        if self.reverse is None:
            self.reverse = IDENTITY
            self.forward = IDENTITY

        self.reverse *= Matrix2D(xzoom, 0, 0, yzoom)

        if xzoom and yzoom:
            self.forward *= Matrix2D(1.0 / xzoom, 0, 0, 1.0 / yzoom)
        else:
            self.forward *= Matrix2D(0, 0, 0, 0)

    def add_shader(self, shader):
        """
        Adds a shader to the list of shaders that will be used to render
        this Render and its children.
        """

        if self.shaders is None:
            self.shaders = (shader,)
            return

        if shader in self.shaders:
            return

        self.shaders = self.shaders + (shader,)

    def add_uniform(self, name, value):
        """
        Adds a uniform with the given name and value that will be passed
        to the shaders that render this Render and its children.
        """

        if type(value) is Render:
            self.depends_on(value)
            self.uniforms_has_render = True

        if self.uniforms is None:
            self.uniforms = { name : value }
        else:
            self.uniforms[name] = value

    def add_property(self, name, value):
        """
        Adds a render property with name and value.
        """

        if name[:3] == "gl_":
            name = name[3:]

        if self.properties is None:
            self.properties = { name : value }
        else:
            self.properties[name] = value

    def get_property(self, name, default):

        if self.properties is None:
            return default

        if name[:3] == "gl_":
            name = name[3:]

        return self.properties.get(name, default)


class Canvas(object):

    def __init__(self, surf): #@DuplicatedSignature
        self.surf = surf

    def rect(self, color, rect, width=0):

        try:
            blit_lock.acquire()
            pygame.draw.rect(self.surf,
                             renpy.easy.color(color),
                             rect,
                             width)
        finally:
            blit_lock.release()

    def polygon(self, color, pointlist, width=0):
        try:
            blit_lock.acquire()
            pygame.draw.polygon(self.surf,
                                renpy.easy.color(color),
                                pointlist,
                                width)
        finally:
            blit_lock.release()

    def circle(self, color, pos, radius, width=0):

        try:
            blit_lock.acquire()
            pygame.draw.circle(self.surf,
                               renpy.easy.color(color),
                               pos,
                               radius,
                               width)

        finally:
            blit_lock.release()

    def ellipse(self, color, rect, width=0):
        try:
            blit_lock.acquire()
            pygame.draw.ellipse(self.surf,
                                renpy.easy.color(color),
                                rect,
                                width)
        finally:
            blit_lock.release()


    def arc(self, color, rect, start_angle, stop_angle, width=1):
        try:
            blit_lock.acquire()
            pygame.draw.arc(self.surf,
                            renpy.easy.color(color),
                            rect,
                            start_angle,
                            stop_angle,
                            width)
        finally:
            blit_lock.release()


    def line(self, color, start_pos, end_pos, width=1):
        try:
            blit_lock.acquire()
            pygame.draw.line(self.surf,
                             renpy.easy.color(color),
                             start_pos,
                             end_pos,
                             width)
        finally:
            blit_lock.release()

    def lines(self, color, closed, pointlist, width=1):
        try:
            blit_lock.acquire()
            pygame.draw.lines(self.surf,
                              renpy.easy.color(color),
                              closed,
                              pointlist,
                              width)
        finally:
            blit_lock.release()

    def aaline(self, color, startpos, endpos, blend=1):
        try:
            blit_lock.acquire()
            pygame.draw.aaline(self.surf,
                               renpy.easy.color(color),
                               startpos,
                               endpos,
                               blend)
        finally:
            blit_lock.release()

    def aalines(self, color, closed, pointlist, blend=1):
        try:
            blit_lock.acquire()
            pygame.draw.aalines(self.surf,
                                renpy.easy.color(color),
                                closed,
                                pointlist,
                                blend)
        finally:
            blit_lock.release()

    def get_surface(self):
        return self.surf

_types = """
screen_render : Render|None
IDENTITY : renpy.display.matrix.Matrix
blit_lock : threading.Condition
"""
