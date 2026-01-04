#ifndef AAI_SLCLUSTER_MQH
#define AAI_SLCLUSTER_MQH

//+------------------------------------------------------------------+
//| >>> T039: SL Cluster Event Processor <<<                         |
//+------------------------------------------------------------------+
void SLC_ProcessEvent(int original_direction, double sl_price, datetime sl_time)
{
    if(!SLC_Enable) return;

    // --- Select direction-specific buffers and state ---
    if(original_direction > 0) // Buy trade was stopped out
    {
        // Push to ring buffer
        g_slc_history_buy[g_slc_head_buy].price = sl_price;
        g_slc_history_buy[g_slc_head_buy].time = sl_time;
        g_slc_head_buy = (g_slc_head_buy + 1) % SLC_History;
        if(g_slc_count_buy < SLC_History) g_slc_count_buy++;

        // Check for cluster
        int cluster_size = 0;
        for(int i = 0; i < g_slc_count_buy; i++)
        {
            if(MathAbs(g_slc_history_buy[i].price - sl_price) <= SLC_ClusterPoints * _Point &&
               (sl_time - g_slc_history_buy[i].time) <= SLC_ClusterWindowSec)
            {
                cluster_size++;
            }
        }

        // Trigger cooldown if cluster detected
        if(cluster_size >= SLC_MinEvents)
        {
            g_slc_repeats_buy++;
            double cool_sec = MathMin(SLC_CooldownMaxSec, SLC_CooldownMinSec * MathPow(SLC_BackoffMultiplier, g_slc_repeats_buy - 1));
g_slc_cool_until_buy  = (datetime)(sl_time + (long)MathRound(cool_sec));
            if(SLC_LogVerbose) PrintFormat("[SLC_EVENT] BUY cluster detected (size=%d), cool until %s", cluster_size, TimeToString(g_slc_cool_until_buy));
        }
    }
    else // Sell trade was stopped out
    {
        // Push to ring buffer
        g_slc_history_sell[g_slc_head_sell].price = sl_price;
        g_slc_history_sell[g_slc_head_sell].time = sl_time;
        g_slc_head_sell = (g_slc_head_sell + 1) % SLC_History;
        if(g_slc_count_sell < SLC_History) g_slc_count_sell++;

        // Check for cluster
        int cluster_size = 0;
        for(int i = 0; i < g_slc_count_sell; i++)
        {
            if(MathAbs(g_slc_history_sell[i].price - sl_price) <= SLC_ClusterPoints * _Point &&
               (sl_time - g_slc_history_sell[i].time) <= SLC_ClusterWindowSec)
            {
                cluster_size++;
            }
        }
       
        // Trigger cooldown if cluster detected
        if(cluster_size >= SLC_MinEvents)
        {
            g_slc_repeats_sell++;
            double cool_sec = MathMin(SLC_CooldownMaxSec, SLC_CooldownMinSec * MathPow(SLC_BackoffMultiplier, g_slc_repeats_sell - 1));
g_slc_cool_until_sell = (datetime)(sl_time + (long)MathRound(cool_sec));
            if(SLC_LogVerbose) PrintFormat("[SLC_EVENT] SELL cluster detected (size=%d), cool until %s", cluster_size, TimeToString(g_slc_cool_until_sell));
        }
    }
}
void AAI_ConfBands_OnEntry(const ulong id, const double conf)
{
   int idx = AAI_ConfBandIndex(conf);
   if(idx < 0) return;

   for(int i = 0; i < AAI_CB_MAX_OPEN; ++i)
   {
      if(AAI_cb_deal[i] == 0 || AAI_cb_deal[i] == id)
      {
         AAI_cb_deal[i] = id;
         AAI_cb_band[i] = idx;
         return;
      }
   }
}




#endif 
//+------------------------------------------------------------------+
//|                                                AAI_SLCluster.mqh |
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
