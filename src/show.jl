# colored show for errors 

using Base: StackTraces
using .StackTraces: StackFrame
using Core: CodeInfo, MethodInstance, CodeInstance, Method
# using InteractiveUtils: InteractiveUtils


# The trick is to define a special IO with custom type coloring behavior
struct MyIO{T<:IO} <: IO
    io::T
end
Base.pipe_writer(m::MyIO) = Base.pipe_writer(m.io)
Base.pipe_reader(m::MyIO) = Base.pipe_reader(m.io)
Base.getindex(m::MyIO, i) = Base.getindex(m.io, i)
Base.haskey(m::MyIO, k) = Base.haskey(m.io, k)
Base.get(m::MyIO, k, d) = Base.get(m.io, k, d)
Base.keys(m::MyIO) = Base.keys(m.io)
Base.setindex!(m::MyIO, v, k) = Base.setindex!(m.io, v, k)


Base.read(s::MyIO, t::Type{UInt8}) = Base.read(s.io, t)
Base.write(s::MyIO, x::UInt8) = Base.write(s.io, x)

mio = MyIO(stdout)

const MyIOTypes = Union{<:MyIO,<:IOContext{<:MyIO}};
function Base.show(io::MyIOTypes, x::Union{DataType,UnionAll,Type})
    buffer = IOBuffer()
    mio = MyIO(buffer)
    ctx = IOContext(mio, io)
    invoke(Base.show, Tuple{IO,DataType}, ctx, x)

    str = String(take!(buffer))

    if isconcretetype(x)
        if x isa Union && length(Base.uniontypes(x)) > 4
            printstyled(io, str; color=:yellow)
        else
            printstyled(io, str; color=:light_green)
        end
    else
        printstyled(io, str; color=:red)
    end
end

# Copy-pasted code to override type coloring behavior in method signature printing
function Base.show_tuple_as_call(out::IOContext{<:MyIO}, name::Symbol, sig::Type;
    demangle=false, kwargs=nothing, argnames=nothing,
    qualified=false, hasfirst=true)
    # print a method signature tuple for a lambda definition
    if sig === Tuple
        print(out, demangle ? demangle_function_name(name) : name, "(...)")
        return
    end
    tv = Any[]
    buf = IOBuffer()
    io = IOContext(MyIO(buf), out)
    env_io = io
    while isa(sig, UnionAll)
        push!(tv, sig.var)
        env_io = IOContext(env_io, :unionall_env => sig.var)
        sig = sig.body
    end
    n = 1
    sig = (sig::DataType).parameters
    if hasfirst
        Base.show_signature_function(env_io, sig[1], demangle, "", false, qualified)
        n += 1
    end
    first = true
    Base.print_within_stacktrace(io, "(", bold=true)
    show_argnames = argnames !== nothing && length(argnames) == length(sig)
    for i = n:length(sig)  # fixme (iter): `eachindex` with offset?
        first || print(io, ", ")
        first = false
        if show_argnames
            Base.print_within_stacktrace(io, argnames[i]; color=:light_black)
        end
        print(io, "::")
        show(env_io, sig[i])
    end
    if kwargs !== nothing
        print(io, "; ")
        first = true
        for (k, t) in kwargs
            first || print(io, ", ")
            first = false
            Base.print_within_stacktrace(io, k; color=:light_black)
            if t == pairs(NamedTuple)
                # omit type annotation for splat keyword argument
                print(io, "...")
            else
                print(io, "::")
                show(io, t)
            end
        end
    end
    Base.print_within_stacktrace(io, ")", bold=true)
    Base.show_method_params(io, tv)
    str = String(take!(buf))
    str = Base.type_limited_string_from_context(out, str)
    print(out, str)
    nothing
end


# Copy-pasted due to to too restrictive signature
function verify_print_stmt(io::IO, codeinfo::CodeInfo, sptypes::Vector{TrimVerifier.VarState}, stmtidx::Int)
    if codeinfo.slotnames !== nothing
        io = IOContext(io, :SOURCE_SLOTNAMES => TrimVerifier.sourceinfo_slotnames(codeinfo))
    end
    print(io, TrimVerifier.mapssavaluetypes(codeinfo, sptypes, TrimVerifier.SSAValue(stmtidx)))
end

# Copy-pasted due to to too restrictive signature
function verify_print_error(io::IO, desc::TrimVerifier.CallMissing, parents::TrimVerifier.ParentMap)
    (; codeinst, codeinfo, sptypes, stmtidx, desc) = desc
    frames = TrimVerifier.verify_create_stackframes(codeinst, stmtidx, parents)
    print(io, desc, " from statement ")
    verify_print_stmt(io, codeinfo, sptypes, stmtidx)
    Base.show_backtrace(io, frames)
    print(io, "\n\n")
    nothing
end

# Copy-pasted due to to too restrictive signature
function verify_print_error(io::IO, desc::TrimVerifier.CCallableMissing, parents::TrimVerifier.ParentMap)
    print(io, desc.desc, " for ", desc.sig, " => ", desc.rt, "\n\n")
    nothing
end

function Base.show(io::IO, tve::TrimVerificationErrors)
    mio = MyIO(io)
    counts = [0, 0] # errors, warnings

    for err in tve.errors
        warn, desc = err
        severity = warn ? 2 : 1
        no = (counts[severity] += 1)
        print(mio, warn ? "Verifier warning #" : "Verifier error #", no, ": ")
        verify_print_error(mio, desc, tve.parents)
    end
    return nothing
end