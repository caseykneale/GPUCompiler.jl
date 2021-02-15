using GPUCompiler

include("test/definitions/native.jl")

original() = 0

kernel() = original()

replaced() = 42
GPUCompiler.@override GPUCompiler.CI_CACHE original() replaced

function main()
    native_code_llvm(kernel, Tuple{}; debuginfo=:none)
end

isinteractive() || main()
