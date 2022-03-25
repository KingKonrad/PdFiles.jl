using Test, PdFiles

const curdir = pwd()
cd(@__DIR__)
if !isdir("testdir")
    mkdir("testdir")
end

@testset "PdRawFile" begin
    @testset "Writing" begin
        f = PdFiles.pdrawopen("testdir/testfile", om"w")
        @test f isa PdFiles.PdRawFile
        @test write(f, UInt8[1,2,3,4,5,6,7,8]) == 8
        @test write(f, 1) == 8
        @test write(f, 0x01) == 1
        close(f)
    end
    @testset "Reading" begin
        f = PdFiles.pdrawopen("testdir/testfile", om"r")
        @test f isa PdFiles.PdRawFile
        @test read!(f, Vector{UInt8}(undef, 8)) == UInt8[1,2,3,4,5,6,7,8]
        @test read(f, Int) == 1
        @test read(f, UInt8) == 1
    end
end

@testset "PdWriteFile" begin
    for i in 1:1024
        f = pdopen("testdir/testfile$i", om"w", i)
        @test f isa PdFiles.PdWriteFile
        @test position(f) == 0
        @test write(f, UInt8[1,2,3,4,5,6,7,8]) == 8
        @test position(f) == 8
        @test write(f, 1) == 8
        @test position(f) == 16
        @test write(f, 0x01) == 1
        @test position(f) == 17
        close(f)
    end
end

@testset "PdReadFile" begin
    for i in 1:1024
        f = PdFiles.pdopen("testdir/testfile$i", om"r", i)
        @test f isa PdFiles.PdReadFile
        @test eof(f) == false
        @test position(f) == 0
        @test read(f, 8) == UInt8[1,2,3,4,5,6,7,8]
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

@testset "PdMmapFile" begin
    @testset "Write" begin
        f = pdopen("testdir/mmaptestfile", om"mr+", 16)
        @test f isa PdFiles.PdMmapFile
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
        f = pdopen("testdir/mmaptestfile", om"mr")
        @test f isa PdFiles.PdMmapFile
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

rm("testdir", recursive=true)
cd(curdir)