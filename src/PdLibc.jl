"""
    PdLibc

Interface for all the C-Calls and Constants used.

If a C-Function returns an error-code, `Base.systemerror` is used to confirm the return code, so the User does not need to do any error-checking themselfs.
"""
module PdLibc

export Coff_t, O_CREAT, O_TRUNC, O_APPEND, O_RDONLY, O_WRONLY, O_RDWR, SEEK_SET, SEEK_CUR, SEEK_END, cmemcpy, cmemmove, copen, clseek, cread, cwrite, cclose, cmadvise, cmmap, cmunmap, cftruncate, cmsync
export S_IRWXU, S_IRUSR, S_IWUSR, S_IXUSR, S_IRWXG, S_IRGRP, S_IWGRP, S_IXGRP, S_IRWXO, S_IROTH, S_IWOTH, S_IXOTH, S_PDDEF, PROT_NONE, PROT_READ, PROT_WRITE, PROT_EXEC, MADV_SEQUENTIAL, MAP_SHARED, MS_SYNC

# C-Types

const Coff_t = Clong
const Cmode_t = Cuint

# Constants for copen

const O_CREAT = Cint(64)
const O_TRUNC = Cint(512)
const O_APPEND = Cint(1024)
const O_RDONLY = Cint(0)
const O_WRONLY = Cint(1)
const O_RDWR = Cint(2)

# Constants for the copen-Permissions

const S_IRWXU = Cmode_t(0b111000000)
const S_IRUSR = Cmode_t(0b100000000)
const S_IWUSR = Cmode_t(0b010000000)
const S_IXUSR = Cmode_t(0b001000000)
const S_IRWXG = Cmode_t(0b000111000)
const S_IRGRP = Cmode_t(0b000100000)
const S_IWGRP = Cmode_t(0b000010000)
const S_IXGRP = Cmode_t(0b000001000)
const S_IRWXO = Cmode_t(0b000000111)
const S_IROTH = Cmode_t(0b000000100)
const S_IWOTH = Cmode_t(0b000000010)
const S_IXOTH = Cmode_t(0b000000001)

# My Default

const S_PDDEF = Cmode_t(0b110100100)

# Constants for clseek

const SEEK_SET = Cint(0)
const SEEK_CUR = Cint(1)
const SEEK_END = Cint(2)

function cmemcpy(dest, src, nbytes)
    @ccall memcpy(dest::Ptr{Cvoid}, src::Ptr{Cvoid}, nbytes::Csize_t)::Ptr{Cvoid}
    return nothing
end

function cmemmove(dest, src, nbytes)
    @ccall memmove(dest::Ptr{Cvoid}, src::Ptr{Cvoid}, nbytes::Csize_t)::Ptr{Cvoid}
    return nothing
end

function copen(pathname, flags, mode)
    fd = @ccall open(pathname::Cstring, flags::Cint, mode::Cmode_t)::Cint
    Base.systemerror(:open, fd == -1)
    return fd
end

function copen(pathname, flags, mode::Nothing=nothing)
    fd = @ccall open(pathname::Cstring, flags::Cint)::Cint
    Base.systemerror(:open, fd == -1)
    return fd
end

function clseek(fd, offset, whence)
    return @ccall lseek(fd::Cint, offset::Coff_t, whence::Cint)::Coff_t
end

function cread(fd, buf, count)
    return @ccall read(fd::Cint, buf::Ptr{Cvoid}, count::Csize_t)::Cssize_t
end

function cwrite(fd, buf, count)
    return @ccall write(fd::Cint, buf::Ptr{Cvoid}, count::Csize_t)::Cssize_t
end

function cftruncate(fd, length)
    rt = @ccall ftruncate(fd::Cint, length::Coff_t)::Cint
    Base.systemerror(:ftruncate, rt == -1)
    return nothing
end

function cclose(fd)
    rt = @ccall close(fd::Cint)::Cint
    Base.systemerror(:close, rt == -1)
    return nothing
end

# Constants for cmmap protect

const PROT_NONE = Cint(0)
const PROT_READ = Cint(1)
const PROT_WRITE = Cint(2)
const PROT_EXEC = Cint(4)

# Constants for cmmap 

const MAP_SHARED = Cint(1)

# Constants for cmadvise

const MADV_SEQUENTIAL = Cint(2)
 
# Constants for cmsync

const MS_SYNC = Cint(4)

# 0xFFFFFFFFFFFFFFFF is returned by Mmap upon failure

const MAP_FAILED = Ptr{Nothing}(-1)

function cmmap(addr, length, prot, flags, fd, offset)
    ptr = @ccall mmap(addr::Ptr{Cvoid}, length::Csize_t, prot::Cint, flags::Cint, fd::Cint, offset::Coff_t)::Ptr{Cvoid}
    Base.systemerror(:mmap, ptr == MAP_FAILED)
    return ptr
end

function cmunmap(addr, length)
    rt = @ccall munmap(addr::Ptr{Cvoid}, length::Csize_t)::Cint
    Base.systemerror(:munmap, rt == -1)
    return nothing
end

function cmadvise(addr, length, advice)
    rt = @ccall madvise(addr::Ptr{Cvoid}, length::Csize_t, advice::Cint)::Cint
    Base.systemerror(:madvise, rt == -1)
    return nothing
end

function cmsync(addr, length, flags)
    rt = @ccall msync(addr::Ptr{Cvoid}, length::Csize_t, flags::Cint)::Cint
    Base.systemerror(:msync, rt == -1)
    return nothing
end

end # module