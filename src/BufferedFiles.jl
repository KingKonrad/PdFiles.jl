"""
    BufferedFiles
"""
module BufferedFiles

using Base.Filesystem

abstract type OpenMode end

export @om_str

struct ReadOnly <: OpenMode end
struct WriteTruncOnly <: OpenMode end
struct WriteOnly <: OpenMode end

function string2openmode(s::AbstractString)
    if s == "r"
        return ReadOnly()
    elseif s == "w"
        return WriteTruncOnly()
    else
        throw(ArgumentError("no matching openmode found"))
    end
end

macro om_str(s::String)
    return string2openmode(s)
end

mutable struct BufferedReadFile <: IO
    file::File
    filepos::UInt
    bufpos::UInt
    bufread::UInt
    total_filesize::UInt
    buf::Vector{UInt8}
    function BufferedReadFile(args...)
        f = new(args...)
        finalizer(close, f)
        return f
    end
end

function memcpy(dest, src, nbytes)
    @ccall memcpy(dest::Ptr{Cvoid}, src::Ptr{Cvoid}, nbytes::Csize_t)::Ptr{Cvoid}
    return
end

function memmove(dest, src, nbytes)
    @ccall memmove(dest::Ptr{Cvoid}, src::Ptr{Cvoid}, nbytes::Csize_t)::Ptr{Cvoid}
    return
end

Base.eof(r::BufferedReadFile) = r.total_filesize == r.filepos && r.bufpos == r.bufread

const DEFAULT_BUFSIZE = 1024 * 1024 # 1MB

function Base.open(fname::AbstractString, ::ReadOnly, bufsize::Integer=DEFAULT_BUFSIZE)
    buf = Vector{UInt8}(undef, bufsize)
    file = Filesystem.open(fname, JL_O_RDONLY)
    fs = filesize(file)
    return BufferedReadFile(file, 0, 0, 0, fs, buf)
end

function Base.bytesavailable(r::BufferedReadFile)
    return r.bufread - r.bufpos
end

function move_old(r::BufferedReadFile)
    "Move existing, not yet read Bytes to the beginning of the buffer"
    ncopy = bytesavailable(r)
    buf = r.buf
    GC.@preserve buf memmove(pointer(buf), pointer(buf) + r.bufpos, ncopy)
    r.bufpos = 0
    r.bufread = ncopy
    return
end

"Read in new Bytes"
function read_new(r::BufferedReadFile)
    buf = r.buf
    to_read = min((length(buf) % UInt - r.bufread), r.total_filesize - r.filepos)::UInt
    GC.@preserve buf unsafe_read(r.file, pointer(buf) + r.bufread, to_read)
    r.filepos += to_read
    r.bufread += to_read
    return
end

function refresh(r::BufferedReadFile)
    move_old(r)
    read_new(r)
    return r
end

function Base.seek(r::BufferedReadFile, off::Integer)
    uOff::UInt = off
    offstart = r.filepos - r.bufread
    offend = r.filepos
    if offstart <= uOff <= offend # is within read buffer
        r.bufpos = r.filepos - uOff
    else
        seek(r.file, uOff)
        r.bufpos = 0
        r.bufread = 0
        r.filepos = uOff
    end
    return r
end

function Base.position(r::BufferedReadFile)
    return r.filepos - (r.bufread - r.bufpos)
end

function Base.skip(r::BufferedReadFile, rel::Integer)
    return seek(r, (position(rel) % (rel isa Signed ? Int : UInt)) + rel)
end

function Base.read(r::BufferedReadFile, ::Type{UInt8})
    isopen(r.file) || error("file is closed")
    if r.bufpos < r.bufread
        r.bufpos += UInt(1)
        return r.buf[r.bufpos]
    else
        "Have to attempt to read more from file"
        refresh(r)
        if r.bufpos < r.bufread
            r.bufpos += UInt(1)
            return r.buf[r.bufpos]
        else
            throw(EOFError())
        end
    end

    error("how did control flow get here?")
end

function Base.resize!(r::BufferedReadFile, ns::Integer)
    uOff = position(r)
    resize!(r.buf, ns)
    r.bufpos = 0
    r.bufread = 0
    seek(r.file, uOff)
    r.filepos = uOff
    return r
end

function Base.unsafe_read(r::BufferedReadFile, p::Ptr{UInt8}, n::UInt)
    isopen(r.file) || error("file is closed")
    if n > 0 && eof(r)
        throw(EOFError())
    end
    buf = r.buf
    ba = bytesavailable(r)
    if ba >= n # usually can just copy from memory
        GC.@preserve buf memcpy(p, pointer(buf) + r.bufpos, n)
        r.bufpos += n
    else
        GC.@preserve buf memcpy(p, pointer(buf) + r.bufpos, ba)
        r.bufpos += ba

        "if the amount of data to be read is larger than the rest of the buffer, just read straight from file"
        if n - ba > (length(buf) % UInt)
            r.bufpos = 0
            r.bufread = 0
            r.filepos += n - ba
            unsafe_read(r.file, p + ba, n - ba)
        else
            refresh(r)
            unsafe_read(r, p + ba, n - ba)
        end
    end
    return
end

function Base.close(r::BufferedReadFile)
    resize!(r.buf, 0)
    sizehint!(r.buf, 0)
    r.bufpos = 0
    r.bufread = 0
    r.total_filesize = 0
    if isopen(r.file)
        close(r.file)
    end
    return r
end

# Overwrites two @noinline julia functions which cause allocations in a lot of situations
function Base.unsafe_read(s::BufferedReadFile, p::Ref{T}, n::Integer) where {T}
    GC.@preserve p unsafe_read(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n)
end
function Base.unsafe_read(s::BufferedReadFile, p::Ptr, n::Integer)
    return unsafe_read(s, convert(Ptr{UInt8}, p)::Ptr{UInt8}, convert(UInt, n)::UInt)
end

mutable struct BufferedWriteFile <: IO
    file::File
    filepos::Int
    bufpos::Int
    buf::Vector{UInt8}
    function BufferedWriteFile(args...)
        f = new(args...)
        finalizer(close, f)
        return f
    end
end

function Base.unsafe_write(s::BufferedWriteFile, p::Ref{T}, n::Integer) where {T}
    GC.@preserve p unsafe_write(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n)
end
function Base.unsafe_write(s::BufferedWriteFile, p::Ptr, n::Integer)
    return unsafe_write(s, convert(Ptr{UInt8}, p), convert(UInt, n))
end

function Base.open(file::AbstractString,
                   ::WriteTruncOnly,
                   bufsize::Integer=DEFAULT_BUFSIZE)
    buf = Vector{UInt8}(undef, bufsize)
    file = Filesystem.open(file, JL_O_CREAT | JL_O_TRUNC | JL_O_WRONLY,
                           S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    return BufferedWriteFile(file, 0, 0, buf)
end

function Base.open(file::AbstractString,
                   ::WriteOnly,
                   bufsize::Integer=DEFAULT_BUFSIZE)
    buf = Vector{UInt8}(undef, bufsize)
    file = Filesystem.open(file, JL_O_WRONLY)
    return BufferedWriteFile(file, 0, 0, buf)
end

function Base.flush(f::BufferedWriteFile)
    GC.@preserve f begin
        unsafe_write(f.file, pointer(f.buf), f.bufpos)
    end
    f.filepos += f.bufpos
    f.bufpos = 0
    return f
end

function Base.position(f::BufferedWriteFile)::Int
    return f.filepos + f.bufpos
end

function Base.seek(f::BufferedWriteFile, n::Integer)
    if f.filepos <= n <= position(f) # position within buffer
        f.bufpos = n - f.filepos
    else
        flush(f)
        seek(f.file, n)
        f.filepos = n
    end
    return f
end

function Base.skip(f::BufferedWriteFile, n::Integer)
    seek(f, (position(f) % Int) + n)
end

function Base.write(s::BufferedWriteFile, u::UInt8)
    isopen(s.file) || error("file is closed")
    freespace::UInt = (length(s.buf) - s.bufpos)
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

function Base.unsafe_write(f::BufferedWriteFile, p::Ptr{UInt8}, nb::UInt)::UInt
    isopen(f.file) || error("file is closed")
    freespace::UInt = (length(f.buf) - f.bufpos)
    @assert freespace > 0
    if freespace > nb
        GC.@preserve f begin
            memcpy(pointer(f.buf) + f.bufpos, p, nb)
        end
        f.bufpos += nb
        return nb
    elseif freespace <= nb
        GC.@preserve f begin
            memcpy(pointer(f.buf) + f.bufpos, p, freespace)
        end
        f.bufpos += freespace
        flush(f)
        return freespace + unsafe_write(f, p + freespace, nb - freespace)
    else
        error("This should never happen!")
    end
end

function Base.resize!(f::BufferedWriteFile, ns::Integer)
    flush(f)
    resize!(f.buf, ns)
end

function Base.close(f::BufferedWriteFile)
    if isopen(f.file)
        flush(f)
        close(f.file)
    end
end

#=
function Base.unsafe_write(s::BufferedFile, p::Ptr, n::Integer)
    return unsafe_write(s, convert(Ptr{UInt8}, p), convert(UInt, n))
end
function Base.unsafe_write(s::BufferedFile, p::Ref{T}, n::Integer) where {T}
    GC.@preserve p unsafe_write(s, Base.unsafe_convert(Ref{T}, p)::Ptr, n)
end
=#

end # module