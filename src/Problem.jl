"""
    SteadyStateProblem

    Abstract type for steady state problems.
"""
abstract type SteadyStateProblem end

"""
$(TYPEDEF)

Holds a set of algebraic equations describing the steady state of a system.

# Fields
$(TYPEDFIELDS)

#  Constructors
```julia
HomotopyContinuationProblem(
    eom::HarmonicEquation,
    swept::AbstractDict,
    fixed::AbstractDict;
    compile_Jacobian::Bool=true,
)
```
"""
mutable struct HomotopyContinuationProblem{
    ParType<:Number,
    Jac<:JacobianFunction(ComplexF64), # HC.jl only supports Float64
} <: SteadyStateProblem
    "The harmonic variables to be solved for."
    variables::Vector{Num}
    "All symbols which are not the harmonic variables."
    parameters::Vector{Num}
    "The swept parameters in the homotopy."
    swept_parameters::OrderedDict{Num,Vector{ParType}}
    "The fixed parameters in the homotopy."
    fixed_parameters::OrderedDict{Num,ParType}
    "The input object for HomotopyContinuation.jl solver methods."
    system::HC.System
    """
    The Jacobian matrix (possibly symbolic or compiled function).
    If `Matrix{Nan}` and implicit function is compiled when a `Result` is created.
    """
    jacobian::Jac
    "The HarmonicEquation object used to generate this `HomotopyContinuationProblem`."
    eom::HarmonicEquation

    function HomotopyContinuationProblem(
        variables, parameters, swept::OrderedDict, fixed::OrderedDict{K,V}, system, jacobian
    ) where {K,V}
        return new{V,typeof(jacobian)}(
            variables, parameters, swept, fixed, system, jacobian
        )
    end # incomplete initialization for user-defined symbolic systems
    function HomotopyContinuationProblem(
        variables, parameters, swept::OrderedDict, fixed::OrderedDict{K,V}, system
    ) where {K,V}
        return new{V,JacobianFunction(ComplexF64)}(
            variables, parameters, swept, fixed, system
        )
    end # incomplete initialization for user-defined symbolic systems
    function HomotopyContinuationProblem(
        variables,
        parameters,
        swept::OrderedDict,
        fixed::OrderedDict{K,V},
        system,
        jacobian,
        eom,
    ) where {K,V}
        return new{V,typeof(jacobian)}(
            variables, parameters, swept, fixed, system, jacobian, eom
        )
    end
end

"Constructor for the type `HomotopyContinuationProblem` (to be solved by HomotopyContinuation)
from a `HarmonicEquation`."
function HarmonicSteadyState.HomotopyContinuationProblem(
    eom::HarmonicEquation, swept::AbstractDict, fixed::AbstractDict; compile_jacobian=true
)
    S = HomotopyContinuation.System(eom)
    vars_new = declare_variables(eom)

    swept, fixed = promote_types(swept, fixed)
    # check_fixed_and_sweep(eom, swept, fixed) # check later in `solve_homotopy`

    if compile_jacobian
        jac = _compile_Jacobian(eom, ComplexF64, swept, fixed)
        # ^ HC.jl only supports Float64 (https://github.com/JuliaHomotopyContinuation/HomotopyContinuation.jl/issues/604)
        return HomotopyContinuationProblem(
            vars_new, eom.parameters, swept, fixed, S, jac, eom
        )
    else
        return HomotopyContinuationProblem(vars_new, eom.parameters, swept, fixed, S)
    end
end # Probably should merge both constructors

"A constructor for HomotopyContinuationProblem from explicitly entered equations, variables and parameters."
function HarmonicSteadyState.HomotopyContinuationProblem(
    equations::Vector{Num},
    variables::Vector{Num},
    parameters::Vector{Num},
    swept::AbstractDict,
    fixed::AbstractDict,
)
    swept, fixed = promote_types(swept, fixed)
    vars_new = declare_variable.(string.(variables))
    pars_new = declare_variable.(string.(parameters))

    system = HomotopyContinuation.System(equations, vars_new, pars_new)
    J = HarmonicSteadyState.compute_and_compile_Jacobian(
        equations, vars_new, ComplexF64, swept, fixed
    )
    return HomotopyContinuationProblem(vars_new, pars_new, swept, fixed, system, J)
end # Probably should merge both constructors

Symbolics.get_variables(p::HomotopyContinuationProblem)::Vector{Num} = p.variables

function Base.show(io::IO, p::HomotopyContinuationProblem)
    println(io, length(p.system.expressions), " algebraic equations for steady states")
    println(io, "Variables: ", join(string.(p.variables), ", "))
    println(io, "Parameters: ", join(string.(p.parameters), ", "))
    return nothing
end

# assume this order of variables in all compiled function (transform_solutions, Jacobians)
function _free_symbols(p::HomotopyContinuationProblem)::Vector{Num}
    return cat(p.variables, collect(keys(p.swept_parameters)); dims=1)
end

function QuestBase.declare_variables(p::HomotopyContinuationProblem)
    return declare_variable.(string.(cat(p.parameters, p.variables; dims=1)))
end

function check_fixed_and_sweep(
    eom::Union{HomotopyContinuationProblem,HarmonicEquation}, sweeps, fixed_parameters
)
    # Check if any of the variables are being fixed/swept
    variable_names = var_name.([keys(fixed_parameters)..., keys(sweeps)...])
    for var in get_variables(eom)
        if var_name(var) ∈ variable_names
            e = ArgumentError(
                "Parameter '$(var)' is a variable of the system and as such cannot be fixed
                nor swept. Please only provide system parameters."
            )
            throw(e)
        end
    end

    all_keys = cat(collect(keys(sweeps)), collect(keys(fixed_parameters)); dims=1)
    param_counts = Dict(
        par => count(x -> isequal(x, par), all_keys) for par in eom.parameters
    )

    # Error if any parameter is missing
    missing_params = filter(p -> param_counts[p] == 0, eom.parameters)
    if !isempty(missing_params)
        e = ArgumentError("Missing parameters: $(join(missing_params, ", "))")
        throw(e)
    end

    # Error if any parameter appears multiple times
    duplicate_params = filter(p -> param_counts[p] > 1, eom.parameters)
    if !isempty(duplicate_params)
        e = ArgumentError(
            "Parameters appear multiple times: $(join(duplicate_params, ", "))"
        )
        throw(e)
    end

    # Error if there are extra parameters not in eom
    extra_params = setdiff(all_keys, eom.parameters)
    if !isempty(extra_params)
        e = ArgumentError("Unknown parameters provided: $(join(extra_params, ", "))")
        throw(e)
    end

    return nothing
end

function unique_fixed_and_permutations(
    eom::Union{HomotopyContinuationProblem,HarmonicEquation}, sweeps, fixed_parameters
)
    check_fixed_and_sweep(eom, sweeps, fixed_parameters)

    # Create permutation for parameter ordering
    unique_fixed = filter_duplicate_parameters(sweeps, fixed_parameters)
    all_keys = cat(collect(keys(sweeps)), collect(keys(fixed_parameters)); dims=1)
    permutation = [findfirst(x -> isequal(x, par), all_keys) for par in eom.parameters]

    return unique_fixed, permutation
end
