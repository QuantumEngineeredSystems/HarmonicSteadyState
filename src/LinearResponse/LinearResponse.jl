module LinearResponse

using Printf: Printf, @printf
using DocStringExtensions
using ProgressMeter: ProgressMeter, Progress, next!

using Symbolics: Symbolics, Num, unwrap
using LinearAlgebra: norm, eigen, eigvals, eigvecs

using HarmonicSteadyState:
    HarmonicSteadyState,
    Result,
    get_variable_solutions,
    _get_mask,
    StateDict,
    get_single_solution,
    get_class,
    swept_parameters,
    _free_symbols,
    get_response_matrix

using QuestBase: HarmonicVariable, substitute_all

include("types.jl")
include("utils.jl")
include("Lorentzian_spectrum.jl")
include("response.jl")

export show,
    get_jacobian_response,
    get_linear_response,
    get_rotframe_jacobian_response,
    eigenvalues,
    eigenvectors

end
