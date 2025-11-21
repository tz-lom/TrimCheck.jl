module TrimCheck

using Compiler: Compiler, TrimVerifier
using Pkg
using Serialization
using MLStyle: @match
using Test
using ProgressMeter
using Distributed

export @check_calls
# public(validate, ValidationResult)


struct TrimVerificationErrors
    errors
    parents
end

include("show.jl")


struct ValidationResult
    call::Expr
    error
end

function Base.show(io::IO, vr::ValidationResult)
    if isnothing(vr.error)
        print(io, "Call `$(vr.call)` is trim compatible.")
    else
        print(io, "Call `$(vr.call)` failed trim checking with:\n")
        print(io, vr.error)
    end
end

function hook_verify_typeinf_trim(call)

    # Capture verify_typeinf_trim implementation to collect errors instead of printing them
    if VERSION >= v"1.12.1"
        code = quote
            function verify_typeinf_trim(codeinfos::Vector{Any}, onlywarn::Bool)
                errors, parents = get_verify_typeinf_trim(codeinfos)

                if !isempty(errors)
                    throw($TrimVerificationErrors(errors, parents))
                end
            end
        end
    else
        code = quote
            function verify_typeinf_trim(io::IO, codeinfos::Vector{Any}, onlywarn::Bool)
                errors, parents = get_verify_typeinf_trim(codeinfos)

                if !isempty(errors)
                    throw($TrimVerificationErrors(errors, parents))
                end
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
        if msg != "" && match(r"^WARNING: Method definition verify_typeinf_trim\(.+?\) in module Compiler at .+ overwritten in module TrimVerifier at [^\n]+\n$"s, msg) === nothing
            error("Failed to override verify_typeinf_trim, unexpected warning: $msg")
        end
        invokelatest(call)
    finally
        Base.delete_method(methods(impl)[1])
    end
end

function validate_function(call::Expr)::ValidationResult
    try
        @assert call.head == :call
        func = Main.eval(call.args[1])
        args = call.args[2:end] .|> Main.eval

        ret_types = Base.return_types(func, args)
        @assert length(ret_types) == 1
        ret_type = ret_types[1]


        try
            hook_verify_typeinf_trim() do
                Compiler.typeinf_ext_toplevel(Any[Core.svec(ret_type, Tuple{typeof(func),args...})], [Base.get_world_counter()], Compiler.TRIM_SAFE)
            end
        catch err
            if err isa TrimVerificationErrors
                return ValidationResult(call, err)
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
    JobValidated(res::ValidationResult) = new(ValidationResult(res.call, isnothing(res.error) ? nothing : sprint(res.error)))
    result::ValidationResult
end
struct JobStartedValidation <: JobResponse end
struct JobDone <: JobResponse end


function validate(init, signatures; skip_fixes=false, progressbar=false)::Vector{ValidationResult}
    pb = Progress(length(signatures); dt=0, desc="Trim Check")
    update!(pb, 0, showvalues=["" => "initializing..."], force=true)
    results = ValidationResult[]
    wid = addprocs(1)[1]

    try
        fetch(@spawnat wid Main.eval(:(using TrimCheck)))
        fetch(@spawnat wid TrimCheck.init_validation(init, skip_fixes))
        for (idx, signature) in enumerate(signatures)
            try
                update!(pb, idx, showvalues=["" => "Validating call: $signature"], force=true)

                result = @spawnat wid TrimCheck.perform_validation(signature)
                append!(results, fetch(result))

            catch e
                @debug "Validation error" e
                append!(results, ValidationResult(signature, e))
            end
        end
        return results
    finally
        if isempty(current_exceptions())
            cancel(pb, "Done ✓", color=:green)
        else
            cancel(pb, "Failed ✗", color=:red)
        end
        rmprocs(wid)
    end
end

"""
    @check_calls [init=initialization code] [verbose=true] call, [call,...]

 Generates a `@testset` with tests that check whether every `call` can be fully type-inferred.
The test is executed in a separate Julia process, which inherits the current project environment.
`init` is the code that sets up the environment for the test in that process.
`verbose` is passed as a parameter to `@testset`.
"""
macro check_calls(exprs::Vararg{Expr})
    initialize = :()
    verbose = true
    calls = Expr[]

    for expr in exprs
        @match expr begin
            :(verbose = true) => begin
                verbose = true
            end
            :(verbose = false) => begin
                verbose = false
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

    esc(quote
        $(Test).@testset "TrimCheck" verbose = $verbose begin
            results = $validate($(QuoteNode(initialize)), $(calls); progressbar=true)

            $report_tests(results)
        end
    end)
end

function init_validation(init::Expr, skip_fixes::Bool)
    Main.eval(init)
    if skip_fixes
        Main.include(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-base.jl"))
        Main.include(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-stdlib.jl"))
    end
end

function perform_validation(call::Expr; kwargs...)
    result = validate_function(call; kwargs...)
    return ValidationResult(result.call, isnothing(result.error) ? nothing : sprint(show, result.error; context=:color => get(stdout, :color, false)))
end


function report_tests(results::Vector)
    for result in results
        Test.do_test(Test.Returned(isnothing(result.error), result, LineNumberNode(0)), result.call)
    end
end


end # module TrimCheck
