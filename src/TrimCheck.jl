module TrimCheck

using Base: Compiler
using Pkg
using Serialization
using MLStyle: @match
using Test

export @check_calls

struct ValidationResult
    call::Expr
    errors::Vector
end

function Base.show(io::IO, vr::ValidationResult)
    if isempty(vr.errors)
        print(io, "Call `$(vr.call)` type checks successfully.")
    else
        print(io, "Call `$(vr.call)` failed type checking with errors:\n")
        for err in vr.errors
            print(io, err, "\n")
        end
    end
end

function validate_function(call::Expr)::ValidationResult #func, args::Tuple{Vararg{<:Type}})
    @assert call.head == :call
    func = Main.eval(call.args[1])
    args = call.args[2:end] .|> Main.eval

    show(stderr, args)

    ret_types = Base.return_types(func, args)
    @assert length(ret_types) == 1
    ret_type = ret_types[1]


    # Check suppressor code how to capture without temp file
    mktemp() do path, io
        redirect_stdout(io) do
            try
                Compiler.typeinf_ext_toplevel(Any[Core.svec(ret_type, Tuple{typeof(func),args...})], [Base.get_world_counter()], Compiler.TRIM_SAFE)
            catch err
                seek(io, 0)
                return ValidationResult(call, [read(io, String)])
            end
            return ValidationResult(call, [])
        end
    end
end

struct JobRequest
    preload::Expr
    signatures::Vector{Expr}
end

struct JobResponse
    results::Vector
end


function validate(preload, signatures)
    try
        inp = Base.PipeEndpoint()
        out = Base.PipeEndpoint()
        err = Base.PipeEndpoint()

        command = `$(Base.julia_cmd()) --project=$(Pkg.project().path) -e "using TrimCheck;TrimCheck.perform_validation()"`
        exec = run(command, inp, out, err; wait=false)
        serialize(exec, JobRequest(preload, signatures))
        wait(exec)

        if exec.exitcode != 0
            ProcessFailedException(exec)
        end

        data = read(exec)

        try
            response = deserialize(PipeBuffer(data))
            if !(response isa JobResponse)
                error("Report object is of wrong type $(typeof(response)) $response")
            end
            return response
        catch e
            error("Failed to deserialize $data : $(read(err, String))")
        end

    catch e
        # @warn "failed with" e stacktrace()
        throw(e)
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
            results = $validate($(QuoteNode(initialize)), $(calls))

            $report_tests(results)
        end
    end)
end

function perform_validation(req::JobRequest; skip_fixes=false)::JobResponse
    Main.eval(req.preload)
    if !skip_fixes
        Main.include(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-base.jl"))
        Main.include(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-stdlib.jl"))
    end

    results = req.signatures .|> validate_function
    return JobResponse(results)
end

function perform_validation()
    try
        request = deserialize(stdin)
        response = perform_validation(request)
        serialize(stdout, response)
    catch
        for (exc, bt) in current_exceptions()
            showerror(stderr, exc, bt)
            println(stderr)
        end
    end
end


function report_tests(results::JobResponse)
    for result in results.results
        Test.do_test(Test.Returned(isempty(result.errors), result, LineNumberNode(0)), result.call)
    end
end


end # module TrimCheck
