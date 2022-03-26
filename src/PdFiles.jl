"""
    PdFiles

Implementations of a better Filehandles. 

Includes a Read-Only Filehandle, 
a better Write-Only Filehandle 
as well as Mmap-Filehandles allowing both Reading and writing (but not appending (yet)).

Main Functions: [`pdopen`](@ref) and [`@om_str`](@ref)
"""
module PdFiles

export @om_str, pdopen

using Mmap

include("PdLibc.jl")
using .PdLibc

"""
    const PD_BUFSIZE = 16 * (1024) * (1024)

Default size of the read/write-buffer of [`PdReadFile`](@ref) and [`PdWriteFile`](@ref).
"""
const PD_BUFSIZE = 16 * (1024) * (1024)

"""
    abstract type PdOpenMode end

Types Implemented by [`@om_str`](@ref), used in [`pdopen`](@ref)
"""
abstract type PdOpenMode end

struct Read <: PdOpenMode end

openflags(::Read) = O_RDONLY
openmode(::Read) = nothing

struct WriteTrunc <: PdOpenMode end

openflags(::WriteTrunc) = O_WRONLY | O_TRUNC | O_CREAT
openmode(::WriteTrunc) = S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH

struct Append <: PdOpenMode end

openflags(::Append) = O_WRONLY | O_APPEND
openmode(::Append) = nothing

struct ReadWrite <: PdOpenMode end

openflags(::ReadWrite) = O_RDWR | O_APPEND
openmode(::ReadWrite) = nothing

struct ReadWriteTrunc <: PdOpenMode end

openflags(::ReadWriteTrunc) = O_RDWR | O_CREAT | O_TRUNC
openmode(::ReadWriteTrunc) = S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH

struct ReadAppend <: PdOpenMode end

openflags(::ReadAppend) = O_RDWR | O_APPEND
openmode(::ReadAppend) = nothing

struct MmapRead <: PdOpenMode end

struct MmapReadWrite <: PdOpenMode end

"""
    PdOpenMode(pattern::AbstractString)

Convert `pattern` into its corresponding subtype of `PdOpenMode`. 

Recommended Usage of this is with the [`@om_str`](@ref) macro at parse-time.
"""
function PdOpenMode(pattern::AbstractString) 
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
    error("Error, no matching string found!")
end

"""
    @om_str "pattern"
    om"pattern"

Convert `pattern` into its corresponding subtype of [`PdOpenMode`](@ref) at parse-time.
"""
macro om_str(pattern) PdOpenMode(pattern) end

"""
    abstract type PdFile <: IO end

Abstract Type for my Filehandles, to overwrite some of Julias functions from io.jl that cause allocations.
"""
abstract type PdFile <: IO end

Base.read(s::PdFile, ::Type{UInt8}) = read!(s, Ref{UInt8}())[]
Base.write(s::PdFile, v::UInt8) = write(s, Ref{UInt8}(v))

Base.unsafe_read(s::PdFile, p::Ref{T}, n::Integer) where {T} = GC.@preserve p unsafe_read(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n) # Overwrites two @noinline julia functions which cause allocations in a lot of situations
Base.unsafe_write(s::PdFile, p::Ref{T}, n::Integer) where {T} = GC.@preserve p unsafe_write(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n)

Base.unsafe_read(s::PdFile, p::Ptr, n::Integer) = unsafe_read(s, convert(Ptr{UInt8}, p), convert(UInt, n))
Base.unsafe_write(s::PdFile, p::Ptr, n::Integer) = unsafe_write(s, convert(Ptr{UInt8}, p), convert(UInt, n))

"""
    struct PdRawFile <: PdFile 
        fd::Cint
    end

Raw Filehandle with no Buffer, that calls the C-Functions for Reading, Writing etc.

Used in [`PdReadFile`](@ref) and [`PdWriteFile`](@ref).
"""
struct PdRawFile <: PdFile 
    fd::Cint
end

function pdrawopen(file::AbstractString, om::PdOpenMode)
    flags = openflags(om)
    mode = openmode(om)
    fdes = copen(file, flags, mode)
    return PdRawFile(fdes)
end

function Base.seek(s::PdRawFile, off)
    clseek(s.fd, off, SEEK_SET)
    return s
end

function Base.skip(s::PdRawFile, off)
    clseek(s.fd, off, SEEK_CUR)
    return s
end

function Base.position(s::PdRawFile)
    return clseek(s.fd, 0, SEEK_CUR)
end

Base.unsafe_write(s::PdRawFile, p::Ptr{UInt8}, n::UInt) = cwrite(s.fd, p, n)
Base.unsafe_read(s::PdRawFile, p::Ptr{UInt8}, n::UInt) = cread(s.fd, p, n)

Base.close(s::PdRawFile) = cclose(s.fd)

"""
    PdReadFile

Buffered Filehandle for more performant Reading.

Opened via [`pdopen(filename, om"r")`](@ref pdopen(::AbstractString, ::Read)).
"""
mutable struct PdReadFile <: PdFile
    rf::PdRawFile
    buf::Vector{UInt8}
    pos::Int
    lastread::Int
    isopen::Bool
    function PdReadFile(rf, buf, pos, lastread, isopen)
        f = new(rf, buf, pos, lastread, isopen)
        finalizer(close, f)
        refresh(f)
        return f
    end
end

Base.isopen(p::PdReadFile) = p.isopen

"""
    pdopen(file::AbstractString, openmode::AbstractString, args...)

Open a File.

Which type of Filehandle is returned depends on openmode.
"""
pdopen(file::AbstractString, openmode::AbstractString, args...) = pdopen(file, PdOpenMode(openmode), args...)

"""
    pdopen(file::AbstractString, om"r"[, bufsize::Integer])
    
Open a File in Read-Only Mode.

Returns a [`PdReadFile`](@ref).
"""
function pdopen(file::AbstractString, ::Read, bufsize::Integer=PD_BUFSIZE)
    rf = pdrawopen(file, om"r")
    buf = Vector{UInt8}(undef, bufsize)
    f = PdReadFile(rf, buf, 0, 0, true)
    refresh(f)
    return f
end

function refresh(f::PdReadFile)
    GC.@preserve f begin 
        cmemmove(pointer(f.buf), pointer(f.buf) + f.pos, f.lastread - f.pos)
        f.lastread = f.lastread - f.pos
        f.pos = 0
        f.lastread += unsafe_read(f.rf, pointer(f.buf) + f.lastread, length(f.buf) - f.lastread)
    end
    return f
end

function Base.position(f::PdReadFile)::Int
    return position(f.rf) - (f.lastread - f.pos)
end

function Base.eof(f::PdReadFile)::Bool
    return (f.lastread - f.pos) == 0
end

function Base.skip(f::PdReadFile, n::Integer)
    u::Int = n
    if u < 0 && f.pos + u > 0
        f.pos += u
        return f
    elseif u > 0 && (f.lastread - f.pos) > u
        f.pos += u
        return f
    elseif u == 0
        return f
    else
        skip(f.rf, u)
        f.lastread = 0
        f.pos = 0
        refresh(f)
        return f
    end
end

function Base.seek(f::PdReadFile, n::Integer)
    u::Int = n
    seek(f.rf, u)
    f.lastread = 0
    f.pos = 0
    refresh(f)
    return f
end

function Base.close(f::PdReadFile)
    if isopen(f)
        flush(f)
        f.isopen = false
        close(f.rf)
    end
    return nothing
end

function Base.unsafe_read(f::PdReadFile, p::Ptr{UInt8}, nb::UInt)::UInt
    todo::UInt = (f.lastread - f.pos)
    if todo == 0
        if nb > 0
            throw(EOFError())
        else
            return 0
        end
    end
    if todo > nb
        GC.@preserve f begin
            cmemcpy(p, pointer(f.buf) + f.pos, nb)
        end
        f.pos += nb
        return nb
    elseif todo < nb
        GC.@preserve f begin
            cmemcpy(p, pointer(f.buf) + f.pos, todo)
        end
        f.pos = f.lastread
        refresh(f)
        return todo + unsafe_read(f, p + todo, nb - todo)
    elseif todo == nb
        GC.@preserve f begin
            cmemcpy(p, pointer(f.buf) + f.pos, todo)
        end
        f.pos = f.lastread
        refresh(f)
        return todo
    else
        error("This should never happen!")
    end
end

"""
    PdReadFile

Buffered Filehandle for more performant Reading.

Opened via [`pdopen(filename, om"r")`](@ref pdopen(::AbstractString, ::Read)).
"""
mutable struct PdWriteFile <: PdFile 
    rf::PdRawFile
    buf::Vector{UInt8}
    pos::Int
    isopen::Bool
    function PdWriteFile(rf, buf, pos, isopen)
        f = new(rf, buf, pos, isopen)
        finalizer(close, f)
        return f
    end
end

"""
    pdopen(file::AbstractString, om"w"[, bufsize::Integer])
    
Open a File in Write-Only Mode.

Truncates the File when opening it.

Returns a [`PdWriteFile`](@ref).
"""
function pdopen(file::AbstractString, ::WriteTrunc, bufsize::Integer=PD_BUFSIZE)
    rf = pdrawopen(file, om"w")
    buf = Vector{UInt8}(undef, bufsize)
    return PdWriteFile(rf, buf, 0, true)
end

function Base.flush(f::PdWriteFile)
    GC.@preserve f begin
        rt = unsafe_write(f.rf, pointer(f.buf), f.pos) 
    end
    @assert rt == f.pos
    f.pos = 0
    return f
end

function Base.position(f::PdWriteFile)::Int
    return position(f.rf) + f.pos
end

function Base.skip(f::PdWriteFile, n::Integer)
    flush(f)
    skip(f.rf, n)
    return f
end

function Base.seek(f::PdWriteFile, n::Integer)
    flush(f)
    seek(f.rf, n)
    return f
end

function Base.close(f::PdWriteFile)
    if isopen(f)
        flush(f)
        f.isopen = false
        close(f.rf)
    end
    return nothing
end

function Base.unsafe_write(f::PdWriteFile, p::Ptr{UInt8}, nb::UInt)::UInt
    freespace::UInt = (length(f.buf) - f.pos)
    @assert freespace > 0
    if freespace > nb
        GC.@preserve f begin
            cmemcpy(pointer(f.buf) + f.pos, p, nb)
        end
        f.pos += nb
        return nb
    elseif freespace <= nb
        GC.@preserve f begin
            cmemcpy(pointer(f.buf) + f.pos, p, freespace)
        end
        f.pos += freespace
        flush(f)
        return freespace + unsafe_write(f, p + freespace, nb - freespace)
    else
        error("This should never happen!")
    end
end

mutable struct PdMmapFile <: PdFile
    mm::Ptr{UInt8}
    length::Csize_t
    pos::UInt
    function PdMmapFile(mm, length, pos)
        f = new(mm, length, pos)
        finalizer(close, f)
        return f
    end
end

"""
    pdopen(file::AbstractString, om"mr")
    
Open a file via Mmap in Read-Only Mode.
"""
function pdopen(file::AbstractString, ::MmapRead)
    fs = filesize(file)
    raw = pdrawopen(file, om"r")
    mm = cmmap(C_NULL, fs, PROT_READ, MAP_SHARED, raw.fd, 0)
    cmadvise(mm, fs, MADV_SEQUENTIAL)
    close(raw)
    return PdMmapFile(mm, fs, 0)
end

"""
    pdopen(file::AbstractString, om"mr+")
    
Open a file via Mmap in Read-Write Mode.

Appending is currently not possible and will throw an `EOFError`.
"""
function pdopen(file::AbstractString, ::MmapReadWrite)
    fs = filesize(file)
    raw = pdrawopen(file, om"r+")
    mm = cmmap(C_NULL, fs, PROT_READ | PROT_WRITE, MAP_SHARED, raw.fd, 0)
    cmadvise(mm, fs, MADV_SEQUENTIAL)
    close(raw)
    return PdMmapFile(mm, fs, 0)
end

"""
    pdopen(file::AbstractString, om"mr+", fs::Integer)
    
Open a file via Mmap in Read-Write Mode.

The file will be truncated to `fs` Byte before opening it via Mmap.

Appending is currently not possible and will throw an `EOFError`.
"""
function pdopen(file::AbstractString, ::MmapReadWrite, fs::Integer)
    rawfd = copen(file, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    cftruncate(rawfd, fs)
    mm = cmmap(C_NULL, fs, PROT_READ | PROT_WRITE, MAP_SHARED, rawfd, 0)
    cmadvise(mm, fs, MADV_SEQUENTIAL)
    cclose(rawfd)
    return PdMmapFile(mm, fs, 0)
end

function Base.position(io::PdMmapFile)
    return io.pos
end

function Base.seek(io::PdMmapFile, off)
    io.pos = off
end

function Base.skip(io::PdMmapFile, off)
    io.pos += off
end

Base.eof(io::PdMmapFile) = io.pos >= io.length

function Base.read(io::PdMmapFile, ::Type{UInt8})
    if eof(io)
        throw(EOFError())
    end
    GC.@preserve io begin
        val = unsafe_load(io.mm + io.pos)
    end
    io.pos += 1
    return val
end

function Base.write(io::PdMmapFile, u::UInt8)
    if eof(io)
        throw(EOFError())
    end
    GC.@preserve io begin
        unsafe_store!(io.mm + io.pos, u)
    end
    io.pos += 1
    return sizeof(UInt8)
end

function Base.unsafe_read(io::PdMmapFile, ptr::Ptr{UInt8}, n::UInt)
    left::UInt = io.length - io.pos
    if left < n
        cmemcpy(ptr, io.mm + io.pos, left)
        io.pos += left
        throw(EOFError())
    else
        cmemcpy(ptr, io.mm + io.pos, n)
        io.pos += n
        return n
    end
end

function Base.unsafe_write(io::PdMmapFile, ptr::Ptr{UInt8}, n::UInt)
    left::UInt = io.length - io.pos
    if left < n
        cmemcpy(io.mm + io.pos, ptr, left)
        io.pos += left
        throw(EOFError())
    else
        cmemcpy(io.mm + io.pos, ptr, n)
        io.pos += n
        return n
    end
end

function Base.flush(io::PdMmapFile) 
    cmsync(io.mm, io.length, MS_SYNC)
    return io
end

function Base.filesize(io::PdMmapFile)
    return io.length
end

Base.isopen(io::PdMmapFile) = io.mm != C_NULL

function Base.close(io::PdMmapFile)
    if isopen(io)
        flush(io)
        cmunmap(io.mm, io.length)
        io.mm = C_NULL
    end
    return
end

end # module