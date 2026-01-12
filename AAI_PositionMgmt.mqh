#ifndef AAI_EVAL_ENTRY_MQH
#define AAI_EVAL_ENTRY_MQH

//+------------------------------------------------------------------+
//| >>> T025 REFACTOR: Main evaluation flow for a closed bar <<<     |
//+------------------------------------------------------------------+

void EvaluateClosedBar()
{
// --- 0. Get cached data from SignalBrain for this bar ---
int    direction   = g_sb.sig;
double conf_eff    = g_sb.conf; // This can be modified by gates
const int    reason_sb   = g_sb.reason;
const double ze_strength = g_sb.ze;
const int    smc_sig     = g_sb.smc_sig;
const double smc_conf    = g_sb.smc_conf;
const int    bc_bias     = g_sb.bc;

// --- DEBUG: Confidence pipeline snapshot (diagnostics only) ---
if(RTP_IS_DIAG)
{
   // Effective MinConfidence after playbook + clamps
   double minconf_eff = AAI_EffectiveMinConf();

   // Optional: context if you want it
   AAI_Context ctx;
   AAI_FillContext(ctx);
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   PrintFormat(
      "DBG_CONF_PIPE|time=%s|sym=%s|tf=%s"
      "|sig=%d|conf_raw=%.1f|minconf_eff=%.1f"
      "|mode=%d|scenario=%d|vol_reg=%d|msm_reg=%d",
      TimeToString(g_sb.closed_bar_time, TIME_DATE|TIME_MINUTES),
      _Symbol,
      EnumToString(_Period),
      direction,
      conf_eff,
      minconf_eff,
      AAI_mode_current,
      (int)scn,
      AAI_regime_vol,
      AAI_regime_msm
   );
}

    // --- Log and Update HUD with the raw state for this bar ---
    LogPerBarStatus(direction, conf_eff, reason_sb, ze_strength, bc_bias);

    // --- T044: Handle periodic state saving ---
    if(g_sb.valid && g_sb.closed_bar_time != g_sp_lastbar)
    {
        g_sp_lastbar = g_sb.closed_bar_time;
        g_sp_barcount++;
        SP_Save(false);
    }

    // --- T50: Fail-guard gate (auto-suspend new entries) ---
    if(!T50_AllowedNow(g_sb.closed_bar_time))
    {
        LogBlockOncePerBar("T50_FAIL_GUARD_ACTIVE");
        return;
    }

    // --- Reset per-bar flags ---
    g_vr_flag_for_bar    = 0;
    g_news_flag_for_bar  = 0;
    g_sp_hit_for_bar     = false;
    g_as_exceeded_for_bar= false;
    g_imc_flag_for_bar   = false;
    g_rg_flag_for_bar    = false;

    // --- Signal Gate: If no signal, we're done for this bar. ---
    if(direction == 0)
    {
        return;
    }

    string reason_id; // To be populated by a failing gate

    // --- Execute Gate Chain ---
if(!GateWarmup(reason_id))                                   { LogBlockOncePerBar(reason_id); return; }
if(!GateSpread(reason_id))                                   { LogBlockOncePerBar(reason_id); return; }
if(!GateNews(conf_eff, reason_id))                           { LogBlockOncePerBar(reason_id); return; }
if(!GateRiskGuard(conf_eff, reason_id))                      { LogBlockOncePerBar(reason_id); return; }
if(!GatePHW(reason_id))                                      { LogBlockOncePerBar(reason_id); return; } // T037
if(!GateSession(reason_id))                                  { LogBlockOncePerBar(reason_id); return; }
if(!GateOverExtension(reason_id))                            { LogBlockOncePerBar(reason_id); return; }
if(!GateVolatility(conf_eff, reason_id))                     { LogBlockOncePerBar(reason_id); return; }
if(!GateAdaptiveSpread(conf_eff, reason_id))                 { LogBlockOncePerBar(reason_id); return; }
if(!GateStructureProximity(direction, conf_eff, reason_id))  { LogBlockOncePerBar(reason_id); return; }
if(!GateZE(direction, ze_strength, reason_id))               { LogBlockOncePerBar(reason_id); return; }
if(!GateSMC(direction, smc_sig, smc_conf, reason_id))        { LogBlockOncePerBar(reason_id); return; }
if(!GateBC(direction, bc_bias, reason_id))                   { LogBlockOncePerBar(reason_id); return; }
if(!GateInterMarket(direction, conf_eff, reason_id))         { LogBlockOncePerBar(reason_id); return; }
if(!GateECF(conf_eff, reason_id))                            { LogBlockOncePerBar(reason_id); return; } // T038
if(!GateSLC(direction, reason_id))                           { LogBlockOncePerBar(reason_id); return; } // T039
if(!GateConfidence(conf_eff, reason_id))                     { LogBlockOncePerBar(reason_id); return; }

// NEW: scenario / playbook gate
if(!GatePlaybookScenario(conf_eff, reason_id))               { LogBlockOncePerBar(reason_id); return; }

if(!GateCooldown(direction, reason_id))                      { LogBlockOncePerBar(reason_id); return; }
if(!GateDebounce(direction, reason_id))                      { LogBlockOncePerBar(reason_id); return; }
if(!GatePosition(reason_id))                                 { /* No block log needed */ return; }
if(!GateStreakGuard(conf_eff, reason_id)) return;




const int sb_shift = MathMax(1, SB_ReadShift);

double prev_sig_raw = 0;
if(!Read1(sb_handle, SB_BUF_SIGNAL, sb_shift + 1, prev_sig_raw, "SB_Prev"))
{
   reason_id = "sb_prev_readfail";
   LogBlockOncePerBar(reason_id);
   return;
}

// SB buffer 0 encodes direction as the SIGN of the value (often +/-entry price).
// Use sign-only comparison so edge detection works across symbols/prices.
int prev_sig = 0;
if(prev_sig_raw > 0.0)      prev_sig = 1;
else if(prev_sig_raw < 0.0) prev_sig = -1;

if(!GateTrigger(direction, prev_sig, reason_id))
{
   /* No block log needed */ 
   return;
}

// --- Label entry mode (keep your existing logic) ---
string entry_mode = "";
bool is_bootstrap_trigger = (EntryMode == FirstBarOrEdge && !g_bootstrap_done);
entry_mode = is_bootstrap_trigger ? "bootstrap" : "edge";

// --- NEW: Manual / Hybrid branches ---
if(ExecutionMode == SignalsOnly || Hybrid_RequireApproval)
{
  // Avoid duplicate intents if one is already pending
  if(Hybrid_RequireApproval && g_pending_id != "")
    return;

  double entry, sl, tp, lots, rr; string cmt;
  if(!PrepareOrderParams(direction, conf_eff, reason_sb, ze_strength, bc_bias, smc_sig, smc_conf,
                         entry, sl, tp, lots, rr, cmt))
    return;

  // Capture for approval executor / telemetry
  g_last_side     = (direction>0 ? "BUY" : "SELL");
  g_last_entry    = entry;
  g_last_sl       = sl;
  g_last_tp       = tp;
  g_last_vol      = lots;
  g_last_rr       = rr;
  g_last_conf_raw = g_sb.conf;    // raw from SB cache
  g_last_conf_eff = conf_eff;     // post-gates effective confidence
  g_last_ze       = ze_strength;
  g_last_comment  = cmt;

  // Telegram alert in manual/hybrid modes
  SendTelegramAlert(g_last_side, g_last_conf_eff, ze_strength, entry, sl, tp, rr, reason_sb);

  // For hybrid, emit an intent JSON and wait for approval
  if(Hybrid_RequireApproval){
    // EmitIntent(...) must exist already in your codebase
    if(EmitIntent(g_last_side, entry, sl, tp, lots, rr,
                  g_last_conf_raw, g_last_conf_eff, g_last_ze)){
      // Optionally set g_pending_id inside EmitIntent; otherwise you may set it here.
    }
  }
  return; // Do not auto-trade in these modes
}

// --- Existing behavior: AutoExecute path ---
if(TryOpenPosition(direction, conf_eff, reason_sb, ze_strength, bc_bias, smc_sig, smc_conf, entry_mode))
{
  if(is_bootstrap_trigger) g_bootstrap_done = true;
}

}
//... (rest of the file is identical) ...
//+------------------------------------------------------------------+
//| Helper function to get the string representation of a reason code|
//+------------------------------------------------------------------+
string ReasonCodeToString(int code)
{
    switch((ENUM_REASON_CODE)code)
    {
        case REASON_BUY_HTF_CONTINUATION:   return "Trend Continuation (Buy)";
        case REASON_SELL_HTF_CONTINUATION:  return "Trend Continuation (Sell)";
        case REASON_BUY_LIQ_GRAB_ALIGNED:   return "Liquidity Grab (Buy)";
        case REASON_SELL_LIQ_GRAB_ALIGNED:  return "Liquidity Grab (Sell)";
        case REASON_TEST_SCENARIO:          return "Test Scenario";
        default:                            return "Signal";
    }
}

//+------------------------------------------------------------------+
//| Sends a formatted alert to Telegram for an approval candidate    |
//+------------------------------------------------------------------+
// UTF-8 percent encoder (final, no warnings)
string URLEncodeUtf8(const string s){
  uchar bytes[];
  int n = StringToCharArray(s, bytes, 0, WHOLE_ARRAY, CP_UTF8);
  string out = "";
  for(int i = 0; i < n; i++){
    int bi = (int)bytes[i];
    if(bi == 0) break;  // stop at null terminator if present

    // unreserved characters per RFC3986
    if( (bi >= 'A' && bi <= 'Z') ||
        (bi >= 'a' && bi <= 'z') ||
        (bi >= '0' && bi <= '9') ||
         bi == '-' || bi == '_' || bi == '.' || bi == '~' )
    {
      out += StringFormat("%c", bi);   // safer than CharToString
    }
    else if(bi == ' '){
      out += "%20";
    }
    else {
      out += StringFormat("%%%02X", bi);
    }
  }
  return out;
}


void SendTelegramAlert(const string side, const double conf_eff, const double ze_strength,
                       const double entry, const double sl, const double tp, const double rr,
                       const int reason_code)
{
    if(!UseTelegramFromEA) return;
    string reason_text = ReasonCodeToString(reason_code);
    int sl_pips = (int)MathRound(MathAbs(entry - sl) / PipSize());
    int tp_pips = (tp > 0) ? (int)MathRound(MathAbs(entry - tp) / PipSize()) : 0;

    // Read HTF Bias directly from SignalBrain's output for the message
    double htf_bias_val = 0;
    Read1(sb_handle, SB_BUF_BC, MathMax(1, SB_ReadShift), htf_bias_val, "SB_BC_Alert");
    int htf_bias = (int)MathRound(htf_bias_val);


    string msg_p1 = StringFormat("[Alfred_AI] %s %s • %s • conf %d • ZE %.1f • bias %d",
                                 _Symbol, EnumToString(_Period), side, (int)conf_eff,
                                 ze_strength, htf_bias);
    string msg_p2 = StringFormat("Entry %.5f | SL %.5f (%dp) | TP %.5f (%dp) | R %.2f",
                                 entry, sl, sl_pips, tp, tp_pips, rr);
    string msg_p3 = StringFormat("Reason: %s (%d)", reason_text, reason_code);

    string full_message = msg_p1 + "\n" + msg_p2 + "\n" + msg_p3;
    if(AlertsDryRun || StringLen(TelegramToken) == 0 || StringLen(TelegramChatID) == 0)
    {
        Print(full_message);
        return;
    }
string url_message = URLEncodeUtf8(full_message);
string url = StringFormat(
  "https://api.telegram.org/bot%s/sendMessage?chat_id=%s&text=%s&disable_web_page_preview=1",
  TelegramToken, TelegramChatID, url_message
);

// 7-arg overload (no data_size)
uchar  post[];    // empty body for GET
uchar  result[];
string result_headers = "";
ResetLastError();
int res = WebRequest("GET", url, "", 5000, post, result, result_headers);

if(res == 200){
  Print(EVT_TG_OK);
}else{
  PrintFormat("%s code=%d err=%d", EVT_TG_FAIL, res, GetLastError());
}

}


//+------------------------------------------------------------------+
//| Attempts to open a trade and returns true on success             |
//+------------------------------------------------------------------+
// --- Build order params without sending (used by SignalsOnly / Hybrid)
bool PrepareOrderParams(const int signal, double conf_eff, int reason_code, double ze_strength,
                        int bc_bias, int smc_sig, double smc_conf,
                        double &entryPrice, double &slPrice, double &tpPrice,
                        double &lots, double &rr_calc, string &comment_out)
{
  // ATR -> SL distance (mirror logic from TryOpenPosition)
  double atr_val_raw = 0.0, buf[1];
  if(CopyBuffer(g_hATR, 0, 1, 1, buf) == 1) atr_val_raw = buf[0];

  const double sl_dist_raw = atr_val_raw + (SL_Buffer_Points * point);
  const double sl_min      = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
  const double sl_dist     = MathMax(sl_dist_raw, sl_min);

  lots = CalculateLotSize((int)conf_eff, sl_dist);

  entryPrice = (signal>0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol, SYMBOL_BID));
                         
                         

  if(signal>0){
    slPrice = entryPrice - sl_dist;
    tpPrice = Exit_FixedRR ? entryPrice + Fixed_RR * sl_dist : 0.0;
  }else{
    slPrice = entryPrice + sl_dist;
    tpPrice = Exit_FixedRR ? entryPrice - Fixed_RR * sl_dist : 0.0;
  }

  // Respect broker min-stops / rescale lots/targets exactly as live send does
  if(!SLTA_AdjustAndRescale(signal, entryPrice, slPrice, tpPrice, lots, (int)conf_eff))
    return false;

  rr_calc = (sl_dist>0.0 && tpPrice>0.0) ? (MathAbs(tpPrice-entryPrice)/sl_dist) : 0.0;

  // Keep your comment wiring consistent with existing journaling
  comment_out = StringFormat("AAI|%.1f|%d|%d|%.1f|%.5f|%.5f|%.1f",
                             conf_eff,(int)conf_eff,reason_code,ze_strength,slPrice,tpPrice,smc_conf);
  return true;
}

bool TryOpenPosition(int signal, double conf_eff, int reason_code, double ze_strength, int bc_bias, int smc_sig, double smc_conf, string entry_mode)
{
   // ----- ATR for SL distance (closed bar), with defensive read -----
   double atr_val_raw = 0.0;
   double _tmp_atr_entry_[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, _tmp_atr_entry_) == 1) atr_val_raw = _tmp_atr_entry_[0];

   double sl_dist_raw = atr_val_raw + (SL_Buffer_Points * point);
   double sl_dist = MathMax(sl_dist_raw, (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point);

   // ----- lot sizing based on actual risk distance -----
   double lots_to_trade = CalculateLotSize((int)conf_eff, sl_dist);

   // --- Provisional Entry/SL/TP from signal, before adjustment ---
   double entryPrice = (signal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slPrice, tpPrice;
   if (signal > 0) {
     slPrice = entryPrice - sl_dist;
     tpPrice = (Exit_FixedRR) ? entryPrice + Fixed_RR * sl_dist : 0;
   } else {
     slPrice = entryPrice + sl_dist;
     tpPrice = (Exit_FixedRR) ? entryPrice - Fixed_RR * sl_dist : 0;
   }

   // --- T033: Auto-adjust SL/TP to satisfy broker min-stops & RR; re-scale lots ---
   if(!SLTA_AdjustAndRescale(signal, entryPrice, slPrice, tpPrice, lots_to_trade, (int)conf_eff))
   {
   if(InpSLTA_LogVerbose) Print("[SLTA_CANCEL] Could not meet broker min-stops / RR constraints within bounds.");
   return false; // Cancel this attempt cleanly
   }

   g_last_comment = StringFormat("AAI|%.1f|%d|%d|%.1f|%.5f|%.5f|%.1f",
                                 conf_eff, (int)conf_eff, reason_code, ze_strength, slPrice, tpPrice, smc_conf);

   double rr_calc = (sl_dist > 0 && tpPrice > 0) ? (MathAbs(tpPrice-entryPrice)/sl_dist) : 0.0;

   DJ_Write(signal, conf_eff, reason_code, ze_strength, bc_bias, smc_sig, smc_conf,
            g_vr_flag_for_bar, g_news_flag_for_bar, g_sp_hit_for_bar ? 1 : 0,
            g_as_exceeded_for_bar ? 1 : 0, g_as_cap_pts_last, g_as_hist_count,
            g_imc_flag_for_bar ? 1 : 0, g_imc_support,
            g_rg_flag_for_bar ? 1:0,
            (g_rg_day_start_balance > 0 ? (-g_rg_day_realized_pl / g_rg_day_start_balance) * 100.0 : 0.0),
            -g_rg_day_realized_pl, g_rg_day_sl_hits, g_rg_consec_losses,
            (double)CurrentSpreadPoints(),
            lots_to_trade, sl_dist / point, (tpPrice>0?MathAbs(tpPrice-entryPrice)/point:0), rr_calc, entry_mode);


   // T040: Capture pre-send state
   if(EA_Enable)
   {
       g_ea_state.last_send_ticks = GetTickCount64();
       g_ea_state.last_req_price = entryPrice;
   }

   MqlTradeResult tRes;
   bool sent = OSR_SendMarket(signal, lots_to_trade, entryPrice, slPrice, tpPrice, tRes);

   // T040: Log execution result
   EA_LogSendResult(tRes.retcode);

   if(!sent){
     PrintFormat("[AAI_SENDFAIL] retcode=%u lots=%.2f dir=%d", tRes.retcode, lots_to_trade, signal);
     // T037: Log failure for watchdog
     PHW_LogFailure(tRes.retcode);
     return false;
   }

   // --- Post-open bookkeeping ---
   if(tRes.deal > 0)
   {
ulong pos_ticket = 0;

// Best: derive the position ticket from the deal (hedging-safe)
if(HistoryDealSelect(tRes.deal))
   pos_ticket = (ulong)HistoryDealGetInteger(tRes.deal, DEAL_POSITION_ID);

// Fallback: pick the newest position on this symbol with our magic
if(pos_ticket == 0)
{
   datetime best_time = 0;
   ulong best_ticket = 0;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = (ulong)PositionGetTicket(i);
      if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
      if(pt >= best_time) { best_time = pt; best_ticket = t; }
   }
   pos_ticket = best_ticket;
}


      // Fallback for brokers/builds that don't populate result.position
      if(pos_ticket == 0 && PositionSelect(_Symbol))
         pos_ticket = (ulong)PositionGetInteger(POSITION_TICKET);

      if(pos_ticket > 0 && PositionSelectByTicket(pos_ticket))
      {
         HM_Enqueue(_Symbol, (long)pos_ticket, slPrice, tpPrice);

         // T035 & T036: Create/Update Trailing and PT State (per-position)
         TRL_State *st = TRL_GetState(_Symbol, pos_ticket, true);
         if(st != NULL)
         {
            st.symbol       = _Symbol;
            st.ticket       = pos_ticket;
            st.direction    = signal;
            st.entry_price  = PositionGetDouble(POSITION_PRICE_OPEN);
            st.entry_lots   = PositionGetDouble(POSITION_VOLUME);
            st.entry_sl_pts = (slPrice>0.0 ? MathAbs(st.entry_price - slPrice)/_Point : 0.0); // actual SL on position

            st.pt_closed_lots = PT_GetClosedLotsGV(pos_ticket); // (0 if none)
            st.pt1_done = st.pt2_done = st.pt3_done = false;

            st.pt1_hit_time = 0;
            st.pt2_hit_time = 0;
            st.last_close_bar_time = 0;
            st.pt_frozen = false;
            st.pt2_frozen_price = EMPTY_VALUE;
            st.pt3_frozen_price = EMPTY_VALUE;

            st.be_done = false;
            st.moves_today = 0;
            st.last_mod_time = 0;
            st.day_anchor = g_rg_day_anchor_time;
         }

         // Persist entry lots for this position (PT uses it for % closes after restart)
         PT_GetEntryLotsGV(pos_ticket, PositionGetDouble(POSITION_VOLUME));
      }
   }
   g_entries++;
   PrintFormat("%s Signal:%s ? Executed %.2f lots @%.5f | SL:%.5f TP:%.5f",
               EVT_ENTRY, (signal > 0 ? "BUY":"SELL"), tRes.volume, tRes.price, slPrice, tpPrice);
               
             
// EXEC logs only in OnTradeTransaction on DEAL_ENTRY_IN to avoid duplicates
  // AAI_LogExec(signal, tRes.volume > 0 ? tRes.volume : lots_to_trade);


   datetime current_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
   if(signal > 0) g_last_entry_bar_buy = current_bar_time;
   else           g_last_entry_bar_sell = current_bar_time;
// --- Telegram alert on execution (fires in AutoExecute too)
if(UseTelegramFromEA && !AlertsDryRun)
{
   string side = (signal > 0 ? "BUY" : "SELL");
   string tf   = EnumToString((ENUM_TIMEFRAMES)SignalTimeframe);

   // rr_calc and conf_eff are already in-scope in TryOpenPosition
   string msg = StringFormat(
      "[ENTRY] %s %s • %s • lots %.2f • entry %.5f • SL %.5f • TP %.5f • RR %.2f • conf %.0f",
      _Symbol,
      tf,
      side,
      (tRes.volume > 0 ? tRes.volume : lots_to_trade),
      tRes.price,
      slPrice,
      tpPrice,
      rr_calc,
      conf_eff
   );
SendTelegramAlert(
   _Symbol,                                                    // string
   (double)tRes.price,                                         // entry
   (double)slPrice,                                            // SL
   (double)tpPrice,                                            // TP
   (double)rr_calc,                                            // RR
   (double)conf_eff,                                           // confidence
   (double)(tRes.volume > 0 ? tRes.volume : lots_to_trade),    // lots
   (int)(signal > 0 ? 1 : -1)                                  // direction (+1 buy / -1 sell)
);

}

   return true;
}


#endif // AAI_EVAL_ENTRY_MQH
