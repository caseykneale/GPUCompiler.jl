using GPUCompiler

include("test/definitions/native.jl")

original() = 0

kernel() = original()

replaced() = 42
GPUCompiler.add_override!(GPUCompiler.CI_CACHE, original, replaced)

function main()
    @show kernel()

    empty!(GPUCompiler.CI_CACHE.dict)
    native_code_llvm(kernel, Tuple{}; debuginfo=:none)
end

isinteractive() || main()
