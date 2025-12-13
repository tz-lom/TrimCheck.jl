module TrimCheck

using Compiler: Compiler, TrimVerifier
using Pkg
using Serialization
using MLStyle: @match
using Test
using ProgressMeter
using Distributed

export @validate
public validate

struct TrimVerificationErrors
	errors::Any
	parents::Any
	only_first_error::Bool

	TrimVerificationErrors(errors, parents; only_first_error::Bool = false) =
		new(errors, parents, only_first_error)
	TrimVerificationErrors(
		prev::TrimVerificationErrors;
		only_first_error::Union{Missing,Bool} = missing,
	) =
		ismissing(only_first_error) ? prev :
		new(prev.errors, prev.parents, only_first_error)
end

struct ValidationResult
	call::Expr
	error::Any
end

include("show.jl")

function hook_verify_typeinf_trim(call)
	original_methods = methods(TrimVerifier.verify_typeinf_trim)
	# Capture verify_typeinf_trim implementation to collect errors instead of printing them
	code = quote
		function verify_typeinf_trim(io::IO, codeinfos::Vector{Any}, onlywarn::Bool)
			errors, parents = get_verify_typeinf_trim(codeinfos)

			if !isempty(errors)
				throw($TrimVerificationErrors(errors, parents))
			end
		end
	end

	out = stderr
	rd, wr = Base.redirect_stderr()
	impl = Base.eval(TrimVerifier, code)
	try
		Base.redirect_stderr(out)
		close(wr)
		msg = read(rd, String)
		if msg != "" &&
		   match(
			r"^WARNING: Method definition verify_typeinf_trim\(.+?\) in module .+ overwritten [^\n]+\n$"s,
			msg,
		) === nothing
			error(
				"Failed to override verify_typeinf_trim, unexpected warning: $msg\n\nMethods: $original_methods",
			)
		end
		invokelatest(call)
	finally
		Base.delete_method(
			only(methods(TrimVerifier.verify_typeinf_trim, (IO, Vector{Any}, Bool))),
		)
	end
end

function validate_function(call::Expr; only_first_error::Bool = true)::ValidationResult
	try
		@assert call.head == :call
		func = Main.eval(call.args[1])
		args = call.args[2:end] .|> Main.eval

		ret_types = Base.return_types(func, args)
		@assert length(ret_types) == 1
		ret_type = ret_types[1]

		try
			hook_verify_typeinf_trim() do
				Compiler.typeinf_ext_toplevel(
					Any[Core.svec(ret_type, Tuple{typeof(func),args...})],
					[Base.get_world_counter()],
					Compiler.TRIM_SAFE,
				)
			end
		catch err
			if err isa TrimVerificationErrors
				return ValidationResult(call, TrimVerificationErrors(err; only_first_error))
			else
				# @warn "e" err
				throw(err)
			end
		end
		return ValidationResult(call, nothing)
	catch err
		return ValidationResult(call, err)
	end
end

struct JobRequest
	init::Expr
	skip_fixes::Bool
	signatures::Vector{Expr}
end

abstract type JobResponse end
struct JobValidated <: JobResponse
	JobValidated(res::ValidationResult) =
		new(ValidationResult(res.call, isnothing(res.error) ? nothing : sprint(res.error)))
	result::ValidationResult
end
struct JobStartedValidation <: JobResponse end
struct JobDone <: JobResponse end

"""
	validate(signatures...; [init], [skip_fixes], [progressbar], [color])::Vector{ValidationResult}

Validates a list of function call signatures (as expressions) for trim compatibility.
`signatures` is a vector of expressions representing function calls to validate.
`init` is an expression that initializes the environment before validation.
`skip_fixes` if set to true, skips applying fixes during validation. Default is false.
`progressbar` controls whether a progress bar is shown during validation. Default is false.
`color` controls whether error messages are colorized. Default is true.
"""
function validate(
	signatures...;
	init = :(),
	skip_fixes = false,
	progressbar = false,
	kwargs...,
)::Vector{ValidationResult}
	pb = Progress(length(signatures); dt = 0, desc = "Trim Check", enabled = progressbar)
	update!(pb, 0; showvalues = ["" => "initializing..."], force = true)
	results = ValidationResult[]
	wid = addprocs(1)[1]

	try
		remotecall_eval(Main, wid, :(using TrimCheck))
		fetch(remotecall(TrimCheck.init_validation, wid, init, skip_fixes))
		for (idx, signature) in enumerate(signatures)
			try
				msg = "Validating call: $signature"
				update!(pb, idx; showvalues = ["" => msg], force = true)
				if !progressbar
					printstyled(msg, '\n'; color = :blue)
				end

				result = remotecall(TrimCheck.perform_validation, wid, signature; kwargs...)
				push!(results, fetch(result))

			catch e
				@debug "Validation error" e
				push!(results, ValidationResult(signature, e))
			end
		end
		return results
	finally
		if isempty(current_exceptions())
			if progressbar
				cancel(pb, "Done ✓"; color = :green)
			else
				printstyled("Done ✓\n"; color = :green)
			end
		else
			if progressbar
				cancel(pb, "Failed ✗"; color = :red)
			else
				printstyled("Failed ✗\n"; color = :red)
			end
		end
		rmprocs(wid)
	end
end

"""
	@validate call, [call,...] [init=initialization code] [verbose=true] [color=true] [only_first_error=true] [progressbar=true] [skip_fixes=false]

Generates a `@testset` with tests that check whether every `call` can be fully type-inferred.
The test is executed in a separate Julia process, which inherits the current project environment.
`init` is the code that sets up the environment for the test in that process.
`verbose` is passed as a parameter to `@testset`.
`color` controls whether error messages are colorized.
`only_first_error` if set to true, only the first error found in each call is reported in details.
`progressbar` controls whether a progress bar is shown during validation. By default is enabled unless running in CI environment.
`skip_fixes` controls whether fixes are skipped during validation. By default is false.
"""
macro validate(exprs::Vararg{Expr})
	initialize = :()
	verbose = true
	calls = Expr[]
	color = true
	only_first_error = true
	progress_bar = !haskey(ENV, "CI")
	skip_fixes = false

	for expr in exprs
		@match expr begin
			:(verbose = true) => begin
				verbose = true
			end
			:(verbose = false) => begin
				verbose = false
			end
			:(color = true) => begin
				color = true
			end
			:(color = false) => begin
				color = false
			end
			:(only_first_error = true) => begin
				only_first_error = true
			end
			:(only_first_error = false) => begin
				only_first_error = false
			end
			:(progressbar = true) => begin
				progress_bar = true
			end
			:(progressbar = false) => begin
				progress_bar = false
			end
			:(skip_fixes = true) => begin
				skip_fixes = true
			end
			:(skip_fixes = false) => begin
				skip_fixes = false
			end
			Expr(:call, _...) => begin
				push!(calls, expr)
			end
			:(init = $blk) => begin
				@assert initialize == :() "Only one initialization expression allowed $initialize vs $blk"
				initialize = blk
			end
		end
	end

	esc(
		quote
			$(Test).@testset "TrimCheck" verbose = $verbose begin
				results = $validate(
					$(map(QuoteNode, calls)...);
					init = $(QuoteNode(initialize)),
					progressbar = $progress_bar,
					color = $color,
					only_first_error = $only_first_error,
					skip_fixes = $skip_fixes,
				)

				$report_tests(results)
			end
		end,
	)
end

function init_validation(init::Expr, skip_fixes::Bool)
	Main.eval(init)
	if ! skip_fixes
		Main.include(
			joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-base.jl"),
		)
		Main.include(
			joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-stdlib.jl"),
		)
	end
end

function perform_validation(call::Expr; color = true, kwargs...)
	result = validate_function(call; kwargs...)
	return ValidationResult(
		result.call,
		isnothing(result.error) ? nothing :
		sprint(show, result.error; context = :color => color),
	)
end

function report_tests(results::Vector)
	for result in results
		Test.do_test(
			Test.Returned(isnothing(result.error), result, LineNumberNode(0)),
			result.call,
		)
	end
end

end # module TrimCheck
