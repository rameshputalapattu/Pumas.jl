using Unitful
using Markdown

"""
    Formulation

Type of formulations. There are IV (intravenous) and EV (extravascular).
"""
@enum Formulation IVBolus IVInfusion EV DosingUnknown
# Formulation behaves like scalar
Broadcast.broadcastable(x::Formulation) = Ref(x)
isiv(x) = x === IVBolus || x === IVInfusion

"""
  NCADose

`NCADose` takes the following arguments
- `time`: time of the dose
- `amt`: The amount of dosage
- `formulation`: Type of formulation, `NCA.IV` or `NCA.EV`
"""
struct NCADose{T,A,R,D}
  time::T
  amt::A
  rate::R
  duration::D
  formulation::Formulation
  function NCADose(time, amt, rate, duration, formulation)
    formulation′ = if formulation === EV
      EV
    else # IV
      has_rate = rate !== nothing && !iszero(rate)
      has_duration = rate !== nothing && !iszero(rate)
      (has_rate && has_duration) && throw(ArgumentError("Both duration and rate cannot be given at the same time"))
      has_rate || has_duration ? IVInfusion : IVBolus
    end
    return new{typeof(time), typeof(amt), typeof(rate), typeof(duration)}(time, amt, rate, duration, formulation′)
  end
end

# NCADose should behave like a scalar in broadcast
Broadcast.broadcastable(x::NCADose) = Ref(x)
Base.first(x::NCADose) = x

# any changes in here must be reflected to ./simple.jl, too
mutable struct NCASubject{C,T,TT,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}
  # allow id to be non-int, e.g. 001-100-1001 or STUD011001
  id::ID
  group::G
  conc::C
  # `time` will be time after dose (TAD) for multiple dosing, and it will be in
  # the form of [TAD₁, TAD₂, ..., TADₙ] where `TADᵢ` denotes the TAD for the
  # `i`th dose, which is a vector. Hence, `time` could be a vector of vectors.
  time::T
  # `abstime` is always a vector, and it leaves untouched except BLQ handling
  abstime::TT
  maxidx::I
  lastidx::I
  dose::D
  lambdaz::Z
  llq::N
  r2::F
  adjr2::F
  intercept::F
  firstpoint::tEltype
  points::P
  auc_last::AUC
  aumc_last::AUMC
  method::Symbol
end

"""
To be completed
"""
function NCASubject(conc′, time′;
                    concu=true, timeu=true,
                    id=1, group=nothing, dose::T=nothing, llq=nothing, clean=true,
                    lambdaz=nothing, kwargs...) where T
  if concu !== true || timeu !== true
    conc′ = map(x -> ismissing(x) ? x : x*concu, conc′)
    time′ = map(x -> ismissing(x) ? x : x*timeu, time′)
  end
  multidose = T <: AbstractArray && length(dose) > 1
  # we check monotonic later, because multidose could have TAD or TIME
  conc, time = clean ? cleanblq(conc′, time′; llq=llq, monotonictime=!multidose, kwargs...) : (conc′, time′)
  abstime = time # leave `abstime` untouched
  unitconc = oneunit(eltype(conc))
  unittime = oneunit(eltype(time))
  llq === nothing && (llq = zero(unitconc))
  auc_proto = -unitconc * unittime
  aumc_proto = auc_proto * unittime
  intercept = r2_proto = ustrip(unittime/unitconc)
  _lambdaz = inv(unittime)
  lambdaz_proto = lambdaz === nothing ? _lambdaz : lambdaz
  if multidose
    n = length(dose)
    ct = let time=time, dose=dose
      map(eachindex(dose)) do i
        idxs = ithdoseidxs(time, dose, i)
        clean && checkmonotonic(time, idxs)
        iszero(time[idxs[1]]) ? (conc[idxs], time[idxs]) : (conc[idxs], time[idxs].-time[idxs[1]])
      end
    end
    conc = map(x->x[1], ct)
    time = map(x->x[2], ct)
    maxidx  = map(c->conc_maximum(c, eachindex(c))[2], conc)
    lastidx = @. ctlast_idx(conc, time; llq=llq, check=false)
    return NCASubject{typeof(conc), typeof(time), typeof(abstime), eltype(time),
                      Vector{typeof(auc_proto)}, Vector{typeof(aumc_proto)},
                      typeof(dose), Vector{typeof(lambdaz_proto)},
                      Vector{typeof(r2_proto)}, typeof(llq), typeof(lastidx),
                      Vector{Int}, typeof(id), typeof(group)}(id, group,
                        conc, time, abstime, maxidx, lastidx, dose, fill(lambdaz_proto, n), llq,
                        fill(r2_proto, n), fill(r2_proto, n), fill(intercept, n),
                        fill(-unittime, n), fill(0, n),
                        fill(auc_proto, n), fill(aumc_proto, n), :___)
  end
  dose !== nothing && (dose = first(dose))
  _, maxidx = conc_maximum(conc, eachindex(conc))
  lastidx = ctlast_idx(conc, time; llq=llq, check=false)
  NCASubject{typeof(conc),   typeof(time), typeof(abstime), eltype(time),
          typeof(auc_proto), typeof(aumc_proto),
          typeof(dose),      typeof(lambdaz_proto),
          typeof(r2_proto),  typeof(llq), typeof(lastidx),
          Int, typeof(id), typeof(group)}(id, group,
            conc, time, abstime, maxidx, lastidx, dose, lambdaz_proto, llq,
            r2_proto,  r2_proto, intercept, unittime, 0,
            auc_proto, aumc_proto, :___)
end

showunits(nca::NCASubject, args...) = showunits(stdout, nca, args...)
function showunits(io::IO, ::NCASubject{C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}, indent=0) where {C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}
  pad   = " "^indent
  if D <: NCADose
    doseT = D.parameters[2]
  elseif D <: AbstractArray
    doseT = eltype(D).parameters[2]
  else
    doseT = D
  end
  multidose = D <: AbstractArray
  _C = multidose ? eltype(C) : C
  _T = multidose ? eltype(T) : T
  _AUC = multidose ? eltype(AUC) : AUC
  _AUMC = multidose ? eltype(AUMC) : AUMC
  _Z = multidose ? eltype(Z) : Z
  if eltype(_C) <: Quantity
    conct = string(unit(eltype(_C)))
    timet = string(unit(eltype(_T)))
    AUCt  = string(unit(_AUC))
    AUMCt = string(unit(_AUMC))
    Zt    = string(unit(_Z))
    Dt    = D === Nothing ? D : string(unit(doseT))
  else
    conct = nameof(eltype(_C))
    timet = nameof(eltype(_T))
    AUCt  = _AUC
    AUMCt = _AUMC
    Zt    = _Z
    Dt    = doseT
  end
  println(io, "$(pad)concentration: $conct")
  println(io, "$(pad)time:          $timet")
  println(io, "$(pad)auc:           $AUCt")
  println(io, "$(pad)aumc:          $AUMCt")
  println(io, "$(pad)λz:            $Zt")
  print(  io, "$(pad)dose:          $Dt")
end

function Base.show(io::IO, n::NCASubject)
  println(io, "NCASubject:")
  println(io, "  ID: $(n.id)")
  n.group === nothing || println(io, "  Group: $(n.group)")
  showunits(io, n, 4)
end

struct NCAPopulation{T<:NCASubject} <: AbstractVector{T}
  subjects::Vector{T}
end

Base.size(n::NCAPopulation) = size(n.subjects)
function Base.getindex(n::NCAPopulation, I...)
  subj = getindex(n.subjects, I...)
  subj isa Vector ? NCAPopulation(subj) : subj
end
Base.setindex!(n::NCAPopulation, X, I...) = setindex!(n.subjects, X, I...)
Base.show(io::IO, pop::NCAPopulation) = show(io, MIME"text/plain"(), pop)
function Base.show(io::IO, ::MIME"text/plain", pop::NCAPopulation)
  println(io, "NCAPopulation ($(length(pop)) subjects):")
  println(io, "  ID: $([subj.id for subj in pop])")
  first(pop).group === nothing || println(io, "  Group: $(unique([subj.group for subj in pop]))")
  showunits(io, first(pop), 4)
end

ismultidose(nca::NCASubject) = ismultidose(typeof(nca))
ismultidose(nca::NCAPopulation) = ismultidose(eltype(nca.subjects))
function ismultidose(::Type{NCASubject{C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}}) where {C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}
  return D <: AbstractArray
end

hasdose(nca::NCASubject) = hasdose(typeof(nca))
hasdose(nca::NCAPopulation) = hasdose(eltype(nca.subjects))
function hasdose(::Type{NCASubject{C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}}) where {C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}
  return D !== Nothing
end

# Summary and report
struct NCAReport{S,V}
  settings::S
  values::V
end

function NCAReport(nca::Union{NCASubject, NCAPopulation}; kwargs...)
  !hasdose(nca) && @warn "`dose` is not provided. No dependent quantities will be calculated"
  settings = Dict(:multidose=>ismultidose(nca), :subject=>(nca isa NCASubject))

  # Calculate summary values
  funcs = (lambdaz, lambdazr2, lambdazadjr2, lambdazintercept, lambdaznpoints, lambdaztimefirst,
   cmax, tmax, cmin, tmin, c0, clast, tlast, thalf, auc, aumc, auc_extrap_percent, aumc_extrap_percent,
   cl, clf, vss, vz, tlag, mrt, fluctation, accumulationindex,
   swing, bioav, tau, cavg, mat)
  names = map(nameof, funcs)
  values = NamedTuple{names}(f(nca; label = i==1, kwargs...) for (i, f) in enumerate(funcs))

  NCAReport(settings, values)
end

Base.summary(::NCAReport) = "NCAReport"

function Base.show(io::IO, report::NCAReport)
  println(io, summary(report))
  print(io, "  keys: $(keys(report.values))")
end

# units go under the header
to_dataframe(report::NCAReport) = convert(DataFrame, report)
function Base.convert(::Type{DataFrame}, report::NCAReport)
  report.settings[:subject] && return DataFrame(map(x->[x], report.values))
  hcat(report.values...)
end

to_markdown(report::NCAReport) = convert(Markdown.MD, report)
function Base.convert(::Type{Markdown.MD}, report::NCAReport)
  _io = IOBuffer()
  println(_io, "# Noncompartmental Analysis Report")
  println(_io, "PuMaS version " * string(Pkg.installed()["PuMaS"]))
  println(_io, "Julia version " * string(VERSION))
  println(_io, "")
  println(_io, "Date and Time: " * Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"))
  println(_io, "")

  println(_io, "## Calculation Setting")
  # TODO
  println(_io, "")

  println(_io, "## Calculated Values")
  println(_io, "|         Name         |    Value   |")
  println(_io, "|:---------------------|-----------:|")
  for entry in pairs(report.values)
    _name = string(entry[1])
    name = replace(_name, "_"=>"\\_") # escape underscore
    ismissing(entry[2]) && (@printf(_io, "| %s | %s |\n", name, "missing"); continue)
    for (i, v) in enumerate(entry[2])
      val = ismissing(v) ? v : round(ustrip(v), digits=2)*oneunit(v)
      @printf(_io, "| %s | %s |\n", name, val)
    end
  end
  return Markdown.parse(String(take!(_io)))
end

@recipe function f(subj::NCASubject{C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}; linear=true, loglinear=true) where {C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}
  istwoplots = linear && loglinear
  istwoplots && (layout --> (1, 2))
  hastitle = length(get(plotattributes, :title, [])) >= 2
  hasunits = eltype(C) <: Quantity
  timename = hasunits ? "Time ($(string(unit(eltype(T)))))" : "Time"
  xguide --> timename
  label --> subj.id
  vars = (ustrip.(subj.abstime), vcat(ustrip.(subj.conc)...))
  if linear
    @series begin
      concname = hasunits ? "Concentration ($(string(unit(eltype(C)))))" : "Concentration"
      yguide --> concname
      seriestype --> :path
      istwoplots && (subplot --> 1)
      _title = hastitle ? plotattributes[:title][1] : "Linear view"
      title := _title
      vars
    end
  end
  if loglinear
    @series begin
      yscale --> :log10
      seriestype --> :path
      istwoplots && (subplot --> 2)
      _title = hastitle ? plotattributes[:title][2] : "Semilogrithmic view"
      title := _title
      vars
    end
  end
end

@recipe function f(pop::NCAPopulation{NCASubject{C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}}; linear=true, loglinear=true) where {C,TT,T,tEltype,AUC,AUMC,D,Z,F,N,I,P,ID,G}
  istwoplots = linear && loglinear
  istwoplots && (layout --> (1, 2))
  hastitle = length(get(plotattributes, :title, [])) >= 2
  hasunits = eltype(C) <: Quantity
  timename = hasunits ? "Time ($(string(unit(eltype(T)))))" : "Time"
  xguide --> timename
  label --> [subj.id for subj in pop]
  linestyle --> :auto
  legend --> false
  timearr = [ustrip.(subj.abstime) for subj in pop]
  concarr = [vcat(map(x->ustrip.(x), subj.conc)...) for subj in pop]
  if linear
    @series begin
      concname = hasunits ? "Concentration ($(string(unit(eltype(C)))))" : "Concentration"
      yguide --> concname
      seriestype --> :path
      istwoplots && (subplot --> 1)
      _title = hastitle ? plotattributes[:title][1] : "Linear view"
      title := _title
      (timearr, concarr)
    end
  end
  if loglinear
    @series begin
      concname = hasunits ? "Concentration ($(string(unit(eltype(C)))))" : "Concentration"
      yguide --> concname
      yscale --> :log10
      seriestype --> :path
      istwoplots && (subplot --> 2)
      _title = hastitle ? plotattributes[:title][2] : "Semilogrithmic view"
      title := _title
      (timearr, concarr)
    end
  end
end
