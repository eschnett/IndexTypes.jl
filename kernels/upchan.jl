# CHORD upchannelization kernel
# <CHORD_GPU_upchannelization.pdf>

using CUDA
using CUDASIMDTypes
using IndexSpaces

bitsign(b::Bool) = b ? -1 : +1
bitsign(i::Integer) = bitsign(isodd(i))

Base.clamp(x::Complex, a, b) = Complex(clamp(x.re, a, b), clamp(x.im, a, b))
Base.clamp(x::Complex, ab::UnitRange) = clamp(x, ab.start, ab.stop)
Base.round(::Type{T}, x::Complex) where {T} = Complex(round(T, x.re), round(T, x.im))

linterp(x1, y1, x2, y2, x) = (x - x2) * y1 / (x1 - x2) + (x - x1) * y2 / (x2 - x1)
@assert(linterp(1.0f0, 2.0f0, 3.0f0, 4.0f0, 1.0f0) == 2.0f0)
@assert(linterp(1.0f0, 2.0f0, 3.0f0, 4.0f0, 3.0f0) == 4.0f0)
@assert(linterp(1.0f0, 2.0f0, 3.0f0, 4.0f0, 2.0f0) == 3.0f0)

function interp(table, x)
    @assert !isempty(table)
    @assert x ≥ table[begin].first
    @assert x ≤ table[end].first
    for n in 1:(length(table) - 1)
        if x ≤ table[n + 1].first
            return linterp(table[n].first, table[n].second, table[n + 1].first, table[n + 1].second, x)
        end
    end
    @assert false
end
let
    table = [1.0f0 => +1.0f0, 2.0f0 => -1.0f0, 3.0f0 => +3.0f0]
    @assert(interp(table, 1.0f0) == +1.0f0)
    @assert(interp(table, 1.5f0) == +0.0f0)
    @assert(interp(table, 2.0f0) == -1.0f0)
    @assert(interp(table, 2.5f0) == +1.0f0)
    @assert(interp(table, 3.0f0) == +3.0f0)
end

# Un-normalized `sinc` function, without `π`
sinc′(x) = x == 0 ? one(x) : sin(x) / x

# CHORD Setup

# Compile-time constants

const sampling_time_μsec = 4096 / (2 * 1200)
const C = 2
const T = 256 #TODO 32768
const D = 512
const P = 2
const F₀ = 16
# const F = 16
const F = 2
# const F = 84 ÷ (D ÷ 128)
const U = 16
const M = 4
const K = 4

# Derived constants

const W = 16
const B = 2

const Touter = 256
const Packed = true

# Machine setup

const num_simd_bits = 32
const num_threads = 32
const num_warps = W
const num_blocks = (D ÷ 128) * P * F
const num_blocks_per_sm = B

# Benchmark results:

# Setup for full CHORD on A40:
#
# benchmark-result:
#   kernel: "upchan"
#   description: "Upchannelizer"
#   design-parameters:
#     number-of-complex-components: 2
#     number-of-dishes: 512
#     number-of-frequencies: 21
#     number-of-polarizations: 2
#     number-of-taps: 4
#     number-of-timesamples: 32768
#     sampling-time-μsec: 1.7066666666666668
#     upchannelization-factor: 16
#   compile-parameters:
#     minthreads: 512
#     blocks_per_sm: 2
#   call-parameters:
#     threads: [32, 16]
#     blocks: [168]
#     shmem_bytes: 69888
#   result-μsec:
#     runtime: 2742.1
#     scaled-runtime: 2089.2
#     scaled-number-of-frequencies: 16
#     dataframe-length: 55924.1
#     dataframe-percent: 3.7

# CHORD indices

@enum CHORDTag begin
    CplxTag
    TimeTag
    DishTag
    PolrTag
    FreqTag
    MTapsTag
    ReplTag
    ThreadTag
    WarpTag
    BlockTag
end

const Cplx = Index{Physics,CplxTag}
const Time = Index{Physics,TimeTag}
const Dish = Index{Physics,DishTag}
const Polr = Index{Physics,PolrTag}
const Freq = Index{Physics,FreqTag}
const MTaps = Index{Physics,MTapsTag}
const Repl = Index{Physics,ReplTag}

# Layouts

# Global memory layouts

const layout_W_memory = Layout([
    FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    # TODO: Choose a convenient layout and shuffle when loading
    # TODO: Calculate on the GPU
    #TODO Time(:time, 1, 2) => SIMD(:simd, 16, 2),
    #TODO Time(:time, 2, (U ÷ 2) * M) => Memory(:memory, 1, (U ÷ 2) * M),
    Time(:time, 1 << 3, 2) => SIMD(:simd, 16, 2),
    Time(:time, 1, 8) => Memory(:memory, 1, 8),
    # Time(:time, 16, U * M ÷ 16) => Memory(:memory, 8, U * M ÷ 16),
    Time(:time, 16, U ÷ 16) => Memory(:memory, 8, U ÷ 16),
    MTaps(:mtaps, 1, M) => Memory(:memory, 8 * (U ÷ 16), M),
])

const layout_G_memory = Layout([
    FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    Freq(:freq, 1, 2) => SIMD(:simd, 16, 2),
    Freq(:freq, 2, (F * U) ÷ 2) => Memory(:memory, 1, (F * U) ÷ 2),
])

const layout_E_memory = Layout([
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 4) => SIMD(:simd, 8, 4),
    Dish(:dish, 4, D ÷ 4) => Memory(:memory, 1, D ÷ 4),
    Freq(:freq, U, F) => Memory(:memory, (D ÷ 4), F),
    Polr(:polr, 1, P) => Memory(:memory, (D ÷ 4) * F, P),
    Time(:time, 1, T) => Memory(:memory, (D ÷ 4) * F * P, T),
])

const layout_Ē_memory = Layout([
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 4) => SIMD(:simd, 8, 4),
    Dish(:dish, 4, D ÷ 4) => Memory(:memory, 1, D ÷ 4),
    Freq(:freq, 1, F * U) => Memory(:memory, (D ÷ 4), F * U),
    Polr(:polr, 1, P) => Memory(:memory, (D ÷ 4) * (F * U), P),
    Time(:time, U, T ÷ U) => Memory(:memory, (D ÷ 4) * (F * U) * P, T ÷ U),
])

const layout_info_memory = Layout([
    IntValue(:intvalue, 1, 32) => SIMD(:simd, 1, 32),
    Index{Physics,ThreadTag}(:thread, 1, num_threads) => Memory(:memory, 1, num_threads),
    Index{Physics,WarpTag}(:warp, 1, num_warps) => Memory(:memory, num_threads, num_warps),
    Index{Physics,BlockTag}(:block, 1, num_blocks) => Memory(:memory, num_threads * num_warps, num_blocks),
])

# Shared memory layouts

# eqn. (101)
const Σ = U ≤ 64 ? 32 * U + 33 : 65 * (U ÷ 2) + 1
@assert Σ ≥ 65 * (U ÷ 2) && Σ % 32 == 1

# eqn. (99)
@assert U == 16
@assert Packed
const layout_F_shared = Layout([
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 2) => SIMD(:simd, 8, 2),
    Time(:time, 8, 2) => SIMD(:simd, 16, 2),
    #Unpacked FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    #Unpacked Cplx(:cplx, 1, C) => Register(:cplx, 1, C),
    #Unpacked Dish(:dish, 1 << 0, 2) => Register(:dish, 1 << 0, 2),
    #Unpacked UFactor(:ufactor, 1, 2) => SIMD(:simd, 16, 2),
    # eqn. (94)
    Dish(:dish, 4, 32) => Shared(:shared, 1, 32),
    Dish(:dish, 2, 2) => Shared(:shared, 32, 2),
    # eqn. (100)
    Time(:time, 4, 2) => Shared(:shared, 65 * 1, 2),
    Time(:time, 2, 2) => Shared(:shared, 65 * 2, 2),
    Time(:time, 1, 2) => Shared(:shared, 65 * 4, 2),
    # eqn. (100)
    Time(:time, U, Touter ÷ U) => Shared(:shared, Σ, Touter ÷ U),
    Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
    # sect. 5.2
    Dish(:dish, 128, D ÷ 128) => Block(:block, 1, D ÷ 128),
    Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
    Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
])
const layout_F_shared_size = Σ * (Touter ÷ U)

@assert K == 4
const layout_F̄_shared = Layout([
    IntValue(:intvalue, 1, K) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 2) => SIMD(:simd, 8, 2),
    Freq(:freq, 1, 2) => SIMD(:simd, 16, 2),
    # eqn. (94)
    Dish(:dish, 4, 32) => Shared(:shared, 1, 32),
    Dish(:dish, 2, 2) => Shared(:shared, 32, 2),
    # eqn. (102)
    Freq(:freq, 2, 8) => Shared(:shared, 65, 8),
    # eqn. (102)
    Time(:time, U, Touter ÷ U) => Shared(:shared, Σ, Touter ÷ U),
    Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
    # Cplx(:cplx, 1, C) => Shared(:shared, Σ * (Touter ÷ U), 2),
    # sect. 5.2
    Dish(:dish, 128, D ÷ 128) => Block(:block, 1, D ÷ 128),
    Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
    Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
])
const layout_F̄_shared_size = Σ * (Touter ÷ U)

# Register layouts

@assert U ≤ 32
# eqn. (126)
@assert U == 16
const layout_W_registers = Layout([
    FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    Time(:time, 8, 2) => SIMD(:simd, 16, 2),
    Time(:time, 4, 2) => Thread(:thread, 1 << 1, 2),
    Time(:time, 2, 2) => Thread(:thread, 1 << 0, 2),
    Time(:time, 1, 2) => Thread(:thread, 1 << 2, 2),
    # Thread(:thread, 1 << 4, 2),
    # Thread(:thread, 1 << 3, 2),
    MTaps(:mtaps, 1, M) => Register(:mtaps, 1, M),
])

@assert U ≤ 32
# eqn. (127)
@assert U == 16
const layout_X_registers = Layout(
    Dict(
        FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
        Time(:time, 8, 2) => SIMD(:simd, 16, 2),
        Time(:time, 4, 2) => Thread(:thread, 1 << 1, 2),
        Time(:time, 2, 2) => Thread(:thread, 1 << 0, 2),
        Time(:time, 1, 2) => Thread(:thread, 1 << 2, 2),
        # Thread(:thread, 1 << 4, 2),
        # Thread(:thread, 1 << 3, 2),
        Cplx(:cplx, 1, C) => Register(:cplx, 1, C),
    ),
)

@assert U ≤ 32
# eqn. (128)
@assert U == 16
const layout_G_registers = Layout([
    FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    Freq(:freq, 1, 2) => SIMD(:simd, 16, 2),
    Freq(:freq, 2, 2) => Thread(:thread, 1 << 1, 2),
    Freq(:freq, 4, 2) => Thread(:thread, 1 << 0, 2),
    Freq(:freq, 8, 2) => Thread(:thread, 1 << 2, 2),
    # Thread(:thread, 1 << 4, 2),
    # Thread(:thread, 1 << 3, 2),
])

# eqn. (133)
@assert U == 16
const layout_E_registers = Layout([
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 4) => SIMD(:simd, 8, 4),
    Dish(:dish, 4, 4) => Register(:dish, 4, 4),
    Dish(:dish, 16, 8) => Thread(:thread, 1, 8),
    Time(:time, 8, 2) => Thread(:thread, 8, 2),
    Time(:time, 4, 2) => Thread(:thread, 16, 2),
    Time(:time, 1, 4) => Register(:time, 1, 4),
    # one input tile: 128 dishes, 4 times
    # assign input tiles to warps
    Time(:time, U, Touter ÷ U) => Warp(:warp, 1, 16),
    Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
    # sect. 5.2
    Dish(:dish, 128, D ÷ 128) => Block(:block, 1, D ÷ 128),
    Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
    Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
])

# eqn. (142)
@assert U == 16
const layout_Ē_registers = Layout([
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 2) => SIMD(:simd, 8, 2),
    Freq(:freq, 1, 2) => SIMD(:simd, 16, 2),
    Dish(:dish, 16, 2) => Thread(:thread, 1, 2),
    Dish(:dish, 32, 2) => Thread(:thread, 2, 2),
    Dish(:dish, 64, 2) => Thread(:thread, 4, 2),
    Dish(:dish, 8, 2) => Thread(:thread, 8, 2),
    Freq(:freq, 2, 2) => Thread(:thread, 16, 2),
    Dish(:dish, 2, 4) => Register(:dish, 2, 4),
    Freq(:freq, 4, U ÷ 4) => Register(:freq, 4, U ÷ 4),
    # one input tile: 128 dishes, 4 times
    # assign input tiles to warps
    Time(:time, U, Touter ÷ U) => Warp(:warp, 1, 16),
    Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
    # sect. 5.2
    Dish(:dish, 128, D ÷ 128) => Block(:block, 1, D ÷ 128),
    Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
    Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
])

# eqn. (104)
@assert U ≤ 32
const (Ut, Ur) = (U ÷ 2, 1)
const (Dt, Dr) = (64 ÷ U, U ÷ W)
@assert Ut * Dr == U ÷ 2
@assert W * Dt * Dr == 64
@assert Ut * Ur == U ÷ 2
@assert Dt * Dr == D ÷ 128

@assert U == 16
@assert W == 16
@assert Packed
const layout_F_registers = Layout([
    # eqn. (110)
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 2) => SIMD(:simd, 8, 2),
    Time(:time, 8, 2) => SIMD(:simd, 16, 2),
    # eqn. (111)
    #Unpacked FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    #Unpacked Cplx(:cplx, 1, C) => Register(:cplx, 1, C),
    #Unpacked Dish(:dish, 1 << 0, 2) => Register(:dish, 1, 2),
    #Unpacked Time(:time, 1 << 3, 2) => SIMD(:simd, 16, 2),
    # eqn. (105)
    Time(:time, 4, 2) => Thread(:thread, 1 << 1, 2),
    Time(:time, 2, 2) => Thread(:thread, 1 << 0, 2),
    Time(:time, 1, 2) => Thread(:thread, 1 << 2, 2),
    Time(:time, U, Touter ÷ U) => Loop(:t_inner, U, Touter ÷ U),
    Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
    Dish(:dish, 32, 2) => Thread(:thread, 1 << 4, 2),
    Dish(:dish, 64, 2) => Thread(:thread, 1 << 3, 2),
    Dish(:dish, 4, 2) => Warp(:warp, 1 << 0, 2),
    Dish(:dish, 8, 2) => Warp(:warp, 1 << 1, 2),
    Dish(:dish, 16, 2) => Warp(:warp, 1 << 2, 2),
    Dish(:dish, 2, 2) => Warp(:warp, 1 << 3, 2),
    # sect. 5.2
    Dish(:dish, 128, D ÷ 128) => Block(:block, 1, D ÷ 128),
    Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
    Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
])

@assert U == 16
@assert W == 16
@assert K == 4
@assert Packed
const layout_F̄_registers = Layout([
    # eqn. (110)
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 2) => SIMD(:simd, 8, 2),
    Freq(:freq, 1, 2) => SIMD(:simd, 16, 2),
    # eqn. (111)
    #Unpacked FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    #Unpacked Cplx(:cplx, 1, C) => Register(:cplx, 1, C),
    #Unpacked Dish(:dish, 1 << 0, 2) => Register(:dish, 1, 2),
    #Unpacked Freq(:freq, 1 << 0, 2) => SIMD(:simd, 16, 2),
    # eqn. (105)
    Freq(:freq, 2, 2) => Thread(:thread, 1 << 1, 2),
    Freq(:freq, 4, 2) => Thread(:thread, 1 << 0, 2),
    Freq(:freq, 8, 2) => Thread(:thread, 1 << 2, 2),
    Time(:time, U, Touter ÷ U) => Loop(:t_inner, U, Touter ÷ U),
    Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
    Dish(:dish, 32, 2) => Thread(:thread, 1 << 4, 2),
    Dish(:dish, 64, 2) => Thread(:thread, 1 << 3, 2),
    Dish(:dish, 4, 2) => Warp(:warp, 1 << 0, 2),
    Dish(:dish, 8, 2) => Warp(:warp, 1 << 1, 2),
    Dish(:dish, 16, 2) => Warp(:warp, 1 << 2, 2),
    Dish(:dish, 2, 2) => Warp(:warp, 1 << 3, 2),
    # sect. 5.2
    Dish(:dish, 128, D ÷ 128) => Block(:block, 1, D ÷ 128),
    Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
    Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
])

const layout_F_ringbuf_registers = Layout([
    # eqn. (110)
    IntValue(:intvalue, 1, 4) => SIMD(:simd, 1, 4),
    Cplx(:cplx, 1, C) => SIMD(:simd, 4, 2),
    Dish(:dish, 1, 2) => SIMD(:simd, 8, 2),
    Time(:time, 8, 2) => SIMD(:simd, 16, 2),
    # eqn. (111)
    #Unpacked FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
    #Unpacked Cplx(:cplx, 1, C) => Register(:cplx, 1, C),
    #Unpacked Dish(:dish, 1 << 0, 2) => Register(:dish, 1, 2),
    #Unpacked Time(:time, 1 << 3, 2) => SIMD(:simd, 16, 2),
    MTaps(:mtaps, 1, M - 1) => Register(:mtaps, 1, M - 1),
    Time(:time, U ÷ Ur, Ur) => Register(:time, U ÷ Ur, Ur),
    Dish(:dish, D ÷ Dr, Dr) => Register(:dish, D ÷ Dr, Dr),
    # eqn. (105)
    Time(:time, 4, 2) => Thread(:thread, 1 << 1, 2),
    Time(:time, 2, 2) => Thread(:thread, 1 << 0, 2),
    Time(:time, 1, 2) => Thread(:thread, 1 << 2, 2),
    Dish(:dish, 32, 2) => Thread(:thread, 1 << 4, 2),
    Dish(:dish, 64, 2) => Thread(:thread, 1 << 3, 2),
    Dish(:dish, 4, 2) => Warp(:warp, 1 << 0, 2),
    Dish(:dish, 8, 2) => Warp(:warp, 1 << 1, 2),
    Dish(:dish, 16, 2) => Warp(:warp, 1 << 2, 2),
    Dish(:dish, 2, 2) => Warp(:warp, 1 << 3, 2),
    # sect. 5.2
    Dish(:dish, 128, D ÷ 128) => Block(:block, 1, D ÷ 128),
    Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
    Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
])

const layout_info_registers = Layout([
    IntValue(:intvalue, 1, 32) => SIMD(:simd, 1, 32),
    Index{Physics,ThreadTag}(:thread, 1, num_threads) => Thread(:thread, 1, num_threads),
    Index{Physics,WarpTag}(:warp, 1, num_warps) => Warp(:warp, 1, num_warps),
    Index{Physics,BlockTag}(:block, 1, num_blocks) => Block(:block, 1, num_blocks),
])

# Kernel setup

const shmem_size = cld(layout_F_shared_size, 32) * 32 + cld(layout_F̄_shared_size, 32) * 32

const shmem_bytes = 4 * shmem_size

const kernel_setup = KernelSetup(num_threads, num_warps, num_blocks, num_blocks_per_sm, shmem_bytes)

# Generate Code

# sect. 5.5
function upchan!(emitter)
    # Set info output
    apply!(emitter, :info => layout_info_registers, 1i32)
    store!(emitter, :info_memory => layout_info_memory, :info)

    # Initialize ring buffer
    apply!(emitter, :F_ringbuf => layout_F_ringbuf_registers, :(zero(Int4x8)))

    # Load gains
    load!(emitter, :Gains => layout_G_registers, :G_memory => layout_G_memory)

    # Load weights
    load!(emitter, :Wpfb => layout_W_registers, :W_memory => layout_W_memory)

    # Calculate extra phases
    # eqn. (88), (125), (139)
    push!(
        emitter.statements,
        quote
            (X0, X1) = let
                thread = IndexSpaces.assume_inrange(IndexSpaces.cuda_threadidx(), 0, $num_threads)
                thread0 = (thread ÷ 1i32) % 2i32
                thread1 = (thread ÷ 2i32) % 2i32
                thread2 = (thread ÷ 4i32) % 2i32
                time0 = 1i32 * thread2 + 2i32 * thread0 + 4i32 * thread1
                time1 = time0 + 8i32
                X0 = cispi((time0 * $(Int32(U - 1)) / Float32(U)) % 2.0f0)
                X1 = cispi((time1 * $(Int32(U - 1)) / Float32(U)) % 2.0f0)
                (X0, X1)
            end
        end,
    )
    layout_Xreim_registers = delete!(copy(layout_X_registers), Cplx(:cplx, 1, C))
    apply!(emitter, :Xre => layout_Xreim_registers, :(Float16x2(real(X0), real(X1))))
    apply!(emitter, :Xim => layout_Xreim_registers, :(Float16x2(imag(X0), imag(X1))))
    merge!(emitter, :X, [:Xre, :Xim], Cplx(:cplx, 1, C) => Register(:cplx, 1, C))

    # Calculate FFT coefficients
    @assert U == 16
    layout_Γ¹reim_registers = Layout([
        FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
        Time(:time, 8, 2) => SIMD(:simd, 16, 2),
        Time(:time, 4, 2) => Thread(:thread, 1 << 1, 2),
        Time(:time, 2, 2) => Thread(:thread, 1 << 0, 2),
        Freq(:freq, 1, 2) => Thread(:thread, 1 << 2, 2),
        Freq(:freq, 2, 2) => Thread(:thread, 1 << 4, 2),
        Freq(:freq, 4, 2) => Thread(:thread, 1 << 3, 2),
    ])
    # eqn. (60)
    push!(
        emitter.statements,
        quote
            (Γ¹0, Γ¹1) = let
                thread = IndexSpaces.assume_inrange(IndexSpaces.cuda_threadidx(), 0, $num_threads)
                thread0 = (thread ÷ 1i32) % 2i32
                thread1 = (thread ÷ 2i32) % 2i32
                thread2 = (thread ÷ 4i32) % 2i32
                thread3 = (thread ÷ 8i32) % 2i32
                thread4 = (thread ÷ 16i32) % 2i32
                timehi0 = 1i32 * thread0 + 2i32 * thread1
                timehi1 = timehi0 + 4i32
                freqlo = 1i32 * thread2 + 2i32 * thread3 + 4i32 * thread4
                Γ¹0, Γ¹1 = (
                    cispi((-2 * timehi0 * freqlo / Float32(2^8)) % 2.0f0), cispi((-2 * timehi1 * freqlo / Float32(2^8)) % 2.0f0)
                )
                (Γ¹0, Γ¹1)
            end
        end,
    )
    apply!(emitter, :Γ¹rere => layout_Γ¹reim_registers, :(Float16x2(real(Γ¹0), real(Γ¹1))))
    apply!(emitter, :Γ¹reim => layout_Γ¹reim_registers, :(Float16x2(-imag(Γ¹0), -imag(Γ¹1))))
    apply!(emitter, :Γ¹imre => layout_Γ¹reim_registers, :(Float16x2(imag(Γ¹0), imag(Γ¹1))))
    apply!(emitter, :Γ¹imim => layout_Γ¹reim_registers, :(Float16x2(real(Γ¹0), real(Γ¹1))))
    merge!(emitter, :Γ¹re, [:Γ¹rere, :Γ¹reim], Cplx(:cplx_in, 1, C) => Register(:cplx_in, 1, C))
    merge!(emitter, :Γ¹im, [:Γ¹imre, :Γ¹imim], Cplx(:cplx_in, 1, C) => Register(:cplx_in, 1, C))
    merge!(emitter, :Γ¹, [:Γ¹re, :Γ¹im], Cplx(:cplx, 1, C) => Register(:cplx, 1, C))

    @assert U == 16
    layout_Γ²reim_registers = Layout([
        FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
        Time(:time, 1, 2) => SIMD(:simd, 16, 2),
        Freq(:freq, 1, 2) => Thread(:thread, 1 << 2, 2),
        Freq(:freq, 2, 2) => Thread(:thread, 1 << 4, 2),
        Freq(:freq, 4, 2) => Thread(:thread, 1 << 3, 2),
    ])
    # eqn. (61)
    push!(
        emitter.statements,
        quote
            (Γ²0, Γ²1) = let
                thread = IndexSpaces.assume_inrange(IndexSpaces.cuda_threadidx(), 0, $num_threads)
                thread0 = (thread ÷ 1i32) % 2i32
                thread1 = (thread ÷ 2i32) % 2i32
                thread2 = (thread ÷ 4i32) % 2i32
                thread3 = (thread ÷ 8i32) % 2i32
                thread4 = (thread ÷ 16i32) % 2i32
                timelo0 = 0i32
                timelo1 = 1i32
                freqlo = 1i32 * thread2 + 2i32 * thread3 + 4i32 * thread4
                (Γ²0, Γ²1) = (
                    cispi((-2 * timelo0 * freqlo / Float32(2^16)) % 2.0f0),
                    cispi((-2 * timelo1 * freqlo / Float32(2^16)) % 2.0f0),
                )
                (Γ²0, Γ²1)
            end
        end,
    )
    apply!(emitter, :Γ²re => layout_Γ²reim_registers, :(Float16x2(real(Γ²0), real(Γ²1))))
    apply!(emitter, :Γ²im => layout_Γ²reim_registers, :(Float16x2(imag(Γ²0), imag(Γ²1))))
    merge!(emitter, :Γ², [:Γ²re, :Γ²im], Cplx(:cplx, 1, C) => Register(:cplx, 1, C))

    @assert U == 16
    layout_Γ³reim_registers = Layout([
        FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
        Time(:time, 1, 2) => SIMD(:simd, 16, 2),
        Dish(:dish_in, 32, 2) => Thread(:thread, 1 << 1, 2),
        Dish(:dish_in, 64, 2) => Thread(:thread, 1 << 0, 2),
        Freq(:freq, 8, 2) => Thread(:thread, 1 << 2, 2),
        Dish(:dish, 32, 2) => Thread(:thread, 1 << 4, 2),
        Dish(:dish, 64, 2) => Thread(:thread, 1 << 3, 2),
    ])
    # eqn. (62)
    push!(
        emitter.statements,
        quote
            (Γ³0, Γ³1) = let
                thread = IndexSpaces.assume_inrange(IndexSpaces.cuda_threadidx(), 0, $num_threads)
                thread0 = (thread ÷ 1i32) % 2i32
                thread1 = (thread ÷ 2i32) % 2i32
                thread2 = (thread ÷ 4i32) % 2i32
                thread3 = (thread ÷ 8i32) % 2i32
                thread4 = (thread ÷ 16i32) % 2i32
                timelo0 = 0i32
                timelo1 = 1i32
                freqlo = 1i32 * thread2
                # Sparsity pattern, a Kronecker δ in the spectator indices
                dish_in = 1i32 * thread1 + 2i32 * thread0
                dish = 1i32 * thread4 + 2i32 * thread3
                delta = dish == dish_in
                Γ³0, Γ³1 = (
                    delta * cispi((-2 * timelo0 * freqlo / Float32(2^1)) % 2.0f0),
                    delta * cispi((-2 * timelo1 * freqlo / Float32(2^1)) % 2.0f0),
                )
                (Γ³0, Γ³1)
            end
        end,
    )
    apply!(emitter, :Γ³rere => layout_Γ³reim_registers, :(Float16x2(real(Γ³0), real(Γ³1))))
    apply!(emitter, :Γ³reim => layout_Γ³reim_registers, :(Float16x2(-imag(Γ³0), -imag(Γ³1))))
    apply!(emitter, :Γ³imre => layout_Γ³reim_registers, :(Float16x2(imag(Γ³0), imag(Γ³1))))
    apply!(emitter, :Γ³imim => layout_Γ³reim_registers, :(Float16x2(real(Γ³0), real(Γ³1))))
    merge!(emitter, :Γ³re, [:Γ³rere, :Γ³reim], Cplx(:cplx_in, 1, C) => Register(:cplx_in, 1, C))
    merge!(emitter, :Γ³im, [:Γ³imre, :Γ³imim], Cplx(:cplx_in, 1, C) => Register(:cplx_in, 1, C))
    merge!(emitter, :Γ³, [:Γ³re, :Γ³im], Cplx(:cplx, 1, C) => Register(:cplx, 1, C))
    # Why do we need this? `mma_row_col_m16n8k16_f16!` should skip this tag if not present.
    merge!(emitter, :Γ³, [:Γ³, :Γ³], Dish(:dish, 1, 2) => Register(:dish, 1, 2))

    # Outermost loop over outer blocks
    loop!(emitter, Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter)) do emitter

        # Step1: Copy outer block from global memory to shared memory

        # Load E
        load!(emitter, :E => layout_E_registers, :E_memory => layout_E_memory; align=16)
        # eqn. (136)
        # Swap Dish(8,2) and Time(8,2), i.e. Register(:dish,8,2) and Thread(8,2)
        permute!(emitter, :E1, :E, Dish(:dish, 8, 2), Time(:time, 8, 2))
        split!(emitter, [:E1lo, :E1hi], :E1, Register(:dish, 8, 2))
        merge!(emitter, :E1, [:E1lo, :E1hi], Time(:time, 8, 2) => Register(:time, 8, 2))
        # Swap Dish(2,2) and Time(8,2), i.e. Register(:time,8,2) and SIMD(16,2)
        permute!(emitter, :E2, :E1, Dish(:dish, 2, 2), Time(:time, 8, 2))
        split!(emitter, [:E2lo, :E2hi], :E2, Register(:time, 8, 2))
        merge!(emitter, :E2, [:E2lo, :E2hi], Dish(:dish, 2, 2) => Register(:dish, 2, 2))
        apply!(emitter, :F, [:E2], (E2,) -> :($E2))
        # Unpack
        #Unpack widen2!(
        #Unpack     emitter,
        #Unpack     :F,
        #Unpack     :E2,
        #Unpack     SIMD(:simd, 4, 2) => Register(:cplx, 1, C),
        #Unpack     SIMD(:simd, 8, 2) => Register(:dish, 1, 2);
        #Unpack     newtype=FloatValue,
        #Unpack )
        # Store F
        store!(emitter, :F_shared => layout_F_shared, :F)

        sync_threads!(emitter)

        # Loop over inner blocks
        loop!(emitter, Time(:time, U, Touter ÷ U) => Loop(:t_inner, U, Touter ÷ U)) do emitter

            # Loop over packed miniblocks
            unrolled_loop!(emitter, Dish(:dish, D ÷ Dr, Dr) => UnrolledLoop(:dish, D ÷ Dr, Dr)) do emitter

                # Step 2: Read F-array miniblock from shared memory

                load!(emitter, :F_in => layout_F_registers, :F_shared => layout_F_shared)

                # Loop over unpacked miniblocks:
                # This is an implicit loop over Dish(:dish, 1, 2)

                # Step 3: Compute E by unpacking F_in
                widen2!(
                    emitter,
                    :E,
                    :F_in,
                    SIMD(:simd, 4, 2) => Register(:cplx, 1, C),
                    SIMD(:simd, 8, 2) => Register(:dish, 1, 2);
                    newtype=FloatValue,
                )

                # Step 4: Compute E2 from E
                # m = M-1
                split!(emitter, [Symbol(:W_m, m) for m in 0:(M - 1)], :Wpfb, Register(:mtaps, 1, M))
                apply!(emitter, :E2, [:E, Symbol(:W_m, M - 1)], (E, W) -> :($(isodd(M - 1) ? :(-$W) : :(+$W)) * $E))
                # m ∈ 0:M-2
                # NOTE: For some reason, this `unrolled_loop!`
                # construct calls `widen2!` on all mtaps, not just the
                # ones selected in the current unrolled loop
                # iteration. This makes `unrolled_loop!` unusable, and
                # we have to roll our own.
                # unrolled_loop!(emitter, MTaps(:mtaps, 1, M - 1) => UnrolledLoop(:mtaps, 1, M - 1)) do emitter
                #     widen2!(
                #         emitter,
                #         :E_ringbuf,
                #         :F_ringbuf,
                #         SIMD(:simd, 4, 2) => Register(:cplx, 1, C),
                #         SIMD(:simd, 8, 2) => Register(:dish, 1, 2);
                #         newtype=FloatValue,
                #     )
                #     delete!(emitter.environment[:E_ringbuf], MTaps(:mtaps, 1, M - 1))
                #     apply!(emitter, :E2, [:E2, :E_ringbuf, :W1], (E2, E, W1) -> :(muladd($W1, $E, $E2)))
                #     return nothing
                # end
                split!(emitter, [Symbol(:F_ringbuf_m, m) for m in 0:(M - 2)], :F_ringbuf, Register(:mtaps, 1, M - 1))
                for m in 0:(M - 2)
                    widen2!(
                        emitter,
                        Symbol(:E_ringbuf_m, m),
                        Symbol(:F_ringbuf_m, m),
                        SIMD(:simd, 4, 2) => Register(:cplx, 1, C),
                        SIMD(:simd, 8, 2) => Register(:dish, 1, 2);
                        newtype=FloatValue,
                    )
                    apply!(
                        emitter,
                        :E2,
                        [:E2, Symbol(:E_ringbuf_m, m), Symbol(:W_m, m)],
                        (E2, E, W) -> :(muladd($(isodd(m) ? :(-$W) : :(+$W)), $E, $E2)),
                    )
                end

                # Step 5: Compute E3 by applying phases to E2
                # TODO: Combine `W` and `X` into a single factor (only for small `M`?)
                split!(emitter, [:E2re, :E2im], :E2, Cplx(:cplx, 1, C))
                split!(emitter, [:Xre, :Xim], :X, Cplx(:cplx, 1, C))
                apply!(emitter, :E3re, [:E2re, :E2im, :Xre, :Xim], (E2re, E2im, Xre, Xim) -> :(muladd($Xre, $E2re, -$Xim * $E2im)))
                apply!(emitter, :E3im, [:E2re, :E2im, :Xre, :Xim], (E2re, E2im, Xre, Xim) -> :(muladd($Xre, $E2im, $Xim * $E2re)))
                merge!(emitter, :E3, [:E3re, :E3im], Cplx(:cplx, 1, C) => Register(:cplx, 1, C))

                # Step 6: Compute E4 by FFTing E3
                apply!(emitter, :XX, [:E3], (E3,) -> :($E3))
                if U == 16

                    # Step 6.1: Length 8 FFT: W = exp(...) X
                    begin
                        # D_ik = A_ij * B_jk + C_ik
                        # output indices
                        mma_is = [Freq(:freq, 1, 2), Freq(:freq, 4, 2), Freq(:freq, 2, 2), Cplx(:cplx, 1, C)]
                        # input indices
                        mma_js = [Time(:time, 8, 2), Time(:time, 2, 2), Time(:time, 4, 2), Cplx(:cplx_in, 1, 2)]
                        # spectator indices
                        mma_ks = [Time(:time, 1, 2), Dish(:dish, 64, 2), Dish(:dish, 32, 2)]
                        layout_WW_registers = Layout([
                            FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
                            Time(:time, 1 << 0, 2) => SIMD(:simd, 16, 2),
                            Dish(:dish, 1 << 5, 2) => Thread(:thread, 1 << 1, 2),
                            Dish(:dish, 1 << 6, 2) => Thread(:thread, 1 << 0, 2),
                            Freq(:freq, 1, 2) => Thread(:thread, 1 << 2, 2),
                            Freq(:freq, 2, 2) => Thread(:thread, 1 << 4, 2),
                            Freq(:freq, 4, 2) => Thread(:thread, 1 << 3, 2),
                            Cplx(:cplx, 1, C) => Register(:cplx, 1, C),
                            Time(:time, U, Touter ÷ U) => Loop(:t_inner, U, Touter ÷ U),
                            Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
                            Dish(:dish, 1 << 2, 2) => Warp(:warp, 1 << 0, 2),
                            Dish(:dish, 1 << 3, 2) => Warp(:warp, 1 << 1, 2),
                            Dish(:dish, 1 << 4, 2) => Warp(:warp, 1 << 2, 2),
                            Dish(:dish, 1 << 1, 2) => Warp(:warp, 1 << 3, 2),
                            Dish(:dish, 1 << 0, 2) => Register(:dish, 1 << 0, 2),
                            # sect. 5.2
                            Dish(:dish, 1 << 7, D ÷ 128) => Block(:block, 1, D ÷ 128),
                            Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
                            Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
                        ])
                        split!(emitter, [:XXre, :XXim], :XX, Cplx(:cplx, 1, C))
                        merge!(emitter, :XX, [:XXre, :XXim], Cplx(:cplx_in, 1, C) => Register(:cplx_in, 1, C))
                        apply!(emitter, :WW => layout_WW_registers, :(zero(Float16x2)))
                        mma_row_col_m16n8k16_f16!(
                            emitter, :WW, :Γ¹ => (mma_is, mma_js), :XX => (mma_js, mma_ks), :WW => (mma_is, mma_ks)
                        )
                    end

                    # Step 6.2: Z = exp(...) W
                    split!(emitter, [:Γ²re, :Γ²im], :Γ², Cplx(:cplx, 1, C))
                    split!(emitter, [:WWre, :WWim], :WW, Cplx(:cplx, 1, C))
                    apply!(
                        emitter,
                        :ZZre,
                        [:WWre, :WWim, :Γ²re, :Γ²im],
                        (WWre, WWim, Γ²re, Γ²im) -> :(muladd($Γ²re, $WWre, -$Γ²im * $WWim)),
                    )
                    apply!(
                        emitter,
                        :ZZim,
                        [:WWre, :WWim, :Γ²re, :Γ²im],
                        (WWre, WWim, Γ²re, Γ²im) -> :(muladd($Γ²re, $WWim, $Γ²im * $WWre)),
                    )
                    merge!(emitter, :ZZ, [:ZZre, :ZZim], Cplx(:cplx, 1, C) => Register(:cplx, 1, C))

                    # Step 6.3: Length 2 FFT: Y = exp(...) Z
                    begin
                        # D_ik = A_ij * B_jk + C_ik
                        # output indices
                        mma_is = [Freq(:freq, 8, 2), Dish(:dish, 64, 2), Dish(:dish, 32, 2), Cplx(:cplx, 1, C)]
                        # input indices
                        mma_js = [Time(:time, 1, 2), Dish(:dish_in, 64, 2), Dish(:dish_in, 32, 2), Cplx(:cplx_in, 1, 2)]
                        # spectator indices
                        mma_ks = [Freq(:freq, 1, 2), Freq(:freq, 4, 2), Freq(:freq, 2, 2)]
                        #
                        split!(emitter, [:ZZre, :ZZim], :ZZ, Cplx(:cplx, 1, C))
                        merge!(emitter, :ZZ, [:ZZre, :ZZim], Cplx(:cplx_in, 1, C) => Register(:cplx_in, 1, C))
                        let
                            layout = copy(emitter.environment[:ZZ])
                            for dish in [1 << 5, 1 << 6]
                                k = Dish(:dish, dish, 2)
                                k′ = Dish(:dish_in, dish, 2)
                                v = layout[k]
                                delete!(layout, k)
                                layout[k′] = v
                            end
                            emitter.environment[:ZZ] = layout
                        end
                        layout_YY_registers = Layout([
                            FloatValue(:floatvalue, 1, 16) => SIMD(:simd, 1, 16),
                            Freq(:freq, 1 << 0, 2) => SIMD(:simd, 16, 2),
                            Freq(:freq, 1 << 1, 2) => Thread(:thread, 1 << 1, 2),
                            Freq(:freq, 1 << 2, 2) => Thread(:thread, 1 << 0, 2),
                            Freq(:freq, 1 << 3, 2) => Thread(:thread, 1 << 2, 2),
                            Dish(:dish, 1 << 5, 2) => Thread(:thread, 1 << 4, 2),
                            Dish(:dish, 1 << 6, 2) => Thread(:thread, 1 << 3, 2),
                            Cplx(:cplx, 1, C) => Register(:cplx, 1, C),
                            Time(:time, U, Touter ÷ U) => Loop(:t_inner, U, Touter ÷ U),
                            Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter),
                            Dish(:dish, 1 << 2, 2) => Warp(:warp, 1 << 0, 2),
                            Dish(:dish, 1 << 3, 2) => Warp(:warp, 1 << 1, 2),
                            Dish(:dish, 1 << 4, 2) => Warp(:warp, 1 << 2, 2),
                            Dish(:dish, 1 << 1, 2) => Warp(:warp, 1 << 3, 2),
                            Dish(:dish, 1 << 0, 2) => Register(:dish, 1 << 0, 2),
                            # sect. 5.2
                            Dish(:dish, 1 << 7, D ÷ 128) => Block(:block, 1, D ÷ 128),
                            Polr(:polr, 1, P) => Block(:block, D ÷ 128, P),
                            Freq(:freq, U, F) => Block(:block, (D ÷ 128) * P, F),
                        ])
                        apply!(emitter, :YY => layout_YY_registers, :(zero(Float16x2)))
                        mma_row_col_m16n8k16_f16!(
                            emitter, :YY, :Γ³ => (mma_is, mma_js), :ZZ => (mma_js, mma_ks), :YY => (mma_is, mma_ks)
                        )
                    end
                    apply!(emitter, :E4, [:YY], (YY,) -> :($YY))

                else            # unsupported value for U
                    @assert false
                end

                # Step 7: Compute E5 by applying gains to E4
                # TODO: Combine gains and last FFT step
                apply!(emitter, :E5, [:E4, :Gains], (E4, G) -> :($G * $E4))

                # Step 8: Compute F̄_out by quantizing E5
                apply!(emitter, :E5, [:E5], (E5,) -> :(clamp($E5, Float16x2(-7, -7), Float16x2(+7, +7))))
                narrow2!(
                    emitter,
                    :F̄_out,
                    :E5,
                    Register(:cplx, 1, C) => SIMD(:simd, 4, 2),
                    Register(:dish, 1, 2) => SIMD(:simd, 8, 2);
                    newtype=IntValue,
                )
                @assert emitter.environment[:F̄_out] == layout_F̄_registers

                # Step 9: Write F̄_out to shared memory
                store!(emitter, :F̄_shared => layout_F̄_shared, :F̄_out)

                # Advance ring buffer
                split!(emitter, [Symbol(:F_ringbuf_m, m) for m in 0:(M - 2)], :F_ringbuf, Register(:mtaps, 1, M - 1))
                for m in 0:(M - 3)
                    apply!(emitter, Symbol(:F_ringbuf_m, m), [Symbol(:F_ringbuf_m, m + 1)], (F,) -> :($F))
                end
                apply!(
                    emitter,
                    Symbol(:F_ringbuf_m, M - 2),
                    [Symbol(:F_ringbuf_m, M - 2), :F_in],
                    (F_ringbuf, F) -> :($F);
                    ignore=[Time(:time, 16, 16)],
                )
                merge!(
                    emitter,
                    :F_ringbuf,
                    [Symbol(:F_ringbuf_m, m) for m in 0:(M - 2)],
                    MTaps(:mtaps, 1, M - 1) => Register(:mtaps, 1, M - 1),
                )

                return nothing
            end # unrolled_loop!(Dish(:dish, D ÷ Dr, Dr) => UnrolledLoop(:dish, D ÷ Dr, Dr))

            return nothing
        end # loop!(Time(:time, U, Touter ÷ U) => Loop(:t_inner, U, Touter ÷ U))

        sync_threads!(emitter)

        # Step 10: Copy outer block from shared memory to global memory
        load!(emitter, :Ē => layout_Ē_registers, :F̄_shared => layout_F̄_shared)
        # eqn. (145)
        # Swap Dish(2,2) and Freq(2,2), i.e. Register(:dish,2,2) and SIMD(16,2)
        permute!(emitter, :Ē1, :Ē, Dish(:dish, 2, 2), Freq(:freq, 1, 2))
        split!(emitter, [:Ē1lo, :Ē1hi], :Ē1, Register(:dish, 2, 2))
        merge!(emitter, :Ē1, [:Ē1lo, :Ē1hi], Freq(:freq, 1, 2) => Register(:freq, 1, 2))
        # Swap Dish(8,2) and Freq(1,2), i.e. Register(:freq,1,2) and Thread(8,2)
        permute!(emitter, :Ē2, :Ē1, Dish(:dish, 8, 2), Freq(:freq, 1, 2))
        split!(emitter, [:Ē2lo, :Ē2hi], :Ē2, Register(:freq, 1, 2))
        merge!(emitter, :Ē2, [:Ē2lo, :Ē2hi], Dish(:dish, 8, 2) => Register(:dish, 8, 2))
        store!(emitter, :Ē_memory => layout_Ē_memory, :Ē2; align=16)

        return nothing
    end # loop!(Time(:time, Touter, T ÷ Touter) => Loop(:t_outer, Touter, T ÷ Touter))

    # Set info output
    apply!(emitter, :info => layout_info_registers, 0i32)
    store!(emitter, :info_memory => layout_info_memory, :info)

    return nothing
end

function make_upchan_kernel()
    emitter = Emitter(kernel_setup)

    # Generate kernel
    upchan!(emitter)

    # Emit code
    stmts = clean_code(
        quote
            #TODO @fastmath @inbounds begin
            begin
                $(emitter.init_statements...)
                $(emitter.statements...)
            end
        end,
    )

    return stmts
end

println("[Creating upchan kernel...]")
const upchan_kernel = make_upchan_kernel()
println("[Done creating upchan kernel]")

open("output-A40/upchan.jl", "w") do fh
    println(fh, upchan_kernel)
end

@eval function upchan(G_memory, W_memory, E_memory, Ē_memory, info_memory)
    shmem = @cuDynamicSharedMem(UInt8, shmem_bytes, 0)
    F_shared = reinterpret(Int4x8, shmem)
    F̄_shared = reinterpret(Int4x8, shmem)
    $upchan_kernel
    return nothing
end

function main(; compile_only::Bool=false, nruns::Int=0, run_selftest::Bool=false, silent::Bool=false)
    !silent && println("CHORD upchannelizer")

    !silent && println("Compiling kernel...")
    num_threads = kernel_setup.num_threads
    num_warps = kernel_setup.num_warps
    num_blocks = kernel_setup.num_blocks
    num_blocks_per_sm = kernel_setup.num_blocks_per_sm
    shmem_bytes = kernel_setup.shmem_bytes
    shmem_size = shmem_bytes ÷ 4
    @assert num_warps * num_blocks_per_sm ≤ 32 # (???)
    @assert shmem_bytes ≤ 99 * 1024 # NVIDIA A10/A40 have 99 kB shared memory
    kernel = @cuda launch = false minthreads = num_threads * num_warps blocks_per_sm = num_blocks_per_sm upchan(
        CUDA.zeros(Float16x2, 0), CUDA.zeros(Float16x2, 0), CUDA.zeros(Int4x8, 0), CUDA.zeros(Int4x8, 0), CUDA.zeros(Int32, 0)
    )
    attributes(kernel.fun)[CUDA.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES] = shmem_bytes

    if compile_only
        return nothing
    end

    !silent && println("Allocating input data...")
    G_memory = Array{Float16}(undef, F * U)
    W_memory = Array{Float16}(undef, U * M)
    E_memory = Array{Int4x2}(undef, D * F * P * T)
    Ē_wanted = Array{Complex{Float32}}(undef, D * (F * U) * P * (T ÷ U))
    info_wanted = Array{Int32}(undef, num_threads * num_warps * num_blocks)

    !silent && println("Setting up input data...")

    for freq in 0:(F * U - 1)
        G_memory[freq + 1] = 1
    end

    for s in 0:(M * U - 1)
        # sinc-Hanning weight function, eqn. (11), with `N=U`
        time = s % U
        mtap = s ÷ U
        @assert 0 ≤ mtap < M
        Widx = (time ÷ 8 % 2) + 2 * (time % 8) + 16 * (time ÷ 16) + U * mtap
        @assert 0 ≤ Widx < length(W_memory)

        W_memory[Widx + 1] = cospi((s - (M * U - 1) / 2.0f0) / (M * U + 1))^2 * sinc′((s - (M * U - 1) / 2.0f0) / U)
    end
    W_memory /= sum(W_memory)

    amp = 7.5f0                 # amplitude
    bin = 0                     # frequency bin
    delta = 0.0f0               # frequency offset
    test_freq = bin - (U - 1) / 2.0f0 + delta
    attenuation_factors = Pair{Float32,Float32}[
        0 => 1.00007,
        0.0001 => 1.00007,
        0.001 => 1.00005,
        0.01 => 0.999116,
        0.1 => 0.910357,
        0.2 => 0.680212,
        0.3 => 0.402912,
        0.4 => 0.172467,
        0.5 => 0.0374226,
        1.0 => 0.000714811,
        2.0 => 0, # not measured, down in the noise
    ]
    att = interp(attenuation_factors, delta)

    # map!(i -> zero(Int4x2), E_memory, E_memory)
    for time in 0:(T - 1), polr in 0:(P - 1), freq in 0:(F - 1), dish in 0:(D - 1)
        Eidx = dish + D * freq + D * F * polr + D * F * P * time
        if polr == 0 && freq == 0 && dish == 0
            E1 = amp * cispi((2 * time / Float32(U) * test_freq) % 2.0f0)
        else
            E1 = 0.0f0 + 0im
        end
        E1 = clamp(round(Int, E1), -7, +7)
        E_memory[Eidx + 1] = Int4x2(E1.re, E1.im)
    end

    # map!(i -> zero(Int4x2), Ẽ_wanted, Ẽ_wanted)
    for tbar in 0:(T ÷ U - 1), polr in 0:(P - 1), fbar in 0:(F * U - 1), dish in 0:(D - 1)
        Ēidx = dish + D * fbar + D * (F * U) * polr + D * (F * U) * P * tbar
        if polr == 0 && fbar == 0 && dish == 0
            Ē1 = fbar == bin ? att * amp * cispi((2 * (tbar - (M - 1) + M / 2.0f0) * (0.5f0 + delta)) % 2.0f0) : 0
        else
            Ē1 = 0.0f0 + 0im
        end
        Ē_wanted[Ēidx + 1] = Ē1
    end

    map!(i -> zero(Int32), info_wanted, info_wanted)

    G_memory = reinterpret(Float16x2, G_memory)
    W_memory = reinterpret(Float16x2, W_memory)
    E_memory = reinterpret(Int4x8, E_memory)

    !silent && println("Copying data from CPU to GPU...")
    G_cuda = CuArray(G_memory)
    W_cuda = CuArray(W_memory)
    E_cuda = CuArray(E_memory)
    Ē_cuda = CUDA.fill(Int4x8(-8, -8, -8, -8, -8, -8, -8, -8), (C ÷ 2) * (D ÷ 4) * (F * U) * P * (T ÷ U))
    info_cuda = CUDA.fill(-1i32, length(info_wanted))

    @assert sizeof(G_cuda) < 2^32
    @assert sizeof(W_cuda) < 2^32
    @assert sizeof(E_cuda) < 2^32
    @assert sizeof(Ē_cuda) < 2^32

    !silent && println("Running kernel...")
    kernel(G_cuda, W_cuda, E_cuda, Ē_cuda, info_cuda; threads=(num_threads, num_warps), blocks=num_blocks, shmem=shmem_bytes)
    synchronize()

    if nruns > 0
        !silent && println("Benchmarking...")
        stats = @timed begin
            for run in 1:nruns
                kernel(
                    G_cuda,
                    W_cuda,
                    E_cuda,
                    Ē_cuda,
                    info_cuda;
                    threads=(num_threads, num_warps),
                    blocks=num_blocks,
                    shmem=shmem_bytes,
                )
            end
            synchronize()
        end
        # All times in μsec
        runtime = stats.time / nruns * 1.0e+6
        num_frequencies_scaled = F₀
        runtime_scaled = runtime / F * num_frequencies_scaled
        dataframe_length = T * sampling_time_μsec
        fraction = runtime_scaled / dataframe_length
        round1(x) = round(x; digits=1)
        println("""
        benchmark-result:
          kernel: "upchan"
          description: "Upchannelizer"
          design-parameters:
            number-of-complex-components: $C
            number-of-dishes: $D
            number-of-frequencies: $F
            number-of-polarizations: $P
            number-of-taps: $M
            number-of-timesamples: $T
            sampling-time-μsec: $sampling_time_μsec
            upchannelization-factor: $U
          compile-parameters:
            minthreads: $(num_threads * num_warps)
            blocks_per_sm: $num_blocks_per_sm
          call-parameters:
            threads: [$num_threads, $num_warps]
            blocks: [$num_blocks]
            shmem_bytes: $shmem_bytes
          result-μsec:
            runtime: $(round1(runtime))
            scaled-runtime: $(round1(runtime_scaled))
            scaled-number-of-frequencies: $num_frequencies_scaled
            dataframe-length: $(round1(dataframe_length))
            dataframe-percent: $(round1(fraction * 100))
        """)
    end

    !silent && println("Copying data back from GPU to CPU...")
    Ē_memory = Array(Ē_cuda)
    info_memory = Array(info_cuda)
    @assert all(info_memory .== 0)

    Ē_memory = reinterpret(Int4x2, Ē_memory)

    if run_selftest
        println("Checking results...")
        num_errors = 0
        println("    Ē:")
        did_test_Ē_memory = falses(length(Ē_memory))
        # for tbar in 0:(T ÷ U - 1), polr in 0:(P - 1), fbar in 0:(F * U - 1), dish in 0:(D - 1)
        for polr in 0:(P - 1), dish in 0:(D - 1), fbar in 0:(F * U - 1), tbar in 0:(T ÷ U - 1)
            Ēidx = dish + D * fbar + D * (F * U) * polr + D * (F * U) * P * tbar
            @assert !did_test_Ē_memory[Ēidx + 1]
            did_test_Ē_memory[Ēidx + 1] = true
            have_value = Complex(convert(NTuple{2,Int32}, Ē_memory[Ēidx + 1])...)
            want_value = Ē_wanted[Ēidx + 1]
            if have_value ≠ want_value
                if true || (dish == 0 && polr == 0)
                    num_errors += 1
                    if num_errors ≤ 100
                        # if !isapprox(have_value, want_value; atol=10 * eps(Float16), rtol=10 * eps(Float16))
                        println("        dish=$dish fbar=$fbar polr=$polr tbar=$tbar Ē=$have_value Ē₀=$want_value")
                    elseif num_errors == 101
                        println("        [skipping further error output]")
                    end
                end
            end
        end
        @assert all(did_test_Ē_memory)
        println("Found $num_errors errors")
        @assert num_errors == 0
    end

    !silent && println("Done.")
    return nothing
end

function fix_ptx_kernel()
    ptx = read("output-A40/upchan.ptx", String)
    ptx = replace(ptx, r".extern .func ([^;]*);"s => s".func \1.noreturn\n{\n\ttrap;\n}")
    open("output-A40/upchan.ptx", "w") do fh
        write(fh, ptx)
    end
    kernel_name = match(r"\s\.globl\s+(\S+)"m, ptx).captures[1]
    open("output-A40/upchan.yaml", "w") do fh
        print(
            fh,
            """
    --- !<tag:chord-observatory.ca/x-engine/kernel-description-1.0.0>
    kernel-description:
      name: "upchan"
      description: "Upchannelizer"
      design-parameters:
        number-of-complex-components: $C
        number-of-dishes: $D
        number-of-frequencies: $F
        number-of-polarizations: $P
        number-of-taps: $M
        number-of-timesamples: $T
        sampling-time-μsec: $sampling_time_μsec
        upchannelization-factor: $U
      compile-parameters:
        minthreads: $(num_threads * num_warps)
        blocks_per_sm: $num_blocks_per_sm
      call-parameters:
        threads: [$num_threads, $num_warps]
        blocks: [$num_blocks]
        shmem_bytes: $shmem_bytes
      kernel-name: "$kernel_name"
      kernel-arguments:
        - name: "G"
          intent: in
          type: Float16
          indices: [F̄]
          shape: [$(F*U)]
          strides: [1]
        - name: "W"
          intent: in
          type: Float16
          indices: [U, M]
          shape: [$U, $M]
          strides: [1, $U]
        - name: "E"
          intent: in
          type: Int4
          indices: [C, D, F, P, T]
          shape: [$C, $D, $F, $P, $T]
          strides: [1, $C, $(C*D), $(C*D*F), $(C*D*F*P)]
        - name: "Ē"
          intent: out
          type: Int4
          indices: [C, D, F̄, P, T̄]
          shape: [$C, $D, $(F*U), $P, $(T÷U)]
          strides: [1, $C, $(C*D), $(C*D*F*U), $(C*D*F*U*P)]
        - name: "info"
          intent: out
          type: Int32
          indices: [thread, warp, block]
          shapes: [$num_threads, $num_warps, $num_blocks]
          strides: [1, $num_threads, $(num_threads*num_warps)]
    ...
    """,
        )
    end
    return nothing
end

if CUDA.functional()
    # # Output kernel
    # println("Writing PTX code...")
    # open("output-A40/upchan.ptx", "w") do fh
    #     redirect_stdout(fh) do
    #         @device_code_ptx main(; compile_only=true, silent=true)
    #     end
    # end
    # fix_ptx_kernel()
    # println("Writing SASS code...")
    # open("output-A40/upchan.sass", "w") do fh
    #     redirect_stdout(fh) do
    #         @device_code_sass main(; compile_only=true, silent=true)
    #     end
    # end

    # Run test
    main(; run_selftest=true)

    # # Run benchmark
    # main(; nruns=100)

    # # Regular run, also for profiling
    # main()
end