# native target for CPU execution

## target

export NativeCompilerTarget

Base.@kwdef struct NativeCompilerTarget <: AbstractCompilerTarget
    cpu::String=(LLVM.version() < v"8") ? "" : unsafe_string(LLVM.API.LLVMGetHostCPUName())
    features::String=(LLVM.version() < v"8") ? "" : unsafe_string(LLVM.API.LLVMGetHostCPUFeatures())
end

llvm_triple(::NativeCompilerTarget) = Sys.MACHINE

function llvm_machine(target::NativeCompilerTarget, static)
    triple = llvm_triple(target)

    t = Target(triple=triple)

    optlevel = LLVM.API.LLVMCodeGenLevelDefault
    reloc = static ? LLVM.API.LLVMRelocPIC : LLVM.API.LLVMRelocDefault
    tm = TargetMachine(t, triple, target.cpu, target.features, optlevel, reloc)
    asm_verbosity!(tm, true)

    return tm
end


## job

runtime_slug(job::CompilerJob{NativeCompilerTarget}) = "native_$(job.target.cpu)-$(hash(job.target.features))"
