# Julia compiler integration

## cache

using Core.Compiler: CodeInstance, MethodInstance

struct CodeCache
    dict::Dict{MethodInstance,Vector{CodeInstance}}
    CodeCache() = new(Dict{MethodInstance,Vector{CodeInstance}}())
end

function Base.show(io::IO, ::MIME"text/plain", cc::CodeCache)
    print(io, "CodeCache with $(mapreduce(length, +, values(cc.dict); init=0)) entries: ")
    for (mi, cis) in cc.dict
        println(io)
        print(io, "  ")
        show(io, mi)

        function worldstr(min_world, max_world)
            if min_world == typemax(UInt)
                "empty world range"
            elseif max_world == typemax(UInt)
                "worlds $(Int(min_world))+"
            else
                "worlds $(Int(min_world)) to $(Int(max_world))"
            end
        end

        for (i,ci) in enumerate(cis)
            println(io)
            print(io, "    CodeInstance for ", worldstr(ci.min_world, ci.max_world))
        end
    end
end

function Core.Compiler.setindex!(cache::CodeCache, ci::CodeInstance, mi::MethodInstance)
    # make sure the invalidation callback is attached to the method instance
    callback(mi, max_world) = invalidate(cache, mi, max_world)
    if !isdefined(mi, :callbacks)
        mi.callbacks = Any[callback]
    else
        if all(cb -> cb !== callback, mi.callbacks)
            push!(mi.callbacks, callback)
        end
    end

    cis = get!(cache.dict, mi, CodeInstance[])
    push!(cis, ci)
end

# invalidation (like invalidate_method_instance, but for our cache)
function invalidate(cache::CodeCache, replaced::MethodInstance, max_world, depth=0)
    cis = get(cache.dict, replaced, nothing)
    if cis === nothing
        return
    end
    for ci in cis
        if ci.max_world == ~0 % Csize_t
            @assert ci.min_world - 1 <= max_world "attempting to set illogical constraints"
            ci.max_world = max_world
        end
        @assert ci.max_world <= max_world
    end

    # recurse to all backedges to update their valid range also
    if isdefined(replaced, :backedges)
        backedges = replaced.backedges
        # Don't touch/empty backedges `invalidate_method_instance` in C will do that later
        # replaced.backedges = Any[]

        for mi in backedges
            invalidate(cache, mi, max_world, depth + 1)
        end
    end
end

const CI_CACHE = CodeCache()


## interpreter

using Core.Compiler: AbstractInterpreter, InferenceResult, InferenceParams, InferenceState, OptimizationParams

struct GPUInterpreter <: AbstractInterpreter
    # Cache of inference results for this particular interpreter
    cache::Vector{InferenceResult}
    # The world age we're working inside of
    world::UInt

    # Parameters for inference and optimization
    inf_params::InferenceParams
    opt_params::OptimizationParams

    function GPUInterpreter(world::UInt)
        @assert world <= Base.get_world_counter()

        return new(
            # Initially empty cache
            Vector{InferenceResult}(),

            # world age counter
            world,

            # parameters for inference and optimization
            InferenceParams(unoptimize_throw_blocks=false),
            OptimizationParams(unoptimize_throw_blocks=false),
        )
    end
end

# Quickly and easily satisfy the AbstractInterpreter API contract
Core.Compiler.get_world_counter(ni::GPUInterpreter) = ni.world
Core.Compiler.get_inference_cache(ni::GPUInterpreter) = ni.cache
Core.Compiler.InferenceParams(ni::GPUInterpreter) = ni.inf_params
Core.Compiler.OptimizationParams(ni::GPUInterpreter) = ni.opt_params
Core.Compiler.may_optimize(ni::GPUInterpreter) = true
Core.Compiler.may_compress(ni::GPUInterpreter) = true
Core.Compiler.may_discard_trees(ni::GPUInterpreter) = true
Core.Compiler.add_remark!(ni::GPUInterpreter, sv::InferenceState, msg) = nothing # TODO


## world view of the cache

using Core.Compiler: WorldView

function Core.Compiler.haskey(wvc::WorldView{CodeCache}, mi::MethodInstance)
    Core.Compiler.get(wvc, mi, nothing) !== nothing
end

function Core.Compiler.get(wvc::WorldView{CodeCache}, mi::MethodInstance, default)
    cache = wvc.cache
    for ci in get!(cache.dict, mi, CodeInstance[])
        if ci.min_world <= wvc.worlds.min_world && wvc.worlds.max_world <= ci.max_world
            # TODO: if (code && (code == jl_nothing || jl_ir_flag_inferred((jl_array_t*)code)))
            return ci
        end
    end

    return default
end

function Core.Compiler.getindex(wvc::WorldView{CodeCache}, mi::MethodInstance)
    r = Core.Compiler.get(wvc, mi, nothing)
    r === nothing && throw(KeyError(mi))
    return r::CodeInstance
end

function Core.Compiler.setindex!(wvc::WorldView{CodeCache}, ci::CodeInstance, mi::MethodInstance)
    Core.Compiler.setindex!(wvc.cache, ci, mi)
end


## codegen/inference integration

Core.Compiler.code_cache(ni::GPUInterpreter) = WorldView(CI_CACHE, ni.world)

# No need to do any locking since we're not putting our results into the runtime cache
Core.Compiler.lock_mi_inference(ni::GPUInterpreter, mi::MethodInstance) = nothing
Core.Compiler.unlock_mi_inference(ni::GPUInterpreter, mi::MethodInstance) = nothing

function ci_cache_populate(mi, min_world, max_world)
    interp = GPUInterpreter(min_world)
    src = Core.Compiler.typeinf_ext_toplevel(interp, mi)

    # inference populates the cache, so we don't need to jl_get_method_inferred
    wvc = WorldView(CI_CACHE, min_world, max_world)
    @assert Core.Compiler.haskey(wvc, mi)

    # if src is rettyp_const, the codeinfo won't cache ci.inferred
    # (because it is normally not supposed to be used ever again).
    # to avoid the need to re-infer, set that field here.
    ci = Core.Compiler.getindex(wvc, mi)
    if ci !== nothing && ci.inferred === nothing
        ci.inferred = src
    end

    return
end

function ci_cache_lookup(mi, min_world, max_world)
    wvc = WorldView(CI_CACHE, min_world, max_world)
    return Core.Compiler.get(wvc, mi, nothing)
end


## interface

function compile_method_instance(@nospecialize(job::CompilerJob), method_instance::MethodInstance, world)
    # set-up the compiler interface
    debug_info_kind = if Base.JLOptions().debug_level == 0
        LLVM.API.LLVMDebugEmissionKindNoDebug
    elseif Base.JLOptions().debug_level == 1
        LLVM.API.LLVMDebugEmissionKindLineTablesOnly
    elseif Base.JLOptions().debug_level >= 2
        LLVM.API.LLVMDebugEmissionKindFullDebug
    end
    if job.target isa PTXCompilerTarget && !job.target.debuginfo
        debug_info_kind = LLVM.API.LLVMDebugEmissionKindNoDebug
    end
    params = Base.CodegenParams(;
        track_allocations  = false,
        code_coverage      = false,
        prefer_specsig     = true,
        gnu_pubnames       = false,
        debug_info_kind    = Cint(debug_info_kind),
        lookup             = @cfunction(ci_cache_lookup, Any, (Any, UInt, UInt)))

    # popoulate the cache
    if ci_cache_lookup(method_instance, world, world) === nothing
        ci_cache_populate(method_instance, world, world)
    end

    # generate IR
    native_code = ccall(:jl_create_native, Ptr{Cvoid},
                        (Vector{MethodInstance}, Base.CodegenParams, Cint),
                        [method_instance], params, #=extern policy=# 1)
    @assert native_code != C_NULL
    llvm_mod_ref = ccall(:jl_get_llvm_module, LLVM.API.LLVMModuleRef,
                         (Ptr{Cvoid},), native_code)
    @assert llvm_mod_ref != C_NULL
    llvm_mod = LLVM.Module(llvm_mod_ref)

    # get the top-level code
    code = ci_cache_lookup(method_instance, world, world)

    # get the top-level function index
    llvm_func_idx = Ref{Int32}(-1)
    llvm_specfunc_idx = Ref{Int32}(-1)
    ccall(:jl_get_function_id, Nothing,
          (Ptr{Cvoid}, Any, Ptr{Int32}, Ptr{Int32}),
          native_code, code, llvm_func_idx, llvm_specfunc_idx)
    @assert llvm_func_idx[] != -1
    @assert llvm_specfunc_idx[] != -1

    # get the top-level function)
    llvm_func_ref = ccall(:jl_get_llvm_function, LLVM.API.LLVMValueRef,
                          (Ptr{Cvoid}, UInt32), native_code, llvm_func_idx[]-1)
    @assert llvm_func_ref != C_NULL
    llvm_func = LLVM.Function(llvm_func_ref)
    llvm_specfunc_ref = ccall(:jl_get_llvm_function, LLVM.API.LLVMValueRef,
                              (Ptr{Cvoid}, UInt32), native_code, llvm_specfunc_idx[]-1)
    @assert llvm_specfunc_ref != C_NULL
    llvm_specfunc = LLVM.Function(llvm_specfunc_ref)

    # configure the module
    triple!(llvm_mod, llvm_triple(job.target))
    if julia_datalayout(job.target) !== nothing
        datalayout!(llvm_mod, julia_datalayout(job.target))
    end

    return llvm_specfunc, llvm_mod
end

Base.empty!(cache::CodeCache) = empty!(cache.dict)
