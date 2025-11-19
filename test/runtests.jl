using Test
using TrimCheck
using TrimCheck: validate
# @check_calls(init = begin
#         include(joinpath(@__DIR__, "funcs.jl"))
#     end, verbose = true,
#     foo(Int32),
#     foo(String),
#     foo(TypeUnstable),
#     foo(TypeStable))

@testset "validate_function" begin

    result = TrimCheck.validate_function(:(sin(Int)))
    @test isnothing(result.error)
    @test result.call == :(sin(Int))

    result = TrimCheck.validate_function(:(sin(1)))
    @test result.call == :(sin(1))
    @test result.error isa ErrorException

    result = TrimCheck.validate_function(:(maximum(Vector{Any})))
    @test result.call == :(maximum(Vector{Any}))
    @test result.error isa TrimCheck.TrimVerificationErrors
    @test result.error.errors[1].second isa TrimCheck.TrimVerifier.CallMissing
    @test occursin("unresolved call", result.error.errors[1].second.desc)
end