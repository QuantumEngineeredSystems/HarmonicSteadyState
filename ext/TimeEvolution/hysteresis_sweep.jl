"""
Calculate distance between a given state and a stable branch
"""
function _closest_branch_index(
    res::Result{D,S}, state::SteadyState(P), index::Int64
) where {D,S,P}
    # search only among stable solutions
    stable = get_solutions(res; class=["physical", "stable"], not_class=[])

    steadystates = reduce(hcat, stable[index])
    distances = vec(sum(abs2.(steadystates .- state); dims=1))
    return argmin(replace(distances, NaN => Inf))
end

"""
$(TYPEDSIGNATURES)

Return the indexes and values following stable branches along a 1D sweep.
When a no stable solutions are found (e.g. in a bifurcation), the next stable solution is calculated by time evolving the previous solution (quench).

## Keyword arguments
  - `y`:  Dependent variable expression (parsed into Symbolics.jl) to evaluate the followed solution branches on .
  - `sweep`: Direction for the sweeping of solutions. A `right` (`left`) sweep proceeds from the first (last) solution, ordered as the sweeping parameter.
  - `tf`: time to reach steady
  - `ϵ`: small random perturbation applied to quenched solution, in a bifurcation in order to favour convergence in cases where multiple solutions are identically accessible (e.g. symmetry breaking into two equal amplitude states)
"""
function HarmonicSteadyState.follow_branch(
    starting_branch::Int64, res::Result; y="u1^2+v1^2", sweep="right", tf=10000, ϵ=1e-4
)
    sweep_directions = ["left", "right"]
    sweep ∈ sweep_directions || error(
        "Only the following (1D) sweeping directions are allowed:  ", sweep_directions
    )

    # get stable solutions
    Ys = get_solutions(res, y; class=["physical", "stable"], not_class=[], realify=true)
    Ys = sweep == "left" ? reverse(Ys) : Ys

    followed_branch = zeros(Int64, length(Ys))  # followed branch indexes
    followed_branch[1] = starting_branch

    p1 = first(keys(res.swept_parameters)) # parameter values

    for i in 2:length(Ys)
        s = Ys[i][followed_branch[i - 1]] # solution amplitude in the current branch and current parameter index
        if !isnan(s) # the solution is not unstable or unphysical
            followed_branch[i] = followed_branch[i - 1]
        else # bifurcation found
            next_index = sweep == "right" ? i : length(Ys) - i + 1

            # create a synthetic starting point out of an unphysical solution: quench and time evolve
            # the actual solution is complex there, i.e. non physical. Take real part for the quench.
            sol_dict = get_single_solution(
                res; branch=followed_branch[i - 1], index=next_index
            )

            var = res.problem.variables
            var_values_noise =
                real.(getindex.(Ref(sol_dict), var)) .+ 0.0im .+ ϵ * rand(length(var))
            for (i, v) in enumerate(var)
                sol_dict[v] = var_values_noise[i]
            end

            problem_t = ODEProblem(res.problem.eom, sol_dict; timespan=(0, tf))
            res_t = solve(problem_t, OrdinaryDiffEqTsit5.Tsit5(); saveat=tf)

            # closest branch to final state
            followed_branch[i] = _closest_branch_index(res, res_t.u[end], next_index)

            @info "bifurcation @ $p1 = $(real(sol_dict[p1])): switched branch $(followed_branch[i-1]) ➡ $(followed_branch[i])"
        end
    end
    if sweep == "left"
        Ys = reverse(Ys)
        followed_branch = reverse(followed_branch)
    end

    return followed_branch, Ys
end
