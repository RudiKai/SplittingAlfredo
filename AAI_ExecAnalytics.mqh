#ifndef AAI_EXECANALYTICS_MQH
#define AAI_EXECANALYTICS_MQH

//+------------------------------------------------------------------+
//| >>> T040: Execution Analytics Helpers <<<                        |
//+------------------------------------------------------------------+
void EA_ResetDay()
{
    // Reset rolling counters, keep EWMAs as they represent a longer-term profile.
    ArrayInitialize(g_ea_state.rej_history, 0);
    g_ea_state.rej_head = 0;
    g_ea_state.rej_count = 0;
}

double EA_RecentRejectRate()
{
    if(g_ea_state.rej_count == 0) return 0.0;
    int sum_rej = 0;
    for(int i = 0; i < g_ea_state.rej_count; i++)
    {
        sum_rej += g_ea_state.rej_history[i];
    }
    return (double)sum_rej / (double)g_ea_state.rej_count;
}

bool OSR_IsRejectRetcode(const uint retcode)
{
    switch(retcode)
    {
        case TRADE_RETCODE_REQUOTE:
        case TRADE_RETCODE_PRICE_OFF:
        case TRADE_RETCODE_PRICE_CHANGED: // Not in OSR_IsRetryable, but is a form of reject
        case TRADE_RETCODE_REJECT:
        case 10025: // TRADE_RETCODE_NO_CONNECTION
        case 10026: // TRADE_RETCODE_TRADE_CONTEXT_BUSY
            return true;
    }
    return false;
}

void EA_LogSendResult(const uint retcode)
{
    if(!EA_Enable) return;
    // Log 1 for a reject, 0 for a successful send.
    int result = OSR_IsRejectRetcode(retcode) ? 1 : 0;
    g_ea_state.rej_history[g_ea_state.rej_head] = result;
    g_ea_state.rej_head = (g_ea_state.rej_head + 1) % EA_RejWindowTrades;
    if(g_ea_state.rej_count < EA_RejWindowTrades)
    {
        g_ea_state.rej_count++;
    }
}

int EA_GetAdaptiveDeviation()
{
    if(!EA_Enable) return InpOSR_SlipPtsInitial;

    double dev_from_slip   = MathCeil(g_ea_state.ewma_slip_pts * EA_DevVsSlipMul);
    double dev_from_spread = MathCeil(CurrentSpreadPoints() * EA_DevVsSpreadFrac);
    double dev = MathMax(EA_BaseDeviationPts, MathMax(dev_from_slip, dev_from_spread));

    if(EA_RecentRejectRate() > 0.20) // Threshold for "elevated" rejects
    {
        dev += EA_RejBumpPts;
    }
    if(g_ea_state.ewma_latency_ms > EA_LatBumpMs)
    {
        dev += EA_LatBumpPts;
    }

    int final_dev = (int)MathMax(EA_MinDeviationPts, MathMin(EA_MaxDeviationPts, dev));

    if(EA_LogVerbose)
    {
        static datetime last_log_time = 0;
        if(g_sb.valid && g_sb.closed_bar_time != last_log_time)
        {
            PrintFormat("[EA] dev=%dpts slipEWMA=%.1f latEWMA=%.0fms rejRate=%.2f spread=%d",
                        final_dev, g_ea_state.ewma_slip_pts, g_ea_state.ewma_latency_ms,
                        EA_RecentRejectRate(), CurrentSpreadPoints());
            last_log_time = g_sb.closed_bar_time;
        }
    }
   
    g_last_dev_pts = final_dev; // T042: Store for telemetry
    return final_dev;
}

#endif 
