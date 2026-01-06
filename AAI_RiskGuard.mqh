#ifndef AAI_RISKGUARD_MQH
#define AAI_RISKGUARD_MQH

//+------------------------------------------------------------------+
//| >>> T030: Risk Guard Helpers <<<                                 |
//+------------------------------------------------------------------+
void RG_ResetDay()
{
    MqlDateTime now;
    TimeToStruct(TimeCurrent(), now);

    // Calculate the most recent reset time
    MqlDateTime anchor_dt = now;
    anchor_dt.hour = InpRG_ResetHourServer;
    anchor_dt.min = 0;
    anchor_dt.sec = 0;

    datetime candidate_anchor = StructToTime(anchor_dt);
    if(candidate_anchor > TimeCurrent())
    {
        candidate_anchor -= 86400; // It's tomorrow's anchor, use yesterday's
    }

    g_rg_day_anchor_time = candidate_anchor;
    g_rg_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_rg_day_realized_pl = 0.0;
    g_rg_day_sl_hits = 0;
    g_rg_consec_losses     = 0;  

    // g_rg_consec_losses persists across days unless reset by a win

    g_rg_block_active = false;
    g_rg_block_until = 0;
    PrintFormat("[RISK_GUARD] Day rolled over. Anchor: %s, Start Balance: %.2f", TimeToString(g_rg_day_anchor_time), g_rg_day_start_balance);
   
    // --- T041: Optional Daily Reset for MSM ---
    g_msm_atr_head = 0;
    g_msm_atr_count = 0;
    ArrayInitialize(g_msm_atr_hist, 0.0);
   
    // --- T042: Reset Telemetry Counter ---
    g_tel_barcount = 0;
   
    // --- T043: Reset Parity Harness Counter ---
    g_pth_barcount = 0;
}
void RG_MaybeRollover()
{
  MqlDateTime now; TimeToStruct(TimeCurrent(), now);
  MqlDateTime anchor = now; anchor.hour = InpRG_ResetHourServer; anchor.min = 0; anchor.sec = 0;
  datetime today_anchor = StructToTime(anchor);
  if(today_anchor > TimeCurrent()) today_anchor -= 86400;

  // If stored anchor is before today's anchor, roll the day
  if(g_rg_day_anchor_time < today_anchor){
    RG_ResetDay();
    EA_ResetDay();
  }
}


#endif
