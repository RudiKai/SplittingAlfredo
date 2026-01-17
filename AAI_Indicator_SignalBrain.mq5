//+------------------------------------------------------------------+
//|                  AAI_Indicator_SignalBrain.mq5                   |
//|                    v4.3 - Geometric Confluence                   |
//|                                                                  |
//| Acts as the confluence and trade signal engine.                  |
//| Now aggregates all foundational indicators internally.           |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property version "4.3"

#define SB_BUILD_TAG "SB 4.3.0+TAG999"

// --- Indicator Buffers (Expanded to 7) ---
#property indicator_buffers 7
#property indicator_plots   7 // Must match buffer count for EA/iCustom access.

// --- Buffer 0: Final Signal ---
#property indicator_type1   DRAW_NONE
#property indicator_label1  "FinalSignal"
double FinalSignalBuffer[];

// --- Buffer 1: Final Confidence ---
#property indicator_type2   DRAW_NONE
#property indicator_label2  "FinalConfidence"
double FinalConfidenceBuffer[];

// --- Buffer 2: ReasonCode ---
#property indicator_type3   DRAW_NONE
#property indicator_label3  "ReasonCode"
double ReasonCodeBuffer[];

// --- Buffer 3: Raw ZE Strength ---
#property indicator_type4   DRAW_NONE
#property indicator_label4  "RawZEStrength"
double RawZEStrengthBuffer[];

// --- Buffer 4: Raw SMC Signal ---
#property indicator_type5   DRAW_NONE
#property indicator_label5  "RawSMCSignal"
double RawSMCSignalBuffer[];

// --- Buffer 5: Raw SMC Confidence ---
#property indicator_type6   DRAW_NONE
#property indicator_label6  "RawSMCConfidence"
double RawSMCConfidenceBuffer[];

// --- Buffer 6: Raw BC Bias ---
#property indicator_type7   DRAW_NONE
#property indicator_label7  "RawBCBias"
double RawBCBiasBuffer[];


//--- Indicator Inputs ---
input group "--- Core Settings ---"
input bool SB_SafeTest        = false;
input bool SB_UseZE           = true;
input bool SB_UseBC           = true;
input bool SB_UseSMC          = true;
input int  SB_WarmupBars      = 150;
input int  SB_FastMA          = 5;
input int  SB_SlowMA          = 12;
input int  SB_MinZoneStrength = 4;
input bool EnableDebugLogging = false;

//--- Confluence Bonuses (for Additive model) ---
input group "--- Additive Model Bonuses ---"
input int  SB_Bonus_ZE        = 4;
input int  SB_Bonus_BC        = 4;
input int  SB_Bonus_SMC       = 4;
input int  SB_BaseConf        = 4;
input double Inp_SB_EliteBoost = 15.0;


//--- Pass-through to BiasCompass ---
input group "--- BiasCompass Pass-Through ---"
input int  SB_BC_FastMA       = 5;
input int  SB_BC_SlowMA       = 12;

//--- Pass-through to ZoneEngine ---
input group "--- ZoneEngine Pass-Through ---"
input double SB_ZE_MinImpulseMovePips = 10.0;

//--- Pass-through to SMC ---
input group "--- SMC Pass-Through ---"
input bool   SB_SMC_UseFVG      = true;
input bool   SB_SMC_UseOB       = true;
input bool   SB_SMC_UseBOS      = true;
input double SB_SMC_FVG_MinPips = 1.0;
input int    SB_SMC_OB_Lookback = 20;
input int    SB_SMC_BOS_Lookback= 50;

//--- Confluence Model Selection & Geometric Weights ---
input group "--- Confluence Model ---";
enum ENUM_SB_ConfModel { SB_CONF_ADDITIVE=0, SB_CONF_GEOMETRIC=1 };
input ENUM_SB_ConfModel InpSB_ConfModel = SB_CONF_GEOMETRIC;
input double InpSB_W_BASE = 1.0;
input double InpSB_W_BC   = 1.0;
input double InpSB_W_ZE   = 1.0;
input double InpSB_W_SMC  = 1.0;
input double InpSB_ConflictPenalty = 0.80;


// --- Enums for Clarity ---
enum ENUM_REASON_CODE
{
    REASON_NONE,                  // 0
    REASON_BUY_HTF_CONTINUATION,  // 1
    REASON_SELL_HTF_CONTINUATION, // 2
    REASON_BUY_LIQ_GRAB_ALIGNED,  // 3
    REASON_SELL_LIQ_GRAB_ALIGNED, // 4
    REASON_NO_ZONE,               // 5
    REASON_LOW_ZONE_STRENGTH,     // 6
    REASON_BIAS_CONFLICT,         // 7
    REASON_TEST_SCENARIO          // 8
};

// --- Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) return name;
   return AAI_IND_PREFIX + name;
}

// --- TICKET T023: Helper for Global Variables ---
double GlobalOrDefault(const string name, double def_value)
{
    if(GlobalVariableCheck(name))
    {
        return GlobalVariableGet(name);
    }
    return def_value;
}
// --- Local TF label helper (avoids TfLabel + ENUM_TIMEFRAMES) ---
string AAI_TfLabelFromMinutes(const int tf_minutes)
{
   if(tf_minutes < 60)                    return "M"  + IntegerToString(tf_minutes);
   if(tf_minutes < 1440 && tf_minutes%60==0) return "H"  + IntegerToString(tf_minutes/60);
   if(tf_minutes == 1440)                 return "D1";
   if(tf_minutes == 10080)                return "W1";
   if(tf_minutes == 43200)                return "MN1";
   return IntegerToString(tf_minutes); // fallback
}

string SB_TfLabelFromEnum(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);  // e.g. "PERIOD_M15"
   int p = StringFind(s, "PERIOD_");
   return (p == 0 ? StringSubstr(s, 7) : s); // -> "M15"
}

string SB_GVPrefix()
{
   return StringFormat("AAI/SB/%I64d/%s/%s/",
                       (long)AccountInfoInteger(ACCOUNT_LOGIN),
                       _Symbol,
                       SB_TfLabelFromEnum((ENUM_TIMEFRAMES)_Period));
}


string SB_GVKey(const string leaf) { return SB_GVPrefix() + leaf; }



// --- Indicator Handles ---
int ZE_handle     = INVALID_HANDLE;
int BC_handle     = INVALID_HANDLE;
int SMC_handle    = INVALID_HANDLE;
int fastMA_handle = INVALID_HANDLE;
int slowMA_handle = INVALID_HANDLE;

// --- Globals for one-time logging ---
static datetime g_last_log_time = 0;
static datetime g_last_ze_fail_log_time = 0;
static datetime g_last_bc_fail_log_time = 0;
static datetime g_last_smc_fail_log_time = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
// Effective params (EA pushes namespaced globals; fall back to indicator inputs)
const string kModel = SB_GVKey("ConfModel");
const string kWb    = SB_GVKey("W_BASE");
const string kWbc   = SB_GVKey("W_BC");
const string kWze   = SB_GVKey("W_ZE");
const string kWsmc  = SB_GVKey("W_SMC");
const string kCpen  = SB_GVKey("ConflictPenalty");

int model   = (int)GlobalOrDefault(SB_GVKey("ConfModel"), (double)InpSB_ConfModel);
double wb   = GlobalOrDefault(SB_GVKey("W_BASE"),        InpSB_W_BASE);
double wbc  = GlobalOrDefault(SB_GVKey("W_BC"),          InpSB_W_BC);
double wze  = GlobalOrDefault(SB_GVKey("W_ZE"),          InpSB_W_ZE);
double wsmc = GlobalOrDefault(SB_GVKey("W_SMC"),         InpSB_W_SMC);
double cpen = GlobalOrDefault(SB_GVKey("ConflictPenalty"), InpSB_ConflictPenalty);

int    eff_baseConf   = (int)GlobalOrDefault(SB_GVKey("BaseConf"),        (double)SB_BaseConf);
double eff_eliteBoost =      GlobalOrDefault(SB_GVKey("EliteBoost"),      (double)Inp_SB_EliteBoost);

int    eff_bcFast     = (int)GlobalOrDefault(SB_GVKey("BC_FastMA"),       (double)SB_BC_FastMA);
int    eff_bcSlow     = (int)GlobalOrDefault(SB_GVKey("BC_SlowMA"),       (double)SB_BC_SlowMA);

double eff_zeMinImp   =      GlobalOrDefault(SB_GVKey("ZE_MinImpulseMovePips"), (double)SB_ZE_MinImpulseMovePips);

double eff_fvgMin     =      GlobalOrDefault(SB_GVKey("SMC_FVG_MinPips"), (double)SB_SMC_FVG_MinPips);
int    eff_obLb       = (int)GlobalOrDefault(SB_GVKey("SMC_OB_Lookback"), (double)SB_SMC_OB_Lookback);
int    eff_bosLb      = (int)GlobalOrDefault(SB_GVKey("SMC_BOS_Lookback"),(double)SB_SMC_BOS_Lookback);

// --- EA-driven toggles / warmup / debug (must exist in OnInit too) ---
int  eff_warmup = (int)GlobalOrDefault(SB_GVKey("WarmupBars"), (double)SB_WarmupBars);

bool eff_useZE  = (GlobalOrDefault(SB_GVKey("UseZE"),  (SB_UseZE  ? 1.0 : 0.0)) > 0.5);
bool eff_useBC  = (GlobalOrDefault(SB_GVKey("UseBC"),  (SB_UseBC  ? 1.0 : 0.0)) > 0.5);
bool eff_useSMC = (GlobalOrDefault(SB_GVKey("UseSMC"), (SB_UseSMC ? 1.0 : 0.0)) > 0.5);

bool eff_debug  = (GlobalOrDefault(SB_GVKey("EnableDebugLogging"),
                                  (EnableDebugLogging ? 1.0 : 0.0)) > 0.5);

//




   PrintFormat("[SB_INIT] %s name=%s path=%s now=%s input_model=%d input_wb=%.2f input_wbc=%.2f input_wze=%.2f input_wsmc=%.2f input_cpen=%.2f",
               SB_BUILD_TAG,
               MQLInfoString(MQL_PROGRAM_NAME),
               MQLInfoString(MQL_PROGRAM_PATH),
               TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
               (int)InpSB_ConfModel, InpSB_W_BASE, InpSB_W_BC, InpSB_W_ZE, InpSB_W_SMC, InpSB_ConflictPenalty);

   PrintFormat("[SB_MODEL] gv_model=%.0f eff_model=%d wb=%.2f wbc=%.2f wze=%.2f wsmc=%.2f cpen=%.2f",
GlobalVariableCheck(SB_GVKey("ConfModel")) ? GlobalVariableGet(SB_GVKey("ConfModel")) : -1.0,
               model, wb, wbc, wze, wsmc, cpen);
// --- Effective SB_ARGS (optional GV overrides; otherwise inputs) ---
int    effBaseConf = (int)GlobalOrDefault(SB_GVKey("BaseConf"), (double)SB_BaseConf);
double effElite    =      GlobalOrDefault(SB_GVKey("EliteBoost"), Inp_SB_EliteBoost);

int    effBCFast   = (int)GlobalOrDefault(SB_GVKey("BC_FastMA"), (double)SB_BC_FastMA);
int    effBCSlow   = (int)GlobalOrDefault(SB_GVKey("BC_SlowMA"), (double)SB_BC_SlowMA);

double effZEmin    =      GlobalOrDefault(SB_GVKey("ZE_MinImpulseMovePips"), SB_ZE_MinImpulseMovePips);

bool   effFVG      = (GlobalOrDefault(SB_GVKey("SMC_UseFVG"), SB_SMC_UseFVG?1.0:0.0) > 0.5);
bool   effOB       = (GlobalOrDefault(SB_GVKey("SMC_UseOB"),  SB_SMC_UseOB ?1.0:0.0) > 0.5);
bool   effBOS      = (GlobalOrDefault(SB_GVKey("SMC_UseBOS"), SB_SMC_UseBOS?1.0:0.0) > 0.5);

double effFVGmin   =      GlobalOrDefault(SB_GVKey("SMC_FVG_MinPips"), SB_SMC_FVG_MinPips);
int    effOBLB     = (int)GlobalOrDefault(SB_GVKey("SMC_OB_Lookback"), (double)SB_SMC_OB_Lookback);
int    effBOSLB    = (int)GlobalOrDefault(SB_GVKey("SMC_BOS_Lookback"), (double)SB_SMC_BOS_Lookback);

            
PrintFormat("[SB_ARGS_INP] BaseConf=%d EliteBoost=%.1f BC_MA=%d/%d ZE_MinImpulse=%.2f SMC(FVG/OB/BOS)=%d/%d/%d FVGmin=%.2f OB_lb=%d BOS_lb=%d | ConfModel_inp=%d W_inp=%.2f/%.2f/%.2f/%.2f cpen_inp=%.2f",
            SB_BaseConf, Inp_SB_EliteBoost,
            SB_BC_FastMA, SB_BC_SlowMA,
            SB_ZE_MinImpulseMovePips,
            (int)SB_SMC_UseFVG, (int)SB_SMC_UseOB, (int)SB_SMC_UseBOS,
            SB_SMC_FVG_MinPips, SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback,
            (int)InpSB_ConfModel, InpSB_W_BASE, InpSB_W_BC, InpSB_W_ZE, InpSB_W_SMC, InpSB_ConflictPenalty);

PrintFormat("[SB_ARGS_EFF] BaseConf=%d EliteBoost=%.1f BC_MA=%d/%d ZE_MinImpulse=%.2f SMC(FVG/OB/BOS)=%d/%d/%d FVGmin=%.2f OB_lb=%d BOS_lb=%d | ConfModel_eff=%d W_eff=%.2f/%.2f/%.2f/%.2f cpen_eff=%.2f",
            effBaseConf, effElite,
            effBCFast, effBCSlow,
            effZEmin,
            (int)effFVG, (int)effOB, (int)effBOS,
            effFVGmin, effOBLB, effBOSLB,
            model, wb, wbc, wze, wsmc, cpen);

       
            
    // --- Bind all 7 data buffers ---
    SetIndexBuffer(0, FinalSignalBuffer,      INDICATOR_DATA);
    SetIndexBuffer(1, FinalConfidenceBuffer,  INDICATOR_DATA);
    SetIndexBuffer(2, ReasonCodeBuffer,       INDICATOR_DATA);
    SetIndexBuffer(3, RawZEStrengthBuffer,    INDICATOR_DATA);
    SetIndexBuffer(4, RawSMCSignalBuffer,     INDICATOR_DATA);
    SetIndexBuffer(5, RawSMCConfidenceBuffer, INDICATOR_DATA);
    SetIndexBuffer(6, RawBCBiasBuffer,        INDICATOR_DATA);

    // --- Set buffers as series arrays ---
    ArraySetAsSeries(FinalSignalBuffer,      true);
    ArraySetAsSeries(FinalConfidenceBuffer,  true);
    ArraySetAsSeries(ReasonCodeBuffer,       true);
    ArraySetAsSeries(RawZEStrengthBuffer,    true);
    ArraySetAsSeries(RawSMCSignalBuffer,     true);
    ArraySetAsSeries(RawSMCConfidenceBuffer, true);
    ArraySetAsSeries(RawBCBiasBuffer,        true);

    // --- Set empty values for buffers ---
    for(int i = 0; i < 7; i++)
    {
        PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, 0.0);
    }
    IndicatorSetInteger(INDICATOR_DIGITS,0);

    // --- Create dependent indicator handles ---
int eff_fastMA = (int)GlobalOrDefault(SB_GVKey("FastMA"), (double)SB_FastMA);
int eff_slowMA = (int)GlobalOrDefault(SB_GVKey("SlowMA"), (double)SB_SlowMA);

fastMA_handle = iMA(_Symbol, _Period, eff_fastMA, 0, MODE_SMA, PRICE_CLOSE);
slowMA_handle = iMA(_Symbol, _Period, eff_slowMA, 0, MODE_SMA, PRICE_CLOSE);
    if(fastMA_handle == INVALID_HANDLE || slowMA_handle == INVALID_HANDLE)
    {
        Print("[SB_ERR] Failed to create one or more MA handles.");
        return(INIT_FAILED);
    }

if(eff_useZE)
{
   ZE_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_ZoneEngine"), eff_zeMinImp, true);
   if(ZE_handle == INVALID_HANDLE) Print("[SB_WARN] Failed to create ZoneEngine handle.");
}
if(eff_useBC)
{
   BC_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_BiasCompass"), eff_bcFast, eff_bcSlow);
   if(BC_handle == INVALID_HANDLE) Print("[SB_WARN] Failed to create BiasCompass handle.");
}
if(eff_useSMC)
{
   bool effFVG = (GlobalOrDefault(SB_GVKey("SMC_UseFVG"), SB_SMC_UseFVG ? 1.0 : 0.0) > 0.5);
   bool effOB  = (GlobalOrDefault(SB_GVKey("SMC_UseOB"),  SB_SMC_UseOB  ? 1.0 : 0.0) > 0.5);
   bool effBOS = (GlobalOrDefault(SB_GVKey("SMC_UseBOS"), SB_SMC_UseBOS ? 1.0 : 0.0) > 0.5);

   SMC_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_SMC"),
                        effFVG,
                        effOB,
                        effBOS,
                        eff_warmup,     // IMPORTANT: EA-driven warmup
                        eff_fvgMin,
                        eff_obLb,
                        eff_bosLb);

   if(SMC_handle == INVALID_HANDLE) Print("[SB_WARN] Failed to create SMC handle.");
}

    double tmp[1];

if(BC_handle != INVALID_HANDLE)
    {
       for(int bi=0; bi<1; bi++)
       {
          ResetLastError();
          int got = CopyBuffer(BC_handle, bi, 1, 1, tmp);
          // <--- WRAPPED
          if(eff_debug)

             PrintFormat("[SB_PROBE] BC buf=%d got=%d val=%.5f err=%d", bi, got, (got>0?tmp[0]:0.0), GetLastError());
       }
    }

    if(ZE_handle != INVALID_HANDLE)
    {
       for(int bi=0; bi<1; bi++)
       {
          ResetLastError();
          int got = CopyBuffer(ZE_handle, bi, 1, 1, tmp);
          // <--- WRAPPED
         if(eff_debug)

             PrintFormat("[SB_PROBE] ZE buf=%d got=%d val=%.5f err=%d", bi, got, (got>0?tmp[0]:0.0), GetLastError());
       }
    }
    if(SMC_handle != INVALID_HANDLE)
    {
       for(int bi=0; bi<3; bi++) // 0=sig, 1=conf, 2=reason (adjust if needed)
       {
          ResetLastError();
          int got = CopyBuffer(SMC_handle, bi, 1, 1, tmp);
          // <--- WRAPPED
        if(eff_debug)

             PrintFormat("[SB_PROBE] SMC buf=%d got=%d val=%.5f err=%d", bi, got, (got>0?tmp[0]:0.0), GetLastError());
       }
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ZE_handle != INVALID_HANDLE) IndicatorRelease(ZE_handle);
    if(BC_handle != INVALID_HANDLE) IndicatorRelease(BC_handle);
    if(SMC_handle != INVALID_HANDLE) IndicatorRelease(SMC_handle);
    if(fastMA_handle != INVALID_HANDLE) IndicatorRelease(fastMA_handle);
    if(slowMA_handle != INVALID_HANDLE) IndicatorRelease(slowMA_handle);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{

// --- Effective config (EA -> SB via GlobalVariables) ---
int  eff_warmup = (int)GlobalOrDefault(SB_GVKey("WarmupBars"), (double)SB_WarmupBars);

bool eff_useZE  = (GlobalOrDefault(SB_GVKey("UseZE"),  (SB_UseZE  ? 1.0 : 0.0)) > 0.5);
bool eff_useBC  = (GlobalOrDefault(SB_GVKey("UseBC"),  (SB_UseBC  ? 1.0 : 0.0)) > 0.5);
bool eff_useSMC = (GlobalOrDefault(SB_GVKey("UseSMC"), (SB_UseSMC ? 1.0 : 0.0)) > 0.5);

bool eff_debug  = (GlobalOrDefault(SB_GVKey("EnableDebugLogging"),
                                  (EnableDebugLogging ? 1.0 : 0.0)) > 0.5);

if(rates_total < eff_warmup)
    {
        for(int i = 0; i < rates_total; i++)
        {
            FinalSignalBuffer[i] = 0; FinalConfidenceBuffer[i] = 0; ReasonCodeBuffer[i] = REASON_NONE;
            RawZEStrengthBuffer[i] = 0; RawSMCSignalBuffer[i] = 0; RawSMCConfidenceBuffer[i] = 0; RawBCBiasBuffer[i] = 0;
        }
return(rates_total);
    }
    
    int start_bar = rates_total - 2;
    if(prev_calculated > 0)
    {
        start_bar = rates_total - prev_calculated;
    }
start_bar = MathMax(1, start_bar);

static int hist[11];        // 0-10,10-20,...,90-100
static bool hist_done=false;
static double cmin=1e9, cmax=-1e9, csum=0.0;
static long ccount=0;


// --- Read effective globals ONCE per call ---
const string kModel = SB_GVKey("ConfModel");
const string kWb    = SB_GVKey("W_BASE");
const string kWbc   = SB_GVKey("W_BC");
const string kWze   = SB_GVKey("W_ZE");
const string kWsmc  = SB_GVKey("W_SMC");
const string kCpen  = SB_GVKey("ConflictPenalty");

int model   = (int)GlobalOrDefault(SB_GVKey("ConfModel"), (double)InpSB_ConfModel);
double wb   = GlobalOrDefault(SB_GVKey("W_BASE"),        InpSB_W_BASE);
double wbc  = GlobalOrDefault(SB_GVKey("W_BC"),          InpSB_W_BC);
double wze  = GlobalOrDefault(SB_GVKey("W_ZE"),          InpSB_W_ZE);
double wsmc = GlobalOrDefault(SB_GVKey("W_SMC"),         InpSB_W_SMC);
double cpen = GlobalOrDefault(SB_GVKey("ConflictPenalty"), InpSB_ConflictPenalty);



int    eff_baseConf   = (int)GlobalOrDefault(SB_GVKey("BaseConf"), (double)SB_BaseConf);
double eff_eliteBoost =      GlobalOrDefault(SB_GVKey("EliteBoost"), (double)Inp_SB_EliteBoost);

int eff_minZone = (int)GlobalOrDefault(SB_GVKey("MinZoneStrength"), (double)SB_MinZoneStrength);
int eff_bZE     = (int)GlobalOrDefault(SB_GVKey("Bonus_ZE"), (double)SB_Bonus_ZE);
int eff_bBC     = (int)GlobalOrDefault(SB_GVKey("Bonus_BC"), (double)SB_Bonus_BC);
int eff_bSMC    = (int)GlobalOrDefault(SB_GVKey("Bonus_SMC"), (double)SB_Bonus_SMC);


for(int i = start_bar; i >= 1; i--)
{
        double finalSignal = 0.0;
        double finalConfidence = 0.0;
        ENUM_REASON_CODE reasonCode = REASON_NONE;
        double rawZEStrength=0, rawSMCConfidence=0, rawBCBias=0;
        double rawSMCSignal=0;

        // --- 1. Base Signal: MA Cross ---
        double fast_arr[1], slow_arr[1];
        if (CopyBuffer(fastMA_handle, 0, i, 1, fast_arr) > 0 && CopyBuffer(slowMA_handle, 0, i, 1, slow_arr) > 0)
        {
            if(fast_arr[0] != 0.0 && slow_arr[0] != 0.0)
            {
               if(fast_arr[0] > slow_arr[0]) { finalSignal = 1.0; reasonCode = REASON_BUY_HTF_CONTINUATION; }
               else if(fast_arr[0] < slow_arr[0]) { finalSignal = -1.0; reasonCode = REASON_SELL_HTF_CONTINUATION; }
            }
        }

// --- 2. Read Raw Data from Foundational Indicators (with diagnostics) ---
        if(eff_useZE && ZE_handle != INVALID_HANDLE)
        {
           double v[1];
           ResetLastError();
           int got = CopyBuffer(ZE_handle, 0, i, 1, v);
           if(got <= 0) {
              // <--- WRAPPED Option A
              if(eff_debug)
                 PrintFormat("[SB_DBG] ZE CopyBuffer fail i=%d err=%d", i, GetLastError());
           } else {
              rawZEStrength = v[0];
           }
        }

        if(eff_useBC && BC_handle != INVALID_HANDLE)
        {
           double v[1];
           ResetLastError();
           int got = CopyBuffer(BC_handle, 0, i, 1, v);
           if(got <= 0) {
              // <--- WRAPPED Option A
              if(eff_debug)
                 PrintFormat("[SB_DBG] BC CopyBuffer fail i=%d err=%d", i, GetLastError());
           } else {
              rawBCBias = v[0];
           }
        }

        if(eff_useSMC && SMC_handle != INVALID_HANDLE)
        {
           double v[1];

           ResetLastError();
           int got0 = CopyBuffer(SMC_handle, 0, i, 1, v);
           if(got0 <= 0) {
              // <--- WRAPPED Option A
              if(eff_debug)
                 PrintFormat("[SB_DBG] SMC buf0(signal) CopyBuffer fail i=%d err=%d", i, GetLastError());
           } else {
              rawSMCSignal = v[0];
           }

           ResetLastError();
           int got1 = CopyBuffer(SMC_handle, 1, i, 1, v);
           if(got1 <= 0) {
              // <--- WRAPPED Option A
              if(eff_debug)
                 PrintFormat("[SB_DBG] SMC buf1(conf) CopyBuffer fail i=%d err=%d", i, GetLastError());
           } else {
              rawSMCConfidence = v[0];
           }
        }
// --- 2b. Smart Entry Pricing Logic (Option B) ---
        double smartEntryPrice = close[i]; // Default to Market (Close)
        
   if(finalSignal != 0.0)
        {
            // STRATEGY 1: SMC Precision (Highest Priority)
            if(eff_useSMC && rawSMCSignal != 0 && rawSMCSignal == finalSignal)
            {
                // If SMC signal is active, we try to grab the specific level
                // (Assuming your SMC indicator outputs the level in a buffer, or we approximate)
                // For this version, we use a "0.382 Retracement" of the signal bar as a proxy 
                // for an Order Block retest if exact OB price isn't in a buffer.
                double bar_range = high[i] - low[i];
                if(finalSignal > 0) smartEntryPrice = low[i] + bar_range * 0.382; // Buy Dip
                else                smartEntryPrice = high[i] - bar_range * 0.382; // Sell Rally
            }
            // STRATEGY 2: Volatility Retracement (Standard Trend)
            else
            {
                // "Discount Entry": Don't buy the top. Buy the 50% pullback of the breakout candle.
                double mid_point = (high[i] + low[i]) / 2.0;
                smartEntryPrice = mid_point;
            }
            
            // Safety: Ensure we don't price it BEYOND the close (which would make it a Stop order)
            // For a LIMIT order:
            // Buy Limit must be < Current Close
            // Sell Limit must be > Current Close
            if(finalSignal > 0) smartEntryPrice = MathMin(smartEntryPrice, close[i]); 
            else                smartEntryPrice = MathMax(smartEntryPrice, close[i]);
        }
       
        // --- 3. Calculate Final Confidence based on selected model ---
        if (finalSignal != 0.0)
        {
if(model == 1) // Geometric Model
{
   double eps = 1e-9;

   double wsum = 0.0;
   double logsum = 0.0;

   // Base always included (Base is a FLOOR, not a probability)
   double p_base = MathMax(eps, MathMin(1.0, 0.5 + (double)eff_baseConf / 200.0));
   wsum += wb;
   logsum += wb * MathLog(p_base);

   // BC
   if(eff_useBC && MathAbs(rawBCBias) > 1e-6)
   {
      double bc_dir = rawBCBias * finalSignal; // aligned positive, conflict negative
      bc_dir = MathMax(-1.0, MathMin(1.0, bc_dir));
      double p_bc = 0.5 + 0.5 * bc_dir;        // map [-1..+1] -> [0..1]
      p_bc = MathMax(eps, MathMin(1.0, p_bc));
      wsum += wbc;
      logsum += wbc * MathLog(p_bc);
   }

   // ZE
if(eff_useZE && rawZEStrength >= eff_minZone)
   {
      double p_ze = 0.45 + 0.05 * MathMin(10.0, rawZEStrength); // strength 4–10 → ~0.65–0.95
      p_ze = MathMax(eps, MathMin(1.0, p_ze));
      wsum += wze;
      logsum += wze * MathLog(p_ze);
   }

   // SMC
   if(eff_useSMC && rawSMCSignal != 0.0)
   {
      double smc01 = 0.6 + 0.04 * MathMin(10.0, rawSMCConfidence);
      smc01 = MathMax(eps, MathMin(1.0, smc01));
      double p_smc = (rawSMCSignal * finalSignal > 0.0) ? smc01 : (smc01 * cpen);
      wsum += wsmc;
      logsum += wsmc * MathLog(MathMax(eps, MathMin(1.0, p_smc)));
   }

   double p_geom = MathExp(logsum / MathMax(eps, wsum));
   finalConfidence = MathMax(0.0, MathMin(100.0, p_geom * 100.0));

   // Safety floor: cannot drop below base
   finalConfidence = MathMax(finalConfidence, (double)eff_baseConf);

   // Elite boost
   if(
      rawZEStrength >= 9.0 &&
      rawSMCSignal != 0.0 &&
      rawSMCSignal == finalSignal &&
      rawSMCConfidence >= 8.0 &&
      MathAbs(rawBCBias) < 1e-6
   )
      finalConfidence += eff_eliteBoost;

   finalConfidence = MathMin(finalConfidence, 100.0);
}
else // Additive Model
{
   finalConfidence = (double)eff_baseConf;

   bool conflict = false;

   // ZE adds confidence only if strong enough
if(eff_useZE && rawZEStrength >= eff_minZone)
      finalConfidence += eff_bZE;

   // BC adds if aligned, flags conflict otherwise
   if(eff_useBC && MathAbs(rawBCBias) > 1e-6)
   {
      if(rawBCBias * finalSignal > 0.0) finalConfidence += eff_bBC;
      else conflict = true;
   }

   // SMC adds if aligned, flags conflict otherwise
   if(eff_useSMC && rawSMCSignal != 0.0)
   {
      if(rawSMCSignal * finalSignal > 0.0) finalConfidence += eff_bSMC;
      else conflict = true;
   }

   if(conflict)
      finalConfidence *= cpen;

// Elite boost (apply once)
if(
   rawZEStrength >= 9.0 &&
   rawSMCSignal != 0.0 &&
   rawSMCSignal == finalSignal &&
   rawSMCConfidence >= 8.0 &&
   MathAbs(rawBCBias) < 1e-6
)
   finalConfidence += eff_eliteBoost;

// Final clamp once
finalConfidence = MathMax(0.0, MathMin(100.0, finalConfidence));


}

double c = fmax(0.0, fmin(100.0, finalConfidence));
int bin = (int)MathFloor(c / 10.0);
if(bin < 0) bin = 0;
if(bin > 10) bin = 10;

hist[bin]++;
ccount++;
csum += c;
if(c < cmin) cmin = c;
if(c > cmax) cmax = c;

}

        // --- 4. Write ALL buffers ---
// Encode Price into Signal: 
        // Positive Price = BUY LIMIT (e.g. 1.0500)
        // Negative Price = SELL LIMIT (e.g. -1.0500)
        if(finalSignal == 0.0) FinalSignalBuffer[i] = 0.0;
        else FinalSignalBuffer[i] = (finalSignal > 0) ? smartEntryPrice : -smartEntryPrice;
        FinalConfidenceBuffer[i]  = fmax(0.0, fmin(100.0, finalConfidence));
        ReasonCodeBuffer[i]       = (finalSignal != 0.0) ? (double)reasonCode : (double)REASON_NONE;
        RawZEStrengthBuffer[i]    = rawZEStrength;
        RawSMCSignalBuffer[i]     = rawSMCSignal;
        RawSMCConfidenceBuffer[i] = rawSMCConfidence;
        RawBCBiasBuffer[i]        = rawBCBias;
    }

    // --- Mirror last closed bar to current bar ---
    if (rates_total > 1)
    {
        FinalSignalBuffer[0] = FinalSignalBuffer[1]; FinalConfidenceBuffer[0] = FinalConfidenceBuffer[1]; ReasonCodeBuffer[0] = ReasonCodeBuffer[1];
        RawZEStrengthBuffer[0] = RawZEStrengthBuffer[1]; RawSMCSignalBuffer[0] = RawSMCSignalBuffer[1]; RawSMCConfidenceBuffer[0] = RawSMCConfidenceBuffer[1]; RawBCBiasBuffer[0] = RawBCBiasBuffer[1];
    }
    
    // --- Optional Debug Logging ---
static datetime last_log = 0;
datetime t = iTime(_Symbol, _Period, 1);

if(eff_debug && t != last_log)
{
   PrintFormat("[DBG_SB_FINAL] eff_model=%d t=%s conf=%.2f ze=%.2f smc_s=%.0f smc_c=%.2f bc=%.2f",
               model, TimeToString(t),
               FinalConfidenceBuffer[1],
               RawZEStrengthBuffer[1],
               RawSMCSignalBuffer[1], RawSMCConfidenceBuffer[1],
               RawBCBiasBuffer[1]);

   last_log = t;
}
if(!hist_done && ccount > 0)
{
   double mean = csum / (double)ccount;
   PrintFormat("[SB_HIST] eff_model=%d bars=%lld min=%.2f max=%.2f mean=%.2f | 0-10=%d 10-20=%d 20-30=%d 30-40=%d 40-50=%d 50-60=%d 60-70=%d 70-80=%d 80-90=%d 90-100=%d 100=%d",
      model, ccount, cmin, cmax, mean,
      hist[0],hist[1],hist[2],hist[3],hist[4],hist[5],hist[6],hist[7],hist[8],hist[9],hist[10]
   );
   hist_done = true;
}



    return(rates_total);
}
//+------------------------------------------------------------------+
