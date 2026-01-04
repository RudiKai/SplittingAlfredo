
#ifndef AAI_ADAPTIVESPREAD_MQH
#define AAI_ADAPTIVESPREAD_MQH


//+------------------------------------------------------------------+
//| >>> T028: Adaptive Spread Tick Sampler <<<                       |
//+------------------------------------------------------------------+
// Sample current spread (in POINTS) and append to the adaptive-spread buffer.
// Works on variable-spread brokers (no reliance on SYMBOL_SPREAD).
// Sample current spread (in POINTS) and append to the adaptive-spread buffer.
// Bounded & cadence-aware: respects InpAS_SampleEveryNTicks and InpAS_SamplesPerBarMax,
// and rolls bar medians into a fixed-size ring buffer (g_as_bar_medians) to avoid growth.
void AS_OnTickSample()
{
   if(!InpAS_Enable || InpAS_Mode==AS_OFF) return;

   // 1) Detect new bar on the configured SignalTimeframe and finalize the previous bar's median
   datetime cur_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);
   if(g_as_forming_bar_time != 0 && cur_bar_time != g_as_forming_bar_time)
   {
      const int n = ArraySize(g_as_samples);
      if(n > 0)
      {
         // Compute median of samples for the just-closed bar
         double tmp[]; ArrayResize(tmp, n);
         for(int i=0;i<n;i++) tmp[i]=g_as_samples[i];
         ArraySort(tmp);
         const double med = (n%2!=0 ? tmp[n/2] : 0.5*(tmp[n/2-1] + tmp[n/2]));

         // Push into ring buffer g_as_bar_medians
         int cap = ArraySize(g_as_bar_medians);
         if(cap <= 0){ ArrayResize(g_as_bar_medians, 1); cap = 1; }
         g_as_bar_medians[g_as_hist_pos] = med;
         g_as_hist_pos = (g_as_hist_pos + 1) % cap;
         if(g_as_hist_count < cap) g_as_hist_count++;
      }

      // Reset per-bar state
      ArrayResize(g_as_samples, 0);
      g_as_tick_ctr = 0;
      g_as_exceeded_for_bar = false;
      g_as_forming_bar_time = cur_bar_time;
   }

   // 2) Tick-cadence gating
   g_as_tick_ctr++;
   if(InpAS_SampleEveryNTicks > 1 && (g_as_tick_ctr % InpAS_SampleEveryNTicks) != 0)
      return;

   // 3) Per-bar cap on samples
   if(InpAS_SamplesPerBarMax > 0 && ArraySize(g_as_samples) >= InpAS_SamplesPerBarMax)
      return;

   // 4) Fetch spread in points (robust on variable-spread brokers)
   double spr_pts = CurrentSpreadPoints();
   if(spr_pts <= 0.0)
   {
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(ask > 0.0 && bid > 0.0)
         spr_pts = (ask - bid) / _Point;
   }
   if(spr_pts <= 0.0) return;

   // 5) Append to this bar's sample buffer (bounded by step 3)
   int sz = ArraySize(g_as_samples);
   ArrayResize(g_as_samples, sz + 1);
   g_as_samples[sz] = spr_pts;
}

// --- SAO: Strength Add-On Module (Hardened V1) ---
void SAO_OnTick()
{
   if(!InpSAO_Enable) return;
if(InpRS_BlockSAOInTransition && g_rs_transition_active)
   return;

   // Iterate open positions to find PARENTS
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      // 1. RECURSION FILTER: Is this already an Add-On?
      // If the comment starts with the SAO tag, it cannot be a parent.
      string c = PositionGetString(POSITION_COMMENT);
      if(StringFind(c, "AAI_SAO_") >= 0) continue; 

      // 2. CAP CHECK: Have we maxed out adds for this parent?
      int current_adds = SAO_GetAddCount(ticket);
      if(current_adds >= InpSAO_MaxAdds) continue; 

      // 3. INVARIANT: PT Stage (Must be proven winner)
      int pt_stage = PT_GetStageGV(ticket); 
      if(pt_stage < InpSAO_MinPTStage) continue; 

      // 4. INVARIANT: Risk Free (The Professional Check)
      if(InpSAO_HardInvariant)
      {
         double sl = PositionGetDouble(POSITION_SL);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         long type = PositionGetInteger(POSITION_TYPE);
         
         if(sl == 0.0) continue; // No SL = Dangerous
         
         // STRICT: SL must be strictly better than Entry
         // (Using Point/Digits to avoid float compare errors is ideal, but direct compare works for broad safety)
         if(type == POSITION_TYPE_BUY && sl <= open_price) continue;
         if(type == POSITION_TYPE_SELL && sl >= open_price) continue;
      }

      // 5. INVARIANT: Time-Based Cooldown (The Machine-Gun Fix)
      // We check time since LAST ADD, not time since entry.
      datetime last_add = SAO_GetLastAddTime(ticket);
      // If we have added before, check the gap. If never added, last_add is 0 (pass).
      if(last_add > 0 && (TimeCurrent() - last_add) < PeriodSeconds() * InpSAO_CooldownBars) 
         continue;

      // --- EXECUTION ELIGIBILITY CONFIRMED ---
      
      // Calculate Lots: Parent Current + Parent Closed (Original Size)
      double parent_lots = PositionGetDouble(POSITION_VOLUME);
      parent_lots += PT_GetClosedLotsGV(ticket); 
      
      double new_lots = NormalizeLots(parent_lots * InpSAO_RiskFrac);

      // BROKER SAFETY: Min Lot Check
      double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(new_lots < min_vol) continue; 
      
      PrintFormat("[SAO] TRIGGER: Parent=%d | PT=%d | RiskFree=YES | Executing %.2f lots", ticket, pt_stage, new_lots);

      double p=0, sl=0, tp=0; 
      MqlTradeResult r;
      long type = PositionGetInteger(POSITION_TYPE);
      
      // Tag the new trade so it doesn't become a parent (recursion protection)
      string sao_comment = StringFormat("AAI_SAO_PARENT_%d", ticket); 
      
      // Use OSR for execution robustness
      // We send with 0 SL initially to ensure fill, then modify immediately
      if(OSR_SendMarket((type==POSITION_TYPE_BUY?+1:-1), new_lots, p, sl, tp, r, sao_comment))
      {
         // Update State IMMEDIATELY
         SAO_IncrementAddCount(ticket);
         SAO_SetLastAddTime(ticket, TimeCurrent());
         
         // COPY SL: Match parent SL immediately
         double parent_sl = PositionGetDouble(POSITION_SL);
         if(parent_sl > 0)
         {
             // Direct modify for speed/certainty on the add-on
             trade.PositionModify(r.order, parent_sl, 0); 
         }
      }
   }
}



#endif 
//+------------------------------------------------------------------+
//|                                           AAI_AdaptiveSpread.mqh |
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
