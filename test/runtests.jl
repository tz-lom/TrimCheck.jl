using Test
using TrimCheck
using TrimCheck: validate

@testset "" verbose = true begin
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

	@testset "colored types" begin
		result = TrimCheck.validate_function(:(maximum(Vector{Any})))
		buffer = IOBuffer()
		io = IOContext(buffer, :color => true)
		show(
			TrimCheck.ColorfullTypes(io),
			Tuple{
				Int,
				Any,
				Union{Int8,Int16,Int32,Int64},
				Union{Int8,Int16,Int32,Int64,UInt8,Vector},
			},
		)
		str = String(take!(buffer))
		expected = "\e[31mTuple{\e[92mInt64\e[39m, \e[31mAny\e[39m, \e[92mUnion{\e[92mInt16\e[39m, \e[92mInt32\e[39m, \e[92mInt64\e[39m, \e[92mInt8\e[39m}\e[39m, \e[33mUnion{\e[92mInt16\e[39m, \e[92mInt32\e[39m, \e[92mInt64\e[39m, \e[92mInt8\e[39m, \e[92mUInt8\e[39m, \e[31mVector\e[39m}\e[39m}\e[39m"
		@test str == expected
	end

	@testset "@validate macro" begin
		@validate(
			init = begin
				include(joinpath(@__DIR__, "funcs.jl"))
			end,
			verbose = true,
			foo(Int32),
			foo(String),
			# foo(TypeUnstable),
			foo(TypeStable)
		)
	end

	@testset "validation macro (indirectly)" verbose = true begin
		@testset "colored short output" begin
			results = TrimCheck.validate([:(maximum(Vector{Any}))]; color = true)
			@test length(results) == 1
			@test contains(results[1].error, "\e[31m") # check for colored output

			@test contains(results[1].error, "Verifier errors: 7, warnings: 0")
			@test contains(results[1].error, "Verifier error #1")
			@test !contains(results[1].error, "Verifier error #2")
		end

		@testset "no color long output" begin
			results = TrimCheck.validate(
				[:(maximum(Vector{Any}))];
				color = false,
				only_first_error = false,
			)

			@test !contains(results[1].error, "\e[31m") # check for non-colored output
			@test contains(results[1].error, "Verifier errors: 7, warnings: 0")
			@test contains(results[1].error, "Verifier error #1")
		end
	end
end
