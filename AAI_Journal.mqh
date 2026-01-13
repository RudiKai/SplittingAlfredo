#ifndef AAI_JOURNAL_MQH
#define AAI_JOURNAL_MQH

// ====================== AAI JOURNAL HELPERS ======================
#ifndef AAI_EA_LOG_DEFINED
#define AAI_EA_LOG_DEFINED

// Append a line to the AlfredAI journal.
void AAI_AppendJournal(const string line)
{
    if (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
    {
    Print(line);
    return;
    }

    // Live/demo: write to file (optional) and also mirror to Experts log
    string name       = JournalFileName;
    bool   use_common = JournalUseCommonFiles;

    if (name == NULL || name == "")
    {
    Print(line);
    return;
    }

    uint flags = FILE_READ | FILE_WRITE | FILE_TXT;
    if (use_common) flags |= FILE_COMMON;
    int fh = FileOpen(name, flags);
    if (fh == INVALID_HANDLE)
    {
    PrintFormat("[AAI_JOURNAL] open failed (%d) for '%s'", GetLastError(), name);
    Print(line);
    return;
    }

    FileSeek(fh, 0, SEEK_END);
    FileWriteString(fh, line + "\r\n");
    FileFlush(fh);
    FileClose(fh);
    // Mirror to Experts log in live/demo
    Print(line);
}
// RFC3986-ish ASCII encoder for Telegram GET query
string URLEncodeAscii(const string s){
  string out = "";
  const int n = (int)StringLen(s);
  for(int i=0;i<n;i++){
    ushort ch = (ushort)StringGetCharacter(s,i);
    // unreserved
    if((ch>='A'&&ch<='Z')||(ch>='a'&&ch<='z')||(ch>='0'&&ch<='9')||ch=='-'||ch=='_'||ch=='.'||ch=='~'){
      out += (string)ch;
    }else if(ch==' '){
      out += "%20";
    }else{
      out += StringFormat("%%%02X",(int)(ch & 0xFF));
    }
  }
  return out;
}


// Build & write an EXEC line (dir: +1 BUY, -1 SELL).
void AAI_LogExec(const int dir, double lots_hint = 0.0, const string run_id = "adhoc")
{
    double   entry     = 0.0;
    double   sl        = 0.0;
    double   tp        = 0.0;
    double   lots_eff  = (lots_hint > 0.0 ? lots_hint : 0.0);
    datetime ts        = TimeCurrent();

    // If called from OnTradeTransaction on an actual fill, prefer the deal
    if(run_id == "tx" && AAI_last_in_deal > 0 && HistoryDealSelect(AAI_last_in_deal))
    {
        entry = HistoryDealGetDouble(AAI_last_in_deal, DEAL_PRICE);
        ts    = (datetime)HistoryDealGetInteger(AAI_last_in_deal, DEAL_TIME);
        double vol = HistoryDealGetDouble(AAI_last_in_deal, DEAL_VOLUME);
        if(vol > 0.0) lots_eff = vol;
    }
    else
    {
        // Fallback to immediate trade result (after send)
        double r_price  = trade.ResultPrice();
        double r_volume = trade.ResultVolume();
        if(r_price  > 0.0) entry    = r_price;
        if(r_volume > 0.0) lots_eff = r_volume;
    }

// Pull SL/TP and volume from the live position if needed
bool have_pos = false;
ulong pos_ticket = 0;

// If called from OnTradeTransaction path, prefer the exact position id from the last deal
if(run_id == "tx" && AAI_last_in_deal > 0 && HistoryDealSelect(AAI_last_in_deal))
   pos_ticket = (ulong)HistoryDealGetInteger(AAI_last_in_deal, DEAL_POSITION_ID);

if(pos_ticket > 0)
   have_pos = PositionSelectByTicket(pos_ticket);

// Fallback: newest position for this symbol+magic
if(!have_pos)
{
   datetime best_time = 0;
   ulong best_ticket = 0;

   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
      if(pt >= best_time) { best_time = pt; best_ticket = t; }
   }

   if(best_ticket > 0) have_pos = PositionSelectByTicket(best_ticket);
}

if(have_pos)
{
    if(entry   <= 0.0) entry   = PositionGetDouble(POSITION_PRICE_OPEN);
    sl = PositionGetDouble(POSITION_SL);
    tp = PositionGetDouble(POSITION_TP);
    double v = PositionGetDouble(POSITION_VOLUME);
    if(lots_eff <= 0.0 && v > 0.0) lots_eff = v;
}


    // Compute RR if possible
    double rr = 0.0;
    if(entry > 0.0 && sl > 0.0 && tp > 0.0)
    {
        const double risk   = (dir > 0 ? entry - sl : sl - entry);
        const double reward = (dir > 0 ? tp - entry : entry - tp);
        if(risk > 0.0) rr = reward / risk;
    }

    const int  d     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    const string tf  = CurrentTfLabel();
    const string side= (dir > 0 ? "BUY" : "SELL");
    const string tstr= TimeToString(ts, TIME_DATE | TIME_SECONDS);

    string line = StringFormat(
        "EXEC|t=%s|sym=%s|tf=%s|dir=%s|lots=%.2f|entry=%.*f|sl=%.*f|tp=%.*f|rr=%.2f|run=%s",
        tstr, _Symbol, tf, side, lots_eff, d, entry, d, sl, d, tp, rr, run_id
    );

    // Single sink (tester prints, live writes+prints)
    AAI_AppendJournal(line);
}


#endif
// ==================== /AAI JOURNAL HELPERS ======================

#endif // AAI_JOURNAL_MQH
