import benchmark
from memory import memset_zero, stack_allocation
from random import rand
from algorithm import vectorize, parallelize, vectorize_unroll
from algorithm import Static2DTileUnitFunc as Tile2DFunc
from tensor import Tensor
from utils.index import Index
from memory.buffer import NDBuffer

alias M = 512
alias N = 512
alias K = 4096
alias type = DType.float32


struct Matrix:
    var data: DTypePointer[type]
    var rows: Int
    var cols: Int

    # Initialize zeroeing all values
    fn __init__(inout self, rows: Int, cols: Int):
        self.data = DTypePointer[type].alloc(rows * cols)
        memset_zero(self.data, rows * cols)
        self.rows = rows
        self.cols = cols

    # Initialize taking a pointer, don't set any elements
    fn __init__(inout self, rows: Int, cols: Int, data: DTypePointer[DType.float32]):
        self.data = data
        self.rows = rows
        self.cols = cols

    ## Initialize with random values
    @staticmethod
    fn rand(rows: Int, cols: Int) -> Self:
        let data = DTypePointer[type].alloc(rows * cols)
        rand(data, rows * cols)
        return Self(rows, cols, data)

    fn __getitem__(self, y: Int, x: Int) -> Float32:
        return self.load[1](y, x)

    fn __setitem__(self, y: Int, x: Int, val: Float32):
        return self.store[1](y, x, val)

    fn load[nelts: Int](self, y: Int, x: Int) -> SIMD[DType.float32, nelts]:
        return self.data.simd_load[nelts](y * self.cols + x)

    fn store[nelts: Int](self, y: Int, x: Int, val: SIMD[DType.float32, nelts]):
        return self.data.simd_store[nelts](y * self.cols + x, val)


fn naive(inout C: Matrix, A: Matrix, B: Matrix):
    for m in range(C.rows):
        for k in range(A.cols):
            for n in range(C.cols):
                C[m, n] += A[m, k] * B[k, n]


# Mojo has SIMD vector types, we can vectorize the Matmul code as follows.
alias nelts = simdwidthof[type]()  # The SIMD vector width.


# Using stdlib vectorize function
fn vectorized(inout C: Matrix, A: Matrix, B: Matrix):
    for m in range(C.rows):
        for k in range(A.cols):

            @parameter
            fn dot[nelts: Int](n: Int):
                C.store[nelts](
                    m, n, C.load[nelts](m, n) + A[m, k] * B.load[nelts](k, n)
                )

            vectorize[nelts, dot](C.cols)


# Parallelize the code by using the builtin parallelize function
fn parallelized(inout C: Matrix, A: Matrix, B: Matrix):
    @parameter
    fn calc_row(m: Int):
        for k in range(A.cols):

            @parameter
            fn dot[nelts: Int](n: Int):
                C.store[nelts](
                    m, n, C.load[nelts](m, n) + A[m, k] * B.load[nelts](k, n)
                )

            vectorize[nelts, dot](C.cols)

    parallelize[calc_row](C.rows, C.rows)


# Perform 2D tiling on the iteration space defined by end_x and end_y.
fn tile[tiled_fn: Tile2DFunc, tile_x: Int, tile_y: Int](end_x: Int, end_y: Int):
    # Note: this assumes that ends are multiples of the tiles.
    for y in range(0, end_y, tile_y):
        for x in range(0, end_x, tile_x):
            tiled_fn[tile_x, tile_y](x, y)


# Use the above tile function to perform tiled matmul.
fn tiled(inout C: Matrix, A: Matrix, B: Matrix):
    @parameter
    fn calc_row(m: Int):
        @parameter
        fn calc_tile[tile_x: Int, tile_y: Int](x: Int, y: Int):
            for k in range(y, y + tile_y):

                @parameter
                fn dot[
                    nelts: Int,
                ](n: Int):
                    C.store[nelts](
                        m,
                        n + x,
                        C.load[nelts](m, n + x) + A[m, k] * B.load[nelts](k, n + x),
                    )

                vectorize[nelts, dot](tile_x)

        # We hardcode the tile factor to be 4.
        alias tile_size = 4
        tile[calc_tile, nelts * tile_size, tile_size](C.cols, B.rows)

    parallelize[calc_row](C.rows, C.rows)


# Unroll the vectorized loop by a constant factor.
# from Functional import vectorize_unroll
fn unrolled(inout C: Matrix, A: Matrix, B: Matrix):
    alias tile_size = 4

    @parameter
    fn calc_row(m: Int):
        @parameter
        fn calc_tile[tile_x: Int, tile_y: Int](x: Int, y: Int):
            for k in range(y, y + tile_y):

                @parameter
                fn dot[
                    nelts: Int,
                ](n: Int):
                    C.store[nelts](
                        m,
                        n + x,
                        C.load[nelts](m, n + x) + A[m, k] * B.load[nelts](k, n + x),
                    )

                # Vectorize by nelts and unroll by tile_x/nelts
                # Here unroll factor is 4
                vectorize_unroll[nelts, tile_x // nelts, dot](tile_x)

        tile[calc_tile, nelts * tile_size, tile_size](C.cols, B.rows)

    parallelize[calc_row](C.rows, C.rows)


# Perform 2D tiling on the iteration space defined by end_x and end_y, parallelizing over y.
fn tile_parallel[
    tiled_fn: Tile2DFunc, tile_x: Int, tile_y: Int
](end_x: Int, end_y: Int):
    # Note: this assumes that ends are multiples of the tiles.
    @parameter
    fn row(yo: Int):
        let y = tile_y * yo
        for x in range(0, end_x, tile_x):
            tiled_fn[tile_x, tile_y](x, y)

    parallelize[row](end_y // tile_y, M)


# Use stack allocation for tiles to accumulate values efficiently,
# avoiding repeated reads and writes to memory. Also reorder the loops
# and do not fully unroll the loop over the reduction dimension.
fn reordered(inout C: Matrix, A: Matrix, B: Matrix):
    alias tile_k = 8
    alias tile_k_unroll = 8
    alias tile_i = 32
    alias tile_j = nelts * 4

    @parameter
    fn calc_tile[tile_j: Int, tile_i: Int](jo: Int, io: Int):
        # Allocate the tile of accumulators on the stack.
        var accumulators = Matrix(
            tile_i, tile_j, stack_allocation[tile_i * tile_j, DType.float32]()
        )

        for ko in range(0, A.cols, tile_k * tile_k_unroll):
            for _ in range(tile_i):
                for i in range(tile_k):

                    @unroll
                    for k in range(tile_k_unroll):

                        @parameter
                        fn calc_tile_cols[nelts: Int](j: Int):
                            accumulators.store[nelts](
                                i,
                                j,
                                accumulators.load[nelts](i, j)
                                + A[io + i, ko + k] * B.load[nelts](ko + k, jo + j),
                            )

                        vectorize_unroll[nelts, tile_j // nelts, calc_tile_cols](tile_j)

        # Copy the local tile to the output
        for i in range(tile_i):
            for j in range(tile_j):
                C[io + i, jo + j] = accumulators[i, j]

    tile_parallel[calc_tile, tile_j, tile_i](C.cols, C.rows)


# Perform 2D tiling on the iteration space defined by end_x and end_y, parallelizing
# over x and y, and iterating in an order that has better L3 cache locality
fn tile_parallel_swizzled[
    tiled_fn: Tile2DFunc, tile_x: Int, tile_y: Int
](end_x: Int, end_y: Int):
    # Note: this assumes that ends are multiples of the tiles.
    alias tile_outer = 8
    alias group_size = tile_outer * 4

    # L3 cache swizzling
    @parameter
    fn row(swizzled: Int):
        let group_id = swizzled // group_size
        let group_offset_x = (group_id * tile_outer) % (N // tile_y)
        let yo = (swizzled % group_size) // tile_outer
        let xo = group_offset_x + (swizzled % tile_outer)
        let y = tile_y * yo
        let x = tile_x * xo
        tiled_fn[tile_x, tile_y](x, y)

    parallelize[row]((end_y // tile_y * end_x // tile_x), M * 2)


# Same as previous example but utilisizing tile swizzling for better L3 cache locality.
fn swizzled(inout C: Matrix, A: Matrix, B: Matrix):
    alias tile_k = 8
    alias tile_k_unroll = 8
    alias tile_i = 32
    alias tile_j = nelts * 4

    @parameter
    fn calc_tile[tile_j: Int, tile_i: Int](jo: Int, io: Int):
        # Allocate the tile of accumulators on the stack.
        var accumulators = Matrix(
            tile_i, tile_j, stack_allocation[tile_i * tile_j, DType.float32]()
        )

        for ko in range(0, A.cols, tile_k * tile_k_unroll):
            for _ in range(tile_i):
                for i in range(tile_k):

                    @unroll
                    for k in range(tile_k_unroll):

                        @parameter
                        fn calc_tile_cols[nelts: Int](j: Int):
                            accumulators.store[nelts](
                                i,
                                j,
                                accumulators.load[nelts](i, j)
                                + A[io + i, ko + k] * B.load[nelts](ko + k, jo + j),
                            )

                        vectorize_unroll[nelts, tile_j // nelts, calc_tile_cols](tile_j)

        # Copy the local tile to the output
        for i in range(tile_i):
            for j in range(tile_j):
                C[io + i, jo + j] = accumulators[i, j]

    tile_parallel_swizzled[calc_tile, tile_j, tile_i](C.cols, C.rows)


@always_inline
fn bench[
    func: fn (inout Matrix, Matrix, Matrix) -> None, name: StringLiteral
](base_gflops: Float64) raises -> Float64:
    var A = Matrix.rand(M, K)
    var B = Matrix.rand(K, N)
    var C = Matrix(M, N)

    @always_inline
    @parameter
    fn test_fn():
        _ = func(C, A, B)

    let secs = benchmark.run[test_fn]().mean()
    # Prevent the matrices from being freed before the benchmark run
    A.data.free()
    B.data.free()
    C.data.free()
    let gflops = ((2 * M * N * K) / secs) / 1e9
    let speedup: Float64 = gflops / base_gflops
    print(name, " ", gflops, " GFLOPS, ", speedup, "x speedup\n")
    return gflops


@always_inline
fn test[
    func: fn (inout Matrix, Matrix, Matrix) -> None
](A: Matrix, B: Matrix) raises -> SIMD[type, 1]:
    var C = Matrix(M, N)
    _ = func(C, A, B)
    var result = SIMD[type, 1]()
    for i in range(C.rows):
        for j in range(C.cols):
            result += C[i, j]
    return result


fn test_all() raises:
    constrained[M == N, "M and N must be equal for matrix multiplication"]()

    let A = Matrix.rand(M, K)
    let B = Matrix.rand(K, N)

    let result = test[naive](A, B)

    if test[vectorized](A, B) != result:
        raise Error("Vectorize output does not match")
    if test[parallelized](A, B) != result:
        raise Error("Parallelize output incorrect")
    if test[tiled](A, B) != result:
        raise Error("Tiled output incorrect")
    if test[unrolled](A, B) != result:
        raise Error("Unroll output incorrect")
    if test[reordered](A, B) != result:
        raise Error("Loop reorder output incorrect")
    if test[swizzled](A, B) != result:
        raise Error("Swizzled output incorrect")

    A.data.free()
    B.data.free()


fn main() raises:
    # Uncomment below to test correctness of Matmuls
    # test_all()
    print("CPU Results\n")

    let base_gflops = bench[naive, "Naive:"](1)
    _ = bench[vectorized, "Vectorized:"](base_gflops)
    _ = bench[parallelized, "Parallelized:"](base_gflops)
    _ = bench[tiled, "Tiled:"](base_gflops)
    _ = bench[unrolled, "Unrolled:"](base_gflops)
    _ = bench[reordered, "Reordered:"](base_gflops)
    _ = bench[swizzled, "Swizzled:"](base_gflops)
