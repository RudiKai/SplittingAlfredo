#ifndef AAI_GATES_MQH
#define AAI_GATES_MQH

//+------------------------------------------------------------------+
//| >>> T025 GATE REFACTOR: Gate Functions <<<                       |
//+------------------------------------------------------------------+

// --- Gate 1: Warmup ---
bool GateWarmup(string &reason_id)
{
    long bars_avail = Bars(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe);
    if(bars_avail < WarmupBars)
    {
        datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);
        if(g_last_ea_warmup_log_time != barTime)
        {
            PrintFormat("[WARMUP] t=%s sb_handle_ok=%d need=%d have=%d",
                        TimeToString(barTime), (sb_handle != INVALID_HANDLE), WarmupBars, (int)bars_avail);
            g_last_ea_warmup_log_time = barTime;
        }
        reason_id = "warmup";
        return false;
    }
    return true;
}

// --- Gate 2: Fixed Spread ---
bool GateSpread(string &reason_id)
{
    int currentSpread = CurrentSpreadPoints();
    if(currentSpread > MaxSpreadPoints)
    {
        static datetime last_spread_log_time = 0;
        datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
        if(barTime != last_spread_log_time)
        {
            PrintFormat("[SPREAD_BLK] t=%s spread=%d max=%d", TimeToString(barTime), currentSpread, MaxSpreadPoints);
            last_spread_log_time = barTime;
        }
        reason_id = "spread";
        if(g_stamp_spd != g_sb.closed_bar_time) { g_blk_spread++; g_stamp_spd = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}

// --- Gate 3: News ---
bool GateNews(double &conf_io, string &reason_id)
{
    datetime server_now = TimeCurrent();
    // CheckGate will modify conf_io if mode is PREFERRED and set flag for journaling
    if(!g_newsGate.CheckGate(server_now, conf_io, g_news_flag_for_bar))
    {
        reason_id = "news";
        if(g_stamp_news != g_sb.closed_bar_time){ g_blk_news++; g_stamp_news = g_sb.closed_bar_time; }
        return false; // Blocked
    }
    return true; // Passed (confidence may have been penalized)
}


// --- Daily RiskGuard state helper --------------------------------
bool AAI_DailyRiskGuardIsBlocking()
  {
   // "Blocking" means: RG is enabled + mode is REQUIRED + an active block is in effect.
   // This is used by the Mode/Scenario engine so the playbook can correctly display RISK_OFF
   // when daily RiskGuard hard-blocking is active.
   if(!InpRG_Enable) return false;
   if(InpRG_Mode != RG_REQUIRED) return false;

   // Keep day-anchor consistent (safe, cheap)
   RG_MaybeRollover();

   if(!g_rg_block_active) return false;

   // Expire hour-based blocks
   if(InpRG_BlockUntil==RG_BLOCK_FOR_HOURS && TimeCurrent() >= g_rg_block_until)
     {
      g_rg_block_active = false;
      return false;
     }

   // RG_BLOCK_TIL_END_OF_DAY remains active until rollover resets it
   return true;
  }






// --- Gate 4: Risk Guard (T030) ---
bool GateRiskGuard(double &conf_io, string &reason_id)
{
  g_rg_flag_for_bar = false;
  if(!InpRG_Enable || InpRG_Mode==RG_OFF) return true;

  // Rollover check
  MqlDateTime now;
  TimeToStruct(TimeCurrent(), now);
  MqlDateTime anchor_dt = now;
  anchor_dt.hour = InpRG_ResetHourServer;
  anchor_dt.min = 0;
  anchor_dt.sec = 0;
  datetime current_anchor = StructToTime(anchor_dt);
  if(current_anchor > TimeCurrent()) current_anchor -= 86400;
  if(current_anchor != g_rg_day_anchor_time)
  {
      RG_ResetDay();
      EA_ResetDay(); // T040: Also reset execution analytics counters
  }


  // If currently blocked and block time not expired, block
  if(g_rg_block_active && (InpRG_BlockUntil==RG_BLOCK_TIL_END_OF_DAY || TimeCurrent() < g_rg_block_until))
  {
    g_rg_flag_for_bar = true;
    reason_id = "risk";
    if(g_stamp_risk != g_sb.closed_bar_time) { g_blk_risk++; g_stamp_risk = g_sb.closed_bar_time; }
    return false;
  }

  // If a temporary block expired, unblock
  if(g_rg_block_active && InpRG_BlockUntil==RG_BLOCK_FOR_HOURS && TimeCurrent() >= g_rg_block_until)
  {
    g_rg_block_active = false;
  }

  // Compute running % drawdown vs start-of-day balance
  double startBal = (g_rg_day_start_balance>0.0 ? g_rg_day_start_balance : AccountInfoDouble(ACCOUNT_BALANCE));
  double dd_pct   = (startBal>0.0 ? (-g_rg_day_realized_pl / startBal) * 100.0 : 0.0);
  double dd_abs   = -g_rg_day_realized_pl; // positive when loss

  bool hit_pct  = (InpRG_MaxDailyLossPct   > 0.0 && dd_pct >= InpRG_MaxDailyLossPct);
  bool hit_abs  = (InpRG_MaxDailyLossMoney > 0.0 && dd_abs >= InpRG_MaxDailyLossMoney);
  bool hit_sls  = (InpRG_MaxSLHits         > 0   && g_rg_day_sl_hits >= InpRG_MaxSLHits);
  bool hit_seq  = (InpRG_MaxConsecLosses   > 0   && g_rg_consec_losses >= InpRG_MaxConsecLosses);

  bool tripped = (hit_pct || hit_abs || hit_sls || hit_seq);

  if(tripped)
  {
    g_rg_flag_for_bar = true;
    if(InpRG_Mode == RG_REQUIRED){
      reason_id = "risk";

      // Count new hard-block activations (not repeated checks while already blocked)
      if(!g_rg_block_active)
         AAI_rg_trips++;                           // <--- NEW

      g_rg_block_active = true;
      if(InpRG_BlockUntil==RG_BLOCK_FOR_HOURS)
         g_rg_block_until = TimeCurrent() + InpRG_BlockHours*3600;
      if(g_stamp_risk != g_sb.closed_bar_time) { g_blk_risk++; g_stamp_risk = g_sb.closed_bar_time; }
      return false; // hard block
    } else {
      conf_io = MathMax(0.0, conf_io - (double)InpRG_PrefPenalty); // soft penalty
      return true;
    }
  }

  return true;
}

// --- Gate 5: Position Health Watchdog (T037) ---
bool GatePHW(string &reason_id)
{
    if(!PHW_Enable) return true;

    // --- Daily Reset Logic ---
    MqlDateTime now_dt; TimeToStruct(TimeCurrent(), now_dt);
    MqlDateTime anchor_dt = now_dt;
    anchor_dt.hour = PHW_ResetHour; anchor_dt.min = 0; anchor_dt.sec = 0;
    datetime current_anchor = StructToTime(anchor_dt);
    if(current_anchor > TimeCurrent()) current_anchor -= 86400;
    if(current_anchor != g_phw_day_anchor)
    {
        g_phw_day_anchor = current_anchor;
        g_phw_repeats_today = 0;
    }

    // --- Check if currently in cooldown ---
    if(TimeCurrent() < g_phw_cool_until)
    {
        reason_id = "phw_cooldown";
        if(g_stamp_phw != g_sb.closed_bar_time) { g_blk_phw++; g_stamp_phw = g_sb.closed_bar_time; }
        return false;
    }

    // --- Check for new triggers on this bar ---
    bool trigger = false;
    string trigger_reason = "";
    string trigger_details = "";

    // Trigger 1: Spread Spike
    if(CurrentSpreadPoints() >= PHW_SpreadSpikePoints)
    {
        trigger = true;
        trigger_reason = "SPREAD_SPIKE";
        trigger_details = StringFormat("spread=%dpts", CurrentSpreadPoints());
    }

    // Trigger 2: Failure Burst
    if(!trigger && g_phw_fail_count >= PHW_FailBurstN)
    {
        trigger = true;
        trigger_reason = "FAIL_BURST";
        trigger_details = StringFormat("n=%d/%ds", g_phw_fail_count, PHW_FailBurstWindowSec);
    }

    // --- Take action if triggered ---
    if(trigger)
    {
        g_phw_repeats_today++;
        double cool_sec = MathMin(PHW_CooldownMaxSec, PHW_CooldownMinSec * MathPow(PHW_BackoffMultiplier, g_phw_repeats_today - 1));
        g_phw_cool_until = TimeCurrent() + (datetime)cool_sec;
        g_phw_last_trigger_ts = TimeCurrent();

        static datetime last_log_time = 0;
        if(g_sb.closed_bar_time != last_log_time)
        {
            PrintFormat("[WDG] sym=%s reason=%s %s backoff=%.1fx cooldown=%.0fs until=%s",
                        _Symbol,
                        trigger_reason,
                        trigger_details,
                        MathPow(PHW_BackoffMultiplier, g_phw_repeats_today - 1),
                        cool_sec,
                        TimeToString(g_phw_cool_until, TIME_MINUTES|TIME_SECONDS));
            last_log_time = g_sb.closed_bar_time;
        }
       
        if(StringFind(trigger_reason, "FAIL")!=-1) {
          ArrayResize(g_phw_fail_timestamps,0);
          g_phw_fail_count = 0;
        }

        reason_id = "phw_trigger";
        if(g_stamp_phw != g_sb.closed_bar_time) { g_blk_phw++; g_stamp_phw = g_sb.closed_bar_time; }
        return false;
    }

    return true;
}

// --- Gate 6: Session (with minute precision and pre-close block) ---
bool GateSession(string &reason_id)
{
    if(!SessionEnable) return true;
    
    int seconds_to_end = 0;
    if(!AAI_IsInsideAutoSession(seconds_to_end))
    {
        // We are outside the allowed day/time windows
        reason_id = "session";
        if(g_stamp_sess != g_sb.closed_bar_time) { g_stamp_sess = g_sb.closed_bar_time; }
        return false;
    }

    // NEW: Check if we are too close to the session end
    if(InpSession_BlockNewEntriesMins > 0 && seconds_to_end < InpSession_BlockNewEntriesMins * 60)
    {
        // We are inside the session, but too close to the end
        reason_id = "session_ending";
        if(g_stamp_sess != g_sb.closed_bar_time) { g_stamp_sess = g_sb.closed_bar_time; }
        return false;
    }

    return true;
}
// --- Gate 7: Over-extension ---
bool GateOverExtension(string &reason_id)
{
    static datetime last_overext_log_time = 0;
    double mid = 0, atr = 0, px = 0;

    double _tmp_ma_[1];
    if(CopyBuffer(g_hOverextMA, 0, 1, 1, _tmp_ma_) == 1) mid = _tmp_ma_[0];

    double _tmp_atr_[1];
    if(CopyBuffer(g_hATR, 0, 1, 1, _tmp_atr_) == 1) atr = _tmp_atr_[0];

    px = iClose(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);

    if(mid > 0 && atr > 0 && px > 0)
    {
        double up = mid + OverExt_ATR_Mult * atr;
        double dn = mid - OverExt_ATR_Mult * atr;
        const int direction = g_sb.sig;

        bool is_over_long = (direction > 0 && px > up);
        bool is_over_short = (direction < 0 && px < dn);

        if(OverExtMode == HardBlock)
        {
            if(is_over_long || is_over_short)
            {
                if(g_sb.closed_bar_time != last_overext_log_time)
                {
                    PrintFormat("[OVEREXT_BLK] t=%s dir=%d px=%.5f up=%.5f dn=%.5f", TimeToString(g_sb.closed_bar_time), direction, px, up, dn);
                    last_overext_log_time = g_sb.closed_bar_time;
                }
                reason_id = "overext";
                if(g_stamp_over != g_sb.closed_bar_time){ g_blk_over++; g_stamp_over = g_sb.closed_bar_time; }
                return false;
            }
        }
        else // WaitForBand
        {
            if(is_over_long || is_over_short)
            {
                g_overext_wait = OverExt_WaitBars;
            }

            if(g_overext_wait > 0)
            {
                if(px >= dn && px <= up) // Price re-entered the band
                {
                    g_overext_wait = 0;
                }
                else
                {
// ... inside GateOverExtension() ...
if(g_sb.closed_bar_time != g_last_overext_dec_sigbar)
{
    if(g_overext_wait > 0) // Only decrement if we are actively waiting
    {
        g_overext_wait--; 
    }
    g_last_overext_dec_sigbar = g_sb.closed_bar_time;
}

if(g_overext_wait > 0)
{
    // ... logging ...
    reason_id = "overext";
    if(g_stamp_over != g_sb.closed_bar_time){ g_blk_over++; g_stamp_over = g_sb.closed_bar_time; }
    return false;
}

                    if(g_sb.closed_bar_time != last_overext_log_time)
                    {
                        PrintFormat("[OVEREXT_WAIT] t=%s left=%d dir=%d", TimeToString(g_sb.closed_bar_time), g_overext_wait, direction);
                        last_overext_log_time = g_sb.closed_bar_time;
                    }
                    reason_id = "overext";
                    if(g_stamp_over != g_sb.closed_bar_time){ g_blk_over++; g_stamp_over = g_sb.closed_bar_time; }
                    return false;
                }
            }
        }
    }
    return true;
}

// --- Gate 8: Volatility Regime ---
bool GateVolatility(double &conf_io, string &reason_id)
{
    if(!InpVR_Enable || InpVR_Mode == VR_OFF) return true;

    double atrv[1];
    if(g_hATR_VR == INVALID_HANDLE || CopyBuffer(g_hATR_VR, 0, 1, 1, atrv) != 1) return true; // Fail open

    MqlRates rates[];
    if(CopyRates(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, 1, rates) != 1 || rates[0].close == 0) return true; // Fail open

    double atr_bps = (atrv[0] / rates[0].close) * 10000.0;
    bool out_of_band = (atr_bps < InpVR_MinBps || atr_bps > InpVR_MaxBps);

    if(out_of_band) g_vr_flag_for_bar = 1;

    if(!out_of_band) return true;

    if(InpVR_Mode == VR_REQUIRED) {
        reason_id = "vr";
        if(g_stamp_vr != g_sb.closed_bar_time){ g_blk_vr++; g_stamp_vr = g_sb.closed_bar_time; }
        return false;
    }

    // Mode is PREFERRED
    conf_io = MathMax(0.0, conf_io - InpVR_PrefPenalty);
    return true;
}

// --- Gate 9: Adaptive Spread (T028) ---
bool GateAdaptiveSpread(double &conf_io, string &reason_id)
{
  g_as_exceeded_for_bar = false;
  g_as_cap_pts_last = 0.0;

  if(!InpAS_Enable || InpAS_Mode==AS_OFF) return true;
  if(g_as_hist_count == 0) return true; // no history yet ? permissive

  // Build adaptive cap
  double med = AS_MedianOfHistory();       // points
  double cap = med * (1.0 + MathMax(0.0, InpAS_SafetyPct)) + (double)MathMax(0, InpAS_SafetyPts);

  if(InpAS_ClampToFixedMax){
    cap = (MaxSpreadPoints > 0 ? MathMin(cap, (double)MaxSpreadPoints) : cap);
  }

  g_as_cap_pts_last = cap;

  double spread_pts = (double)CurrentSpreadPoints();

  if(spread_pts > cap){
    g_as_exceeded_for_bar = true;
    if(InpAS_Mode == AS_REQUIRED){
      reason_id = "aspread";
      if(g_stamp_aspd != g_sb.closed_bar_time) { g_blk_aspread++; g_stamp_aspd = g_sb.closed_bar_time; }
      return false;
    }else{ // PREFERRED
      conf_io = MathMax(0.0, conf_io - (double)InpAS_PrefPenalty);
      return true;
    }
  }
  return true;
}


// --- Gate 10: Structure Proximity (T027) ---
bool GateStructureProximity(const int direction, double &conf_io, string &reason_id)
{
  g_sp_hit_for_bar = false;
  if(!InpSP_Enable || InpSP_Mode==SP_OFF) return true;

  // 1) Get threshold in POINTS
  double thr_pts = (double)InpSP_AbsPtsThreshold;
  if(InpSP_UseATR){
    double atrv[1];
    if(g_hATR_SP != INVALID_HANDLE && CopyBuffer(g_hATR_SP, 0, 1, 1, atrv)==1){
      thr_pts = (atrv[0] / _Point) * InpSP_ATR_Mult;
    }
  }
  if(thr_pts <= 0) return true; // be permissive

  // 2) Reference price: last closed bar close
  double c[1]; if(CopyClose(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, 1, c) != 1) return true;
  double px = c[0];

  // 3) Collect nearest distances (in POINTS) to enabled structures
  double min_dist_pts = DBL_MAX;

  // 3a) Round numbers (grid)
  if(InpSP_CheckRoundNumbers && InpSP_RoundGridPts > 0){
    const double grid_price = InpSP_RoundGridPts * _Point;
    double aligned = (MathFloor((px - InpSP_RoundOffsetPts*_Point)/grid_price) * grid_price) + InpSP_RoundOffsetPts*_Point;
    double rn_down = aligned;
    double rn_up   = aligned + grid_price;
    double d1 = MathAbs(px - rn_down) / _Point;
    double d2 = MathAbs(rn_up - px)   / _Point;
    min_dist_pts = MathMin(min_dist_pts, MathMin(d1, d2));
  }

  // 3b) Yesterday High/Low (D1, shift=1)
  if(InpSP_CheckYesterdayHighLow){
    double yh[1], yl[1];
    if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, yh)==1 && CopyLow(_Symbol, PERIOD_D1, 1, 1, yl)==1){
      double d_yh = MathAbs(px - (yh[0] - InpSP_YHYL_BufferPts*_Point))/_Point;
      double d_yl = MathAbs(px - (yl[0] + InpSP_YHYL_BufferPts*_Point))/_Point;
      min_dist_pts = MathMin(min_dist_pts, MathMin(d_yh, d_yl));
    }
  }

  // 3c) Weekly Open (W1 open of current week; value is fixed after week start)
  if(InpSP_CheckWeeklyOpen){
    double wo[1];
    if(CopyOpen(_Symbol, PERIOD_W1, 0, 1, wo)==1){ // W1 shift=0 open is stable through week
      double d_wo = MathAbs(px - (wo[0] - InpSP_WOpen_BufferPts*_Point))/_Point;
      min_dist_pts = MathMin(min_dist_pts, d_wo);
    }
  }

  // 3d) Recent swing points on SignalTimeframe
  if(InpSP_CheckSwings){
    double sw_hi = FindRecentSwingHigh(InpSP_SwingLookbackBars, InpSP_SwingLeg);
    double sw_lo = FindRecentSwingLow (InpSP_SwingLookbackBars, InpSP_SwingLeg);
    if(sw_hi>0) min_dist_pts = MathMin(min_dist_pts, MathAbs(px - sw_hi)/_Point);
    if(sw_lo>0) min_dist_pts = MathMin(min_dist_pts, MathAbs(px - sw_lo)/_Point);
  }

  // 4) Decide
  if(min_dist_pts <= thr_pts){
    g_sp_hit_for_bar = true;
    if(InpSP_Mode == SP_REQUIRED){
      reason_id = "struct";
      if(g_stamp_sp != g_sb.closed_bar_time){ g_blk_sp++; g_stamp_sp = g_sb.closed_bar_time; }
      return false; // BLOCK
    }else{ // PREFERRED
      conf_io = MathMax(0.0, conf_io - (double)InpSP_PrefPenalty);
      return true; // allow with penalty
    }
  }

  return true; // far enough from structure
}


// --- Gate 11: ZoneEngine ---
bool GateZE(const int direction, const double ze_strength, string &reason_id)
{
    if(ZE_Gate == ZE_REQUIRED && ze_strength < ZE_MinStrength)
    {
        reason_id = "ZE_REQUIRED";
        if(g_stamp_ze != g_sb.closed_bar_time){ g_blk_ze++; g_stamp_ze = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}

// --- Gate 12: SMC ---
bool GateSMC(const int direction, const int smc_sig, const double smc_conf, string &reason_id)
{
    if(SMC_Mode == SMC_REQUIRED)
    {
        if(smc_sig != direction || smc_conf < SMC_MinConfidence)
        {
            reason_id = "SMC_REQUIRED";
            if(g_stamp_smc != g_sb.closed_bar_time){ g_blk_smc++; g_stamp_smc = g_sb.closed_bar_time; }
            return false;
        }
    }
    return true;
}

// --- Gate 13: BiasCompass ---
bool GateBC(const int direction, const int bc_bias, string &reason_id)
{
    if(BC_AlignMode == BC_REQUIRED)
    {
        if(bc_bias != direction)
        {
            reason_id = "BC_REQUIRED";
            if(g_stamp_bc != g_sb.closed_bar_time){ g_blk_bc++; g_stamp_bc = g_sb.closed_bar_time; }
            return false;
        }
    }
    return true;
}

// --- Gate 14: Inter-Market Confirmation (T029) ---
bool GateInterMarket(const int direction, double &conf_io, string &reason_id)
{
  g_imc_flag_for_bar = false;
  g_imc_support = 1.0;

  if(!InpIMC_Enable || InpIMC_Mode==IMC_OFF) return true;

  // Compute weighted support [0..1] from configured confirmers
  g_imc_support = IMC_WeightedSupport(direction);

  if(g_imc_support < MathMin(1.0, MathMax(0.0, InpIMC_MinSupport)))
  {
    g_imc_flag_for_bar = true;
    if(InpIMC_Mode == IMC_REQUIRED){
      reason_id = "imc";         // inter-market confirmation
      if(g_stamp_imc != g_sb.closed_bar_time) { g_blk_imc++; g_stamp_imc = g_sb.closed_bar_time; }
      return false;              // BLOCK
    } else {
      conf_io = MathMax(0.0, conf_io - (double)InpIMC_PrefPenalty);
      return true;               // allow with penalty
    }
  }

  return true; // passed
}

// --- Gate 15: Equity Curve Feedback (T038) ---
bool GateECF(double &conf_io, string &reason_id)
{
    if(!ECF_Enable) return true;

    // --- Drawdown on closed-trade equity curve ---
    double dd_abs = AAI_peak - AAI_curve;
    double denom  = (AAI_peak != 0.0 ? MathAbs(AAI_peak) : 1.0);
    double dd_pct = 100.0 * (dd_abs / denom);

    // --- Determine multiplier from regime ---
    double mult = 1.0;

    // Penalty region (soft?hard)
    if(dd_pct >= ECF_DD_SoftPct)
    {
        // Map [Soft .. Hard] linearly to [1.0 .. MaxDnMult]
        double t = MathMin(1.0, (dd_pct - ECF_DD_SoftPct) / MathMax(1e-9, (ECF_DD_HardPct - ECF_DD_SoftPct)));
        mult = 1.0 - t * (1.0 - ECF_MaxDnMult);

        if(ECF_HardBlock && dd_pct >= ECF_DD_HardPct)
        {
            reason_id = "ecf";
            if(g_sb.closed_bar_time != g_stamp_ecf)
            {
                PrintFormat("[ECF] HARD_BLOCK dd=%.2f%% curve=%.2f peak=%.2f", dd_pct, AAI_curve, AAI_peak);
                g_stamp_ecf = g_sb.closed_bar_time;
            }
            return false;
        }
    }
    // Boost region (recent strength & near highs)
    else if(AAI_trades >= ECF_MinTradesForBoost && g_ecf_ewma > 0.0)
    {
        double boost = (1.0 - MathMin(1.0, dd_pct / ECF_DD_SoftPct)) * (ECF_MaxUpMult - 1.0);
        mult = 1.0 + boost;
    }

    // Apply and clamp confidence [0..100]
    if(mult != 1.0)
    {
        conf_io = MathMax(0.0, MathMin(100.0, conf_io * mult));
        if(g_sb.closed_bar_time != g_stamp_ecf && ECF_LogVerbose)
        {
            PrintFormat("[ECF] dd=%.2f%% ewma=%.2f mult=%.3f conf=%.1f", dd_pct, g_ecf_ewma, mult, conf_io);
            g_stamp_ecf = g_sb.closed_bar_time;
        }
    }
    return true;
}

// --- Gate 16: SL Cluster Cooldown (T039) ---
bool GateSLC(const int direction, string &reason_id)
{
    if(!SLC_Enable) return true;

    // --- Daily Reset Logic ---
    MqlDateTime now_dt; TimeToStruct(TimeCurrent(), now_dt);
    MqlDateTime anchor_dt = now_dt;
    anchor_dt.hour = SLC_ResetHour; anchor_dt.min = 0; anchor_dt.sec = 0;
    datetime current_anchor = StructToTime(anchor_dt);
    if(current_anchor > TimeCurrent()) current_anchor -= 86400;
    if(current_anchor != g_slc_day_anchor)
    {
        g_slc_day_anchor = current_anchor;
        g_slc_repeats_buy = 0;
        g_slc_repeats_sell = 0;
        g_slc_count_buy = 0;
        g_slc_count_sell = 0;
    }

    // --- Check Cooldown ---
    datetime cool_until = (direction > 0) ? g_slc_cool_until_buy : g_slc_cool_until_sell;
    if(TimeCurrent() < cool_until)
    {
        reason_id = "slc";
        if(g_stamp_slc != g_sb.closed_bar_time) { g_blk_slc++; g_stamp_slc = g_sb.closed_bar_time; }
        if(SLC_LogVerbose && g_stamp_slc == g_sb.closed_bar_time)
        {
            long remaining = cool_until - TimeCurrent();
            PrintFormat("[SLC] sym=%s dir=%d cool=%ds until=%s", _Symbol, direction, (int)remaining, TimeToString(cool_until));
        }
        return false;
    }

    return true;
}

bool GateConfidence(const double conf_eff, string &reason_id)
{
double min_conf_eff = AAI_EffectiveMinConf();
if(RTP_IS_DIAG && g_sb.closed_bar_time != g_stamp_conf) // once per bar
{
   PrintFormat("[CONF_DBG] t=%s conf=%.1f minconf_eff=%.1f clampMin=%.1f clampMax=%.1f vol=%s msm=%s",
      TimeToString(g_sb.closed_bar_time, TIME_DATE|TIME_MINUTES),
      conf_eff,
      min_conf_eff,
      Inp_MinConf_Min,
      Inp_MinConf_Max,
      AAI_VolRegimeName(AAI_regime_vol),
      AAI_MSMRegimeName(AAI_regime_msm)
   );
   g_stamp_conf = g_sb.closed_bar_time;
}


    if(conf_eff < min_conf_eff)
    {
        reason_id = "confidence";
        if(g_stamp_conf != g_sb.closed_bar_time){ g_stamp_conf = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}
// --- Gate XX: Playbook scenario allow_entries ------------------------
bool GatePlaybookScenario(const double conf_eff, string &reason_id)
{
   // Build current context and scenario
   AAI_Context ctx;
   AAI_FillContext(ctx);
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   // Fill playbook for this context
   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   // If this scenario is not allowed to enter, block here
   if(!pb.allow_entries)
     {
      reason_id = "pb_scenario_block";

      // Optional: verbose log, controlled by your existing flag
      if(InpPB_DebugRiskLog)
        {
         PrintFormat(
            "[PB_BLOCK] sym=%s scn=%s allow_entries=%s conf=%.1f",
            _Symbol,
            AAI_ScenarioName(scn),
            (pb.allow_entries ? "true" : "false"),
            conf_eff
         );
        }

      return false;
     }

   return true;
}




// --- Gate XX: Streak / Cooldown guard --------------------------------
bool GateStreakGuard(const double conf_eff, string &reason_id)
  {
   if(!InpStreak_Enable)
      return true;

   if(AAI_streak_cooldown_until <= 0)
      return true;

   datetime now = TimeCurrent();
   if(now >= AAI_streak_cooldown_until)
     {
      // Cooldown expired; reset
      AAI_streak_cooldown_until   = 0;
      AAI_streak_loss_count       = 0;
      AAI_streak_dd_pct           = 0.0;
      AAI_streak_softlanding_armed= false;
      return true;
     }


   reason_id = "streak";
   return false;
  }

// --- Gate 18: Cooldown ---
bool GateCooldown(const int direction, string &reason_id)
{
    int secs = PeriodSeconds((ENUM_TIMEFRAMES)SignalTimeframe);
    datetime until = (direction > 0) ? g_cool_until_buy : g_cool_until_sell;
    int delta = (int)(until - g_sb.closed_bar_time);
    int bars_left = (delta <= 0 || secs <= 0) ? 0 : ((delta + secs - 1) / secs);
    if(bars_left > 0)
    {
        reason_id = "cooldown";
        if(g_stamp_cool != g_sb.closed_bar_time){ g_stamp_cool = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}

// --- Gate 19: Debounce ---
bool GateDebounce(const int direction, string &reason_id)
{
    if(PerBarDebounce)
    {
        bool is_duplicate = (direction > 0)
                              ? (g_last_entry_bar_buy == g_sb.closed_bar_time)
                              : (g_last_entry_bar_sell == g_sb.closed_bar_time);
        if(is_duplicate)
        {
            reason_id = "same_bar";
            if(g_stamp_bar != g_sb.closed_bar_time){ g_stamp_bar = g_sb.closed_bar_time; }
            return false;
        }
    }
    return true;
}


// --- Hedging utilities ---
int CountMyPositions(const string sym, const long magic, int &longCnt, int &shortCnt)
{
   longCnt = 0; shortCnt = 0; int total = 0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      int t = (int)PositionGetInteger(POSITION_TYPE);
      if(t == POSITION_TYPE_BUY)  ++longCnt;
      if(t == POSITION_TYPE_SELL) ++shortCnt;
      ++total;
   }
   return total;
}

double LastEntryPriceOnSide(const string sym, const long magic, const bool isLong)
{
   datetime lastTime = 0; double px = 0.0;
   uint total = HistoryDealsTotal();
   for(int i = (int)total-1; i >= 0; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != sym) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != magic) continue;
      int tp = (int)HistoryDealGetInteger(deal, DEAL_TYPE);
      if( (isLong && tp == DEAL_TYPE_BUY) || (!isLong && tp == DEAL_TYPE_SELL) )
      {
         datetime when = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         if(when > lastTime){ lastTime = when; px = HistoryDealGetDouble(deal, DEAL_PRICE); }
      }
   }
   return px;
}

double ComputePositionRiskPct(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;
   const string sym = PositionGetString(POSITION_SYMBOL);
   const double vol = PositionGetDouble(POSITION_VOLUME);
   const double sl  = PositionGetDouble(POSITION_SL);
   const double op  = PositionGetDouble(POSITION_PRICE_OPEN);
   const int    typ = (int)PositionGetInteger(POSITION_TYPE);
   if(sl <= 0.0 || vol <= 0.0) return 0.0;

   const double dist_pts = MathAbs( (typ==POSITION_TYPE_BUY ? op-sl : sl-op) ) / _Point;
   const double tick_val = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   const double tick_sz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   const double money_per_point = (tick_sz > 0.0 ? (tick_val/tick_sz) : tick_val) * vol;
   const double money_risk = dist_pts * money_per_point;
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return (eq > 0.0 ? 100.0 * money_risk / eq : 0.0);
}

double ComputeAggregateRiskPct(const string sym, const long magic)
{
   double acc = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      acc += ComputePositionRiskPct(ticket);
   }
   return acc;
}


// --- Gate 20: Position (hedging-aware) ---
bool GatePosition(string &reason_id)
{
    if(!InpHEDGE_AllowMultiple)
    {
        if(PositionSelect(_Symbol)) { reason_id = "position_exists"; return false; }
        return true;
    }

    int dir = g_sb.sig; // -1 sell, +1 buy (from SB cache)
    int longCnt, shortCnt;
    const int total = CountMyPositions(_Symbol, (long)MagicNumber, longCnt, shortCnt);

    if(total >= InpHEDGE_MaxPerSymbol)                  { reason_id="hedge_cap_total";  return false; }
    if(dir>0 && longCnt  >= InpHEDGE_MaxLongPerSymbol)  { reason_id="hedge_cap_long";   return false; }
    if(dir<0 && shortCnt >= InpHEDGE_MaxShortPerSymbol) { reason_id="hedge_cap_short";  return false; }

    if(!InpHEDGE_AllowOpposite)
    {
        if( (dir>0 && shortCnt>0) || (dir<0 && longCnt>0) ) { reason_id="hedge_no_opposite"; return false; }
    }

    if(InpHEDGE_MinStepPips>0 && dir!=0)
    {
        const bool isLong = (dir>0);
        const double lastPx = LastEntryPriceOnSide(_Symbol, (long)MagicNumber, isLong);
        if(lastPx>0.0)
        {
            const double pxNow = (isLong ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
            const double stepPips = MathAbs(pxNow - lastPx) / PipSize();
            if(stepPips < InpHEDGE_MinStepPips) { reason_id="hedge_step_too_small"; return false; }
        }
    }

    if(InpHEDGE_MaxAggregateRiskPct>0.0)
    {
        const double agg = ComputeAggregateRiskPct(_Symbol, (long)MagicNumber);
        if(agg >= InpHEDGE_MaxAggregateRiskPct) { reason_id="hedge_agg_risk_cap"; return false; }
    }
    return true;
}


// --- Gate 21: Trigger ---
bool GateTrigger(const int direction, const int prev_sb_sig, string &reason_id)
{
    bool is_edge = (direction != prev_sb_sig);
    if(EntryMode == FirstBarOrEdge && !g_bootstrap_done)
    {
        return true; // Bootstrap trigger
    }
    if(is_edge)
    {
        return true; // Edge trigger
    }

    reason_id = "no_trigger";
    return false;
}

#endif // AAI_GATES_MQH
