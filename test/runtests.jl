using Test, BufferedFiles, BufferedFiles.Libc

const curdir = pwd()
cd(@__DIR__)
if !isdir("testdir")
    mkdir("testdir")
end
cd("testdir")

@testset "Libc" begin
    @testset "cmemcpy" begin
        a = UInt8[0, 0, 0, 0]
        b = UInt8[1, 2, 3, 4]
        GC.@preserve a b cmemcpy(a, b, 4)
        @test a == b == UInt8[1, 2, 3, 4]
    end
    @testset "cmemmove" begin
        b = UInt8[0, 1, 2, 3, 4]
        GC.@preserve b cmemmove(pointer(b), pointer(b, 2), 4)
        @test b == [1, 2, 3, 4, 4]
    end
    @testset "copen, cftruncate, cclose" begin
        if isfile("copen")
            rm("copen")
        end
        @test_throws SystemError copen("copen", O_RDONLY) # File Does Not Exist
        @test_throws SystemError cclose(-1)
        @test_throws SystemError cftruncate(-1, 100)
        a = copen("copen", O_RDWR | O_CREAT, S_DEFAULT)
        @test a != -1
        cftruncate(a, 100)
        cclose(a)
    end
    @testset "cmmap & cmunmap & cmadvise & cmsync" begin
        @test_throws SystemError cmmap(C_NULL, 0, PROT_READ, MAP_SHARED, -1, 0) # Invalid File Descriptor
        @test_throws SystemError cmunmap(Ptr{Nothing}(1), 10) # Invalid Pointer
        @test_throws SystemError cmadvise(C_NULL, 10, 0) # Invalid Pointer
        @test_throws SystemError cmsync(C_NULL, 10, MS_SYNC) # Invalid Pointer
    end
end

@testset "RawFile" begin
    @testset "Writing" begin
        f = BufferedFiles.rawopen("testfile", om"w")
        @test f isa BufferedFiles.RawFile
        @test write(f, UInt8[1, 2, 3, 4, 5, 6, 7, 8]) == 8
        @test write(f, 1) == 8
        @test write(f, 0x01) == 1
        close(f)
    end
    @testset "Reading" begin
        f = BufferedFiles.rawopen("testfile", om"r")
        @test f isa BufferedFiles.RawFile
        @test read!(f, Vector{UInt8}(undef, 8)) == UInt8[1, 2, 3, 4, 5, 6, 7, 8]
        @test read(f, Int) == 1
        @test read(f, UInt8) == 1
    end
end

@testset "BufferedWriteFile" begin
    for i = 1:1024
        f = bufferedopen("testfile$i", om"w", i)
        @test f isa BufferedFiles.BufferedWriteFile
        @test position(f) == 0
        @test write(f, UInt8[1, 2, 3, 4, 5, 6, 7, 8]) == 8
        @test position(f) == 8
        @test write(f, 1) == 8
        @test position(f) == 16
        @test write(f, 0x01) == 1
        @test position(f) == 17
        close(f)
    end
end

@testset "BufferedReadFile" begin
    for i = 1:1024
        f = BufferedFiles.bufferedopen("testfile$i", om"r", i)
        @test f isa BufferedFiles.BufferedReadFile
        @test eof(f) == false
        @test position(f) == 0
        @test read(f, 8) == UInt8[1, 2, 3, 4, 5, 6, 7, 8]
        @test position(f) == 8
        @test eof(f) == false
        @test read(f, Int) == 1
        @test position(f) == 16
        @test eof(f) == false
        @test read(f, UInt8) == 1
        @test position(f) == 17
        @test eof(f) == true
        @test_throws EOFError read(f, UInt8)
        close(f)
    end
end

@testset "MmapFile" begin
    @testset "Write" begin
        f = bufferedopen("mmaptestfile", om"mr+", 16)
        @test f isa BufferedFiles.MmapFile
        @test filesize(f) == 16
        @test eof(f) == false
        @test position(f) == 0
        @test write(f, 1) == 8
        @test eof(f) == false
        @test position(f) == 8
        @test write(f, 2) == 8
        @test eof(f) == true
        @test position(f) == 16
        @test_throws EOFError write(f, 0x00)
        @test_throws EOFError write(f, 0x0000)
        close(f)
    end
    @testset "Read" begin
        f = bufferedopen("mmaptestfile", om"mr")
        @test f isa BufferedFiles.MmapFile
        @test filesize(f) == 16
        @test eof(f) == false
        @test position(f) == 0
        @test read(f, Int) == 1
        @test eof(f) == false
        @test position(f) == 8
        @test read(f, Int) == 2
        @test eof(f) == true
        @test position(f) == 16
        @test_throws EOFError read(f, UInt8)
        @test_throws EOFError read(f, UInt16)
        close(f)
    end
end

cd("../")
rm("testdir", recursive = true)
cd(curdir)
