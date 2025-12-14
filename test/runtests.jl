using Test
using TrimCheck
using TrimCheck: validate

@testset "TrimCheck" verbose = true begin
	@testset "show trimming errors correcty" begin
		err = TrimCheck.TrimVerificationErrors(
			[
				(false, TrimCheck.TrimVerifier.CCallableMissing("rt", "sig", "error 1")),
				(true, TrimCheck.TrimVerifier.CCallableMissing("rt", "sig", "warning 1")),
				(true, TrimCheck.TrimVerifier.CCallableMissing("rt", "sig", "warning 2")),
				(false, TrimCheck.TrimVerifier.CCallableMissing("rt", "sig", "error 2")),
				(false, TrimCheck.TrimVerifier.CCallableMissing("rt", "sig", "error 3")),
				(true, TrimCheck.TrimVerifier.CCallableMissing("rt", "sig", "warning 3")),
			],
			TrimCheck.TrimVerifier.ParentMap(),
		)
		str = sprint(show, err)

		@test contains(str, "Verifier errors: 3, warnings: 3")
		for n = 1:3
			@test contains(str, "Verifier error #$n: error $n")
			@test contains(str, "Verifier warning #$n: warning $n")
		end

		err = TrimCheck.TrimVerificationErrors(err, warnings_limit = 2, errors_limit = 2)
		str = sprint(show, err)

		@test contains(str, "Verifier errors: 3, warnings: 3")
		for n = 1:2
			@test contains(str, "Verifier error #$n: error $n")
			@test contains(str, "Verifier warning #$n: warning $n")
		end
		@test !contains(str, "Verifier error #3: error 3")
		@test !contains(str, "Verifier warning #3: warning 3")
	end

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
			results =
				TrimCheck.validate(:(maximum(Vector{Any})); color = true, errors_limit = 1)
			@test length(results) == 1
			@test contains(results[1].error, "\e[31m") # check for colored output

			m = match(r"Verifier errors: (\d+), warnings: (\d+)", results[1].error)
			@test m !== nothing
			@test parse(Int, m[1]) > 0

			@test contains(results[1].error, "Verifier error #1")
			@test !contains(results[1].error, "Verifier error #2")
		end

		@testset "no color long output" begin
			results = TrimCheck.validate(
				:(maximum(Vector{Any}));
				color = false,
				errors_limit = 10,
			)

			@test !contains(results[1].error, "\e[31m") # check for non-colored output
			m = match(r"Verifier errors: (\d+), warnings: (\d+)", results[1].error)
			@test m !== nothing
			errors = parse(Int, m[1])
			@test errors > 1
			for i = 1:errors
				@test contains(results[1].error, "Verifier error #$i")
			end
		end
	end

	@testset "skip_fixes option" begin
		results = TrimCheck.validate(
			:(mapreduce(typeof(identity), typeof(+), Vector{Int}));
			skip_fixes = true,
			color = false,
		)
		m = match(r"Verifier errors: (\d+), warnings: (\d+)", results[1].error)
		@test m !== nothing
		@test parse(Int, m[1]) > 0

		results = TrimCheck.validate(
			:(mapreduce(typeof(identity), typeof(+), Vector{Int}));
			skip_fixes = false,
			color = false,
		)
		@test isnothing(results[1].error)
	end
end
