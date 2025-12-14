
struct TypeUnstable
    x
end

struct TypeStable
    x::Union{Float64,Int64}
end

function foo(x)
    show(Core.stdout, "=$x=")
end

Base.show(io::IO, x::TypeStable) = print(io, x.x)


function type_defined(x::Int)
    return x+3
end

function @main(args)
    foo(TypeStable(42))
    return 0
end

# julia ~/.julia/juliaup/julia-1.12.1+0.x64.linux.gnu/share/julia/juliac/juliac.jl --experimental --trim --output-exe trimmed ./test/funcs.jl 