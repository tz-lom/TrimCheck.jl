using Base: StackTraces
using .StackTraces: StackFrame
using Core: CodeInfo, MethodInstance, CodeInstance, Method


# The trick is to define a special IO with custom type coloring behavior
struct ColorfullTypes{T<:IO} <: IO
    io::T
end
Base.pipe_writer(m::ColorfullTypes) = Base.pipe_writer(m.io)
Base.pipe_reader(m::ColorfullTypes) = Base.pipe_reader(m.io)
Base.getindex(m::ColorfullTypes, i) = Base.getindex(m.io, i)
Base.haskey(m::ColorfullTypes, k) = Base.haskey(m.io, k)
Base.get(m::ColorfullTypes, k, d) = Base.get(m.io, k, d)
Base.keys(m::ColorfullTypes) = Base.keys(m.io)
Base.setindex!(m::ColorfullTypes, v, k) = Base.setindex!(m.io, v, k)


Base.read(s::ColorfullTypes, t::Type{UInt8}) = Base.read(s.io, t)
Base.write(s::ColorfullTypes, x::UInt8) = Base.write(s.io, x)

const ColorfullTypesIO = Union{<:ColorfullTypes,<:IOContext{<:ColorfullTypes}};

function paint_type(io::IO, str, type::Type)
    if type isa Union
        if length(Base.uniontypes(type)) > 4
            return printstyled(io, str; color=:yellow)
        else
            return printstyled(io, str; color=:light_green)
        end
    elseif isconcretetype(type)
        return printstyled(io, str; color=:light_green)
    else
        return printstyled(io, str; color=:red)
    end
end

function Base.show(io::ColorfullTypesIO, x::Type)
    buffer = IOBuffer()
    ctx = IOContext(ColorfullTypes(buffer), io)
    invoke(Base.show, Tuple{IO,DataType}, ctx, x)
    paint_type(io, String(take!(buffer)), x)
end
function Base.show_typealias(io::ColorfullTypesIO, name::GlobalRef, x::Type, env::Base.SimpleVector, wheres::Vector)
    properx = Base.makeproper(io, x)
    aliases, _ = Base.make_typealiases(properx)
    alias = first(filter(a -> a[1] == name, aliases))
    buffer = IOBuffer()
    ctx = IOContext(ColorfullTypes(buffer), io)
    invoke(Base.show_typealias, Tuple{IO,GlobalRef,Type,Base.SimpleVector,Vector}, ctx, name, x, env, wheres)
    paint_type(io, String(take!(buffer)), alias[3])
end


# Copy-pasted code to override type coloring behavior in method signature printing
function Base.show_tuple_as_call(out::IOContext{<:ColorfullTypes}, name::Symbol, sig::Type;
    demangle=false, kwargs=nothing, argnames=nothing,
    qualified=false, hasfirst=true)
    # print a method signature tuple for a lambda definition
    if sig === Tuple
        print(out, demangle ? demangle_function_name(name) : name, "(...)")
        return
    end
    tv = Any[]
    buf = IOBuffer()
    io = IOContext(ColorfullTypes(buf), out)
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
    mio = ColorfullTypes(io)
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