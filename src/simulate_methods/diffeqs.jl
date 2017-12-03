function simulate(_prob::ODEProblem,set_parameters,θ,ηi,datai::Person,
                  output_reduction = (sol,p,datai) -> sol,
                  alg = Tsit5();kwargs...)
  VarType = promote_type(eltype(ηi),eltype(θ))
  p = set_parameters(θ,ηi,datai.z)
  target_time,cb = ith_patient_cb(p,datai,_prob)
  tstops = [_prob.tspan[1];target_time]
  # From problem_new_parameters but no callbacks

  true_f = DiffEqWrapper(_prob,p)
  # Match the type of ηi for duality in estimator
  prob = ODEProblem(true_f,VarType.(_prob.u0),VarType.(_prob.tspan),callback=cb)
  save_start = true#datai.events[1].ss == 1
  sol = solve(prob,alg;save_start=save_start,tstops=tstops,kwargs...)
  output_reduction(sol,sol.prob.f.params,datai)
end

function ith_patient_cb(p,datai,prob)

  ss_tol = 1e-12 # TODO: Make an option
  ss_max_iters = Inf

  if haskey(p,:bioav)
    bioav = p.bioav
  else
    bioav = one(eltype(prob.u0))
  end

  target_time,events,tstop_times = adjust_event_timings(datai,p,bioav)

  counter = 1
  steady_state_mode = Ref(false)
  steady_state_time = Ref(-one(eltype(tstop_times)))
  steady_state_end = Ref(-one(eltype(tstop_times)))
  steady_state_rate_end = Ref(-one(eltype(tstop_times)))
  steady_state_cache = similar(prob.u0)
  steady_state_ii = Ref(-one(eltype(tstop_times)))
  steady_state_overlap_duration = Ref(-one(eltype(tstop_times)))
  post_steady_state = Ref(false)
  ss_counter = Ref(0)
  ss_event_counter = Ref(0)
  ss_rate_multiplier = Ref(0)
  ss_dropoff_counter = Ref(0)

  # searchsorted is empty iff t ∉ target_time
  # this is a fast way since target_time is sorted
  function condition(t,u,integrator)
    (post_steady_state[] && t == (steady_state_time[] + steady_state_overlap_duration[] + ss_dropoff_counter[]*steady_state_ii[])) ||
    t == steady_state_rate_end[] || (steady_state_mode[] ? t == steady_state_end[] : !isempty(searchsorted(tstop_times,t)))
  end

  function affect!(integrator)
    while counter <= length(target_time) && target_time[counter].time <= integrator.t
      cur_ev = events[counter]
      @inbounds if (cur_ev.evid == 1 || cur_ev.evid == -1) && cur_ev.ss == 0
        savevalues!(integrator)
        if cur_ev.rate == 0
          if typeof(bioav) <: Number
            integrator.u[cur_ev.cmt] += bioav*cur_ev.amt
          else
            integrator.u[cur_ev.cmt] += bioav[cur_ev.cmt]*cur_ev.amt
          end
          savevalues!(integrator)
        else
          integrator.f.rates_on[] += cur_ev.evid > 0
          integrator.f.rates[cur_ev.cmt] += cur_ev.rate
        end
        counter += 1
      elseif cur_ev.ss > 0
        if !steady_state_mode[]
          savevalues!(integrator)
          # This is triggered at the start of a steady-state event
          steady_state_mode[] = true
          integrator.f.rates .= 0
          ss_counter[] = 0
          integrator.opts.save_everystep = false
          post_steady_state[] = false
          steady_state_time[] = integrator.t
          # TODO: Handle saveat in this range
          # TODO: Make compatible with save_everystep = false
          if typeof(bioav) <: Number
            duration = (bioav*cur_ev.amt)/cur_ev.rate
          else
            duration = (bioav[cur_ev.amt]*cur_ev.amt)/cur_ev.rate
          end
          steady_state_overlap_duration[] = mod(duration,cur_ev.ii)
          steady_state_ii[] = cur_ev.ii
          steady_state_end[] = integrator.t + cur_ev.ii
          cur_ev.rate != 0 && (ss_rate_multiplier[] = 1 + (duration ÷ cur_ev.ii))
          steady_state_rate_end[] = integrator.t + steady_state_overlap_duration[]
          steady_state_cache .= integrator.u
          steady_state_dose(integrator,cur_ev,bioav,ss_rate_multiplier,steady_state_rate_end)
          add_tstop!(integrator,steady_state_end[])
          cur_ev.rate != 0 && add_tstop!(integrator,steady_state_rate_end[])
        elseif integrator.t == steady_state_end[]
          integrator.t = steady_state_time[]
          steady_state_cache .-= integrator.u
          if ss_counter[] == ss_max_iters || integrator.opts.internalnorm(steady_state_cache) < ss_tol
            # Steady state complete
            steady_state_mode[] = false
            # TODO: Make compatible with save_everystep = false
            post_steady_state[] = true
            integrator.f.rates .= 0
            integrator.opts.save_everystep = true
            cur_ev.ss == 2 && (integrator.u .+= integrator.sol.u[end])
            steady_state_dose(integrator,cur_ev,bioav,ss_rate_multiplier,steady_state_rate_end)
            if cur_ev.rate != 0
              for k in 0:ss_rate_multiplier[]-1
                println(integrator.t + steady_state_overlap_duration[] + k*steady_state_ii[])
                add_tstop!(integrator,integrator.t + steady_state_overlap_duration[] + k*steady_state_ii[])
              end
              ss_dropoff_counter[] = 0
            end
            ss_event_counter[] = counter
            counter += 1
            post_steady_state[] = true
          else
            steady_state_cache .= integrator.u
            ss_counter[] += 1
            steady_state_dose(integrator,cur_ev,bioav,ss_rate_multiplier,steady_state_rate_end)
            steady_state_rate_end[] < steady_state_end[] && add_tstop!(integrator,steady_state_rate_end[])
            #add_tstop!(integrator,steady_state_end[])
          end
        elseif integrator.t == steady_state_rate_end[]
          integrator.f.rates[cur_ev.cmt] -= cur_ev.rate
          integrator.f.rates_on[] = (ss_rate_multiplier[] > 1)
        end
        break
      elseif cur_ev.evid == 2
        #ignore for now
        counter += 1
      end
    end
    if post_steady_state[] && integrator.t == steady_state_time[] + steady_state_overlap_duration[] + ss_dropoff_counter[]*steady_state_ii[]
      ss_dropoff_counter[] += 1
      ss_dropoff_counter[] == ss_rate_multiplier[]+1 && (post_steady_state[] = false)
      ss_event = events[ss_event_counter[]]
      integrator.f.rates[ss_event.cmt] -= ss_event.rate
      println(steady_state_time[] + steady_state_overlap_duration[] + ss_dropoff_counter[]*steady_state_ii[])
      # TODO: Optimize by setting integrator.f.rates_on[] = false
    end
    flush(STDOUT)
  end
  tstop_times,DiscreteCallback(condition, affect!, initialize = patient_cb_initialize!,
                               save_positions=(false,false))
end

function steady_state_dose(integrator,cur_ev,bioav,ss_rate_multiplier,steady_state_rate_end)
  if cur_ev.rate != 0
    integrator.f.rates_on[] = true
    integrator.f.rates[cur_ev.cmt] = ss_rate_multiplier[]*cur_ev.rate
  else
    if typeof(bioav) <: Number
      integrator.u[cur_ev.cmt] += bioav*cur_ev.amt
    else
      integrator.u[cur_ev.cmt] += bioav[cur_ev.cmt]*cur_ev.amt
    end
  end
end


function patient_cb_initialize!(cb,t,u,integrator)
  if cb.condition(t,u,integrator)
    cb.affect!(integrator)
  end
end

function get_all_event_times(data)
  total_times = copy(data[1].event_times)
  for i in 2:length(data)
    for t in data[i].event_times
      t ∉ total_times && push!(total_times,t)
    end
  end
  total_times
end

struct DiffEqWrapper{F,P,rateType} <: Function
  f::F
  params::P
  rates_on::Ref{Int}
  rates::Vector{rateType}
end
function (f::DiffEqWrapper)(t,u)
  out = f.f(t,u,f.params)
  if f.rates_on[] > 0
    return out + rates
  else
    return out
  end
end
function (f::DiffEqWrapper)(t,u,du)
  f.f(t,u,f.params,du)
  f.rates_on[] > 0 && (du .+= f.rates)
end
DiffEqWrapper(prob,p) = DiffEqWrapper(prob.f,p,Ref(0),zeros(prob.u0))
DiffEqWrapper(f::DiffEqWrapper,p) = DiffEqWrapper(f.f,p,Ref(0),f.rates)
