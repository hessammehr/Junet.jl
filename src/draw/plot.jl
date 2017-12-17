## Plotting networks with Cairo ##

# TODO further play around with the color options
# TODO: introduce color maps for real-valued attributes
# TODO: draw parallel edges gracefully, like in graph-tool

@inline _attribute(v::T) where {T<:AbstractVector} = v
@inline _attribute(v::T) where {T<:AbstractAttribute} = v
@inline _attribute(v::Any) = ConstantAttribute(v)

@inline _color(c::T) where {T<:Tuple{Integer, Integer, Integer}} = (c[1]/255, c[2]/255, c[3]/255)
@inline _color(c::T) where {T<:Tuple{Real, Real, Real}} = c
@inline _color(c::T) where {T<:RGB} = (c.r, c.g, c.b)
@inline _color(c::T) where {T<:AbstractString} = begin
    haskey(color_names, c) || error("unknown color \"$c\"")
    x = color_names[c]
    return (x[1]/255, x[2]/255, x[3]/255)
end

function _rescale_coord(v, newmax::Real, margin::Real)
    oldmin, oldmax = extrema(v)
    newmax -= margin * 2
    return [round(Int16, margin + (x - oldmin) / (oldmax - oldmin) * newmax) for x = v]
end

function _setup_layout(surface::CairoSurface, g::Graph, layout, margin)
    if haskey(g.nodeattrs, :x) && haskey(g.nodeattrs, :y)   # get layout
        x_ = g.nodeattrs[:x]
        y_ = g.nodeattrs[:y]
    elseif length(layout) >= 2
        x_, y_ = layout[1:2]
    else
        x_, y_ = layout_fruchterman_reingold(g)
    end
    if isa(margin, Real)                            # get margins
        m_x = m_y = margin
    elseif typeof(margin) <: Tuple{Real,Real}
        m_x, m_y = margin
    else
        error("invalid margin specification")
    end
    x = _rescale_coord(x_, surface.width, m_x)      # rescale x and y
    y = _rescale_coord(y_, surface.height, m_y)
    return x, y
end

function _setup_node_style(g::Graph; kvargs...)
    style = Dict{Symbol,Any}(       # default node style
        :shape          => ConstantAttribute(:circle),
        :size           => ConstantAttribute(100),
        :color          => ConstantAttribute((.7,.1,.2)),
        :border_color   => ConstantAttribute((1.,1.,1.)),
        :opacity        => ConstantAttribute(.8)
    )
    for (k, v) in g.nodeattrs       # incorporate node attributes
        if haskey(style, k)
            style[k] = _attribute(v)
        end
    end
    for (k, v) in kvargs            # incorporate node kvargs
        m = match(r"(?<=node_)[a-z_]+", string(k))
        if isa(m, RegexMatch)
            k_ = Symbol(m.match)
            if haskey(style, k_)
                style[k_] = _attribute(v)
            end
        end
    end
    return style
end

function _setup_edge_style(g::Graph; kvargs...)
    style = Dict{Symbol,Any}(       # default edge style
        :width          => ConstantAttribute(.5),
        :color          => ConstantAttribute((.5,.5,.5)),
        :opacity        => ConstantAttribute(.8),
        :curve          => ConstantAttribute(0)
    )
    for (k, v) in g.edgeattrs       # incorporate edge attributes
        if haskey(style, k)
            style[k] = _attribute(v)
        end
    end
    for (k, v) in kvargs            # incorporate edge kvargs
        m = match(r"(?<=edge_)[a-z_]+", string(k))
        if isa(m, RegexMatch)
            k_ = Symbol(m.match)
            if haskey(style, k_)
                style[k_] = _attribute(v)
            end
        end
    end
    return style
end


function draw_background!(context::CairoContext;
                          bg_color=(1.,1.,1.),
                          bg_opacity=1,
                          kvargs...)
    set_source_rgba(context, _color(bg_color)..., bg_opacity)
    paint(context)
end

function draw_node!(context::CairoContext, x, y, shape, size, color, bcolor, opacity)
    side = sqrt(size)
    node_path(Val{shape}, context, x, y, side)
    set_source_rgba(context, color..., opacity)
    fill_preserve(context)
    set_source_rgba(context, bcolor..., opacity)
    set_line_width(context, 1)
    stroke(context)
end

function draw_nodes!(context::CairoContext, g::Graph, x, y, nodestyle)
    shape, size, color, border_color, opacity =
        nodestyle[:shape], nodestyle[:size], nodestyle[:color],
        nodestyle[:border_color], nodestyle[:opacity]
    for i = nodes(g)
        draw_node!(context, x[i], y[i],
                   shape[i], size[i], _color(color[i]), _color(border_color[i]), opacity[i])
    end
end

function draw_node_labels!(context::CairoContext, g::Graph, x, y)
    haskey(g.nodeattrs, :label) || return
    label = g[:, :label]
    # select_font_face(context, "Roboto Mono")
    set_font_size(context, 10)
    for i = nodes(g)
        move_to(context, x[i], y[i])
        set_source_rgb(context, 0.1, 0.1, 0.1)
        show_text(context, label[i])
    end
end

function arrow_path!(context::CairoContext, x, y, α, size, width)
    if width > 3
        arc(context, x, y, width / 2, α - 2.3, α + 2.3)
    else
        move_to(context, x, y)
    end
    line_to(context, x + size * cos(α + 2.3), y + size * sin(α + 2.3))
    line_to(context, x + size * cos(α), y + size * sin(α))
    line_to(context, x + size * cos(α - 2.3), y + size * sin(α - 2.3))
    close_path(context)
end

_arc_angle(r, d) = 2 * asin(d/2 / r)

_node_radius(shape, size, a) = node_radius(Val{shape}, sqrt(size), a)

function draw_edge!(context::CairoContext, directed,
                    x1, y1, shape1, size1,
                    x2, y2, shape2, size2,
                    width, color, opacity, curve)
    arrow_size = max(5, width * 1.5)

    α = atan2(y2 - y1, x2 - x1)
    dist = sqrt(float(x2 - x1) ^ 2 + float(y2 - y1) ^ 2)
    cos_a = (x2 - x1) / dist
    sin_a = (y2 - y1) / dist

    if abs(curve) < 0.01 && dist > 0
        start = _node_radius(shape1, size1, α)
        finish = dist - _node_radius(shape2, size2, α + pi)
        finish > start || return
        if directed && finish - arrow_size > start
            finish -= arrow_size
        else
            directed = false
        end
        move_to(context, x1 + start * cos_a, y1 + start * sin_a)
        end_x, end_y = x1 + finish * cos_a, y1 + finish * sin_a
        line_to(context, end_x, end_y)
        end_α = α
    elseif curve >= 0  # edge is a clockwise arc 
        if dist > 0
            c2 = curve / 2 * pi
            r = dist/2 / sin(c2)
        else
            α = 0
            c2 = pi
            r = (sqrt(size1) + arrow_size) / 2
        end
        temp_α = α + (pi/2 - c2)
        xc, yc = x1 + r * cos(temp_α), y1 + r * sin(temp_α)
        α1, α2 = α - pi/2 - c2, α - pi/2 + c2
        r1 = _node_radius(shape1, size1, α1 + pi/2)
        r2 = _node_radius(shape2, size2, α2 - pi/2)
        r1 < 2r && r2 < 2r || return
        start = α1 + _arc_angle(r, r1)
        finish = α2 - _arc_angle(r, r2)
        finish > start || return
        arr_α = _arc_angle(r, arrow_size)
        if directed && finish - arr_α > start
            finish -= arr_α
        else
            directed = false
        end
        arc(context, xc, yc, r, start, finish)
        end_x = xc + r * cos(finish)
        end_y = yc + r * sin(finish)
        end_α = finish + pi/2 + arr_α/2
    elseif curve < 0  # edge is counter-clockwise arc
        if dist > 0
            c2 = -curve / 2 * pi
            r = dist / 2 / sin(c2)
        else
            α = 0
            c2 = pi
            r = (sqrt(size1) + arrow_size) / 2
        end
        temp_α = α - (pi/2 - c2)
        xc, yc = x1 + r * cos(temp_α), y1 + r * sin(temp_α)
        α1, α2 = α + pi/2 + c2, α + pi/2 - c2
        r1 = _node_radius(shape1, size1, α1 + pi/2)
        r2 = _node_radius(shape2, size2, α2 - pi/2)
        r1 < 2r && r2 < 2r || return
        start = α1 - _arc_angle(r, r1)
        finish = α2 + _arc_angle(r, r2)
        finish < start || return
        arr_α = _arc_angle(r, arrow_size)
        if directed && finish + arr_α < start
            finish += arr_α
        else
            directed = false
        end
        arc_negative(context, xc, yc, r, start, finish)
        end_x = xc + r * cos(finish)
        end_y = yc + r * sin(finish)
        end_α = finish - (pi/2 + arr_α/2)
    end
    set_line_width(context, width)
    if width > 3
        set_line_cap(context, 1)
    end
    set_source_rgba(context, color..., opacity)
    stroke(context)
    if directed
        arrow_path!(context, end_x, end_y, end_α, arrow_size, width)
        set_source_rgba(context, color..., opacity)
        fill(context)
    end
end

function draw_edges!(context::CairoContext, g::Graph, x, y, nodestyle, edgestyle)
    shape, size = nodestyle[:shape], nodestyle[:size]
    width, color, opacity, curve =
        edgestyle[:width], edgestyle[:color], edgestyle[:opacity], edgestyle[:curve]
    for e = edges(g)
        draw_edge!(context, e.isdir,
                   x[e.source], y[e.source], shape[e.source], size[e.source],
                   x[e.target], y[e.target], shape[e.target], size[e.target],
                   width[e.id], _color(color[e.id]), opacity[e.id], curve[e.id])
    end
end


function draw_graph!(surface::CairoSurface, g::Graph;
                     layout=(),
                     _layout=(),  # FIXME remove this hack
                     margin=(20,20),
                     _scale=1,
                     kvargs...)   # FIXME remove this hack or make it work well
    context = CairoContext(surface)
    # Draw background
    draw_background!(context; kvargs...)
    nodecount(g) == 0 && return
    # Set up the layout and styles
    _scale != 1 && scale(context, _scale, _scale)
    if _layout != ()
        x, y = _layout
    else
        x, y = _setup_layout(surface, g, layout, margin)
    end
    ns = _setup_node_style(g; kvargs...)
    es = _setup_edge_style(g; kvargs...)
    # Draw the edges
    draw_edges!(context, g, x, y, ns, es)
    # Draw the nodes
    draw_nodes!(context, g, x, y, ns)
    draw_node_labels!(context, g, x, y)
end


"""
    plot(g::Graph[, filename, size, format[, kvargs...]])

Plot the graph `g`. Specify the `filename`, `size`, `format`, or many
of the other parameters.
"""
function plot(g::Graph; filename="", size=(500,500), format=:png, kvargs...)
    if format == :png
        surface = CairoARGBSurface(size...)
        draw_graph!(surface, g; kvargs...)
        if filename != ""
            write_to_png(surface, filename)
        else
            return surface
        end
    elseif format == :svg
        if filename != ""
            surface = CairoSVGSurface(filename, size...)
            draw_graph!(surface, g; kvargs...)
            finish(surface)
        else
            buf = IOBuffer()
            surface = CairoSVGSurface(buf, size...)
            draw_graph!(surface, g; kvargs...)
            finish(surface)
            display(MIME("image/svg+xml"), String(take!(buf)))
        end
    elseif format == :pdf
        @assert(filename != "", "need a file name to write PDF")
        surface = CairoPDFSurface(filename, size...)
        draw_graph!(surface, g; kvargs...)
        finish(surface)
    else:
        error("wrong or unsupported image format :$format")
    end
end
