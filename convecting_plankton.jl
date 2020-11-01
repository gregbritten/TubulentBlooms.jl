# # Critical turbulence hypothesis

using Printf
using JLD2

## https://discourse.julialang.org/t/unable-to-display-plot-using-the-repl-gks-errors/12826/18
ENV["GKSwstype"] = "nul"
using Plots
using Measures: pt

using Oceananigans
using Oceananigans.Utils
using Oceananigans.Grids
using Oceananigans.Advection
using Oceananigans.AbstractOperations
using Oceananigans.OutputWriters
using Oceananigans.Fields
using Oceananigans.Diagnostics: FieldMaximum

# Parameters

just_make_animation = false

Nh = 32     # Horizontal resolution
Nz = 32     # Vertical resolution
Lh = 192    # Domain width
Lz = 96     # Domain height
Qh = 10     # Surface heat flux (W m⁻²)
 ρ = 1026   # Reference density (kg m⁻³)
cᴾ = 3991   # Heat capacity (J (ᵒC)⁻¹ m⁻²)
 α = 2e-4   # Kinematic thermal expansion coefficient (ᵒC m⁻¹)
 g = 9.81   # Gravitational acceleration (m s⁻²)
N∞ = 9.5e-3 # s⁻²
 f = 1e-4   # s⁻¹

buoyancy_flux_parameters = (initial_buoyancy_flux = α * g * Qh / (ρ * cᴾ), # m³ s⁻²
                            start_ramp_down = 1day,
                            shut_off = 2day)

planktonic_parameters = (sunlight_attenuation_scale = 5.0,
                         surface_growth_rate = 1/day,
                         mortality_rate = 0.1/day)

P₀ = 1
initial_plankton_concentration(x, y, z) = P₀ # μM

initial_mixed_layer_depth = 50
initial_time_step = 10
max_time_step = 2minutes
stop_time = 1day
output_interval = hour / 2

@info """ *** Parameters ***

    Resolution:                        ($Nh, $Nh, $Nz)
    Domain:                            ($Lh, $Lh, $Lz) m
    Initial heat flux:                 $(Qh) W m⁻²
    Initial buoyancy flux:             $(@sprintf("%.2e", buoyancy_flux_parameters.initial_buoyancy_flux)) m² s⁻³
    Initial mixed layer depth:         $(initial_mixed_layer_depth) m
    Cooling starts ramping down:       $(prettytime(buoyancy_flux_parameters.start_ramp_down))
    Cooling shuts off:                 $(prettytime(buoyancy_flux_parameters.shut_off))
    Simulation stop time:              $(prettytime(stop_time))
    Plankton surface growth rate:      $(day * planktonic_parameters.surface_growth_rate) day⁻¹
    Plankton mortality rate:           $(day * planktonic_parameters.mortality_rate) day⁻¹
    Sunlight attenuation length scale: $(planktonic_parameters.sunlight_attenuation_scale) m

"""

# Grid

grid = RegularCartesianGrid(size=(Nh, Nh, Nz), extent=(Lh, Lh, Lz))

# Boundary conditions
delayed_ramp_down(t, start, shutoff) =
    ifelse(t < start, 1.0,
    ifelse(t < shutoff, (shutoff - t) / (shutoff - start), 0.0))

buoyancy_flux(x, y, t, θ) = θ.initial_buoyancy_flux * delayed_ramp_down(t, θ.start_ramp_down, θ.shut_off)

buoyancy_top_bc = BoundaryCondition(Flux, buoyancy_flux, parameters=buoyancy_flux_parameters)
buoyancy_bot_bc = BoundaryCondition(Gradient, N∞^2)
                                                   
buoyancy_bcs = TracerBoundaryConditions(grid, top = buoyancy_top_bc, bottom = buoyancy_bot_bc)

# Plankton dynamics
growing_and_grazing(z, P, h, μ₀, m) = (μ₀ * exp(z / h) - m) * P

plankton_forcing_func(x, y, z, t, P, θ) = growing_and_grazing(z, P,
                                                              θ.sunlight_attenuation_scale,
                                                              θ.surface_growth_rate,
                                                              θ.mortality_rate)

plankton_forcing = Forcing(plankton_forcing_func, field_dependencies=:plankton,
                           parameters=planktonic_parameters)

if !just_make_animation
    # Sponge layer for u, v, w, and b
    gaussian_mask = GaussianMask{:z}(center=-grid.Lz, width=grid.Lz/10)

    u_sponge = v_sponge = w_sponge = Relaxation(rate=4/hour, mask=gaussian_mask)

    b_sponge = Relaxation(rate = 4/hour,
                          target = LinearTarget{:z}(intercept=0, gradient=N∞^2),
                          mask = gaussian_mask)

    model = IncompressibleModel(
               architecture = CPU(),
                       grid = grid,
                  advection = UpwindBiasedFifthOrder(),
                timestepper = :RungeKutta3,
                    closure = AnisotropicMinimumDissipation(),
                   coriolis = FPlane(f=f),
                    tracers = (:b, :plankton),
                   buoyancy = BuoyancyTracer(),
                    forcing = (u=u_sponge, v=v_sponge, w=w_sponge,
                               b=b_sponge, plankton=plankton_forcing),
        boundary_conditions = (b=buoyancy_bcs,)
    )

    # Initial condition

    Ξ(z) = N∞^2 * grid.Lz * 1e-4 * randn() * exp(z / 4) # surface-concentrated noise

    stratification(x, y, z) = N∞^2 * z

    initial_buoyancy(x, y, z) =
        Ξ(z) + ifelse(z < -initial_mixed_layer_depth,
                      stratification(x, y, z),
                      stratification(x, y, -initial_mixed_layer_depth))

    set!(model, b=initial_buoyancy, plankton=initial_plankton_concentration)

    # Simulation setup

    wizard = TimeStepWizard(cfl=1.0, Δt=Float64(initial_time_step), max_change=1.1, max_Δt=Float64(max_time_step))

    wmax = FieldMaximum(abs, model.velocities.w)
    Pmax = FieldMaximum(abs, model.tracers.plankton)

    start_time = time_ns() # so we can print the total elapsed wall time

    progress_message(sim) = @info @sprintf(
        "i: % 4d, t: % 12s, Δt: % 12s, max(|w|) = %.1e ms⁻¹, max(|P|) = %.1e μM, wall time: %s\n",
        sim.model.clock.iteration, prettytime(model.clock.time),
        prettytime(wizard.Δt), wmax(sim.model), Pmax(sim.model),
        prettytime((time_ns() - start_time) * 1e-9))

    simulation = Simulation(model, Δt=wizard, stop_time=stop_time,
                            iteration_interval=10, progress=progress_message)

    u, v, w = model.velocities
    P = model.tracers.plankton

     P̂   = AveragedField(P, dims=(1, 2, 3))
    _P_  = AveragedField(P, dims=(1, 2))
    _wP_ = AveragedField(w * P, dims=(1, 2))
    _Pz_ = AveragedField(∂z(P), dims=(1, 2))

    simulation.output_writers[:fields] =
        JLD2OutputWriter(model, merge(model.velocities, model.tracers),
                         schedule = TimeInterval(output_interval),
                         prefix = "convecting_plankton_fields",
                         force = true)

    simulation.output_writers[:averages] =
        JLD2OutputWriter(model, (P = _P_, wP = _wP_, Pz = _Pz_, volume_averaged_P = P̂),
                         schedule = TimeInterval(output_interval),
                         prefix = "convecting_plankton_averages",
                         force = true)

    run!(simulation)
end

# Movie

fields_file = jldopen("convecting_plankton_fields.jld2")
averages_file = jldopen("convecting_plankton_averages.jld2")

iterations = parse.(Int, keys(fields_file["timeseries/t"]))
times = [fields_file["timeseries/t/$iter"] for iter in iterations]
buoyancy_flux_time_series = [buoyancy_flux(0, 0, t, buoyancy_flux_parameters) for t in times] 

xw, yw, zw = nodes((Cell, Cell, Face), grid)
xp, yp, zp = nodes((Cell, Cell, Cell), grid)

function divergent_levels(c, clim, nlevels=31)
    levels = range(-clim, stop=clim, length=nlevels)
    cmax = maximum(abs, c)
    clim < cmax && (levels = vcat([-cmax], levels, [cmax]))
    return (-clim, clim), levels
end

function sequential_levels(c, clims, nlevels=31)
    levels = collect(range(clims[1], stop=clims[2], length=nlevels))
    cmin = minimum(c)
    cmax = maximum(c)
    cmin < clims[1] && pushfirst!(levels, cmin)
    cmax > clims[2] && push!(levels, cmax)
    return clims, levels
end

@info "Making a movie about plankton..."

try
    anim = @animate for (i, iteration) in enumerate(iterations)

        @info "Plotting frame $i from iteration $iteration..."
        
        w = fields_file["timeseries/w/$iteration"][:, 1, :]
        p = fields_file["timeseries/plankton/$iteration"][:, 1, :]

        P = averages_file["timeseries/P/$iteration"][1, 1, :]
        wP = averages_file["timeseries/wP/$iteration"][1, 1, :]
        Pz = averages_file["timeseries/Pz/$iteration"][1, 1, :]

        κᵉᶠᶠ = @. - wP / Pz

        # Normalize profiles
        P ./= P₀
        wP ./= maximum(abs, wP)
        Pz ./= maximum(abs, Pz)

        w_lim = 1e-3 # 0.8 * maximum(abs, w) + 1e-9
        p_lim = 2

        w_lims, w_levels = divergent_levels(w, w_lim)
        p_lims, p_levels = sequential_levels(p, (0.9, p_lim))

        kwargs = (xlabel="x (m)", ylabel="y (m)", aspectratio=1, linewidth=0, colorbar=true,
                  xlims=(0, grid.Lx), ylims=(-grid.Lz, 0))

        w_contours = contourf(xw, zw, w';
                               color = :balance,
                              margin = 10pt,
                              levels = w_levels,
                               clims = w_lims,
                              kwargs...)

        p_contours = contourf(xp, zp, p';
                               color = :matter,
                              margin = 10pt,
                              levels = p_levels,
                               clims = p_lims,
                              kwargs...)

        profile_plot = plot(P, zp, label = "⟨P⟩ / P₀",
                               linewidth = 2,
                                  margin = 20pt,
                                  xlabel = "Normalized plankton statistics",
                                  legend = :bottom,
                                  ylabel = "z (m)")

        plot!(profile_plot, wP, zw, label = "⟨wP⟩ / max|wP|", linewidth = 2)
        plot!(profile_plot, Pz, zw, label = "⟨∂_z P⟩ / max|∂_z P|", linewidth = 2)

        κᵉᶠᶠ_plot = plot(κᵉᶠᶠ, zw,
                       linewidth = 2,
                            margin = 20pt,
                           label = nothing,
                           xlims = (0, 1e-1),
                          ylabel = "z (m)",
                          xlabel = "κᵉᶠᶠ (m² s⁻¹)")

        flux_plot = plot(times ./ day, buoyancy_flux_time_series,
                         linewidth = 1,
                            margin = 20pt,
                             label = "Buoyancy flux time series",
                            legend = :bottomleft,
                            xlabel = "Time (days)",
                            ylabel = "Buoyancy flux (m² s⁻³)",
                             ylims = (0.0, 1.1 * buoyancy_flux_parameters.initial_buoyancy_flux))

        scatter!(flux_plot, times[i:i] / day, buoyancy_flux_time_series[i:i], markershape=:circle, markercolor=:red,
                       label="Current buoyancy flux")

        t = times[i]
        w_title = @sprintf("w(y = 0 m, t = %-16s) (m s⁻¹)", prettytime(t))
        p_title = @sprintf("P(y = 0 m, t = %-16s) (μM)", prettytime(t))

        # Layout something like:
        #
        # [ w contours ]  [ [⟨P⟩+⟨wP⟩] [κ] ]
        # [ p contours ]  [      Qᵇ(t)     ]
        
        layout = @layout [ Plots.grid(2, 1) [ Plots.grid(1, 2)
                                                     c         ] ]

        plot(w_contours, p_contours, profile_plot, κᵉᶠᶠ_plot, flux_plot,
             title=[w_title p_title "" "" ""],
             layout=layout, size=(1600, 700))
    end

    gif(anim, "convecting_plankton.gif", fps = 8) # hide

finally
    close(fields_file)
    close(averages_file)
end