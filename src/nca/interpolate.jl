function interpextrapconc(conc, time, timeout; lambdaz=nothing,
                          clast=nothing, interpmethod=nothing,
                          extrapmethod=:AUCinf, concblq=nothing,
                          missingconc=:drop, check=true, kwargs...)
  if check
    checkconctime(conc, time) # TODO: blq
    conc, time = cleanmissingconc(conc, time, missingconc=missingconc, check=false)
  end
  lambdaz == nothing && (lambdaz = find_lambdaz(conc, time; kwargs...)[1])
  clast, tlast = ctlast(conc, time, check=false)
  isempty(timeout) && throw(ArgumentError("timeout must be a vector with at least one element"))
  out = timeout isa AbstractArray ? fill!(similar(timeout), 0) : zero(timeout)
  for i in eachindex(out)
    if ismissing(out[i])
      @warn warning("Interpolation/extrapolation time is missing at the $(i)th index")
    elseif timeout[i] <= tlast
      _out = interpolateconc(conc, time, timeout[i], interpmethod=interpmethod,
                      concblq=concblq, missingconc=missingconc, check=false)
      out isa AbstractArray ? (out[i] = _out) : (out = _out)
    else
      _out = extrapolateconc(conc, time, timeout[i], extrapmethod=extrapmethod, lambdaz=lambdaz,
                      concblq=concblq, missingconc=missingconc, check=false)
      out isa AbstractArray ? (out[i] = _out) : (out = _out)
    end
  end
  return out
end

function interpolateconc(conc, time, timeout::Number; interpmethod,
                         concblq=nothing, missingconc=:drop, concorigin=0, check=true)
  if check
    checkconctime(conc, time)
    cleanmissingconc(conc, time, check=false, missingconc=missingconc)
    #cleanconcblq(...)
  end
  len = length(time)
  !(concorigin isa Number) && !(concorigin isa Bool) && throw(ArgumentError("concorigin must be a scalar"))
  _, tlast = ctlast(conc, time, check=false)
  !(interpmethod in (:linear, :linuplogdown)) && throw(ArgumentError("Interpolation method must be :linear or :linuplogdown"))
  if timeout < first(time)
    return concorigin
  elseif timeout > tlast
    throw(ArgumentError("interpolateconc can only works through Tlast, please use interpextrapconc to combine both interpolation and extrapolation"))
  elseif (idx=searchsortedfirst(time, timeout)) != len+1 # if there is an exact time match
    return conc[idx]
  else
    idx1 = findlast( t->t<=timeout, time)
    idx2 = idx1 + 1
    idx2 > len && error("something went wrong, please file a bug report")
    #idx2 = findfirst(t->timeout<=t, time)
    time1 = time[idx1]; time2 = conc[idx2]
    conc1 = conc[idx1]; conc2 = conc[idx2]
    if (interpmethod === :linear || interpmethod === :linuplogdown) &&
      (conc1 <= 0 || conc2 <= 0) ||
        (conc1 <= conc2)
      # Do linear interpolation if:
      #   linear interpolation is selected or
      #   lin up/log down interpolation is selected and
      #     one concentration is 0 or
      #     the concentrations are equal
      return conc1+(timeout-time1)/(time2-time1)*(conc2-conc1)
    elseif interpmethod === :linuplogdown
      return exp(log(conc1)+(timeout-time1)/(time2-time1)*(log(conc2)-log(conc1)))
    else
      error("You should never see this error. Please report this as a bug with a reproducible example.")
      return nothing
    end
  end
end

function extrapolateconc(conc, time, timeout::Number; lambdaz=nothing, clast=nothing, extrapmethod=:AUCinf,
                         missingconc=:drop, concblq=nothing, check=true)
  if check
    checkconctime(conc, time) # TODO: blq
    conc, time = cleanmissingconc(conc, time, missingconc=missingconc, check=false)
  end
  clast, tlast = clast === nothing ? ctlast(conc, time) : (clast, ctlast(conc, time)[end])
  !(extrapmethod in (:AUCinf, :AUCall)) &&
    throw(ArgumentError("extrapmethod must be one of AUCinf or AUCall"))
  if timeout <= tlast
    throw(ArgumentError("extrapolateconc can only work beyond Tlast, please use interpextrapconc to combine both interpolation and extrapolation"))
  else
    if extrapmethod === :AUCinf
      # If AUCinf is requested, extrapolate using the half-life
      return clast*exp(-lambdaz*(timeout - tlast))
    elseif extrapmethod === :AUCall && tlast == (maxtime=maximum(time))
      # If AUCall is requested and there are no BLQ at the end, we are already
      # certain that we are after Tlast, so the answer is 0.
      return oneunit(eltype(conc))*false
    elseif extrapmethod === :AUCall
      # If the last non-missing concentration is below the limit of
      # quantification, extrapolate with the triangle method of AUCall.
      previdx = findlast(t->t<=timeout, time)
      timeprev, concprev = time[previdx], concprev[previdx]
      if iszero(concprev)
        return oneunit(eltype(conc))*false
      else
        # If we are not already BLQ, then we have confirmed that we are in the
        # triangle extrapolation region and need to draw a line.
        #if timeprev != maxtime
          nextidx = findfirst(t->t=>timeout, time)
          timenext, concnext = time[nextidx], conc[nextidx]
        #end
        return (timeout - timeprev)/(timenext - timeprev)*concprev
      end
    else
      error("Invalid extrap.method caught too late (seeing this error indicates a software bug)")
      return nothing
    end
  end
end
