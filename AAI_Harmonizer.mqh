
#ifndef AAI_HARMONIZER_MQH
#define AAI_HARMONIZER_MQH


//+------------------------------------------------------------------+
//| >>> T034: Post-Fill Harmonizer Helpers <<<                       |
//+------------------------------------------------------------------+
bool HM_InsideFreezeBand(const string sym, const int direction, const double target_sl, const double target_tp)
{
   if(!InpHM_RespectFreeze) return false;

   const int freeze_pts = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   if(freeze_pts <= 0) return false;

   double bid=0.0, ask=0.0, pt=0.0;
   SymbolInfoDouble(sym, SYMBOL_BID, bid);
   SymbolInfoDouble(sym, SYMBOL_ASK, ask);
   if(!SymbolInfoDouble(sym, SYMBOL_POINT, pt) || pt <= 0.0) pt = _Point;

   const double freeze_px = freeze_pts * pt;

   if(direction > 0) // BUY (validate vs BID)
   {
      if(target_sl > 0.0 && (bid - target_sl) < freeze_px) return true;
      if(target_tp > 0.0 && (target_tp - bid) < freeze_px) return true;
   }
   else // SELL (validate vs ASK)
   {
      if(target_sl > 0.0 && (target_sl - ask) < freeze_px) return true;
      if(target_tp > 0.0 && (ask - target_tp) < freeze_px) return true;
   }
   return false;
}

bool HM_SanitizeTargets(const string sym, const int direction, double &sl_io, double &tp_io)
{
   double bid=0.0, ask=0.0, pt=0.0;
   if(!SymbolInfoDouble(sym, SYMBOL_BID, bid) || !SymbolInfoDouble(sym, SYMBOL_ASK, ask))
      return false;

   if(!SymbolInfoDouble(sym, SYMBOL_POINT, pt) || pt <= 0.0) pt = _Point;

   const long freeze_pts = (long)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   const long stops_pts  = (long)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);

   // "Hard" minimum gap (conservative): max(freeze, stops)
   const double min_gap_px = MathMax((double)freeze_pts, (double)stops_pts) * pt;

   if(direction > 0) // BUY (reference BID)
   {
      if(sl_io > 0.0) sl_io = MathMin(sl_io, bid - min_gap_px); // SL below bid
      if(tp_io > 0.0) tp_io = MathMax(tp_io, bid + min_gap_px); // TP above bid
   }
   else // SELL (reference ASK)
   {
      if(sl_io > 0.0) sl_io = MathMax(sl_io, ask + min_gap_px); // SL above ask
      if(tp_io > 0.0) tp_io = MathMin(tp_io, ask - min_gap_px); // TP below ask
   }

   if(sl_io > 0.0) sl_io = NormalizePriceByTick(sl_io);
   if(tp_io > 0.0) tp_io = NormalizePriceByTick(tp_io);

   // Final sanity
   if(direction > 0)
   {
      if(sl_io > 0.0 && sl_io >= bid) return false;
      if(tp_io > 0.0 && tp_io <= bid) return false;
   }
   else
   {
      if(sl_io > 0.0 && sl_io <= ask) return false;
      if(tp_io > 0.0 && tp_io >= ask) return false;
   }

   return true;
}


bool HM_ShouldModify(const double cur_sl, const double cur_tp,
                     const double tgt_sl, const double tgt_tp,
                     const int minChangePts)
{
  double dsl = ( (cur_sl<=0 || tgt_sl<=0) ? (cur_sl==tgt_sl ? 0.0 : DBL_MAX)
                                          : MathAbs(cur_sl - tgt_sl)/_Point );
  double dtp = ( (cur_tp<=0 || tgt_tp<=0) ? (cur_tp==tgt_tp ? 0.0 : DBL_MAX)
                                          : MathAbs(cur_tp - tgt_tp)/_Point );
  if(dsl==DBL_MAX && dtp==DBL_MAX) return true; // add/remove stops
  return (dsl >= minChangePts) || (dtp >= minChangePts);
}

void HM_Enqueue(const string sym, const long pos_ticket, const double sl_target, const double tp_target)
{
  if(!InpHM_Enable || InpHM_Mode==HM_OFF) return;
  HM_Task *t = new HM_Task;
  t.symbol = sym;
  t.pos_ticket = pos_ticket;
  t.sl_target = (sl_target>0 ? NormalizePriceByTick(sl_target) : 0.0);
  t.tp_target = (tp_target>0 ? NormalizePriceByTick(tp_target) : 0.0);
  t.retries_left = (InpHM_Mode==HM_ONESHOT_IMMEDIATE ? 0 : MathMax(0, InpHM_MaxRetries));
  int delay = (InpHM_Mode==HM_ONESHOT_IMMEDIATE ? 0 : MathMax(0, InpHM_DelayMs));
  t.next_try_time = TimeCurrent() + (delay/1000); // coarse to seconds for server time
  g_hm_tasks.Add(t);
}

void HM_OnTick()
{
  if(!InpHM_Enable || InpHM_Mode==HM_OFF) return;
  if(g_hm_tasks.Total()==0) return;

  int processed = 0;
  for(int i = g_hm_tasks.Total()-1; i >= 0 && processed < 3; --i)
  {
    HM_Task *t = (HM_Task*)g_hm_tasks.At(i);
    if(!t) { g_hm_tasks.Delete(i); continue; }
    if(TimeCurrent() < t.next_try_time) continue;

    // 1) Select the exact position (prefer ticket over symbol)
    bool have = (t.pos_ticket > 0 ? PositionSelectByTicket(t.pos_ticket) : PositionSelect(t.symbol));
    if(!have){ g_hm_tasks.Delete(i); delete t; continue; }

    int    ptype     = (int)PositionGetInteger(POSITION_TYPE);
    int    direction = (ptype==POSITION_TYPE_BUY ? +1 : -1);
    double cur_sl    = PositionGetDouble(POSITION_SL);
    double cur_tp    = PositionGetDouble(POSITION_TP);

    // 2) Start from task targets, then sanitize (clamp vs max(Freeze,Stops))
    double sl = t.sl_target, tp = t.tp_target;
    if(!HM_SanitizeTargets(t.symbol, direction, sl, tp))
    {
      // Defer instead of giving up; price may move to make it legal/tighter
      if(t.retries_left > 0) t.retries_left--;
      t.next_try_time = TimeCurrent() + (MathMax(1, InpHM_BackoffMs)/1000);
      if(InpHM_LogVerbose) PrintFormat("[HM] sanitize defer sym=%s ticket=%I64d", t.symbol, (long)t.pos_ticket);
      continue; // keep in queue
    }

    // 3) After sanitize: if the change is too small, drop the task
    if(!HM_ShouldModify(cur_sl, cur_tp, sl, tp, InpHM_MinChangePts))
    {
      g_hm_tasks.Delete(i); delete t; continue;
    }

    // 4) If still inside freeze band after sanitize, defer
    if(HM_InsideFreezeBand(t.symbol, direction, sl, tp))
    {
      t.next_try_time = TimeCurrent() + (MathMax(1, InpHM_BackoffMs)/1000);
      continue;
    }

    // 5) Throttle with MSO
// Modifies are allowed outside entry session; just pause if terminal/symbol disabled
if(!MSO_MayModify(t.symbol))
{
   if(InpHM_LogVerbose) PrintFormat("[HM] pause modify sym=%s (terminal/symbol disabled)", t.symbol);
   t.next_try_time = TimeCurrent() + (MathMax(1, InpHM_BackoffMs)/1000);
   continue;
}

    // 6) Modify the correct position (use t.symbol, not _Symbol)
    CTrade tr;
    tr.SetExpertMagicNumber(MagicNumber);
    bool ok = tr.PositionModify(t.symbol, sl, tp);
    uint rc = tr.ResultRetcode();

    if(ok && (rc==TRADE_RETCODE_DONE))
    {
      if(InpHM_LogVerbose) Print("[HM] modify done.");
      g_hm_tasks.Delete(i); delete t; processed++; continue;
    }

    if(InpHM_LogVerbose) PrintFormat("[HM] modify fail ret=%u, retries_left=%d", rc, t.retries_left);
    // T037: Log failure for watchdog
    PHW_LogFailure(rc);

    bool retryable = OSR_IsRetryable(rc)
                     || (rc==TRADE_RETCODE_INVALID || rc==TRADE_RETCODE_INVALID_STOPS);

    if(t.retries_left > 0 && retryable)
    {
      t.retries_left--;
      t.next_try_time = TimeCurrent() + (MathMax(1, InpHM_BackoffMs)/1000);
      processed++;
      continue;
    }
    else
    {
      g_hm_tasks.Delete(i); delete t; processed++; continue;
    }
  }
}

#endif 
