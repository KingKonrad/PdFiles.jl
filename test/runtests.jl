using Test, BufferedFiles, BufferedFiles.Libc

const curdir = pwd()
cd(@__DIR__)
if !isdir("testdir")
    mkdir("testdir")
end
cd("testdir")

@testset "BufferedWriteFile" begin
    for i in 1:100
        f = open("testfile$i", om"w", rand(1:20))
        @test f isa BufferedFiles.BufferedWriteFile
        @test position(f) == 0
        @test write(f, UInt8[1, 2, 3, 4, 5, 6, 7, 8]) == 8
        @test position(f) == 8
        @test write(f, 1) == 8
        @test position(f) == 16
        @test write(f, 0x01) == 1
        @test position(f) == 17
        resize!(f, rand(1:100))
        @test write(f, UInt8[1, 2, 3, 4, 5, 6, 7, 8]) == 8
        @test position(f) == 25
        @test write(f, 1) == 8
        @test position(f) == 33
        @test write(f, 0x01) == 1
        @test position(f) == 34
        close(f)
        @test read("testfile$i") ==
              UInt8[1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7,
                    8, 1, 0, 0, 0, 0, 0, 0, 0, 1]
    end
    v = read("testfile1")
end

@testset "BufferedReadFile" begin
    for i in 1:100
        f = BufferedFiles.open("testfile$i", om"r", rand(1:20))
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
        resize!(f, rand(1:100))
        @test position(f) == 17
        @test read(f, 8) == UInt8[1, 2, 3, 4, 5, 6, 7, 8]
        @test position(f) == 25
        @test read(f, Int) == 1
        @test position(f) == 33
        @test read(f, UInt8) == 0x01
        @test position(f) == 34
        @test eof(f) == true
        @test_throws EOFError read(f, UInt8)
        @test_throws EOFError read(f, UInt16)
        close(f)
    end
end

cd("../")
rm("testdir"; recursive=true)
cd(curdir)
