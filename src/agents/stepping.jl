#=
In this file we define how agents are plotted and how the plots are updated while stepping
=#
# TODO: I should check whether it is worth to type-parameterize this.
struct ABMStepper # {X, C, M, S, O, AC, AS, AM, HA}
    ac # ::C
    am # ::M
    as # ::S
    offset # ::O
    scheduler # ::X
    pos # ::Observable
    colors # ::AC
    sizes # ::AS
    markers # ::AM
    heatarray # ::HA
    heatobs # ::HO
end

Base.show(io::IO, ::ABMStepper) =
println(io, "Helper structure for stepping and updating the plot of an agent based model. ",
"It is outputted by `abm_plot` and can be used in `Agents.step!`, see `abm_plot`.")

"Initialize the abmstepper and the plotted observables. Return the stepper."
function abm_init_stepper(model; 
        ac, am, as, scheduler, offset, heatarray)

    if !isnothing(heatarray)
        # TODO: This is also possible for continuous spaces, we have to
        # get the matrix size, and then make a range for each dimension
        # and do heatmap!(ax, x, y, heatobs)
        #
        # TODO: use surface!(heatobs) here?
        matrix = Agents.get_data(model, heatarray, identity)
        if !(matrix isa AbstractMatrix) || size(matrix) ≠ size(model.space)
            error("The heat array property must yield a matrix of same size as the grid!")
        end
        heatobs = Observable(matrix)
    else
        heatobs = nothing
    end

    ids = scheduler(model)
    colors = Observable(ac isa Function ? to_color.([ac(model[i]) for i ∈ ids]) : to_color(ac))
    sizes = Observable(as isa Function ? [as(model[i]) for i ∈ ids] : as)
    markers = Observable(am isa Function ? [am(model[i]) for i ∈ ids] : am)
    
    is3d = length(modellims(model)[1]) == 3
    postype = is3d ? Point3f0 : Point2f0
    if isnothing(offset)
        pos = Observable(postype[model[i].pos for i ∈ ids])
    else
        pos = Observable(postype[model[i].pos .+ offset(model[i]) for i ∈ ids])
    end

    if user_used_polygons(am, markers)
        # For polygons we always need vector, even if all agents are same polygon
        markers[] = [translate(m, p) for (m, p) in zip(markers, pos[])]
    end

    return ABMStepper(
        ac, am, as, offset, scheduler,
        pos, colors, sizes, markers,
        heatarray, heatobs
    )
end

"Initialize the ABM plot and return it."
function abm_init_plot!(ax, fig, model, abmstepper;
        aspect, heatkwargs, add_colorbar, static_preplot!, scatterkwargs)
    
    o, e = modellims(model)
    is3d = length(o) == 3
    @assert length(o) == 2 || is3d "Only 2D and 3D spaces can be plotted."
    # TODO: once graph plotting is possible, this will be adjusted
    @assert typeof(model.space) <: Union{Agents.ContinuousSpace, Agents.DiscreteSpace}
    xlims!(ax, o[1], e[1])
    ylims!(ax, o[2], e[2])
    is3d && zlims!(ax, o[3], e[3])
    is3d || (ax.aspect = aspect)

    if !isnothing(abmstepper.heatobs)
        heatkwargs = merge((colormap=JULIADYNAMICS_CMAP,), heatkwargs)
        hmap = heatmap!(ax, abmstepper.heatobs[]; heatkwargs...)

        add_colorbar && Colorbar(fig[1, 1][1, 2], hmap, width = 20)
        # rowsize!(fig[1,1].fig.layout, 1, ax.scene.px_area[].widths[2]) # Colorbar height = axis height
    end

    static_plot = static_preplot!(ax, model)
    !isnothing(static_plot) && (static_plot.inspectable[] = false)

    # Here we make the decision of whether the user has provided markers, and thus use
    # `scatter`, or polygons, and thus use `poly`:
    if user_used_polygons(abmstepper.am, abmstepper.markers)
        return abmplot!(ax, abmstepper.markers, model;
            ac = abmstepper.colors,
            scatterkwargs
        )
    else
        return abmplot!(ax, abmstepper.pos, model;
            ac = abmstepper.colors,
            am = abmstepper.markers,
            as = abmstepper.sizes,
            scatterkwargs
        )
    end
end

default_static_preplot(ax, model) = nothing

function modellims(model)
    if model.space isa Agents.ContinuousSpace
        e = model.space.extent
    elseif model.space isa Agents.DiscreteSpace
        e = size(model.space.s) .+ 1
    end
    return zero.(e), e
end

function user_used_polygons(am, markers)
    if (am isa Polygon)
        return true
    elseif (am isa Function) && (markers[][1] isa Polygon)
        return true
    else
        return false
    end
end

#=
    Agents.step!(abmstepper, model, agent_step!, model_step!, n::Int)
Step the given `model` for `n` steps while also updating the plot that corresponds to it,
which is produced with the function [`abm_plot`](@ref).

You can still call this function with `n=0` to update the plot for a new `model`,
without doing any stepping.
=#
function Agents.step!(abmstepper::ABMStepper, model, agent_step!, model_step!, n)
    @assert (n isa Int) "Only stepping with integer `n` is possible with `abmstepper`."
    ac, am, as = abmstepper.ac, abmstepper.am, abmstepper.as
    offset = abmstepper.offset
    pos, colors = abmstepper.pos, abmstepper.colors
    sizes, markers =  abmstepper.sizes, abmstepper.markers

    Agents.step!(model, agent_step!, model_step!, n)

    if Agents.nagents(model) == 0
        @warn "The model has no agents"
    end
    ids = abmstepper.scheduler(model)
    if isnothing(offset)
        pos[] = [model[i].pos for i in ids]
    else
        pos[] = [model[i].pos .+ offset(model[i]) for i in ids]
    end
    if ac isa Function; colors[] = to_color.([ac(model[i]) for i in ids]); end
    if as isa Function; sizes[] = [as(model[i]) for i in ids]; end
    if am isa Function; markers[] = [am(model[i]) for i in ids]; end
    # If we use Polygons as markers, do a final update:
    if user_used_polygons(am, markers)
        # translate all polygons according to pos
        markers[] = [translate(m, p) for (m, p) in zip(markers[], pos[])]
    end
    # Finally update the heat array, if any
    if !isnothing(abmstepper.heatarray)
        newmatrix = Agents.get_data(model, abmstepper.heatarray, identity)
        abmstepper.heatobs[] = newmatrix
    end
    return nothing
end