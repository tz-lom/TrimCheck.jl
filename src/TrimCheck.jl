module TrimCheck

using Compiler: Compiler, TrimVerifier
using Pkg
using Serialization
using MLStyle: @match
using Test
using ProgressMeter

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
        if match(r"^WARNING: Method definition verify_typeinf_trim\(.+?\) in module Compiler at .+ overwritten in module TrimVerifier at [^\n]+\n$"s, msg) === nothing
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
                @warn "e" err
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

    inp = Base.PipeEndpoint()
    out = Base.PipeEndpoint()
    err = Base.PipeEndpoint()

    command = `$(Base.julia_cmd()) --project=$(Pkg.project().path) -e "using TrimCheck;TrimCheck.perform_validation()"`
    exec = run(command, inp, out, err; wait=false)
    serialize(exec, JobRequest(init, skip_fixes, signatures))

    results = ValidationResult[]

    pb = Progress(length(signatures); dt=0, desc="Trim Check")
    idx = 0
    try
        while true
            try
                msg =
                    if idx <= 0
                        "Initializing..."
                    elseif 0 < idx <= length(signatures)
                        "Validating call: $(signatures[idx])"
                    else
                        "Finalizing..."
                    end
                update!(pb, idx, showvalues=["" => msg], force=true)
                response = deserialize(exec)
                if response isa JobDone
                    return results
                elseif response isa JobValidated
                    push!(results, response.result)
                    idx += 1
                elseif response isa JobStartedValidation
                    idx = 1
                else
                    error("Report object is of wrong type $(typeof(response)) $response")
                end
            catch e
                error("Failed: $e")
            end
        end
    finally
        cancel(pb, "Done", color=:green)
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

function perform_validation(req::JobRequest)
    Main.eval(req.init)
    if req.skip_fixes
        Main.include(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-base.jl"))
        Main.include(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-stdlib.jl"))
    end
    serialize(stdout, JobStartedValidation())

    for sig in req.signatures
        serialize(stdout, JobValidated(validate_function(sig)))
        sleep(2)
    end
end

function perform_validation()
    try
        request = deserialize(stdin)
        perform_validation(request)
        serialize(stdout, JobDone())
    catch
        for (exc, bt) in current_exceptions()
            showerror(stderr, exc, bt)
            println(stderr)
        end
    end
end


function report_tests(results::Vector)
    for result in results
        Test.do_test(Test.Returned(isnothing(result.error), result, LineNumberNode(0)), result.call)
    end
end


end # module TrimCheck
