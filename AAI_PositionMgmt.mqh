#ifndef AAI_POSMGMT_MQH
#define AAI_POSMGMT_MQH


// --- helper: hedge-safe SL/TP modify by POSITION TICKET ---
bool AAI_ModifySLTP_ByTicket(const ulong pos_ticket, const double sl, const double tp)
{
   if(pos_ticket == 0) return false;
   if(!PositionSelectByTicket(pos_ticket)) return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.position = pos_ticket;
   req.symbol   = PositionGetString(POSITION_SYMBOL);
   req.magic    = (long)MagicNumber;
   req.sl       = sl;
   req.tp       = tp;

   if(!OrderSend(req, res))
      return false;

   return (res.retcode == TRADE_RETCODE_DONE ||
           res.retcode == TRADE_RETCODE_DONE_PARTIAL);
}


void ManageOnePosition(const ulong ticket, const MqlDateTime &loc, bool overnight)
{
   if(ticket == 0) return;
   if(!PositionSelectByTicket(ticket)) return;

   // Safety: only manage our own position
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return;
   if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) return;

   // --- Partial Take-Profit first (if your PT module relies on "currently selected position",
   // selecting by ticket here makes it deterministic in hedging) ---
   if(InpPT_Enable)
   {
      PT_OnTick();

      // Might have closed the position
      if(!PositionSelectByTicket(ticket)) return;
      if(!PositionSelectByTicket(ticket)) return;
      // Re-check ownership/symbol just in case
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) return;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) return;
   }

   if(!Exit_FixedRR)
   {
      // HandlePartialProfits(); // disabled by PT_OnTick
      // (No need to re-select by symbol; we’re ticket-based.)
      if(!PositionSelectByTicket(ticket)) return;
   }

   // --- Friday close (per-position) ---
   if(loc.day_of_week == FRIDAY && loc.hour >= FridayCloseHour)
   {
      if(!MSO_MaySend(_Symbol))
      {
         if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
         {
            PrintFormat("[MSO] defer Close sym=%s reason=guard", _Symbol);
            g_stamp_mso = g_sb.closed_bar_time;
         }
         return; // Defer action
      }

      if(!trade.PositionClose(ticket)) PHW_LogFailure(trade.ResultRetcode()); // T037
      return;
   }

   // --- Read position fields (for this ticket) ---
   ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);

   // --- BE / Trail ---
   if(AAI_ApplyBEAndTrail(side, entry, sl))
   {
      if(!MSO_MaySend(_Symbol))
      {
         if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
         {
            PrintFormat("[MSO] defer Modify sym=%s reason=guard", _Symbol);
            g_stamp_mso = g_sb.closed_bar_time;
         }
         return; // Defer action
      }

      // Hedge-safe modify by ticket (instead of trade.PositionModify(_Symbol,...))
      if(!AAI_ModifySLTP_ByTicket(ticket, sl, tp))
         PHW_LogFailure(trade.ResultRetcode()); // T037 (retcode from CTrade may not reflect OrderSend here)
   }
}


void ManageOpenPositions(const MqlDateTime &loc, bool overnight)
{
   // Iterate backwards so closing doesn’t break indexing
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      // Only manage our symbol + magic
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      ManageOnePosition(ticket, loc, overnight);
   }
}

//+------------------------------------------------------------------+
//| Unified SL updater                                               |
//+------------------------------------------------------------------+
bool AAI_ApplyBEAndTrail(const ENUM_POSITION_TYPE side, const double entry_price, double &sl_io)
{
   if(Exit_FixedRR) return false;

   const double pip = AAI_Pip();
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const bool   is_long = (side==POSITION_TYPE_BUY);
   const double px      = is_long ? bid : ask;
   const double move_p = is_long ? (px - entry_price) : (entry_price - px);
   const double move_pips = move_p / pip;
   bool changed=false;

   double initial_risk_pips = 0;
   string comment = PositionGetString(POSITION_COMMENT);
   string parts[];
   if(StringSplit(comment, '|', parts) >= 8) { // Updated to handle new comment format
       double sl_price = StringToDouble(parts[5]);
       initial_risk_pips = MathAbs(entry_price - sl_price) / PipSize();
   }

   if(Partial_R_multiple > 0 && move_pips >= initial_risk_pips * Partial_R_multiple)
   {
   double be_target = entry_price + (is_long ? +1 : -1) * BE_Offset_Points * _Point;
   if( (is_long && (sl_io < be_target)) || (!is_long && (sl_io > be_target)) )
   {
     sl_io = be_target;
     changed = true;
   }
   }

   if(InpTRL_Enable && InpTRL_Mode != TRL_OFF) // Defer trailing to TRL_OnTick
   {
     // old trailing logic is now handled by TRL_OnTick
   }

   return changed;
}


//+------------------------------------------------------------------+
//| Handle Partial Profits                                           |
//+------------------------------------------------------------------+
void HandlePartialProfits()
{
   string comment = PositionGetString(POSITION_COMMENT);
   if(StringFind(comment, "|P1") != -1) return;

   string parts[];
   if(StringSplit(comment, '|', parts) < 8) return; // Updated for new comment format

   double sl_price = StringToDouble(parts[5]);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   if(sl_price == 0) return;

   double initial_risk_pips = MathAbs(open_price - sl_price) / PipSize();
   if(initial_risk_pips <= 0) return;
   long type = PositionGetInteger(POSITION_TYPE);
   double current_profit_pips = (type == POSITION_TYPE_BUY) ?
   (SymbolInfoDouble(symbolName, SYMBOL_BID) - open_price) / PipSize() : (open_price - SymbolInfoDouble(symbolName, SYMBOL_ASK)) / PipSize();
   if(current_profit_pips >= initial_risk_pips * Partial_R_multiple)
   {
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double close_volume = volume * (Partial_Pct / 100.0);
   double lot_step = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   close_volume = MathRound(close_volume / lot_step) * lot_step;
   if(close_volume < lot_step) return;

   if(!MSO_MaySend(_Symbol))
   {
      if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
      {
         PrintFormat("[MSO] defer PartialClose sym=%s reason=guard", _Symbol);
         g_stamp_mso = g_sb.closed_bar_time;
      }
      return;
   }
   if(trade.PositionClosePartial(ticket, close_volume))
   {
     double be_sl_price = open_price + ((type == POSITION_TYPE_BUY) ? BE_Offset_Points * _Point : -BE_Offset_Points * _Point);
     
     if(!MSO_MaySend(_Symbol))
     {
        if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
        {
           PrintFormat("[MSO] defer PartialModify sym=%s reason=guard", _Symbol);
           g_stamp_mso = g_sb.closed_bar_time;
        }
        return; 
     }
     if(trade.PositionModify(ticket, be_sl_price, PositionGetDouble(POSITION_TP)))
     {
       MqlTradeRequest req;
       MqlTradeResult res; ZeroMemory(req);
       req.action = TRADE_ACTION_MODIFY; req.position = ticket;
       req.sl = be_sl_price; req.tp = PositionGetDouble(POSITION_TP);
       req.comment = comment + "|P1";
       if(!OrderSend(req, res)) PrintFormat("%s Failed to send position modify request. Error: %d", EVT_PARTIAL, GetLastError());
     }
     else { PHW_LogFailure(trade.ResultRetcode()); } // T037
   }
   else { PHW_LogFailure(trade.ResultRetcode()); } // T037
   }
}

//+------------------------------------------------------------------+
//| Journaling Functions                                             |
//+------------------------------------------------------------------+
void JournalClosedPosition(ulong position_id)
{
   if(!EnableJournaling || !HistorySelectByPosition(position_id)) return;

   // --- Variables to aggregate and find ---
   datetime time_close_server = 0;
   string   symbol = "";
   string   dir = "";
   double   entry_price = 0;
   double   sl_price_initial = 0;
   double   tp_price_initial = 0;
   double   exit_price = 0;
   double   total_profit = 0;
   double   conf_eff = 0;
   double   ze_strength = 0;
   double   smc_score = 0;
   int      reason_code = 0;
   string   comment_initial = "";
   ulong    magic = 0;

   ulong first_in_ticket = 0;
   ulong last_out_ticket = 0;

   // --- Find the first opening deal and last closing deal for the position ---
   for(int i=0; i < HistoryDealsTotal(); i++)
   {
   ulong deal_ticket = HistoryDealGetTicket(i);
   if(HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) == position_id)
   {
       if(HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
       {
           if(first_in_ticket == 0) first_in_ticket = deal_ticket;
       }
       else
       {
           last_out_ticket = deal_ticket;
       }
       total_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION) + HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   }
   }

   if(first_in_ticket == 0) return; // No opening deal found, cannot journal

   // --- Populate data from the first opening deal ---
   symbol = HistoryDealGetString(first_in_ticket, DEAL_SYMBOL);
   dir = (HistoryDealGetInteger(first_in_ticket, DEAL_TYPE) == DEAL_TYPE_BUY) ? "BUY" : "SELL";
   entry_price = HistoryDealGetDouble(first_in_ticket, DEAL_PRICE);
   comment_initial = HistoryDealGetString(first_in_ticket, DEAL_COMMENT);
   magic = HistoryDealGetInteger(first_in_ticket, DEAL_MAGIC);

   // --- Parse the comment for original trade context ---
   string parts[];
   if(StringSplit(comment_initial, '|', parts) >= 8)
   {
       conf_eff   = StringToDouble(parts[2]);
       reason_code = (int)StringToInteger(parts[3]);
       ze_strength = StringToDouble(parts[4]);
       sl_price_initial = StringToDouble(parts[5]);
       tp_price_initial = StringToDouble(parts[6]);
       smc_score = StringToDouble(parts[7]);
   }

   // --- Populate data from the last closing deal ---
   if(last_out_ticket != 0)
   {
       exit_price = HistoryDealGetDouble(last_out_ticket, DEAL_PRICE);
       time_close_server = (datetime)HistoryDealGetInteger(last_out_ticket, DEAL_TIME);
   }

   // --- Calculate final fields ---
   double sl_pips = (sl_price_initial > 0) ? MathAbs(entry_price - sl_price_initial) / PipSize() : 0;
   double tp_pips = (tp_price_initial > 0) ? MathAbs(entry_price - tp_price_initial) / PipSize() : 0;
   double rr = (sl_pips > 0 && tp_pips > 0) ? tp_pips / sl_pips : 0;
   string reason_text = ReasonCodeToString(reason_code);

   // --- Write to file ---
   int file_handle = FileOpen(JournalFileName, FILE_READ|FILE_WRITE|FILE_CSV|(JournalUseCommonFiles ? FILE_COMMON : 0), ';');
   if(file_handle != INVALID_HANDLE)
   {
   if(FileSize(file_handle) == 0)
   {
       FileWriteString(file_handle, "TimeLocal;TimeServer;Symbol;TF;Dir;Entry;SL;TP;SL_pips;TP_pips;R;Confidence;ZE_Strength;SMC_Score;ReasonCode;ReasonText;Magic;Ticket;Comment\n");
   }
   FileSeek(file_handle, 0, SEEK_END);

   string line = StringFormat("%s;%s;%s;%s;%s;%.5f;%.5f;%.5f;%.1f;%.1f;%.2f;%.0f;%.0f;%.0f;%d;%s;%d;%I64u;%s\n",
                                TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS),
                                TimeToString(time_close_server, TIME_DATE|TIME_SECONDS),
                                symbol,
                                EnumToString(SignalTimeframe),
                                dir,
                                entry_price,
                                sl_price_initial,
                                tp_price_initial,
                                sl_pips,
                                tp_pips,
                                rr,
                                conf_eff,
                                ze_strength,
                                smc_score,
                                reason_code,
                                reason_text,
                                (int)magic,
                                position_id, // Using Position ID as the unique ticket/identifier for the trade
                                comment_initial
                               );
   FileWriteString(file_handle, line);
   FileClose(file_handle);
   }
   else
   {
   PrintFormat("%s Failed to open journal file '%s'. Error: %d", EVT_JOURNAL, JournalFileName, GetLastError());
   }
}

bool IsPositionLogged(ulong position_id)
{
   for(int i=0; i<g_logged_positions_total; i++) if(g_logged_positions[i] == position_id) return true;
   return false;
}
void AddToLoggedList(ulong position_id)
{
   if(IsPositionLogged(position_id)) return;
   int new_size = g_logged_positions_total + 1;
   ArrayResize(g_logged_positions, new_size);
   g_logged_positions[new_size - 1] = position_id;
   g_logged_positions_total = new_size;
}
//+------------------------------------------------------------------+

#endif // AAI_POSMGMT_MQH
