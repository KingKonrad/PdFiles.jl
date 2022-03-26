"""
    BufferedFiles

Implementations of a better Filehandles.

Includes a Read-Only Filehandle,
a better Write-Only Filehandle
as well as Mmap-Filehandles (currently only on Unix) allowing both Reading and writing (but not appending (yet)).

Main Functions: [`bufferedopen`](@ref) and [`@om_str`](@ref)
"""
module BufferedFiles

export @om_str, bufferedopen

include("Libc.jl")
using .Libc

"""
    const DEFAULT_BUFSIZE = 16 * (1024) * (1024)

Default size of the read/write-buffer of [`BufferedReadFile`](@ref) and [`BufferedWriteFile`](@ref).
"""
const DEFAULT_BUFSIZE = 16 * (1024) * (1024)

"""
    abstract type BufferedOpenMode end

Types Implemented by [`@om_str`](@ref), used in [`bufferedopen`](@ref)
"""
abstract type BufferedOpenMode end

struct Read <: BufferedOpenMode end

openflags(::Read) = O_RDONLY
openmode(::Read) = nothing

struct WriteTrunc <: BufferedOpenMode end

openflags(::WriteTrunc) = O_WRONLY | O_TRUNC | O_CREAT
openmode(::WriteTrunc) = S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH

struct Append <: BufferedOpenMode end

openflags(::Append) = O_WRONLY | O_APPEND
openmode(::Append) = nothing

struct ReadWrite <: BufferedOpenMode end

openflags(::ReadWrite) = O_RDWR | O_APPEND
openmode(::ReadWrite) = nothing

struct ReadWriteTrunc <: BufferedOpenMode end

openflags(::ReadWriteTrunc) = O_RDWR | O_CREAT | O_TRUNC
openmode(::ReadWriteTrunc) = S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH

struct ReadAppend <: BufferedOpenMode end

openflags(::ReadAppend) = O_RDWR | O_APPEND
openmode(::ReadAppend) = nothing

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

Base.read(s::BufferedFile, ::Type{UInt8}) = read!(s, Ref{UInt8}())[]
Base.write(s::BufferedFile, v::UInt8) = write(s, Ref{UInt8}(v))

function Base.unsafe_read(s::BufferedFile, p::Ref{T}, n::Integer) where {T}
    GC.@preserve p unsafe_read(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n)
end # Overwrites two @noinline julia functions which cause allocations in a lot of situations
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
    struct RawFile <: BufferedFile 
        fd::Cint
    end

Raw Filehandle with no Buffer, that calls the C-Functions for Reading, Writing etc.

Used in [`BufferedReadFile`](@ref) and [`BufferedWriteFile`](@ref).
"""
struct RawFile <: BufferedFile
    fd::Cint
end

function rawopen(file::AbstractString, om::BufferedOpenMode)
    flags = openflags(om)
    mode = openmode(om)
    fdes = copen(file, flags, mode)
    return RawFile(fdes)
end

function Base.seek(s::RawFile, off)
    clseek(s.fd, off, SEEK_SET)
    return s
end

function Base.skip(s::RawFile, off)
    clseek(s.fd, off, SEEK_CUR)
    return s
end

function Base.position(s::RawFile)
    return clseek(s.fd, 0, SEEK_CUR)
end

Base.unsafe_write(s::RawFile, p::Ptr{UInt8}, n::UInt) = cwrite(s.fd, p, n)
Base.unsafe_read(s::RawFile, p::Ptr{UInt8}, n::UInt) = cread(s.fd, p, n)

Base.close(s::RawFile) = cclose(s.fd)

"""
    BufferedReadFile

Buffered Filehandle for more performant Reading.

Opened via [`bufferedopen(filename, om"r")`](@ref bufferedopen(::AbstractString, ::Read)).
"""
mutable struct BufferedReadFile <: BufferedFile
    rf::RawFile
    buf::Vector{UInt8}
    pos::Int
    lastread::Int
    isopen::Bool
    function BufferedReadFile(rf, buf, pos, lastread, isopen)
        f = new(rf, buf, pos, lastread, isopen)
        finalizer(close, f)
        refresh(f)
        return f
    end
end

Base.isopen(p::BufferedReadFile) = p.isopen
Base.isreadable(p::BufferedReadFile) = isopen(p)
Base.iswritable(::BufferedReadFile) = false

"""
    bufferedopen(file::AbstractString, openmode::AbstractString, args...)

Open a File.

Which type of Filehandle is returned depends on openmode.
"""
function bufferedopen(file::AbstractString, openmode::AbstractString, args...)
    return bufferedopen(file, BufferedOpenMode(openmode), args...)
end

"""
    bufferedopen(file::AbstractString, om"r"[, bufsize::Integer])

Open a File in Read-Only Mode.

Returns a [`BufferedReadFile`](@ref).
"""
function bufferedopen(file::AbstractString, ::Read, bufsize::Integer = DEFAULT_BUFSIZE)
    rf = rawopen(file, om"r")
    buf = Vector{UInt8}(undef, bufsize)
    f = BufferedReadFile(rf, buf, 0, 0, true)
    refresh(f)
    return f
end

function refresh(f::BufferedReadFile)
    GC.@preserve f begin
        cmemmove(pointer(f.buf), pointer(f.buf) + f.pos, bytesavailable(f))
        f.lastread = bytesavailable(f)
        f.pos = 0
        f.lastread +=
            unsafe_read(f.rf, pointer(f.buf) + f.lastread, length(f.buf) - f.lastread)
    end
    return f
end

function Base.position(f::BufferedReadFile)::Int
    return position(f.rf) - (f.lastread - f.pos)
end

function Base.eof(f::BufferedReadFile)::Bool
    return (f.lastread - f.pos) == 0
end

function Base.skip(f::BufferedReadFile, n::Integer)
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

function Base.seek(f::BufferedReadFile, n::Integer)
    u::Int = n
    seek(f.rf, u)
    f.lastread = 0
    f.pos = 0
    refresh(f)
    return f
end

function Base.close(f::BufferedReadFile)
    if isopen(f)
        flush(f)
        f.isopen = false
        close(f.rf)
    end
    return nothing
end

Base.bytesavailable(f::BufferedReadFile) = f.lastread - f.pos

function Base.unsafe_read(f::BufferedReadFile, p::Ptr{UInt8}, nb::UInt)::UInt
    todo::UInt = bytesavailable(f)
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
    BufferedReadFile

Buffered Filehandle for more performant Reading.

Opened via [`bufferedopen(filename, om"r")`](@ref bufferedopen(::AbstractString, ::Read)).
"""
mutable struct BufferedWriteFile <: BufferedFile
    rf::RawFile
    buf::Vector{UInt8}
    pos::Int
    isopen::Bool
    function BufferedWriteFile(rf, buf, pos, isopen)
        f = new(rf, buf, pos, isopen)
        finalizer(close, f)
        return f
    end
end

Base.isopen(p::BufferedWriteFile) = p.isopen
Base.isreadable(::BufferedWriteFile) = false
Base.iswritable(p::BufferedWriteFile) = isopen(p)

"""
    bufferedopen(file::AbstractString, om"w"[, bufsize::Integer])

Open a File in Write-Only Mode.

Truncates the File when opening it.

Returns a [`BufferedWriteFile`](@ref).
"""
function bufferedopen(file::AbstractString, ::WriteTrunc, bufsize::Integer = DEFAULT_BUFSIZE)
    rf = rawopen(file, om"w")
    buf = Vector{UInt8}(undef, bufsize)
    return BufferedWriteFile(rf, buf, 0, true)
end

function Base.flush(f::BufferedWriteFile)
    GC.@preserve f begin
        rt = unsafe_write(f.rf, pointer(f.buf), f.pos)
    end
    @assert rt == f.pos
    f.pos = 0
    return f
end

function Base.position(f::BufferedWriteFile)::Int
    return position(f.rf) + f.pos
end

function Base.skip(f::BufferedWriteFile, n::Integer)
    flush(f)
    skip(f.rf, n)
    return f
end

function Base.seek(f::BufferedWriteFile, n::Integer)
    flush(f)
    seek(f.rf, n)
    return f
end

function Base.close(f::BufferedWriteFile)
    if isopen(f)
        flush(f)
        f.isopen = false
        close(f.rf)
    end
    return nothing
end

function Base.unsafe_write(f::BufferedWriteFile, p::Ptr{UInt8}, nb::UInt)::UInt
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

mutable struct MmapFile <: BufferedFile
    mm::Ptr{UInt8}
    length::Csize_t
    pos::UInt
    function MmapFile(mm, length, pos)
        f = new(mm, length, pos)
        finalizer(close, f)
        return f
    end
end

"""
    bufferedopen(file::AbstractString, om"mr")

Open a file via Mmap in Read-Only Mode.
"""
function bufferedopen(file::AbstractString, ::MmapRead)
    fs = filesize(file)
    raw = rawopen(file, om"r")
    mm = cmmap(C_NULL, fs, PROT_READ, MAP_SHARED, raw.fd, 0)
    cmadvise(mm, fs, MADV_SEQUENTIAL)
    close(raw)
    return MmapFile(mm, fs, 0)
end

"""
    bufferedopen(file::AbstractString, om"mr+")

Open a file via Mmap in Read-Write Mode.

Appending is currently not possible and will throw an `EOFError`.
"""
function bufferedopen(file::AbstractString, ::MmapReadWrite)
    fs = filesize(file)
    raw = rawopen(file, om"r+")
    mm = cmmap(C_NULL, fs, PROT_READ | PROT_WRITE, MAP_SHARED, raw.fd, 0)
    cmadvise(mm, fs, MADV_SEQUENTIAL)
    close(raw)
    return MmapFile(mm, fs, 0)
end

"""
    bufferedopen(file::AbstractString, om"mr+", fs::Integer)

Open a file via Mmap in Read-Write Mode.

The file will be truncated to `fs` Byte before opening it via Mmap.

Appending is currently not possible and will throw an `EOFError`.
"""
function bufferedopen(file::AbstractString, ::MmapReadWrite, fs::Integer)
    rawfd = copen(file, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    cftruncate(rawfd, fs)
    mm = cmmap(C_NULL, fs, PROT_READ | PROT_WRITE, MAP_SHARED, rawfd, 0)
    cmadvise(mm, fs, MADV_SEQUENTIAL)
    cclose(rawfd)
    return MmapFile(mm, fs, 0)
end

function Base.position(io::MmapFile)
    return io.pos
end

function Base.seek(io::MmapFile, off)
    return io.pos = off
end

function Base.skip(io::MmapFile, off)
    return io.pos += off
end

Base.eof(io::MmapFile) = io.pos >= io.length

function Base.read(io::MmapFile, ::Type{UInt8})
    if eof(io)
        throw(EOFError())
    end
    GC.@preserve io begin
        val = unsafe_load(io.mm + io.pos)
    end
    io.pos += 1
    return val
end

function Base.write(io::MmapFile, u::UInt8)
    if eof(io)
        throw(EOFError())
    end
    GC.@preserve io begin
        unsafe_store!(io.mm + io.pos, u)
    end
    io.pos += 1
    return sizeof(UInt8)
end

function Base.unsafe_read(io::MmapFile, ptr::Ptr{UInt8}, n::UInt)
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

function Base.unsafe_write(io::MmapFile, ptr::Ptr{UInt8}, n::UInt)
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

function Base.flush(io::MmapFile)
    cmsync(io.mm, io.length, MS_SYNC)
    return io
end

function Base.filesize(io::MmapFile)
    return io.length
end

Base.isopen(io::MmapFile) = io.mm != C_NULL

function Base.close(io::MmapFile)
    if isopen(io)
        flush(io)
        cmunmap(io.mm, io.length)
        io.mm = C_NULL
    end
    return
end

end # module
