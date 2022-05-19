"""
    BufferedFiles

Implementations of a better Filehandles.

Includes a Read-Only Filehandle and a better Write-Only Filehandle

Uses Julias Filesystem.File for Portability.

Main Functions: [`open`](@ref) and [`@om_str`](@ref)
"""
module BufferedFiles
using Base.Filesystem

export @om_str, bufferedopen

function cmemcpy(dest, src, nbytes)
    @ccall memcpy(dest::Ptr{Cvoid}, src::Ptr{Cvoid}, nbytes::Csize_t)::Ptr{Cvoid}
    nothing
end

function cmemmove(dest, src, nbytes)
    @ccall memmove(dest::Ptr{Cvoid}, src::Ptr{Cvoid}, nbytes::Csize_t)::Ptr{Cvoid}
    nothing
end

"""
    const DEFAULT_BUFSIZE = 16 * (1024) * (1024)

Default size of the read/write-buffer of [`BufferedReadFile`](@ref) and [`BufferedWriteFile`](@ref).
"""
const DEFAULT_BUFSIZE = 16 * (1024) * (1024)

"""
    abstract type BufferedOpenMode end

Types Implemented by [`@om_str`](@ref), used in [`open`](@ref)
"""
abstract type BufferedOpenMode end

struct Read <: BufferedOpenMode end

struct WriteTrunc <: BufferedOpenMode end

struct Append <: BufferedOpenMode end

struct ReadWrite <: BufferedOpenMode end

struct ReadWriteTrunc <: BufferedOpenMode end

struct ReadAppend <: BufferedOpenMode end

struct MmapRead <: BufferedOpenMode end

struct MmapReadWrite <: BufferedOpenMode end

"""
    BufferedOpenMode(pattern::AbstractString)

Convert `pattern` into its corresponding subtype of `BufferedOpenMode`.

Recommended Usage of this is with the [`@om_str`](@ref) macro at parse-time.
"""
function BufferedOpenMode(pattern::AbstractString)
    if pattern == "r"
        return Read()
    elseif pattern == "w"
        return WriteTrunc()
    elseif pattern == "a"
        return Append()
    elseif pattern == "r+"
        return ReadWrite()
    elseif pattern == "w+"
        return ReadWriteTrunc()
    elseif pattern == "a+"
        return ReadAppend()
    elseif pattern == "mr"
        return MmapRead()
    elseif pattern == "mr+"
        return MmapReadWrite()
    end
    return error("Error, no matching string found!")
end

"""
    @om_str "pattern"
    om"pattern"

Convert `pattern` into its corresponding subtype of [`BufferedOpenMode`](@ref) at parse-time.
"""
macro om_str(pattern)
    return BufferedOpenMode(pattern)
end

"""
    abstract type BufferedFile <: IO end

Abstract Type for my Filehandles, to overwrite some of Julias functions from io.jl that cause allocations.
"""
abstract type BufferedFile <: IO end

const bufferedopen = Base.open

# Overwrites two @noinline julia functions which cause allocations in a lot of situations
function Base.unsafe_read(s::BufferedFile, p::Ref{T}, n::Integer) where {T}
    GC.@preserve p unsafe_read(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n)
end
function Base.unsafe_write(s::BufferedFile, p::Ref{T}, n::Integer) where {T}
    GC.@preserve p unsafe_write(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n)
end

function Base.unsafe_read(s::BufferedFile, p::Ptr, n::Integer)
    return unsafe_read(s, convert(Ptr{UInt8}, p), convert(UInt, n))
end
function Base.unsafe_write(s::BufferedFile, p::Ptr, n::Integer)
    return unsafe_write(s, convert(Ptr{UInt8}, p), convert(UInt, n))
end

"""
    BufferedReadFile

Buffered Filehandle for more performant Reading.

Opened via [`open(filename, om"r")`](@ref Base.open(::AbstractString, ::Read)).
"""
mutable struct BufferedReadFile <: BufferedFile
    rf::File
    buf::Vector{UInt8}
    filepos::Int
    fileend::Int
    bufpos::Int
    buflastread::Int
    function BufferedReadFile(rf, buf)
        f = new(rf, buf, position(rf), filesize(rf), 0, 0)
        finalizer(close, f)
        refresh(f)
        return f
    end
end

Base.isopen(p::BufferedReadFile) = isopen(p.rf)
Base.isreadable(p::BufferedReadFile) = isopen(p)
Base.iswritable(::BufferedReadFile) = false

"""
    open(file::AbstractString, om"r"[, bufsize::Integer])

Open a File in Read-Only Mode.

Returns a [`BufferedReadFile`](@ref).
"""
function Base.open(file::AbstractString, ::Read, bufsize::Integer=DEFAULT_BUFSIZE)
    rf = Filesystem.open(file, JL_O_RDONLY)
    buf = Vector{UInt8}(undef, bufsize)
    f = BufferedReadFile(rf, buf)
    return f
end

function refresh(f::BufferedReadFile)
    GC.@preserve f begin
        cmemmove(pointer(f.buf), pointer(f.buf) + f.bufpos, bytesavailable(f))
        f.buflastread = bytesavailable(f)
        f.bufpos = 0
        to_read::UInt = min(length(f.buf) - f.buflastread, max(0, f.fileend - f.filepos))
        f.filepos += to_read
        unsafe_read(f.rf, pointer(f.buf) + f.buflastread, to_read)
        f.buflastread += to_read
    end
    return f
end

function Base.position(f::BufferedReadFile)::Int
    return f.filepos - (f.buflastread - f.bufpos)
end

function Base.eof(f::BufferedReadFile)::Bool
    return (f.buflastread - f.bufpos) == 0
end

function Base.skip(f::BufferedReadFile, n::Integer)
    todo::UInt = bytesavailable(f)
    if n >= 0
        nb::UInt = n
        if todo == 0
            if nb > 0
                throw(EOFError())
            end
        elseif todo > nb
            f.bufpos += nb
        elseif todo <= nb
            f.bufpos = f.buflastread
            refresh(f)
            skip(f, (nb - todo)::UInt)
        end
    else
        u::UInt = abs(n)
        if f.bufpos < u
            dif = u - f.bufpos
            skip(f.rf, -Int(f.buflastread + dif))
            f.filepos -= (f.buflastread + dif)
            f.bufpos = 0
            f.buflastread = 0
            refresh(f)
        else
            f.bufpos -= u
        end
    end
    return f
end

function Base.seek(f::BufferedReadFile, n::Integer)
    if position(f) != n
        seek(f.rf, n)
        f.filepos = n
        f.buflastread = 0
        f.bufpos = 0
        refresh(f)
    end
    return f
end

function Base.close(f::BufferedReadFile)
    if isopen(f)
        close(f.rf)
        resize!(f.buf, 0)
        sizehint!(f.buf, 0)
    end
    return nothing
end

Base.bytesavailable(f::BufferedReadFile) = f.buflastread - f.bufpos

function Base.read(s::BufferedReadFile, ::Type{UInt8})
    r = bytesavailable(s)
    if r >= 2
        s.bufpos += 1
        return @inbounds s.buf[s.bufpos]
    elseif r == 1
        s.bufpos += 1
        cnt = @inbounds s.buf[s.bufpos]
        refresh(s)
        return cnt
    elseif r == 0
        throw(EOFError())
    else
        error("this should never happen!")
    end
end

function Base.unsafe_read(f::BufferedReadFile, p::Ptr{UInt8}, nb::UInt)
    todo::UInt = bytesavailable(f)
    if todo == 0
        if nb > 0
            throw(EOFError())
        else
            return nothing
        end
    end
    if todo > nb
        GC.@preserve f begin
            cmemcpy(p, pointer(f.buf) + f.bufpos, nb)
        end
        f.bufpos += nb
        return nothing
    elseif todo < nb
        GC.@preserve f begin
            cmemcpy(p, pointer(f.buf) + f.bufpos, todo)
        end
        f.bufpos = f.buflastread
        refresh(f)
        return unsafe_read(f, p + todo, nb - todo)
    elseif todo == nb
        GC.@preserve f begin
            cmemcpy(p, pointer(f.buf) + f.bufpos, todo)
        end
        f.bufpos = f.buflastread
        refresh(f)
        return nothing
    else
        error("This should never happen!")
    end
end

function Base.resize!(b::BufferedReadFile, ns::Integer)
    s = Int(ns)
    if b.buflastread < s
        resize!(b.buf, s)
    elseif b.buflastread >= s
        p = position(b)
        seek(b.rf, p)
        b.filepos = p
        b.buflastread = 0
        b.bufpos = 0
        resize!(b.buf, s)
        refresh(b)
    end
    return b
end

"""
    BufferedWriteFile

Buffered Filehandle for more performant sequential Writing.

Opened via [`open(filename, om"r")`](@ref open(::AbstractString, ::Read)).
"""
mutable struct BufferedWriteFile <: BufferedFile
    rf::File
    buf::Vector{UInt8}
    filepos::Int
    bufpos::Int
    function BufferedWriteFile(rf, buf)
        f = new(rf, buf, position(rf), 0)
        finalizer(close, f)
        return f
    end
end

function Base.resize!(b::BufferedWriteFile, ns::Integer)
    s = Int(ns)
    if s <= b.bufpos
        flush(b)
    end
    resize!(b.buf, s)
    return b
end

Base.isopen(p::BufferedWriteFile) = isopen(p.rf)
Base.isreadable(::BufferedWriteFile) = false
Base.iswritable(p::BufferedWriteFile) = isopen(p)

"""
    open(file::AbstractString, om"w"[, bufsize::Integer])

Open a File in Write-Only Mode.

Truncates the File when opening it.

Returns a [`BufferedWriteFile`](@ref).
"""
function Base.open(file::AbstractString,
                   ::WriteTrunc,
                   bufsize::Integer=DEFAULT_BUFSIZE)
    buf = Vector{UInt8}(undef, bufsize)
    rf = Filesystem.open(file, JL_O_CREAT | JL_O_TRUNC | JL_O_WRONLY,
                         S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    return BufferedWriteFile(rf, buf)
end

function Base.flush(f::BufferedWriteFile)
    GC.@preserve f begin
        unsafe_write(f.rf, pointer(f.buf), f.bufpos)
    end
    f.filepos += f.bufpos
    f.bufpos = 0
    return f
end

function Base.position(f::BufferedWriteFile)::Int
    return f.filepos + f.bufpos
end

function Base.skip(f::BufferedWriteFile, n::Integer)
    flush(f)
    skip(f.rf, n)
    f.filepos += n
    return f
end

function Base.seek(f::BufferedWriteFile, n::Integer)
    if position(f) != n
        flush(f)
        seek(f.rf, n)
    end
    f.filepos = n
    return f
end

function Base.close(f::BufferedWriteFile)
    if isopen(f)
        flush(f)
        close(f.rf)
        resize!(f.buf, 0)
        sizehint!(f.buf, 0)
    end
    return nothing
end

function Base.unsafe_write(f::BufferedWriteFile, p::Ptr{UInt8}, nb::UInt)::UInt
    freespace = (length(f.buf) - f.bufpos)
    @assert freespace > 0
    if freespace > nb
        GC.@preserve f begin
            cmemcpy(pointer(f.buf) + f.bufpos, p, nb)
        end
        f.bufpos += nb
        return nb
    elseif freespace <= nb
        GC.@preserve f begin
            cmemcpy(pointer(f.buf) + f.bufpos, p, freespace)
        end
        f.bufpos += freespace
        flush(f)
        return freespace + unsafe_write(f, p + freespace, nb - freespace)
    else
        error("This should never happen!")
    end
end

function Base.write(s::BufferedWriteFile, u::UInt8)
    freespace = (length(s.buf) - s.bufpos)
    if freespace >= 2
        s.bufpos += 1
        @inbounds s.buf[s.bufpos] = u
    elseif freespace == 1
        s.bufpos += 1
        @inbounds s.buf[s.bufpos] = u
        flush(s)
    else
        error("This should never happen!")
    end
    return 1
end

end # module
