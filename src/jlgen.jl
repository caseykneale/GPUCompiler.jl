# Julia compiler integration

## cache

using Core.Compiler: CodeInstance, MethodInstance

struct CodeCache
    dict::Dict{MethodInstance,Vector{CodeInstance}}
    override_table::Dict{Type,Function}
    override_aliases::Dict{Method,Type}
    CodeCache() = new(Dict{MethodInstance,Vector{CodeInstance}}(),
                      Dict{Type,Function}(), Dict{Method,Type}())
end

jl_method_def(argdata::Core.SimpleVector, ci::Core.CodeInfo, mod::Module) =
    ccall(:jl_method_def, Any, (Core.SimpleVector, Any, Any), argdata, ci, mod)
# `argdata` is `Core.svec(Core.svec(types...), Core.svec(typevars...), LineNumberNode)`

argdata(sig, source) = Core.svec(Base.unwrap_unionall(sig).parameters::Core.SimpleVector, Core.svec(typevars(sig)...), source)

"Recursively get the typevars from a `UnionAll` type"
typevars(T::UnionAll) = (T.var, typevars(T.body)...)
typevars(T::DataType) = ()

getmodule(F::Type{<:Function}) = F.name.mt.module
getmodule(f::Function) = getmodule(typeof(f))

# TODO: get source from macro, proposed syntax:
#       @override sin(::T) where {T<:Float64} CUDA.sin
function add_override!(cache::CodeCache, f::Function, f′::Function, tt=Tuple{Vararg{Any}}, source=Core.LineNumberNode(0))
    # NOTE: instead of manually crafting a method table, we use an anonymous function
    mt = get!(cache.override_table, typeof(f)) do
        @eval Main function $(gensym()) end
    end

    # XXX: easier way to get a dummy code-info (can we use `jl_new_code_info_uninit`?)
    dummy(x) = return
    ci = InteractiveUtils.code_lowered(dummy)[1]
    sig = Base.signature_type(mt, tt)
    meth = jl_method_def(argdata(sig, source), ci, getmodule(mt))

    match = which(mt, tt)
    if meth !== match
        @warn "not reachable"
    end

    cache.override_aliases[meth] = typeof(f′)

    return
end

function Base.show(io::IO, ::MIME"text/plain", cc::CodeCache)
    print(io, "CodeCache with $(mapreduce(length, +, values(cc.dict); init=0)) entries")
    if !isempty(cc.dict)
        print(io, ": ")
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
    sig = Base.unwrap_unionall(mi.specTypes)
    ft, t... = [sig.parameters...]
    tt = Base.to_tuple_type(t)

    # check if we have any overrides for this method instance's function type
    actual_mi = mi
    if haskey(wvc.cache.override_table, ft)
        mt = wvc.cache.override_table[ft]
        if hasmethod(mt, t)
            match = which(mt, t)
            ft′ = wvc.cache.override_aliases[match]

            sig′ = Tuple{ft′, t...}
            meth = which(sig′)

            (ti, env) = ccall(:jl_type_intersection_with_env, Any,
                              (Any, Any), sig′, meth.sig)::Core.SimpleVector
            meth = Base.func_for_method_checked(meth, ti, env)
            actual_mi = ccall(:jl_specializations_get_linfo, Ref{Core.MethodInstance},
                (Any, Any, Any, UInt), meth, ti, env, wvc.worlds.min_world)
        end
    end

    # check the cache
    cache = wvc.cache
    for ci in get!(cache.dict, actual_mi, CodeInstance[])
        if ci.min_world <= wvc.worlds.min_world && wvc.worlds.max_world <= ci.max_world
            # TODO: if (code && (code == jl_nothing || jl_ir_flag_inferred((jl_array_t*)code)))
            return ci
        end
    end

    # if we want to override a method instance, eagerly put its replacement in the cache.
    # this is necessary, because we generally don't populate the cache, inference does,
    # and it won't put the replacement method instance in the cache by itself.
    if mi !== actual_mi
        # XXX: is this OK to do? shouldn't we _inform_ the compiler about the replacement
        # method instead of just spoofing the code instance? I tried to do so using a
        # MethodTableView, but the fact that the resulting MethodMatch referred the
        # replacement function, while there was still a GlobalRef in the IR pointing to
        # the original function, resulted in optimizer confusion.
        return ci_cache_populate(actual_mi, wvc.worlds.min_world, wvc.worlds.max_world)
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

    return ci
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

    # populate the cache
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
    if llvm_datalayout(job.target) !== nothing
        datalayout!(llvm_mod, llvm_datalayout(job.target))
    end

    return llvm_specfunc, llvm_mod
end

Base.empty!(cache::CodeCache) = empty!(cache.dict)
