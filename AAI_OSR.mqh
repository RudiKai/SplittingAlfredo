#ifndef AAI_OSR_MQH
#define AAI_OSR_MQH

//| >>> T031: Order Send Robustness Helpers <<<                      |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

  if(step > 0){
    lots = MathFloor((lots/step) + 1e-9) * step; // snap down to grid
    int prec = (int)MathMax(0, MathCeil(-MathLog10(step)) + 2);
    lots = NormalizeDouble(lots, prec);
  }

  return MathMax(minv, MathMin(maxv, lots));
}


double NormalizePriceByTick(double price)
{
  double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  if(tick <= 0.0) return NormalizeDouble(price, _Digits);
  // Snap to tick grid
  double n = MathRound(price / tick);
  return n * tick;
}
bool OSR_ReducePosition(ulong pos_ticket, int position_dir, double lots, MqlTradeResult &res)
{
  ZeroMemory(res);
  MqlTradeRequest rq; ZeroMemory(rq);
  rq.action       = TRADE_ACTION_DEAL;
  rq.symbol       = _Symbol;
  rq.volume       = NormalizeLots(lots);
  rq.type         = (position_dir>0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY); // opposite
  rq.position     = pos_ticket; // ? ensure reduction, not hedge
  rq.type_filling = ResolveMarketFill((int)InpOSR_FillMode);
  rq.deviation    = (ulong)EA_GetAdaptiveDeviation();
  rq.magic        = MagicNumber;
  rq.comment      = "PT reduce";

  bool sent = OrderSend(rq, res);
  EA_LogSendResult(res.retcode);
  return sent && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL);
}
// -----------------------------------------------------------------------------
// Input sanity checks - prints warnings for likely misconfigurations.
// Safe: only logs EVT_WARN (no runtime behavior changes).
// Call from OnInit() once: CheckInputLogic();
// -----------------------------------------------------------------------------
void CheckInputLogic()
{
   // Helper shorthand for logging
   #define WARN(msg) PrintFormat("[EVT_WARN] %s", msg)

   // 1) PT ordering / thresholds
   if(InpPT_Enable)
   {
      if(InpPT1_Enable && InpPT2_Enable && InpPT2_TriggerRR <= InpPT1_TriggerRR)
         WARN("PT2 TriggerRR <= PT1 TriggerRR — check PT ordering (PT2 should be > PT1).");
      if(InpPT2_Enable && InpPT3_Enable && InpPT3_TriggerRR <= InpPT2_TriggerRR)
         WARN("PT3 TriggerRR <= PT2 TriggerRR — check PT ordering (PT3 should be > PT2).");
      if(InpPT1_ClosePct + InpPT2_ClosePct + InpPT3_ClosePct > 100.0)
         WARN("Sum of PT close percentages > 100% (InpPT1_ClosePct + InpPT2_ClosePct + InpPT3_ClosePct).");
      if(InpPT_MinStepPts <= 0)
         WARN("InpPT_MinStepPts <= 0 — consider setting a positive minimum step size.");
   }

   // 2) SLA / BE coherence
   if(InpPT_Enable && InpTRL_BE_Enable && !InpTRL_Enable)
      WARN("InpTRL_BE_Enable is true but InpTRL_Enable is false (BE will not run).");

   if(InpPT_Enable && InpPT_SLA_UseATR && InpPT_SLA_ATR_Mult <= 0.0)
      WARN("InpPT_SLA_UseATR true but InpPT_SLA_ATR_Mult <= 0 (ATR multiplier should be > 0).");

   // 3) TRL coherence
   if(InpTRL_Enable)
   {
      if(InpTRL_ATR_Mult <= 0.0)
         WARN("InpTRL_ATR_Mult <= 0 — trail multiplier should be positive.");
      if(InpTRL_ATR_Mult_AfterPT2 > 0.0 && InpTRL_ATR_Mult_AfterPT2 > InpTRL_ATR_Mult)
         WARN("InpTRL_ATR_Mult_AfterPT2 is greater than base InpTRL_ATR_Mult and may loosen the trail after PT2.");
      if(InpTRL_ATR_Mult_AfterPT3 > 0.0 && InpTRL_ATR_Mult_AfterPT3 > InpTRL_ATR_Mult)
         WARN("InpTRL_ATR_Mult_AfterPT3 is greater than base InpTRL_ATR_Mult and may loosen the trail after PT3.");
   }

   // 4) VAPT and PT scaling
   if(InpVAPT_Enable)
   {
      if(InpVAPT_PTScaleHot < 1.0)
         WARN("InpVAPT_PTScaleHot < 1.0 — hot scaling < 1 will shrink PT floors in hot regimes.");
      if(InpVAPT_BEScaleHot < 1.0)
         WARN("InpVAPT_BEScaleHot < 1.0 — hot BE scaling < 1 will reduce BE offsets in hot regimes.");
      if(InpVAPT_ArmAfterSec < 0)
         WARN("InpVAPT_ArmAfterSec < 0 — should be >= 0.");
   }

   // 5) Lot sizing / CRC
   if(InpCRC_Enable)
   {
      if(InpCRC_MinLots <= 0.0)
         WARN("InpCRC_MinLots <= 0 — minimum lots must be > 0.");
      if(InpCRC_MaxLots < InpCRC_MinLots)
         WARN("InpCRC_MaxLots < InpCRC_MinLots — max lots smaller than min lots.");
      if(InpCRC_MinRiskPct <= 0.0 || InpCRC_MinRiskPct > 100.0)
         WARN("InpCRC_MinRiskPct should be within (0..100].");
   }

   // 6) Session / AZ (end-of-day) coherence
   if(SessionEnable && InpAZ_TTL_Enable && InpAZ_SessionForceFlat && (InpAZ_TTL_Hours <= 0))
      WARN("InpAZ_TTL_Hours <= 0 while InpAZ_TTL_Enable is true — check session TTL hours.");

   // 7) OSR / HM / Execution sanity
   if(InpOSR_RepriceOnRetry && InpOSR_MaxRetries <= 0)
      WARN("InpOSR_RepriceOnRetry=true but InpOSR_MaxRetries <= 0 — retries are disabled.");
   if(InpHM_RespectFreeze && !InpHM_Enable)
      WARN("InpHM_RespectFreeze=true but HM is disabled (InpHM_Enable=false).");

   // 8) Misc: conflicting toggles
   if(InpPT_Enable == false && (InpPT1_Enable || InpPT2_Enable || InpPT3_Enable))
      WARN("InpPT_Enable=false but some InpPTx_Enable flags are true — PT subsystem disabled globally.");

   if(InpVAPT_Enable == false && (InpVAPT_PTScaleHot != 1.0 || InpVAPT_BEScaleHot != 1.0))
      WARN("VAPT disabled but VAPT scaling inputs not 1.0 — those inputs will be ignored.");

   // 9) User convenience checks
   if(InpPT1_SLA == PT_SLA_NONE && InpTRL_BE_Enable)
      WARN("InpPT1_SLA is NONE while TRL BE is enabled — BE and SLA both try to move stops (possible duplication).");

   // 10) final summary hint
   Print("[EVT_INFO] CheckInputLogic completed (warnings printed above if any).");

   #undef WARN
}

// Ensure SL/TP meet min stop & freeze constraints; push them away if needed.
// Returns true if OK; false if cannot satisfy constraints.
bool EnsureStopsDistance(const int direction, double &price, double &sl, double &tp)
{
  // Min stop distance in points
  int stops_level_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  double min_stop_dist = (double)stops_level_pts * _Point;

  // For market orders, compare to current bid/ask
  if(direction > 0) // BUY
  {
    if(sl > 0 && (price - sl) < min_stop_dist) sl = price - min_stop_dist;
    if(tp > 0 && (tp - price) < min_stop_dist) tp = price + min_stop_dist;
  }
  else // SELL
  {
    if(sl > 0 && (sl - price) < min_stop_dist) sl = price + min_stop_dist;
    if(tp > 0 && (price - tp) < min_stop_dist) tp = price - min_stop_dist;
  }

  // Normalize to tick grid
  if(sl > 0) sl = NormalizePriceByTick(sl);
  if(tp > 0) tp = NormalizePriceByTick(tp);
  price = NormalizePriceByTick(price);

  // Basic sanity
  if(direction > 0 && sl > 0 && sl >= price) return false;
  if(direction > 0 && tp > 0 && tp <= price) return false;
  if(direction < 0 && sl > 0 && sl <= price) return false;
  if(direction < 0 && tp > 0 && tp >= price) return false;

  return true;
}

// Retryable retcodes set (MT5). We retry only on transient price/flow issues.
bool OSR_IsRetryable(const uint retcode)
{
  switch(retcode)
  {
    case TRADE_RETCODE_REQUOTE:
    case TRADE_RETCODE_PRICE_OFF:
    case TRADE_RETCODE_PRICE_CHANGED:   // ? added
    case TRADE_RETCODE_REJECT:
    case TRADE_RETCODE_INVALID_FILL:
    case 10025:
    case 10026:
      return true;
  }
  return false;
}



//+------------------------------------------------------------------+
//| >>> T045: Multi-Symbol Orchestration Helpers <<<                 |
//+------------------------------------------------------------------+
ulong NowMs() { return (ulong)GetMicrosecondCount() / 1000ULL; }

bool GV_Get(const string key, double &val)
{
   if(!GlobalVariableCheck(key)) return false;
   val = GlobalVariableGet(key);
   return true;
}
void GV_Set(const string key, double val) { GlobalVariableSet(key,val); }

// Non-blocking attempt to acquire global lock
bool MSO_TryLock(const ulong now_ms)
{
   const string k = "AAI/MS/LOCK";
   double v=0.0;
   if(GV_Get(k,v))
   {
      if((ulong)v > now_ms) return false; // somebody holds it
   }
   GV_Set(k, (double)(now_ms + (ulong)MSO_LockTTLms));
   return true;
}

// Per-second bucket
bool MSO_BudgetOK(const ulong now_ms)
{
   datetime sec = (datetime)(now_ms/1000ULL);
   string k = StringFormat("AAI/MS/BKT_%I64d", (long)sec);
   double v=0.0;
   if(!GV_Get(k,v)) { GV_Set(k,1.0); return true; }
   if((int)v >= MSO_MaxSendsPerSec) return false;
   GV_Set(k, v+1.0);
   return true;
}

// Per-symbol spacing
bool MSO_SymbolGapOK(const string sym, const ulong now_ms)
{
   string k = "AAI/MS/LAST_" + sym;
   double v=0.0;
   if(GV_Get(k,v))
   {
      if(now_ms < (ulong)v + (ulong)MSO_MinMsBetweenSymbolSends) return false;
   }
   GV_Set(k, (double)now_ms);
   return true;
}

// Main guard: one-shot, non-blocking
bool MSO_MaySend(const string sym)
{
   if(!MSO_Enable) return true;
   const ulong now_ms = NowMs();

   if(!MSO_TryLock(now_ms))                      return false;
   if(!MSO_BudgetOK(now_ms))                     return false;
   if(!MSO_SymbolGapOK(sym, now_ms))             return false;

   return true;
}
// Modifies are safe even when entries are blocked by session hours.
// Only block if trading is globally disabled or symbol is disabled.
bool MSO_MayModify(const string sym)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return(false);
   long tmode=0; SymbolInfoInteger(sym, SYMBOL_TRADE_MODE, tmode);
   return (tmode != SYMBOL_TRADE_MODE_DISABLED);
}


//+------------------------------------------------------------------+
                ////             |
//+------------------------------------------------------------------+
// --- OSR helper: resolve a valid market fill mode for this symbol (IOC/FOK/RETURN)
ENUM_ORDER_TYPE_FILLING ResolveMarketFill(const int user_mode)
{
   // Some servers return a bitmask of allowed fills; some return a single enum value (0/1/2).
   const long fm = (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   // Treat both forms: bitmask (1<<ORDER_FILLING_*) OR exact equality.
   const bool ioc_ok = ((fm & (1 << ORDER_FILLING_IOC))    != 0) || (fm == ORDER_FILLING_IOC);
   const bool fok_ok = ((fm & (1 << ORDER_FILLING_FOK))    != 0) || (fm == ORDER_FILLING_FOK);
   const bool ret_ok = ((fm & (1 << ORDER_FILLING_RETURN)) != 0) || (fm == ORDER_FILLING_RETURN);

   // Respect user's choice when supported
   if(user_mode == OSR_FILL_IOC && ioc_ok) return ORDER_FILLING_IOC;
   if(user_mode == OSR_FILL_FOK && fok_ok) return ORDER_FILLING_FOK;

   // DEFAULT: use server’s declared policy first when it’s a single value
   if(user_mode == OSR_FILL_DEFAULT) {
      if(fm == ORDER_FILLING_IOC)    return ORDER_FILLING_IOC;
      if(fm == ORDER_FILLING_FOK)    return ORDER_FILLING_FOK;
      if(fm == ORDER_FILLING_RETURN) return ORDER_FILLING_RETURN;
      // Or pick a sensible preference when fm looked like a mask
      if(ioc_ok) return ORDER_FILLING_IOC;
      if(fok_ok) return ORDER_FILLING_FOK;
      if(ret_ok) return ORDER_FILLING_RETURN;
   }

   // Fallback preference: IOC -> FOK -> RETURN
   if(ioc_ok) return ORDER_FILLING_IOC;
   if(fok_ok) return ORDER_FILLING_FOK;
   if(ret_ok) return ORDER_FILLING_RETURN;

   // Ultimate fallback (rare)
   return ORDER_FILLING_FOK;
}

//+------------------------------------------------------------------+
//| >>> T031: Core OSR Sender (fail-open) <<<                        |
//+------------------------------------------------------------------+
bool OSR_SendMarket(const int direction,
                    double lots,
                    double &price_io,
                    double &sl_io,
                    double &tp_io,
                    MqlTradeResult &lastRes,
                    string comment="")                 
{
    ZeroMemory(lastRes);

    const datetime bt = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
    // --- SOFT guards (do not block sending)
    if(!MSO_MaySend(_Symbol))
    {
        if(MSO_LogVerbose && bt != g_stamp_mso)
        {
            PrintFormat("[MSO] guard (soft) sym=%s", _Symbol);
            g_stamp_mso = bt;
        }
    }
    if(!T49_MayOpenThisBar(bt))
    {
        if(InpOSR_LogVerbose) Print("[T49] throttle (soft)");
    }
    if(!T50_AllowedNow(bt))
    {
        if(InpOSR_LogVerbose) Print("[T50] window/off-hours (soft)");
    }

    if(!InpOSR_Enable)
    {
        trade.SetTypeFillingBySymbol(_Symbol);
        trade.SetDeviationInPoints(EA_GetAdaptiveDeviation());
        const bool order_sent = (direction > 0)
                              ? trade.Buy(lots, _Symbol, 0.0, sl_io, tp_io, g_last_comment)
                              : trade.Sell(lots, _Symbol, 0.0, sl_io, tp_io, g_last_comment);
        trade.Result(lastRes);
        return order_sent;
    }

    int retries = MathMax(0, InpOSR_MaxRetries);
    int deviation = EA_GetAdaptiveDeviation();

    for(int attempt = 0; attempt <= retries; ++attempt)
    {
        if(InpOSR_RepriceOnRetry || attempt == 0 || InpOSR_PriceMode == OSR_USE_CURRENT)
            price_io = (direction > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                      : SymbolInfoDouble(_Symbol, SYMBOL_BID));

        const int dev_use = MathMin(deviation, InpOSR_SlipPtsMax);

        MqlTradeRequest req;
        ZeroMemory(req);
        ZeroMemory(lastRes);

        req.action       = TRADE_ACTION_DEAL;
        req.symbol       = _Symbol;
        req.volume       = NormalizeLots(lots);
        req.type         = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
        req.type_filling = ResolveMarketFill((int)InpOSR_FillMode);
        req.deviation    = (ulong)dev_use;
        req.magic        = MagicNumber;
        req.comment      = g_last_comment;

        double p = price_io, sl = sl_io, tp = tp_io;
        if(!EnsureStopsDistance(direction, p, sl, tp))
        {
            if(InpOSR_LogVerbose) Print("[OSR] stops violate constraints; giving up.");
            T50_RecordSendFailure(bt);
            return false;
        }
        req.price = p;
        req.sl = sl;
        req.tp = tp;

        // --- Preflight & fallback for fill policy ---
        MqlTradeCheckResult chk;
        ZeroMemory(chk);
        bool ok_check = OrderCheck(req, chk);

        if(!ok_check || chk.retcode != TRADE_RETCODE_DONE)
        {
            if(chk.retcode == TRADE_RETCODE_INVALID_FILL || !ok_check)
            {
                // Try the opposite single fill-mode explicitly
                ENUM_ORDER_TYPE_FILLING alt =
                    (req.type_filling == ORDER_FILLING_IOC ? ORDER_FILLING_FOK : ORDER_FILLING_IOC);
                req.type_filling = alt;
                ZeroMemory(chk);
                ok_check = OrderCheck(req, chk);

                if(!ok_check || chk.retcode != TRADE_RETCODE_DONE)
                {
                    if(InpOSR_LogVerbose)
                        PrintFormat("[OSR] preflight fail: INVALID_FILL after fallback (mask=%ld)",
                                    (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE));
                    T50_RecordSendFailure(bt);
                    return false;
                }
            }
            // else: other precheck errors fall through to send
        } // <<< THIS WAS THE MISSING BRACE FROM THE OUTER "if" STATEMENT

        // --- Send ---
        if(InpOSR_LogVerbose)
            PrintFormat("[OSR] send dir=%d lots=%.2f price=%.5f fill=%d dev=%d",
                        direction, req.volume, req.price, (int)req.type_filling, (int)req.deviation);
        
        // Track send time and requested price for slip/latency EWMA
        g_ea_state.last_send_ticks = GetTickCount64();
        g_ea_state.last_req_price  = p;

        bool sent = OrderSend(req, lastRes);

        // Log result (1=reject, 0=ok) for EWMA reject rate
        EA_LogSendResult(lastRes.retcode);

        if(sent && (lastRes.retcode == TRADE_RETCODE_DONE || lastRes.retcode == TRADE_RETCODE_DONE_PARTIAL))
        {
            price_io = p;
            sl_io = sl;
            tp_io = tp;
            return true;
        }

        if(InpOSR_LogVerbose)
            PrintFormat("[OSR] OrderSend fail (attempt %d): ret=%u, dev=%d, price=%.5f",
                        attempt, lastRes.retcode, dev_use, p);

        if(!OSR_IsRetryable(lastRes.retcode))
        {
            T50_RecordSendFailure(bt);
            return false;
        }
        
        deviation += InpOSR_SlipPtsStep;
        if(InpOSR_RetryDelayMs > 0) Sleep(InpOSR_RetryDelayMs);
    }

    return false;
}
// Effective TargetRR used by T033 SL/TP safety logic.
// Base = InpSLTA_TargetRR, then adjusted by exit_profile_id.
double AAI_EffectiveTargetRR()
  {
   double base = InpSLTA_TargetRR;
   if(base <= 0.0)
      return base;

   // Build current context + playbook
   AAI_Context ctx;
   AAI_FillContext(ctx);
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   // Map exit_profile_id → multiplier
   double mult = 1.0;
   switch(pb.exit_profile_id)
     {
      case 1: mult = InpEP_TargetRRMult_Profile1; break;
      case 2: mult = InpEP_TargetRRMult_Profile2; break;
      default: mult = InpEP_TargetRRMult_Profile0; break;
     }

   double eff = base * mult;
   if(eff <= 0.0)
      eff = base;   // simple safety
      
  if(InpPB_DebugRiskLog)
     {
      PrintFormat(
         "[EP] scn=%s profile=%d baseRR=%.2f mult=%.2f effRR=%.2f",
         AAI_ScenarioName(scn),
         pb.exit_profile_id,
         base,
         mult,
         eff
      );
     }
     
   return eff;
  }
  
// Trailing ATR multiplier adjusted by exit_profile_id
double AAI_EffectiveTrlAtrMult()
{
   double base = InpTRL_ATR_Mult;
   if(base <= 0.0)
      return base;

   AAI_Context ctx;
   AAI_FillContext(ctx);
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   double mult = 1.0;
   switch(pb.exit_profile_id)
     {
      case 1: mult = InpEP_TRL_ATRMult_Profile1; break;
      case 2: mult = InpEP_TRL_ATRMult_Profile2; break;
      default: mult = InpEP_TRL_ATRMult_Profile0; break;
     }

   double eff = base * mult;
   if(eff <= 0.0)
      eff = base;

   return eff;
}
  
// Break-even trigger RR adjusted by exit_profile_id
double AAI_EffectiveTrlBETriggerRR()
{
   double base = InpTRL_BE_TriggerRR;
   if(base <= 0.0)
      return base;

   AAI_Context ctx;
   AAI_FillContext(ctx);
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   double mult = 1.0;
   switch(pb.exit_profile_id)
     {
      case 1: mult = InpEP_TRL_BE_TriggerRRMult_Profile1; break;
      case 2: mult = InpEP_TRL_BE_TriggerRRMult_Profile2; break;
      default: mult = InpEP_TRL_BE_TriggerRRMult_Profile0; break;
     }

   double eff = base * mult;
   if(eff <= 0.0)
      eff = base;

   return eff;
}

// Shared PT RR trigger multiplier (applied to PT1/PT2/PT3 TriggerRR)
double AAI_ExitProfile_PT_RRMult()
{
   AAI_Context ctx;
   AAI_FillContext(ctx);
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   switch(pb.exit_profile_id)
     {
      case 1: return InpEP_PT_TriggerRRMult_Profile1;
      case 2: return InpEP_PT_TriggerRRMult_Profile2;
      default: return InpEP_PT_TriggerRRMult_Profile0;
     }
}

//+------------------------------------------------------------------+
//| >>> T033: SL/TP Safety Helpers <<<                               |
//+------------------------------------------------------------------+
int BrokerMinStopsPts()
{
  int s = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  return MathMax(0, s);
}

bool SLTA_AdjustAndRescale(const int direction,
                           const double entry_price,
                           double &sl_price_io,
                           double &tp_price_io,
                           double &lots_io,
                           const int conf_for_sizing)
{
  if(!InpSLTA_Enable || InpSLTA_Mode==SLTA_OFF) return true;

  const int minStopsPts = BrokerMinStopsPts() + MathMax(0, InpSLTA_ExtraBufferPts);
  const double minStopsPx = minStopsPts * point;

  double sl_pts0 = (sl_price_io>0.0 ? MathAbs(entry_price - sl_price_io)/point : 0.0);
  double tp_pts0 = (tp_price_io>0.0 ? MathAbs(tp_price_io - entry_price)/point : 0.0);

  if(sl_pts0 <= 0.0){
    if(InpSLTA_LogVerbose) Print("[SLTA] No SL provided; cannot control risk - cancel.");
    return !InpSLTA_StrictCancel;
  }

  if(direction > 0){ // BUY: SL below entry
    double min_sl = entry_price - minStopsPx;
    if(sl_price_io <= 0.0 || sl_price_io >= min_sl)
      sl_price_io = min_sl;
  }else{           // SELL: SL above entry
    double min_sl = entry_price + minStopsPx;
    if(sl_price_io <= 0.0 || sl_price_io <= min_sl)
      sl_price_io = min_sl;
  }
  sl_price_io = NormalizePriceByTick(sl_price_io);
  double sl_pts1 = MathAbs(entry_price - sl_price_io)/point;

  if(sl_pts0 > 0.0 && InpSLTA_MaxWidenFrac > 0.0){
    double allowed = sl_pts0 * (1.0 + InpSLTA_MaxWidenFrac);
    if(sl_pts1 > allowed){
      if(InpSLTA_LogVerbose) PrintFormat("[SLTA] SL widening %.0f->%.0f pts exceeds limit (max %.0f).",
                                       sl_pts0, sl_pts1, allowed);
      return !InpSLTA_StrictCancel;
    }
  }

  double tp_pts1 = tp_pts0;
  if(tp_pts0 > 0.0){
    if(InpSLTA_Mode == SLTA_ADJUST_TP_KEEP_RR || InpSLTA_Mode == SLTA_SCALE_BOTH){
      double rr_target = MathMax(InpSLTA_MinRR, AAI_EffectiveTargetRR());
      double tp_needed = sl_pts1 * rr_target;
      tp_pts1 = MathMax(tp_pts0, tp_needed);
    }
    if(InpSLTA_MaxTPPts > 0 && tp_pts1 > InpSLTA_MaxTPPts) tp_pts1 = InpSLTA_MaxTPPts;

    double tp_px = (direction>0 ? entry_price + tp_pts1*point : entry_price - tp_pts1*point);
    tp_price_io = NormalizePriceByTick(tp_px);
    tp_pts1 = MathAbs(tp_price_io - entry_price)/point;
    }else{
    if(InpSLTA_Mode == SLTA_ADJUST_TP_KEEP_RR || InpSLTA_Mode == SLTA_SCALE_BOTH){
      double rr = MathMax(InpSLTA_MinRR, AAI_EffectiveTargetRR());
      tp_pts1 = sl_pts1 * rr;

      if(InpSLTA_MaxTPPts > 0 && tp_pts1 > InpSLTA_MaxTPPts) tp_pts1 = InpSLTA_MaxTPPts;
      double tp_px = (direction>0 ? entry_price + tp_pts1*point : entry_price - tp_pts1*point);
      tp_price_io = NormalizePriceByTick(tp_px);
      tp_pts1 = MathAbs(tp_price_io - entry_price)/point;
    }
  }

  if((InpSLTA_Mode == SLTA_ADJUST_TP_KEEP_RR || InpSLTA_Mode == SLTA_SCALE_BOTH) && InpSLTA_MinRR > 0.0 && tp_pts1 > 0.0){
    double rr_eff = (sl_pts1 > 0) ? tp_pts1 / sl_pts1 : 0;
    if(rr_eff + 1e-9 < InpSLTA_MinRR){
      if(InpSLTA_LogVerbose) PrintFormat("[SLTA] RR %.2f below MinRR %.2f after adjust - cancel.", rr_eff, InpSLTA_MinRR);
      return !InpSLTA_StrictCancel;
    }
  }

  double lots_new = CalculateLotSize(conf_for_sizing, sl_pts1 * point);
  if(lots_new <= 0.0){
    if(InpSLTA_LogVerbose) Print("[SLTA] Lot sizing failed after SL adjust - cancel.");
    return !InpSLTA_StrictCancel;
  }
  lots_io = lots_new;

  return true;
}

#endif // AAI_OSR_MQH
