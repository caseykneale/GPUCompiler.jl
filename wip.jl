using GPUCompiler

include("test/definitions/ptx.jl")

const val = Ref{Int}()

original() = val[] = 1

kernel() = (original(); nothing)

replaced() = val[] = 2
GPUCompiler.@override GPUCompiler.GLOBAL_CI_CACHE original() replaced

function main()
    ptx_code_llvm(kernel, Tuple{}; debuginfo=:none)
end

isinteractive() || main()
