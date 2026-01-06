
#ifndef AAI_TRAILING_MQH
#define AAI_TRAILING_MQH

//+------------------------------------------------------------------+
//| >>> T035: Trailing/BE Helpers <<<                                |
//+------------------------------------------------------------------+
TRL_State* TRL_GetState(const string sym, const ulong pos_ticket, const bool create_if_missing = false)
{
  for(int i=0;i<g_trl_states.Total();++i){
    TRL_State *s = (TRL_State*)g_trl_states.At(i);
    if(s && s.symbol==sym && s.ticket==pos_ticket) return s;
  }
  if(!create_if_missing) return NULL;
  TRL_State *ns = new TRL_State;
  ns.symbol = sym;
  ns.ticket = pos_ticket;
  g_trl_states.Add(ns);
  return ns;
}

// Helper: gather position tickets for this symbol+magic (hedging/pyramiding safe)
int GetMyPositionTickets(const string sym, const long magic, ulong &tickets[])
{
   ArrayResize(tickets, 0);
   const int total = PositionsTotal();
   for(int i=0;i<total;i++)
   {
      const ulong t = (ulong)PositionGetTicket(i);
      if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=magic) continue;

      const int n = ArraySize(tickets);
      ArrayResize(tickets, n+1);
      tickets[n] = t;
   }
   return ArraySize(tickets);
}


void TRL_MaybeRollover(TRL_State &st)
{
  datetime now = TimeCurrent();
  if(st.day_anchor==0 || (now - st.day_anchor) >= 24*3600){
    st.day_anchor = now;
    st.moves_today = 0;
  }
}

double TRL_TightenSL(const int dir, const double cur_sl, const double candidate)
{
   if(candidate <= 0.0) return 0.0;
   if(cur_sl    <= 0.0) return candidate; // first placement allowed

   const double bump = InpTRL_MinBumpPts * _Point;

   // Inclusive checks so an exact-min bump is accepted
   if(dir > 0 && candidate >= cur_sl + bump) return candidate; // BUY: raise SL
   if(dir < 0 && candidate <= cur_sl - bump) return candidate; // SELL: lower SL

   return 0.0; // would loosen or too small
}


bool TRL_GetATR(const string sym, const ENUM_TIMEFRAMES tf, const int period, double &atr_out)
{
  atr_out = 0.0;
  int handle = (tf==PERIOD_CURRENT) ? g_hATR_TRL : iATR(sym, tf, period);
  if(handle == INVALID_HANDLE) return false;

  double a[1];
  if(CopyBuffer(handle, 0, (InpTRL_OnBarClose?1:0), 1, a) != 1) return false;
  atr_out = a[0];

  if(tf != PERIOD_CURRENT) IndicatorRelease(handle);
  return (atr_out>0.0);
}

bool TRL_HHLL(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, double &hh, double &ll)
{
  hh=0.0; ll=0.0;
  double H[], L[]; ArraySetAsSeries(H,true); ArraySetAsSeries(L,true);
  if(CopyHigh(sym, tf, (InpTRL_OnBarClose?1:0), lookback, H) != lookback) return false;
  if(CopyLow (sym, tf, (InpTRL_OnBarClose?1:0), lookback, L) != lookback) return false;

  int ih = ArrayMaximum(H, 0, WHOLE_ARRAY);
  int il = ArrayMinimum(L, 0, WHOLE_ARRAY);
  if(ih<0 || il<0) return false;
  hh = H[ih];
  ll = L[il];
  return true;
}
void PT_ResetFreeze()
{
   g_PT2_FrozenPrice = EMPTY_VALUE;
   g_PT3_FrozenPrice = EMPTY_VALUE;
   g_PT_Frozen       = false;
   g_PT_FreezeTicket = 0;
   g_PT_LastCloseBarTime = 0; // Also reset the optional block
   g_PT1_LastHitTime = 0;
   g_PT2_LastHitTime = 0;

}
// Returns the price we actually use to decide the close
double PT_TargetForStep(const int step, const ulong ticket, const double dyn_level)
{
   if(!InpPT_FreezeAfterPT1) return dyn_level;

   TRL_State *st = TRL_GetState(_Symbol, ticket, false);
   if(st==NULL || !st.pt_frozen) return dyn_level;

   if(step==2 && st.pt2_frozen_price!=EMPTY_VALUE) return st.pt2_frozen_price;
   if(step==3 && st.pt3_frozen_price!=EMPTY_VALUE) return st.pt3_frozen_price;

   return dyn_level;
}

// ---------- PT: per-ticket persistence via Global Variables ----------
string PT_Key(const string name, const ulong ticket)
{
   return StringFormat("AAI_PT_%s_%I64u", name, ticket);
}

bool PT_IsLatchedGV(const int step, const ulong ticket)
{
   const string k = PT_Key((step==1 ? "S1" : step==2 ? "S2" : "S3"), ticket);
   return GlobalVariableCheck(k);
}

void PT_LatchGV(const int step, const ulong ticket)
{
   const string k = PT_Key((step==1 ? "S1" : step==2 ? "S2" : "S3"), ticket);
   if(!GlobalVariableCheck(k)) GlobalVariableSet(k, (double)TimeCurrent());
}

double PT_GetEntryLotsGV(const ulong ticket, const double fallback)
{
   const string k = PT_Key("ENTRYLOTS", ticket);
   if(GlobalVariableCheck(k)) return GlobalVariableGet(k);
   GlobalVariableSet(k, fallback);
   return fallback;
}

double PT_GetClosedLotsGV(const ulong ticket)
{
   const string k = PT_Key("CLOSEDLOTS", ticket);
   if(GlobalVariableCheck(k)) return GlobalVariableGet(k);
   return 0.0;
}

void PT_AddClosedLotsGV(const ulong ticket, const double add)
{
   const string k = PT_Key("CLOSEDLOTS", ticket);
   const double cur = PT_GetClosedLotsGV(ticket) + add;
   GlobalVariableSet(k, cur);
}

bool PT_IsThrottledGV(const ulong ticket, const int minSec)
{
   if(minSec<=0) return false;
   const string k = PT_Key("LASTMOD", ticket);
   if(!GlobalVariableCheck(k)) return false;
   const double last = GlobalVariableGet(k);
   const double now  = (double)TimeCurrent();
   return ((now - last) < (double)minSec);
}

void PT_TouchThrottleGV(const ulong ticket)
{
   const string k = PT_Key("LASTMOD", ticket);
   GlobalVariableSet(k, (double)TimeCurrent());
}

// Conservative lot normalization (round down to step and obey min/max)
double PT_NormLots(double lots)
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(vmin, MathMin(lots, vmax));
   if(vstep>0.0) lots = MathFloor(lots / vstep) * vstep;
   // guard tiny float noise
   if(lots < vmin - 1e-9) lots = 0.0;
   return lots;
}

// Ceil quantization to volume step (opposite of PT_NormLots' flooring)
double PT_QuantizeCeil(double lots)
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(0.0, MathMin(lots, vmax)); // allow 0 (meaning "no trade")

   if(vstep > 0.0)
   {
      lots = MathCeil(lots / vstep) * vstep;
      int prec = (int)MathMax(0, MathCeil(-MathLog10(vstep)) + 2);
      lots = NormalizeDouble(lots, prec);
   }

   if(lots > 0.0 && lots < vmin) lots = vmin;
   return lots;
}
//////////////////////////////////////
// ATR value helper for MQL5 (handle + CopyBuffer pattern)
bool GetATRValue(const string sym, const ENUM_TIMEFRAMES tf, const int period, const bool on_bar_close, double &atr_out)
{
   atr_out = 0.0;
   const int h = iATR(sym, tf, period);
   if(h==INVALID_HANDLE) return false;

   const int shift = (on_bar_close ? 1 : 0);
   double buf[]; ArraySetAsSeries(buf, true);
   const int got = CopyBuffer(h, 0, shift, 1, buf);
   IndicatorRelease(h);
   if(got!=1) return false;

   atr_out = buf[0];
   return (atr_out>0.0);
}
//////////////////////////////////
bool AAI_MarkTrlTicket(const ulong ticket)
{
   int n = ArraySize(AAI_trl_seen_tickets);
   for(int i = 0; i < n; ++i)
   {
      if(AAI_trl_seen_tickets[i] == ticket)
         return false;  // already counted
   }
   ArrayResize(AAI_trl_seen_tickets, n+1);
   AAI_trl_seen_tickets[n] = ticket;
   return true;         // first time we see this ticket
}

//+------------------------------------------------------------------+
//| >>> T035: Trailing/BE Worker (Corrected) <<<                     |
//+------------------------------------------------------------------+
void TRL_OnTickTicket(const ulong pos_ticket)
{
   if(!InpTRL_Enable || InpTRL_Mode==TRL_OFF) return;   if(!PositionSelectByTicket(pos_ticket)) return;
   if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) return;

   const ulong  ticket = pos_ticket;
const int    dir    = ((int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? +1 : -1);
   const double cur_sl = PositionGetDouble(POSITION_SL);
   const double cur_tp = PositionGetDouble(POSITION_TP);
   const double px_op  = PositionGetDouble(POSITION_PRICE_OPEN);
   const double px_c   = (InpTRL_OnBarClose
                         ? iClose(_Symbol,(ENUM_TIMEFRAMES)SignalTimeframe,1)
                         : (dir>0 ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                                  : SymbolInfoDouble(_Symbol,SYMBOL_ASK)));

   TRL_State *st = TRL_GetState(_Symbol, ticket, true);
   if(st==NULL) return;

   st.symbol = _Symbol;
   st.ticket = ticket;

   // Restore PT hit times from per-ticket GV latches (survives restarts)
   if(st.pt1_hit_time==0 && PT_IsLatchedGV(1, ticket))
      st.pt1_hit_time = (datetime)GlobalVariableGet(PT_Key("S1", ticket));
   if(st.pt2_hit_time==0 && PT_IsLatchedGV(2, ticket))
      st.pt2_hit_time = (datetime)GlobalVariableGet(PT_Key("S2", ticket));

   
   // Management guards
      if(InpTRL_MinHoldSecAfterEntry>0){
      const datetime t0=(datetime)PositionGetInteger(POSITION_TIME);
      if((int)(TimeCurrent()-t0) < InpTRL_MinHoldSecAfterEntry) return;
   }
   if(!Mgmt_SpreadOk()) return;

   // Direction flip -> re-prime
   if(st.direction!=0 && st.direction!=dir)
   {
      st.be_done       = false;
      st.moves_today   = 0;
      st.last_mod_time = 0;
      st.entry_price   = px_op;
      st.entry_sl_pts  = (cur_sl>0.0 ? MathAbs(px_op-cur_sl)/_Point : 0.0);
   }
   st.direction = dir;

   // Prime once
   if(st.entry_price<=0.0) st.entry_price = px_op;
   if(st.entry_sl_pts<=0.0 && cur_sl>0.0) st.entry_sl_pts = MathAbs(px_op-cur_sl)/_Point;

   TRL_MaybeRollover(*st);

// 1) Break-even vs initial risk
if(InpTRL_BE_Enable && !st.be_done)
{
   // --- VAPT + PT1/time/MFE gates for BE --------------------------------
   double atr_fast_pts = 0.0;
   ReadATRFastPts(atr_fast_pts);  // ok if returns false; atr_fast_pts stays 0

   bool be_allowed = true;

   // Block BE until VAPT arms (same args you use elsewhere)
   if(!VAPT_Armed(dir, px_c))
      be_allowed = false;

   // Optional: require PT1 to be hit before BE can start creeping
   if(be_allowed && InpTRL_BE_AfterPT1Only && st.pt1_hit_time == 0)
      be_allowed = false;

   // Optional: time delay after PT1
   if(be_allowed && InpTRL_BE_WaitSecAfterPT1 > 0 && st.pt1_hit_time > 0)
   {
      if((int)(TimeCurrent() - st.pt1_hit_time) < InpTRL_BE_WaitSecAfterPT1)
         be_allowed = false;
   }

   // Optional: require a minimum MFE vs fast ATR before BE
   if(be_allowed && InpTRL_BE_MinMFE_ATR > 0.0 && atr_fast_pts > 0.0)
   {
      const double mfe_pts =
         (dir > 0 ? (px_c - st.entry_price) : (st.entry_price - px_c)) / _Point;
      if(mfe_pts < atr_fast_pts * InpTRL_BE_MinMFE_ATR)
         be_allowed = false;
   }
   // ---------------------------------------------------------------------

   if(be_allowed)
   {
      bool trigger = false;
      const double be_base = AAI_EffectiveTrlBETriggerRR();

      if(be_base > 0.0 && st.entry_sl_pts > 0.0)
      {
         const double rr =
            MathAbs(px_c - st.entry_price) / _Point / st.entry_sl_pts;
         const double be_rr = be_base * (VR_IsHot() ? InpVAPT_BEScaleHot : 1.0);
         if(rr >= be_rr)
            trigger = true;
      }

      if(!trigger && InpTRL_BE_TriggerPts > 0)
      {
         const double prof_pts =
            (dir > 0 ? (px_c - st.entry_price) : (st.entry_price - px_c))/_Point;
         if(prof_pts >= (double)InpTRL_BE_TriggerPts)
            trigger = true;
      }

      if(trigger && Mgmt_SpreadOk())
      {
         // Cushion so BE is not razor-thin at entry
         int cushion_pts = InpTRL_BE_CushionPts;
         if(InpTRL_BE_CushionATR > 0.0 && atr_fast_pts > 0.0)
            cushion_pts = (int)MathMax(
               cushion_pts,
               (int)MathRound(atr_fast_pts * InpTRL_BE_CushionATR)
            );

         const double be_px =
            st.entry_price +
            (dir > 0
               ? (InpTRL_BE_OffsetPts + cushion_pts) * _Point
               : -(InpTRL_BE_OffsetPts + cushion_pts) * _Point);

         const double cand = TRL_TightenSL(dir, cur_sl, be_px);

         if(cand > 0.0)
         {
            HM_Enqueue(_Symbol, (long)ticket, cand, cur_tp);
            st.be_done       = true;
            st.last_mod_time = TimeCurrent();
            st.moves_today++;
            if(InpTRL_LogVerbose)
               Print("[TRL] BE move enqueued.");
         }
         else
         {
            // Only mark BE done if current SL already at/through BE price;
            // otherwise keep trying.
            if( (dir > 0 && cur_sl >= be_px - _Point) ||
                (dir < 0 && cur_sl <= be_px + _Point) )
            {
               st.be_done = true;
            }
         }
      }
   } // end be_allowed
}   // end BE block

// <<< PASTE THE TWO LINES HERE! >>>
if(InpTRL_MinSecondsBetween>0 && (TimeCurrent()-st.last_mod_time)<InpTRL_MinSecondsBetween) return;
if(InpTRL_MaxDailyMoves>0    && st.moves_today>=InpTRL_MaxDailyMoves) return;
   if(InpTRL_Mode==TRL_BE_ONLY) return;

   // +++ LOGIC FIX: Replaced the flawed Gating logic with this correct version +++
   // 1. Check if we are allowed to START the trail
if(InpTRL_WaitForPT1 && st.pt1_hit_time == 0)
   {
       // PT1 is required to start, but it hasn't been hit yet. Stop all trailing.
     //  if(InpTRL_LogVerbose) PrintFormat("[TRL] Waiting for PT1 before starting trail (GV S1=false).");
       return; 
   }
   // --- END OF FIX ---

   // 2) Trail target
   double target_sl = 0.0;
   if(InpTRL_Mode==TRL_ATR || InpTRL_Mode==TRL_CHANDELIER)
   {
      double atr=0.0;
      const ENUM_TIMEFRAMES tf = (InpTRL_ATR_Timeframe==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)SignalTimeframe : InpTRL_ATR_Timeframe);
      if(!GetATRValue(_Symbol, tf, InpTRL_ATR_Period, InpTRL_OnBarClose, atr)) return;

      // Base ATR multiplier from profile
      double atr_mult_eff = AAI_EffectiveTrlAtrMult(); // base from exit profile

      // Check PT latches once
      const bool pt2_hit = PT_IsLatchedGV(2, ticket);
      const bool pt3_hit = PT_IsLatchedGV(3, ticket);

      int max_stage_hit = 0;
      if(PT_IsLatchedGV(1, ticket)) max_stage_hit = 1;
      if(PT_IsLatchedGV(2, ticket)) max_stage_hit = 2;
      if(PT_IsLatchedGV(3, ticket)) max_stage_hit = 3;

      // --- PT2/PT3-specific tightening (existing AlfredAI behaviour) ---
      if(InpTRL_WaitForPT2 && st.pt2_hit_time == 0)
      {
         if(pt2_hit) // tighten only after PT2 happened
         {
            if(InpTRL_ATR_Mult_AfterPT2 > 0.0)
               atr_mult_eff = MathMin(atr_mult_eff, InpTRL_ATR_Mult_AfterPT2);
            if(pt3_hit && InpTRL_ATR_Mult_AfterPT3 > 0.0)
               atr_mult_eff = MathMin(atr_mult_eff, InpTRL_ATR_Mult_AfterPT3);
         }
         // else: PT2 not yet hit -> keep base atr_mult_eff (no tightening)
      }
      else
      {
         // If WaitForPT2 is false, apply available tightenings immediately when they exist
         if(pt2_hit && InpTRL_ATR_Mult_AfterPT2 > 0.0)
            atr_mult_eff = MathMin(atr_mult_eff, InpTRL_ATR_Mult_AfterPT2);
         if(pt3_hit && InpTRL_ATR_Mult_AfterPT3 > 0.0)
            atr_mult_eff = MathMin(atr_mult_eff, InpTRL_ATR_Mult_AfterPT3);
      }
      // --- END PT2/PT3 tightening ---

      // --- Victory Lap soft/hard overrides ---
// 1) Soft victory: gentle tighten, no PT stage requirement
if(g_pl_soft_active && !g_pl_hard_active && InpPL_SoftATRMult > 0.0)
{
   atr_mult_eff = MathMin(atr_mult_eff, InpPL_SoftATRMult);
}

// 2) Hard victory: full choke, only after partial stage (house money)
if(g_pl_hard_active &&
   max_stage_hit >= InpPL_MinPTStage &&
   InpPL_SnapATRMult > 0.0)
{
   atr_mult_eff = MathMin(atr_mult_eff, InpPL_SnapATRMult);
}

      // --- END Victory Lap overrides ---

      if(InpTRL_Mode==TRL_ATR)
      {
         target_sl = px_c + (dir>0 ? -atr_mult_eff*atr : +atr_mult_eff*atr);
      }
      else // CHANDELIER
      {
         const double hi = iHigh(_Symbol,(ENUM_TIMEFRAMES)SignalTimeframe,1);
         const double lo = iLow (_Symbol,(ENUM_TIMEFRAMES)SignalTimeframe,1);
         if(dir>0) target_sl = hi - atr_mult_eff*atr;
         else      target_sl = lo + atr_mult_eff*atr;
      }
   }

   else if(InpTRL_Mode==TRL_SWING)
   {
      const double sw_hi = FindRecentSwingHigh(InpTRL_SwingLookbackBars, InpTRL_SwingLeg);
      const double sw_lo = FindRecentSwingLow (InpTRL_SwingLookbackBars, InpTRL_SwingLeg);
      if(dir>0 && sw_lo>0.0) target_sl = sw_lo - InpTRL_SwingBufferPts*_Point;
      if(dir<0 && sw_hi>0.0) target_sl = sw_hi + InpTRL_SwingBufferPts*_Point;
   }
   else return;

   if(target_sl <= 0.0) return;

   double cand = TRL_TightenSL(dir, cur_sl, target_sl);
   if(cand <= 0.0) return;

   // Never loosen vs current SL
   if(cur_sl > 0.0)
      cand = (dir > 0) ? MathMax(cand, cur_sl)   // BUY: tighten upward
                       : MathMin(cand, cur_sl);  // SELL: tighten downward

   // (Recommended) skip micro-changes smaller than your bump threshold
   if(MathAbs(cand - cur_sl) < InpTRL_MinBumpPts * _Point) return;
   
   // Normalize to tick before enqueue (HM will still sanitize)
   cand = NormalizePriceByTick(cand);

   HM_Enqueue(_Symbol, (long)ticket, cand, cur_tp);
   st.last_mod_time = TimeCurrent();
   st.moves_today++;
      // Count trades that experienced at least one trailing/BE move
   if(AAI_MarkTrlTicket(ticket))
      AAI_trl_trades++;     // <--- NEW
   if(InpTRL_LogVerbose)
      PrintFormat("[TRL] Trail enqueued: old_sl=%.5f new_sl=%.5f", cur_sl, cand);
      
      
}


void TRL_OnTick()
{
   if(!InpTRL_Enable || InpTRL_Mode==TRL_OFF) return;

   ulong tickets[];
   if(GetMyPositionTickets(_Symbol, (long)MagicNumber, tickets) <= 0)
      return;

   for(int i=0;i<ArraySize(tickets);++i)
      TRL_OnTickTicket(tickets[i]);
}


#endif 

