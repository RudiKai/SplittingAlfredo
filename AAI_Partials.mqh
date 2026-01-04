

#ifndef AAI_PARTIALS_MQH
#define AAI_PARTIALS_MQH
//+------------------------------------------------------------------+
//| >>> T036: Partial Take-Profit Helpers <<<                        |
//+------------------------------------------------------------------+

bool PT_Progress(const TRL_State &st, const int dir, const double cur_price, double &rr_out, double &profit_pts_out)
{
  rr_out = 0.0; profit_pts_out = 0.0;
  if(st.entry_sl_pts <= 0.0 || st.entry_price <= 0.0) return false;
  double move_pts = (dir>0 ? (cur_price - st.entry_price) : (st.entry_price - cur_price))/_Point;
  profit_pts_out = move_pts;
  rr_out = (st.entry_sl_pts>0.0 ? (move_pts / st.entry_sl_pts) : 0.0);
  return true;
}

bool PT_StepTriggered(const double rr, const double prof_pts, const double rr_thr, const int pts_thr)
{
  if(rr_thr > 0.0 && rr >= rr_thr) return true;
  if(pts_thr > 0   && prof_pts >= pts_thr) return true;
  return false;
}

double PT_LotsToClose(const TRL_State &st, const double step_pct, const double cur_pos_lots)
{
  if(st.entry_lots <= 0.0 || step_pct <= 0.0) return 0.0;
  double intended_close_for_step = st.entry_lots * (step_pct/100.0);
  // This logic seems incorrect in the ticket, it should be based on total original lots, not what's left.
  // Correcting based on "portion of ORIGINAL entry lots"
  double already_closed_by_pt = st.pt_closed_lots;
  double total_to_be_closed_at_this_step = st.entry_lots * (step_pct/100.0);

  // The logic in the ticket `intended_total_for_step - st.pt_closed_lots` is incorrect.
  // It should be based on the cumulative percentage.
  // Let's re-read: "% of ORIGINAL entry lots to close".
  // Let's assume the percentages are additive. So step 2's 33% is on top of step 1.
  // This means the ticket's logic might be right after all if we consider step_pct is *the amount to close for this specific step*.
  // Let's stick to the ticket's provided logic.
  double lots_for_this_step = st.entry_lots * (step_pct / 100.0);
  return MathMin(lots_for_this_step, cur_pos_lots);
}

void PT_ApplySLA(const int dir,
                 const ENUM_PT_SLA sla_mode,
                 const int offset_pts,
                 const double entry_price,
                 const double cur_tp,
                 const double pt_level_price,
                 const ulong pos_ticket)
{
   if(!PositionSelectByTicket(pos_ticket)) return;

   const string sym = PositionGetString(POSITION_SYMBOL);
   TRL_State *st = TRL_GetState(sym, pos_ticket, true);
   if(st!=NULL)
   {
      st.symbol = sym;
      st.ticket = pos_ticket;
      if(st.pt1_hit_time==0 && PT_IsLatchedGV(1, pos_ticket))
         st.pt1_hit_time = (datetime)GlobalVariableGet(PT_Key("S1", pos_ticket));
   }
   const datetime pt1_ts = (st!=NULL ? st.pt1_hit_time : 0);

   const double cur_sl = PositionGetDouble(POSITION_SL);
   double new_sl = 0.0;
// === BEGIN: Option B gates + cushion (PT SLA) ===============================
// Make ATR-fast available and read it once
double atr_fast_pts = 0.0;
ReadATRFastPts(atr_fast_pts);  // ok if false; atr_fast_pts stays 0

// Current price (conservative for MFE calc)
MqlTick tk; SymbolInfoTick(_Symbol, tk);
const double px_c = (dir > 0 ? tk.bid : tk.ask);

// 1) Require PT1 first (if enabled)
if(InpTRL_BE_AfterPT1Only && pt1_ts == 0)
   return;

// 2) VAPT arming (same call you use in TRL)
if(!VAPT_Armed(dir, px_c))
   return;

// 3) Time delay after PT1 (if set)
if(InpTRL_BE_WaitSecAfterPT1 > 0 && pt1_ts > 0)
{
   if((int)(TimeCurrent() - pt1_ts) < InpTRL_BE_WaitSecAfterPT1)
      return;
}

// 4) Minimum MFE vs ATR before tightening (if set)
if(InpTRL_BE_MinMFE_ATR > 0.0 && atr_fast_pts > 0.0)
{
   const double mfe_pts = (dir > 0 ? (px_c - entry_price) : (entry_price - px_c)) / _Point;
   if(mfe_pts < atr_fast_pts * InpTRL_BE_MinMFE_ATR)
      return;
}

// 5) Compute final offset (max of: input offset, ATR cushion, SLA floor)
int cushion_pts = InpTRL_BE_CushionPts;
if(InpTRL_BE_CushionATR > 0.0 && atr_fast_pts > 0.0)
   cushion_pts = (int)MathMax(cushion_pts, (int)MathRound(atr_fast_pts * InpTRL_BE_CushionATR));

int sla_floor_pts = InpPT_SLA_MinGapPts;
if(InpPT_SLA_UseATR && atr_fast_pts > 0.0)
   sla_floor_pts = (int)MathMax(sla_floor_pts, (int)MathRound(atr_fast_pts * InpPT_SLA_ATR_Mult));

const int final_offset_pts = MathMax(offset_pts, MathMax(cushion_pts, sla_floor_pts));
// === END: Option B gates + cushion =========================================
   switch(sla_mode)
   {
      case PT_SLA_NONE:
         return;

      // Move SL to entry ± final_offset_pts (BE with cushion/floor)
      case PT_SLA_TO_BE:
      {
         const double cand = entry_price + (dir > 0 ? +final_offset_pts*_Point : -final_offset_pts*_Point);
         new_sl = (cur_sl > 0.0 ? (dir > 0 ? MathMax(cur_sl, cand) : MathMin(cur_sl, cand)) : cand);
         break;
      }

      // Lock SL at entry ± final_offset_pts (same math as TO_BE; semantics differ by naming)
      case PT_SLA_LOCK_OFFSET:
      {
         const double cand = entry_price + (dir > 0 ? +final_offset_pts*_Point : -final_offset_pts*_Point);
         new_sl = (cur_sl > 0.0 ? (dir > 0 ? MathMax(cur_sl, cand) : MathMin(cur_sl, cand)) : cand);
         break;
      }

      // Move SL toward the PT level (PT1/2/3) minus/plus final_offset_pts
      case PT_SLA_TO_TARGET:
      {
         const double base = (pt_level_price > 0.0 ? pt_level_price : entry_price);
         // For longs: SL below base by offset; for shorts: SL above base by offset
         const double cand = (dir > 0 ? base - final_offset_pts*_Point : base + final_offset_pts*_Point);
         new_sl = (cur_sl > 0.0 ? (dir > 0 ? MathMax(cur_sl, cand) : MathMin(cur_sl, cand)) : cand);
         break;
      }
   }

   // If nothing to do, exit
   if(new_sl <= 0.0 || new_sl == cur_sl)
      return;

   if(InpPT_LogVerbose)
      PrintFormat("[PT_SLA] mode=%d final_offset=%d (inp=%d, cushion=%d, floor=%d) SL: %.5f -> %.5f",
                  (int)sla_mode, final_offset_pts, offset_pts, cushion_pts, sla_floor_pts, cur_sl, new_sl);


   if(!InpPT_DirectModify){
      HM_Enqueue(_Symbol, (long)pos_ticket, new_sl, cur_tp);
      return;
   }

   // Position symbol (don’t assume _Symbol)
   string pos_sym = _Symbol, got_sym;
   if(PositionGetString(POSITION_SYMBOL, got_sym) && got_sym != "") pos_sym = got_sym;

   // Make levels legal now (same rule as HM)
   double sl = new_sl, tp = cur_tp;
   if(!HM_SanitizeTargets(pos_sym, dir, sl, tp)){
      if(InpPT_LogVerbose) PrintFormat("[PT] SLA sanitize defer sym=%s sl=%.5f tp=%.5f", pos_sym, sl, tp);
      HM_Enqueue(pos_sym, (long)pos_ticket, sl, tp);
      return;
   }
   // If we're inside freeze band, don't even try direct modify (prevents "failed modify ... Invalid stops" spam)
if(HM_InsideFreezeBand(pos_sym, dir, sl, tp))
{
   if(InpPT_LogVerbose) PrintFormat("[PT] freeze defer -> HM (sl=%.5f tp=%.5f)", sl, tp);
   HM_Enqueue(pos_sym, (long)pos_ticket, sl, tp);
   return;
}

// Veto modify if spread is blown out
if(!Mgmt_SpreadOk()) return;

   // Modifies are allowed even if entry session is closed
   if(!MSO_MayModify(pos_sym)){
      if(InpPT_LogVerbose) PrintFormat("[PT] direct blocked ? HM sym=%s sl=%.5f tp=%.5f", pos_sym, sl, tp);
      HM_Enqueue(pos_sym, (long)pos_ticket, sl, tp);
      return;
   }

   // Direct modify + one retry; then HM fallback
   CTrade tr; tr.SetExpertMagicNumber(MagicNumber);

   if(tr.PositionModify(pos_sym, sl, tp)){
      if(InpPT_LogVerbose) PrintFormat("[PT] direct modify done (sl=%.5f tp=%.5f)", sl, tp);
      return;
   }

   uint rc = tr.ResultRetcode();
   if(OSR_IsRetryable(rc) || rc==TRADE_RETCODE_INVALID || rc==TRADE_RETCODE_INVALID_STOPS){
      Sleep((int)MathMax(50, InpHM_BackoffMs));
      if(tr.PositionModify(pos_sym, sl, tp)){
         if(InpPT_LogVerbose) PrintFormat("[PT] direct modify done (retry) (sl=%.5f tp=%.5f)", sl, tp);
         return;
      }
      rc = tr.ResultRetcode();
   }

   if(InpPT_LogVerbose) PrintFormat("[PT] direct modify fail ret=%u ? HM fallback (sl=%.5f tp=%.5f)", rc, sl, tp);
   HM_Enqueue(pos_sym, (long)pos_ticket, sl, tp);
}

//+------------------------------------------------------------------+
//| >>> T036: PT Safety Clamp Helper <<<                             |
//+------------------------------------------------------------------+
// Clamps the PT price to be at least 1 tick in profit
void EnsurePTNotCrossEntry(double &pt_price_io, const int dir, const double entry_price)
{
   // Use 1 tick as the minimum safety gap
   const double gap = _Point; 

   if(dir > 0) // BUY
   {
      // PT must be >= entry_price + gap
      if(pt_price_io < entry_price + gap)
         pt_price_io = entry_price + gap;
   }
   else // SELL
   {
      // PT must be <= entry_price - gap
      if(pt_price_io > entry_price - gap)
         pt_price_io = entry_price - gap;
   }
}
//+------------------------------------------------------------------+
//| >>> T036: Partial Take-Profit Worker (GV-based) - fixed version  |
//+------------------------------------------------------------------+
void PT_OnTickTicket(const ulong pos_ticket)

{

if(!PositionSelectByTicket(pos_ticket)) return;
if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) return;

   // Per-position hold guard
   if(InpPT_MinHoldSecAfterEntry>0){
      const datetime t0=(datetime)PositionGetInteger(POSITION_TIME);
      if((int)(TimeCurrent()-t0) < InpPT_MinHoldSecAfterEntry) return;
   }
   // Spread guard (symbol-level)
   if(!Mgmt_SpreadOk()) return;


   const int    dir     = ((int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? +1 : -1);
   const double cur_vol = PositionGetDouble(POSITION_VOLUME);
   if(cur_vol <= 0.0) return;

   const ulong  ticket  = pos_ticket;
   const double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
   const double cur_sl  = PositionGetDouble(POSITION_SL);
   const double cur_tp  = PositionGetDouble(POSITION_TP);

   const double px = (InpPT_OnBarClose
                     ? iClose(_Symbol,(ENUM_TIMEFRAMES)SignalTimeframe,1)
                     : (dir>0 ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol,SYMBOL_ASK)));

   // Global throttle (GV)
   if(PT_IsThrottledGV(ticket, InpPT_MinSecondsBetween)) return;

   // --- Shared trailing state (POINTER; use st->member) ---
   TRL_State *st = TRL_GetState(_Symbol, ticket, true);
   if(st == NULL) return;

   st.symbol = _Symbol;
   st.ticket = ticket;

   // Restore PT hit times from per-ticket GV latches (survives restarts)
   if(st.pt1_hit_time==0 && PT_IsLatchedGV(1, ticket)) st.pt1_hit_time = (datetime)GlobalVariableGet(PT_Key("S1", ticket));
   if(st.pt2_hit_time==0 && PT_IsLatchedGV(2, ticket)) st.pt2_hit_time = (datetime)GlobalVariableGet(PT_Key("S2", ticket));


   if(st.entry_price  <= 0.0) st.entry_price  = entry;
   if(st.entry_sl_pts <= 0 && cur_sl>0.0)
      st.entry_sl_pts = (int)MathRound(MathAbs(entry - cur_sl)/_Point);

   // Profit distance only (0 if not in favour)
   double prof_pts = (dir>0 ? (px - st.entry_price) : (st.entry_price - px)) / _Point;
   if(prof_pts < 0.0) prof_pts = 0.0;

   // RR based on initial risk in points
   const double rr = (st.entry_sl_pts > 0 ? (prof_pts / (double)st.entry_sl_pts) : 0.0);

   const double pt_rr_mult = AAI_ExitProfile_PT_RRMult();

   struct StepCfg { int id; double pct; double rr; int pts; ENUM_PT_SLA sla; int offset; };
   StepCfg steps[3] =
   {
      {1, InpPT1_ClosePct, InpPT1_TriggerRR * pt_rr_mult, InpPT1_TriggerPts, InpPT1_SLA, InpPT1_SLA_OffsetPts},
      {2, InpPT2_ClosePct, InpPT2_TriggerRR * pt_rr_mult, InpPT2_TriggerPts, InpPT2_SLA, InpPT2_SLA_OffsetPts},
      {3, InpPT3_ClosePct, InpPT3_TriggerRR * pt_rr_mult, InpPT3_TriggerPts, InpPT3_SLA, InpPT3_SLA_OffsetPts}
   };


   for(int ix=0; ix<3; ++ix)
   {
      if(!VAPT_Armed(dir, entry)) { continue; }

      const StepCfg s = steps[ix];
      if(s.id==1 && !InpPT1_Enable) continue;
      if(s.id==2 && !InpPT2_Enable) continue;
      if(s.id==3 && !InpPT3_Enable) continue;
      if(s.pct <= 0.0) continue;

const string latch_key = PT_Key((s.id==1?"S1":(s.id==2?"S2":"S3")), ticket);
if(GlobalVariableCheck(latch_key))
  {
   // Step already executed -> remove its ghost line if present
   if(InpPT_DrawGhostLevels)
     {
      string ghost_name = StringFormat("AAI_PT_GHOST_%d_%I64u", s.id, ticket);
      ObjectDelete(0, ghost_name);
     }
   continue;
  }


      // (Optional) Block same-bar chain
      if(s.id > 1 && InpPT_BlockSameBarChain)
      {
          if(st.last_close_bar_time == iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0))
          {
             continue; // Skip PT2/PT3 this bar
          }
      }

      // 1. Calculate the DYNAMIC price level
      const double base_entry = (st.entry_price > 0.0 ? st.entry_price : entry);
      const double rr_scale   = (VR_IsHot() ? InpVAPT_PTScaleHot : 1.0);
      const double eff_rr     = s.rr * rr_scale;

      double atr_fast_pts = 0.0;
      ReadATRFastPts(atr_fast_pts);
      
      const double pt_rr_mult2 = AAI_ExitProfile_PT_RRMult(); // same per-profile factor

      int step1_pts = (int)MathRound((double)st.entry_sl_pts * InpPT1_TriggerRR * pt_rr_mult2);
      int step2_pts = (int)MathRound((double)st.entry_sl_pts * InpPT2_TriggerRR * pt_rr_mult2);
      int step3_pts = (int)MathRound((double)st.entry_sl_pts * InpPT3_TriggerRR * pt_rr_mult2);


// Apply ATR floors when VAPT is on; also scale floors in hot regime
if(InpPT_VolAdaptive && atr_fast_pts > 0.0){
   const double hot = (InpVAPT_Enable && VR_IsHot() ? InpVAPT_PTScaleHot : 1.0);
   step1_pts = (int)MathMax(step1_pts, (int)MathRound(atr_fast_pts * InpPT_ATR1_Mult * hot));
   step2_pts = (int)MathMax(step2_pts, (int)MathRound(atr_fast_pts * InpPT_ATR2_Mult * hot));
   step3_pts = (int)MathMax(step3_pts, (int)MathRound(atr_fast_pts * InpPT_ATR3_Mult * hot));


      }

      step1_pts = (int)MathMax(step1_pts, InpPT_MinStepPts);
      step2_pts = (int)MathMax(step2_pts, InpPT_MinStepPts);
      step3_pts = (int)MathMax(step3_pts, InpPT_MinStepPts);

      if(step2_pts < step1_pts) step2_pts = step1_pts;
      if(step3_pts < step2_pts) step3_pts = step2_pts;

      int step_pts = (s.id==1?step1_pts:(s.id==2?step2_pts:step3_pts));
      double pt_level_dyn = base_entry + (dir>0 ? +step_pts*_Point : -step_pts*_Point);

      if (s.rr > 0.0 && st.entry_sl_pts > 0)
         pt_level_dyn = base_entry + (dir > 0 ? +1.0 : -1.0) * (eff_rr * (double)st.entry_sl_pts * _Point);
      else if (s.pts > 0)
         pt_level_dyn = base_entry + (dir > 0 ? +1.0 : -1.0) * (s.pts * _Point);

      // 2. Get the level we should actually USE (dynamic or frozen)
      double pt_level_use = PT_TargetForStep(s.id, ticket, pt_level_dyn);
      
      // --- NEW: Safety clamp to prevent PT from crossing entry ---
      if(pt_level_use > 0.0) // Only clamp if the level is valid
         EnsurePTNotCrossEntry(pt_level_use, dir, base_entry);
      // --- END NEW ---
      
      bool   usedFrozen   = (pt_level_use != pt_level_dyn);
// --- Draw ghost PT level for this step (visual planning aid) -----
if(InpPT_DrawGhostLevels && pt_level_use > 0.0)
  {
   string ghost_name = StringFormat("AAI_PT_GHOST_%d_%I64u", s.id, ticket);

   color ghost_clr;
   if(s.id == 1)      ghost_clr = clrGold;
   else if(s.id == 2) ghost_clr = clrDeepSkyBlue;
   else               ghost_clr = clrMagenta;

   AAI_DrawGhostLevel(ghost_name, pt_level_use, ghost_clr);
  }

      // 3. NEW Trigger: Check current price ('px') against the 'pt_level_use'
      bool hit = false;
      if (pt_level_use > 0.0) // Only trigger if level is valid
      {
         hit = (dir > 0) ? (px >= pt_level_use)  // BUY: current price 'px' (Bid) must be >= target
                         : (px <= pt_level_use); // SELL: current price 'px' (Ask) must be <= target
      }

      // This 'hit' check REPLACES the old 'trig' check 
      if(!hit) continue;

      // Close % of ORIGINAL entry lots
      double entry_lots = (st.entry_lots > 0.0 ? st.entry_lots
                                               : (cur_vol + PT_GetClosedLotsGV(ticket))); // fallback
      double intended_step = entry_lots * (s.pct * 0.01);

      // Broker lot step & digits
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0.0) step = 0.01; // safe fallback
      int vdig = (int)MathRound(-MathLog10(step));
      if(vdig < 0) vdig = 0;

      // Quantize UP so small steps still execute
      double lots_to_close = MathCeil(intended_step / step) * step;

      // Cap by current position volume and normalize
      lots_to_close = MathMin(lots_to_close, cur_vol);
      lots_to_close = NormalizeDouble(lots_to_close, vdig);

      // Nothing to do? latch & continue (prevents spinning if below min lot step)
      if(lots_to_close <= 0.0) { PT_LatchGV(s.id, ticket); continue; }

      // Read how much PT has already closed for this ticket
      double prev_closed = PT_GetClosedLotsGV(ticket);   // <--- NEW

      MqlTradeRequest tReq; MqlTradeResult tRes;
      ZeroMemory(tReq); ZeroMemory(tRes);
      tReq.action    = TRADE_ACTION_DEAL;
      tReq.symbol    = _Symbol;
      tReq.magic     = MagicNumber;
      tReq.deviation = MaxSlippagePoints;
      tReq.type      = (dir>0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
      tReq.volume    = lots_to_close;
      tReq.position  = ticket; // attach to the current position

      if(!OrderSend(tReq, tRes))
      {
         if(InpPT_LogVerbose) PrintFormat("[PT] step %d close failed: ret=%d", s.id, (int)GetLastError());
         return;
      }

      // --- OrderSend ok ---
      PT_AddClosedLotsGV(ticket, lots_to_close);

      // First partial on this ticket? Count it as a PT trade
      if(prev_closed <= 0.0)
         AAI_pt_trades++;                                  // <--- NEW

      // Prefer recorded entry if available
      // const double base_entry = (st.entry_price > 0.0 ? st.entry_price : entry); // Already defined above

// --- BEGIN: unified PT step computation (VAPT-aware) ------------------------
//double atr_fast_pts = 0.0;
ReadATRFastPts(atr_fast_pts);

// Effective RR (inflate in hot regime, keep originals in normal) /// UPDATED
const bool hot = VAPT_IsHotStableFlag();
const double rr1_eff = (hot ? InpPT1_TriggerRR * InpVAPT_PTScaleHot : InpPT1_TriggerRR);
const double rr2_eff = (hot ? InpPT2_TriggerRR * InpVAPT_PTScaleHot : InpPT2_TriggerRR);
const double rr3_eff = (hot ? InpPT3_TriggerRR * InpVAPT_PTScaleHot : InpPT3_TriggerRR);


// Base RR-derived steps from entry->SL distance (if known)
// st.entry_sl_pts should be your SL distance in points at entry time.
// Fallback to current computed SL distance if that's what you use in your codebase.
//int step1_pts = (st.entry_sl_pts > 0 ? (int)MathRound(st.entry_sl_pts * rr1_eff) : 0);
//int step2_pts = (st.entry_sl_pts > 0 ? (int)MathRound(st.entry_sl_pts * rr2_eff) : 0);
//int step3_pts = (st.entry_sl_pts > 0 ? (int)MathRound(st.entry_sl_pts * rr3_eff) : 0);

// Apply ATR floors when VAPT is on (so steps never get too small on volatile days) //// UPDATED
if(InpPT_VolAdaptive && atr_fast_pts > 0.0){
   const double hot_scale = (hot ? InpVAPT_PTScaleHot : 1.0);
   step1_pts = (int)MathMax(step1_pts, (int)MathRound(atr_fast_pts * InpPT_ATR1_Mult * hot_scale));
   step2_pts = (int)MathMax(step2_pts, (int)MathRound(atr_fast_pts * InpPT_ATR2_Mult * hot_scale));
   step3_pts = (int)MathMax(step3_pts, (int)MathRound(atr_fast_pts * InpPT_ATR3_Mult * hot_scale));
}


// IMPORTANT: Explicit TriggerPts act as an additional FLOOR (not an override)
if(InpPT1_TriggerPts > 0) step1_pts = (int)MathMax(step1_pts, InpPT1_TriggerPts);
if(InpPT2_TriggerPts > 0) step2_pts = (int)MathMax(step2_pts, InpPT2_TriggerPts);
if(InpPT3_TriggerPts > 0) step3_pts = (int)MathMax(step3_pts, InpPT3_TriggerPts);

// Absolute minimum & monotonic increase across steps
step1_pts = (int)MathMax(step1_pts, InpPT_MinStepPts);
step2_pts = (int)MathMax(step2_pts, InpPT_MinStepPts);
step3_pts = (int)MathMax(step3_pts, InpPT_MinStepPts);
if(step2_pts < step1_pts) step2_pts = step1_pts;
if(step3_pts < step2_pts) step3_pts = step2_pts;

// Use these step*_pts as the single source of truth for dynamic PT levels
// Example for LONG:
// double pt1_price = entry + step1_pts * _Point;
// double pt2_price = entry + step2_pts * _Point;
// double pt3_price = entry + step3_pts * _Point;
// (mirror with '-' for SHORT)
// --- END: unified PT step computation ---------------------------------------


      // This log is fine, it shows the steps calculated at this moment
      PrintFormat("[PT] steps=%d/%d/%d atr=%.1f rr_eff=%.2f/%.2f/%.2f (in=%.2f/%.2Such/%.2f) min=%d",
                  step1_pts, step2_pts, step3_pts, atr_fast_pts,
                  rr1_eff, rr2_eff, rr3_eff,
                  InpPT1_TriggerRR, InpPT2_TriggerRR, InpPT3_TriggerRR, InpPT_MinStepPts);

      // We re-use pt_level_use which was calculated before the 'hit' check
      double pt_price_level = pt_level_use;
      string pt_source = usedFrozen ? "frozen" : "dynamic"; // For logging

      if(InpPT_LogVerbose)
         // Modify the original log line to include the source
         PrintFormat("[PT] step %d closed %.2f lots (pt_level=%.5f, source=%s)", 
                     s.id, lots_to_close, pt_price_level, pt_source);
                     // Stamp PT1 hit time ONLY when step 1 actually closes
if(s.id == 1) { st.pt1_hit_time = TimeCurrent(); st.pt1_done = true; }
if(s.id == 2) { st.pt2_hit_time = TimeCurrent(); st.pt2_done = true; }
if(s.id == 3) { st.pt3_done = true; }



      // --- PT Freeze: Latch targets on PT1 close ---
if(InpPT_FreezeAfterPT1 && !st.pt_frozen)
{
   const double base_entry = (st.entry_price > 0.0 ? st.entry_price : entry);
   if(dir > 0){
      st.pt2_frozen_price = base_entry + step2_pts * _Point;
      st.pt3_frozen_price = base_entry + step3_pts * _Point;
   }else{
      st.pt2_frozen_price = base_entry - step2_pts * _Point;
      st.pt3_frozen_price = base_entry - step3_pts * _Point;
   }
   
   // --- NEW: Safety clamp the frozen targets before storing them ---
   EnsurePTNotCrossEntry(st.pt2_frozen_price, dir, base_entry);
   EnsurePTNotCrossEntry(st.pt3_frozen_price, dir, base_entry);
   // --- END NEW ---
   
st.pt_frozen = true;
   PrintFormat("[PT_FREEZE] after PT1: PT2=%g PT3=%g (steps: %d / %d pts)",
               st.pt2_frozen_price, st.pt3_frozen_price, step2_pts, step3_pts);
}

      // (Optional) Log same-bar close
      if(InpPT_BlockSameBarChain)
      {
         st.last_close_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);
      }

      // Apply SLA
      if(s.sla != PT_SLA_NONE)
      {
         int offset_to_use = s.offset;
         if(s.sla == PT_SLA_TO_TARGET && InpPT_VolAdaptive){
            double atrp = 0.0; ReadATRFastPts(atrp);
            int floor_from_atr = (int)MathRound( atrp * (s.id==1 ? InpPT_ATR1_Mult : (s.id==2 ? InpPT_ATR2_Mult : InpPT_ATR3_Mult)) );
            int floor_from_rr  = (eff_rr > 0.0 && st.entry_sl_pts > 0)
                           ? (int)MathRound(st.entry_sl_pts * eff_rr) : 0;
            int step_floor     = (int)MathMax(InpPT_MinStepPts, (int)MathMax(floor_from_atr, floor_from_rr));
            offset_to_use      = (int)MathMax(offset_to_use, step_floor);
         }
         PT_ApplySLA(dir, s.sla, offset_to_use, st.entry_price, cur_tp, pt_price_level, ticket);
      }

      PT_LatchGV(s.id, ticket);
      st.pt_closed_lots += lots_to_close;
      PT_TouchThrottleGV(ticket);

      // One step per tick
      return;
   } // end for loop
}


void PT_OnTick()
{
   if(g_victory_lap_active && InpPL_DisableNewPartials)
      return;

   if(!InpPT_Enable)
      return;

   ulong tickets[];
   if(GetMyPositionTickets(_Symbol, (long)MagicNumber, tickets) <= 0)
   {
      // flat -> clear ghosts
      if(InpPT_DrawGhostLevels)
         ObjectsDeleteAll(0, "AAI_PT_GHOST_");
      return;
   }

   for(int i=0;i<ArraySize(tickets);++i)
      PT_OnTickTicket(tickets[i]);
}

void AAI_RegimeStats_OnEntry(const ulong pos_id, const int vol_reg, const int msm_reg)
  {
   int bucket = AAI_RegimeBucketIndex(vol_reg, msm_reg);
   if(bucket < 0) return;

   for(int i = 0; i < AAI_RG_MAX_OPEN; ++i)
     {
      if(AAI_rg_pos_id[i] == 0 || AAI_rg_pos_id[i] == pos_id)
        {
         AAI_rg_pos_id[i]  = pos_id;
         AAI_rg_vol_reg[i] = vol_reg;
         AAI_rg_msm_reg[i] = msm_reg;
         return;
        }
     }
   // if full, silently give up; open-position count is tiny in practice
  }
  
  
void AAI_PosAgg_Update(const ulong pos_id,
                       const double deal_net,
                       double &full_net_out,
                       bool   &is_final)
{
   is_final     = false;
   full_net_out = 0.0;

   // find or allocate slot
   int idx = -1;
   for(int i = 0; i < AAI_POSAGG_MAX; ++i)
   {
      if(AAI_posagg_id[i] == pos_id || AAI_posagg_id[i] == 0)
      {
         idx = i;
         break;
      }
   }
   if(idx < 0) return;

   if(AAI_posagg_id[idx] == 0)
   {
      AAI_posagg_id[idx]  = pos_id;
      AAI_posagg_net[idx] = deal_net;
   }
   else
   {
      AAI_posagg_net[idx] += deal_net;
   }

   // final close? (no position with this id anymore)
   bool still_open = PositionSelectByTicket(pos_id);
   if(!still_open)
   {
      full_net_out = AAI_posagg_net[idx];
      is_final     = true;

      AAI_posagg_id[idx]  = 0;
      AAI_posagg_net[idx] = 0.0;
   }
}

#endif 
//+------------------------------------------------------------------+
//|                                                 AAI_Partials.mqh |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
//+------------------------------------------------------------------+
//| defines                                                          |
//+------------------------------------------------------------------+
// #define MacrosHello   "Hello, world!"
// #define MacrosYear    2010
//+------------------------------------------------------------------+
//| DLL imports                                                      |
//+------------------------------------------------------------------+
// #import "user32.dll"
//   int      SendMessageA(int hWnd,int Msg,int wParam,int lParam);
// #import "my_expert.dll"
//   int      ExpertRecalculate(int wParam,int lParam);
// #import
//+------------------------------------------------------------------+
//| EX5 imports                                                      |
//+------------------------------------------------------------------+
// #import "stdlib.ex5"
//   string ErrorDescription(int error_code);
// #import
//+------------------------------------------------------------------+
