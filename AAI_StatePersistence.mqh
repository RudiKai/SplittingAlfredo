

#ifndef AAI_STATEPERSISTENCE_MQH
#define AAI_STATEPERSISTENCE_MQH
//+------------------------------------------------------------------+
//| >>> T044: State Persistence (SP v1) Helpers <<<                  |
//+------------------------------------------------------------------+
string SP_FileName()
{
string prog = MQLInfoString(MQL_PROGRAM_NAME);
StringReplace(prog, ".ex5", "");
StringReplace(prog, ".mq5", "");

// sanitize path-ish chars
StringReplace(prog, "\\", "_");
StringReplace(prog, "/",  "_");
StringReplace(prog, ":",  "_");

return StringFormat("%s_%s_%d_%s_%s.spv",
                    SP_FilePrefix,
                    prog,
                    (int)AccountInfoInteger(ACCOUNT_LOGIN),
                    _Symbol,
                    CurrentTfLabel());  // <-- respects SignalTimeframe if set

}

string EA_RejectHistoryToString()
{
    string s = "";
    if (g_ea_state.rej_count > 0) {
        for (int i = 0; i < g_ea_state.rej_count; i++) {
            s += IntegerToString(g_ea_state.rej_history[i]);
        }
    }
    return s;
}

void EA_RejectHistoryFromString(const string s)
{
    ArrayInitialize(g_ea_state.rej_history, 0);
    int len = StringLen(s);

    // Do NOT set rej_count here. The caller (SP_Load) does it.

    for(int i = 0; i < len && i < EA_RejWindowTrades; i++) {
        g_ea_state.rej_history[i] = (int)StringToInteger(StringSubstr(s, i, 1));
    }
}


bool SP_Save(bool force)
{
// Never write persistence in Strategy Tester / Optimization (prevents slowdown + cross-run contamination)
if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
   return false;

    if(!SP_Enable) return false;
    if(!force && (SP_WriteEveryN <= 0 || (g_sp_barcount % SP_WriteEveryN) != 0)) return false;

    string rej_hist_str = EA_RejectHistoryToString();
    string core = StringFormat("ST|ver=%d|t=%s|sym=%s|tf=%s|"
                               "phw_until=%I64d|phw_rep=%d|"
                               "slc_b_until=%I64d|slc_s_until=%I64d|slc_b_rep=%d|slc_s_rep=%d|"
                               "ea_slip=%.4f|ea_lat=%.2f|ea_dev=%d|rej_head=%d|rej_cnt=%d|rej=%s|"
                               "ecf_ewma=%.4f|curve=%.2f|peak=%.2f|day=%I64d",
                               SP_Version, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, CurrentTfLabel(),
                               (long)g_phw_cool_until, g_phw_repeats_today,
                               (long)g_slc_cool_until_buy, (long)g_slc_cool_until_sell, g_slc_repeats_buy, g_slc_repeats_sell,
                               g_ea_state.ewma_slip_pts, g_ea_state.ewma_latency_ms, g_last_dev_pts, g_ea_state.rej_head, g_ea_state.rej_count, rej_hist_str,
                               g_ecf_ewma, AAI_curve, AAI_peak, (long)g_rg_day_anchor_time);

uint hash = FNV1a32(core);
string final_line = StringFormat("%s|h=%u", core, hash);


    string fn = SP_FileName();
    int h = FileOpen(fn, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if (h == INVALID_HANDLE) {
        if(SP_LogVerbose) PrintFormat("[SP] Save failed to open %s", fn);
        return false;
    }
    FileWriteString(h, final_line + "\r\n");
    FileClose(h);
    if(SP_LogVerbose) PrintFormat("[SP] State saved to %s", fn);
    return true;
}

bool SP_Load()
{
    if(!SP_Enable) return false;
    if(MQLInfoInteger(MQL_TESTER) && !SP_LoadInTester) return false;

    string fn = SP_FileName();
    if(!FileIsExist(fn, FILE_COMMON)) {
        if(SP_LogVerbose) PrintFormat("[SP] No state file found at %s", fn);
        return false;
    }

    int h = FileOpen(fn, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if (h == INVALID_HANDLE) {
        if(SP_LogVerbose) PrintFormat("[SP] Load failed to open %s", fn);
        return false;
    }
    string line = FileReadString(h);
    FileClose(h);
    StringTrimRight(line);

int p_hash = StringFind(line, "|h=", 0);
if(p_hash < 0) return false;
string core = StringSubstr(line, 0, p_hash);
string hash_str = StringSubstr(line, p_hash + 3);
uint file_hash = (uint)StringToInteger(hash_str);
uint calc_hash = FNV1a32(core);


    if(file_hash != calc_hash) {
        if(SP_LogVerbose) PrintFormat("[SP] Hash mismatch. File: 0x%08X, Calc: 0x%08X", file_hash, calc_hash);
        return false;
    }

    datetime loaded_day_anchor = 0;

    string parts[];
    int n = StringSplit(core, '|', parts);
    for(int i=0; i<n; i++) {
        string kv[];
        if(StringSplit(parts[i], '=', kv) != 2) continue;
        string k = kv[0];
        string v = kv[1];

        if(k=="ver" && (int)StringToInteger(v) != SP_Version) { if(SP_LogVerbose) Print("[SP] Version mismatch"); return false; }
        if(k=="sym" && v != _Symbol) { if(SP_LogVerbose) Print("[SP] Symbol mismatch"); return false; }
       if(k=="tf" && v != CurrentTfLabel()) { if(SP_LogVerbose) Print("[SP] Timeframe mismatch"); return false; }


        if(k=="phw_until")   g_phw_cool_until = (datetime)StringToInteger(v);
        if(k=="phw_rep")     g_phw_repeats_today = (int)StringToInteger(v);
        if(k=="slc_b_until") g_slc_cool_until_buy = (datetime)StringToInteger(v);
        if(k=="slc_s_until") g_slc_cool_until_sell = (datetime)StringToInteger(v);
        if(k=="slc_b_rep")   g_slc_repeats_buy = (int)StringToInteger(v);
        if(k=="slc_s_rep")   g_slc_repeats_sell = (int)StringToInteger(v);
        if(k=="ea_slip")     g_ea_state.ewma_slip_pts = StringToDouble(v);
        if(k=="ea_lat")      g_ea_state.ewma_latency_ms = StringToDouble(v);
        if(k=="ea_dev")      g_last_dev_pts = (int)StringToInteger(v);
        if(k=="rej_head")    g_ea_state.rej_head = (int)StringToInteger(v);
        if(k=="rej_cnt")     g_ea_state.rej_count = (int)StringToInteger(v);
        if(k=="rej")         EA_RejectHistoryFromString(v);
        if(k=="ecf_ewma")    g_ecf_ewma = StringToDouble(v);
        if(k=="curve")       AAI_curve = StringToDouble(v);
        if(k=="peak")        AAI_peak = StringToDouble(v);
        if(k=="day")         loaded_day_anchor = (datetime)StringToInteger(v);
    }
   
    datetime now = TimeCurrent();
    if(g_phw_cool_until < now) g_phw_cool_until = 0;
    if(g_slc_cool_until_buy < now) g_slc_cool_until_buy = 0;
    if(g_slc_cool_until_sell < now) g_slc_cool_until_sell = 0;
   
    // Check if the loaded day anchor corresponds to a different day than now.
    MqlDateTime dt_now; TimeToStruct(now, dt_now);
    MqlDateTime dt_anchor; TimeToStruct(loaded_day_anchor, dt_anchor);
    if(dt_now.year != dt_anchor.year || dt_now.mon != dt_anchor.mon || dt_now.day != dt_anchor.day) {
        g_phw_repeats_today = 0;
        g_slc_repeats_buy = 0;
        g_slc_repeats_sell = 0;
        if(SP_LogVerbose) Print("[SP] Day changed since last state, backoff counters reset.");
    }

    if(SP_LogVerbose) PrintFormat("[SP] State loaded successfully from %s", fn);
    return true;
}
void AAI_ConfBands_Reset()
  {
   ArrayInitialize(AAI_cb_deal, 0);
   ArrayInitialize(AAI_cb_band, -1);

   ArrayInitialize(AAI_cb_trades, 0);
   ArrayInitialize(AAI_cb_wins,   0);
   ArrayInitialize(AAI_cb_losses, 0);
   ArrayInitialize(AAI_cb_net,    0.0);
   ArrayInitialize(AAI_cb_pos,    0.0);
   ArrayInitialize(AAI_cb_neg,    0.0);
  }


#endif 

