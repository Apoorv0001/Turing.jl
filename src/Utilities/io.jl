#########################
# Sampler I/O Interface #
#########################

##########
# Sample #
##########

mutable struct Sample{Tvi}
    weight :: Float64     # particle weight
    lp::Float64
    lf_eps::Float64
    elapsed::Float64
    epsilon::Float64
    lf_num::Int
    eval_num::Int
    vi::Tvi
end
function Base.getproperty(s::Sample, f::Symbol)
    f === :value && return (s.lp, s.lf_eps, s.elapsed, s.epsilon, s.lf_num, s.eval_num, s.vi)
    return getfield(s, f)    
end
function Base.setproperty!(s::Sample, f::Symbol, v)
    if f === :value
        s.lp, s.lf_eps, s.elapsed, s.epsilon, s.lf_num, s.eval_num, s.vi = v
        return v
    end
    return setfield!(s, f, v)    
end

Base.getindex(s::Sample, v::Symbol) = getjuliatype(s, v)

function getjuliatype(s::Sample, v::Symbol, cached_syms=nothing)
    # NOTE: cached_syms is used to cache the filter entiries in svalue. This is helpful when the dimension of model is huge.
    if cached_syms == nothing
        # Get all keys associated with the given symbol
        syms = collect(Iterators.filter(k -> occursin(string(v)*"[", string(k)), keys(s.value)))
    else
        syms = collect((Iterators.filter(k -> occursin(string(v), string(k)), cached_syms)))
    end

    # Map to the corresponding indices part
    idx_str = map(sym -> replace(string(sym), string(v) => ""), syms)
    # Get the indexing component
    idx_comp = map(idx -> collect(Iterators.filter(str -> str != "", split(string(idx), [']','[']))), idx_str)

    # Deal with v is really a symbol, e.g. :x
    if isempty(idx_comp)
        @assert haskey(s.value, v)
        return Base.getindex(s.value, v)
    end

    # Construct container for the frist nesting layer
    dim = length(split(idx_comp[1][1], ','))
    if dim == 1
        sample = Vector(undef, length(unique(map(c -> c[1], idx_comp))))
    else
        d = max(map(c -> eval(parse(c[1])), idx_comp)...)
        sample = Array{Any, length(d)}(undef, d)
    end

    # Fill sample
    for i = 1:length(syms)
        # Get indexing
        idx = Main.eval(parse(idx_comp[i][1]))
        # Determine if nesting
        nested_dim = length(idx_comp[1]) # how many nested layers?
        if nested_dim == 1
        setindex!(sample, getindex(s.value, syms[i]), idx...)
        else  # nested case, iteratively evaluation
        v_indexed = Symbol("$v[$(idx_comp[i][1])]")
        setindex!(sample, getjuliatype(s, v_indexed, syms), idx...)
        end
    end
    sample
end

#########
# Chain #
#########

"""
    Chain(weight::Float64, value::Array{Sample})

A wrapper of output trajactory of samplers.

Example:

```julia
# Define a model
@model xxx begin
  ...
  return(mu,sigma)
end

# Run the inference engine
chain = sample(xxx, SMC(1000))

chain[:logevidence]   # show the log model evidence
chain[:mu]            # show the weighted trajactory for :mu
chain[:sigma]         # show the weighted trajactory for :sigma
mean(chain[:mu])      # find the mean of :mu
mean(chain[:sigma])   # find the mean of :sigma
```
"""
mutable struct Chain{R <: AbstractRange{Int}, Tsamples <: Array{<:Sample}} <: AbstractChains
    weight  ::  Float64                 # log model evidence
    value2  ::  Tsamples
    value   ::  Array{Float64, 3}
    range   ::  R # TODO: Perhaps change to UnitRange?
    names   ::  Vector{String}
    chains  ::  Vector{Int}
    info    ::  Dict{Symbol,Any}
end

function Chain()
    Chain{AbstractRange{Int}, Vector{Sample}}(
        0.0, 
        Vector{Sample}(), 
        Array{Float64, 3}(undef, 0, 0, 0), 
        0:0,
        Vector{String}(), 
        Vector{Int}(), 
        Dict{Symbol,Any}()
    )
end

function Chain(w::Real, s::Array{<:Sample})
    chn = Chain()
    chn.weight = w
    chn.value2 = deepcopy(s)

    chn = flatten!(chn)
    return chn
end

function flatten!(chn::Chain)
    ## Flatten samples into Mamba's chain type.
    local names = Vector{Array{AbstractString}}()
    local vals  = Vector{Array}()
    for s in chn.value2
        v, n = flatten(s)
        push!(vals, v)
        push!(names, n)
    end

    # Assuming that names[i] == names[j] for all (i,j)
    vals2 = [v[i] for v in vals, i=1:length(names[1])]
    vals2 = reshape(vals2, length(vals), length(names[1]), 1)
    c = Chains(vals2, names = names[1])
    chn.value = c.value
    chn.range = c.range
    chn.names = c.names
    chn.chains = c.chains
    return chn
end

# ind2sub is deprecated in Julia 1.0
ind2sub(v, i) = Tuple(CartesianIndices(v)[i])

function flatten(s::Sample)
    vals  = Vector{Float64}()
    names = Vector{AbstractString}()

    flatten(names, vals, "lp", s.lp)
    flatten(names, vals, "lf_eps", s.lf_eps)
    flatten(names, vals, "elapsed", s.elapsed)
    flatten(names, vals, "epsilon", s.epsilon)
    flatten(names, vals, "lf_num", s.lf_num)
    flatten(names, vals, "eval_num", s.eval_num)
    flatten(names, vals, "vi", s.vi)
    return vals, names
end
function flatten(names, value :: Array{Float64}, k :: String, v)
    if isa(v, Number)
        name = k
        push!(value, v)
        push!(names, name)
    elseif isa(v, Array)
        for i = eachindex(v)
            if isa(v[i], Number)
                name = k * string(ind2sub(size(v), i))
                name = replace(name, "(" => "[");
                name = replace(name, ",)" => "]");
                name = replace(name, ")" => "]");
                isa(v[i], Nothing) && println(v, i, v[i])
                push!(value, Float64(v[i]))
                push!(names, name)
            elseif isa(v[i], Array)
                name = k * string(ind2sub(size(v), i))
                flatten(names, value, name, v[i])
            else
                error("Unknown var type: typeof($v[i])=$(typeof(v[i]))")
            end
        end
  else
      error("Unknown var type: typeof($v)=$(typeof(v))")
  end
end

function Base.getindex(c::Chain, v::Symbol)
    # This strange implementation is mostly to keep backward compatability.
    #  Needs some refactoring a better format for storing results is available.
    if v == :logevidence
        log(c.weight)
    elseif v==:samples
        c.value2
    elseif v==:logweights
        c[:lp]
    else
        map((s)->Base.getindex(s, v), c.value2)
    end
end

function Base.getindex(c::Chain, expr::Expr)
    str = replace(string(expr), r"\(|\)" => "")
    @assert match(r"^\w+(\[(\d\,?)*\])+$", str) != nothing "[Turing.jl] $expr invalid for getindex(::Chain, ::Expr)"
    c[Symbol(str)]
end

function Base.vcat(c1::Chain, args::Chain...)
    names = c1.names
    all(c -> c.names == names, args) || throw(ArgumentError("chain names differ"))

    chains = c1.chains
    all(c -> c.chains == chains, args) || throw(ArgumentError("sets of chains differ"))

    value2 = cat(c1.value2, map(c -> c.value2, args)..., dims=1)
    Chain(0, value2)
end

function save!(c::Chain, spl, model, vi)
    c.info[:spl] = spl
    c.info[:model] = model
    c.info[:vi] = deepcopy(vi)
end

function resume(c::Chain, n_iter::Int)
    @assert !isempty(c.info) "[Turing] cannot resume from a chain without state info"
    sample(
        c.info[:model],
        c.info[:spl].alg;    # this is actually not used
        resume_from=c,
        reuse_spl_n=n_iter
    )
end
