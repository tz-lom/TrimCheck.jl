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
    @test isempty(result.errors)
    @test result.call == :(sin(Int))

    result = TrimCheck.validate_function(:(sin(1)))
    @test result.call == :(sin(1))
    @test length(result.errors) == 1
    @test occursin("Failed to run validation", result.errors[1])

    result = TrimCheck.validate_function(:(maximum(Vector{Any})))
    @test result.call == :(maximum(Vector{Any}))
    @test length(result.errors) >= 1
    @test occursin("unresolved call from statement", result.errors[1])
end