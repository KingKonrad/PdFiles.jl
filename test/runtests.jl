using Test, BufferedFiles, BufferedFiles.Libc

const curdir = pwd()
cd(@__DIR__)
if !isdir("testdir")
    mkdir("testdir")
end
cd("testdir")

@testset "BufferedWriteFile" begin
    for i = 1:1024
        f = open("testfile$i", om"w", i)
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
        f = BufferedFiles.open("testfile$i", om"r", i)
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

cd("../")
rm("testdir", recursive = true)
cd(curdir)
