# BufferedFiles.jl

Implementation of Buffered Filehandles for higher IO Performance.

## Installation:

```julia
import Pkg
Pkg.add("BufferedFiles")
```
or:
```julia
# Change to Pkg-Mode with ]
(@v1.7) pkg> add BufferedFiles
```

## Usage:

```julia
using BufferedFiles

io = bufferedopen("/path/to/file", om"r") # Read
# ... or:
io = bufferedopen("/path/to/file", om"w") # Write
```

[Documentation](https://pauldepping.github.io/BufferedFiles/)
