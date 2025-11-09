using TrimCheck

@check_calls(init = begin
        include(joinpath(@__DIR__, "funcs.jl"))
    end, verbose = true,
    foo(Int32),
    foo(String),
    foo(TypeUnstable),
    foo(TypeStable))
