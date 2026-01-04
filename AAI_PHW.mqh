#ifndef AAI_PHW_MQH
#define AAI_PHW_MQH


//+------------------------------------------------------------------+
//| >>> T037: Position Health Watchdog (PHW) Helpers <<<             |
//+------------------------------------------------------------------+
bool PHW_IsQualifyingFailure(const uint retcode)
{
    switch(retcode)
    {
        case TRADE_RETCODE_REQUOTE:
        case TRADE_RETCODE_PRICE_OFF:
        case TRADE_RETCODE_REJECT:
        case 10025: // TRADE_RETCODE_NO_CONNECTION
        case 10026: // TRADE_RETCODE_TRADE_CONTEXT_BUSY
            return true;
    }
    return false;
}

void PHW_LogFailure(const uint retcode)
{
    if(!PHW_Enable || !PHW_IsQualifyingFailure(retcode)) return;

    datetime now = TimeCurrent();
    // Prune old timestamps from the circular buffer
    int new_size = 0;
    for(int i = 0; i < g_phw_fail_count; i++)
    {
        if(now - g_phw_fail_timestamps[i] <= PHW_FailBurstWindowSec)
        {
            if (new_size != i) g_phw_fail_timestamps[new_size] = g_phw_fail_timestamps[i];
            new_size++;
        }
    }
    g_phw_fail_count = new_size;

    // Add the new failure
    ArrayResize(g_phw_fail_timestamps, g_phw_fail_count + 1);
    g_phw_fail_timestamps[g_phw_fail_count] = now;
    g_phw_fail_count++;
}



#endif 
//+------------------------------------------------------------------+
//|                                                      AAI_PHW.mqh |
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
