#include "inc/AAI_Metrics.mqh"
//+------------------------------------------------------------------+
//| AAI_EA_Trade_Manager.mq5                                         |       
//|                                       v5.12 - Telemetry v2       |
//|            HEDGING INPUTS ADDED                                  |
//| (Consumes all data from the refactored AAI_Indicator_SignalBrain)|
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property version   "5.12"
#property description "Manages trades based on signals from the central SignalBrain indicator."

#include <Trade\Trade.mqh>
#include <Arrays\ArrayObj.mqh>
#include <Arrays\ArrayLong.mqh>
#include <AAI/AAI_Include_News.mqh>          //// this is still to be built...

// --- Forward Declarations (needed because used before defined) ---
void   PHW_LogFailure(const uint retcode);
int    CountMyPositions(const string sym, const long magic, int &longCnt, int &shortCnt);
double NormalizeLots(double lots);
// --- End Forward Declarations ---

// === T49: Account-wide New-Position Throttle (default OFF) ===============

// === T49: Account-wide New-Position Throttle (default OFF) ===============
const bool T49_Enable     = true;             // leave OFF by default
const bool T49_LogVerbose = RTP_IS_DIAG;       // logs only in Diagnostics profile
static datetime g_t49_last_log = 0;

bool T49_MayOpenThisBar(const datetime bar_time)
{
   if(!InpT49_EnableBarLock)
      return(true);
   if(!T49_Enable) return true;

   const string k = "AAI/ACC/BARLOCK";
   double v = 0.0;

   if(GlobalVariableCheck(k))
   {
      v = GlobalVariableGet(k);
      if((datetime)v == bar_time)
      {
         if(T49_LogVerbose && bar_time != g_t49_last_log)
         {
            PrintFormat("[T49] throttle: position already opened @ %s",
                        TimeToString(bar_time, TIME_DATE|TIME_SECONDS));
            g_t49_last_log = bar_time;
         }
                  AAI_t49_blocks++;            // <--- NEW: count this blocked entry

         return false;
      }
   }

   // Claim this bar for the account so other charts skip new entries this bar
   GlobalVariableSet(k, (double)bar_time);
   return true;
}

// === T50 prototypes (bodies are elsewhere in the file) ====================
// === T50: Failsafe / Self-check (default OFF) =============================
enum { T50_RING = 16 };
const bool T50_Enable           = true;    // default OFF
const int  T50_ErrorWindowBars  = 5;        // failures within this many bars…
const int  T50_SuspendBars      = 10;       // …suspend for N bars
const bool T50_LogVerbose       = RTP_IS_DIAG;

static datetime g_t50_err_ring[T50_RING];
static int      g_t50_err_head  = 0;
static int      g_t50_err_count = 0;
static datetime g_t50_suspend_until = 0;
static datetime g_t50_last_log = 0;

void T50_RecordSendFailure(const datetime bar_time)
{
   if(!InpT50_EnableFailGuard) return;
   if(!T50_Enable) return; // feature flag

   g_t50_err_ring[g_t50_err_head] = bar_time;
   g_t50_err_head = (g_t50_err_head + 1) % T50_RING;
   if(g_t50_err_count < T50_RING) g_t50_err_count++;

   int within = 0;
   const int ps = PeriodSeconds((ENUM_TIMEFRAMES)SignalTimeframe);
   const int win = MathMax(1, InpT50_WindowBars);
   const datetime window_start = bar_time - (ps * (win-1));

   for(int i=0;i<g_t50_err_count;i++)
   {
      int idx = (g_t50_err_head - 1 - i + T50_RING) % T50_RING;
      datetime bt_i = g_t50_err_ring[idx];
      if(bt_i >= window_start) within++;
      else break;
   }

   if(within >= MathMax(1, InpT50_MaxFailsInWindow))
   {
      // Only count a new “trip” when we’re not already suspended
      if(g_t50_suspend_until <= bar_time)
         AAI_t50_trips++;

      g_t50_suspend_until = bar_time + (ps * MathMax(1, InpT50_SuspendBars));

      if(T50_LogVerbose && bar_time != g_t50_last_log)
      {
         PrintFormat("[T50] suspend: fails=%d window=%d bars; blocked until %s",
                     within,
                     win,
                     TimeToString(g_t50_suspend_until, TIME_DATE|TIME_SECONDS));
         g_t50_last_log = bar_time;
      }
   }
}


bool T50_AllowedNow(const datetime bar_time)
{
   if(!InpT50_EnableFailGuard) return(true);
   if(!T50_Enable) return(true); // feature flag

   if(g_t50_suspend_until <= 0) return(true);
   if(TimeCurrent() >= g_t50_suspend_until) return(true);

   if(T50_LogVerbose && bar_time != g_t50_last_log)
   {
      PrintFormat("[T50] blocked until %s",
                  TimeToString(g_t50_suspend_until, TIME_DATE|TIME_SECONDS));
      g_t50_last_log = bar_time;
   }
   return(false);
}




#define EVT_INIT  "[INIT]"
#define EVT_BAR   "[BAR]"
#define EVT_ENTRY "[ENTRY]"
#define EVT_EXIT  "[EXIT]"
#define EVT_TS    "[TS]"
#define EVT_PARTIAL "[PARTIAL]"
#define EVT_JOURNAL "[JOURNAL]"
#define EVT_ENTRY_CHECK "[EVT_ENTRY_CHECK]"
#define EVT_ORDER_BLOCKED "[EVT_ORDER_BLOCKED]"
#define EVT_WAIT "[EVT_WAIT]"
#define EVT_HEARTBEAT "[EVT_HEARTBEAT]"
#define EVT_TICK "[TICK]"
#define EVT_FIRST_BAR_OR_NEW "[EVT_FIRST_BAR_OR_NEW]"
#define EVT_WARN "[EVT_WARN]"
#define DBG_GATES "[DBG_GATES]"
#define DBG_STOPS "[DBG_STOPS]"
#define DBG_ZE    "[DBG_ZE]"
#define DBG_SPD   "[DBG_SPD]"
#define DBG_OVER  "[DBG_OVER]"
#define EVT_SUPPRESS "[EVT_SUPPRESS]"
#define EVT_COOLDOWN "[EVT_COOLDOWN]"
#define DBG_CONF  "[DBG_CONF]"
#define AAI_BLOCK_LOG "[AAI_BLOCK]"
#define INIT_ERROR "[INIT_ERROR]"
#define EVT_IDEA "[EVT_IDEA]"
#define EVT_SKIP "[EVT_SKIP]"
#define EVT_TG_OK "[EVT_TG_OK]"
#define EVT_TG_FAIL "[EVT_TG_FAIL]"


// === TICKET #2: Constants for NEW SignalBrain buffer indexes ===
#define SB_BUF_SIGNAL   0
#define SB_BUF_CONF     1
#define SB_BUF_REASON   2
#define SB_BUF_ZE       3
#define SB_BUF_SMC_SIG  4
#define SB_BUF_SMC_CONF 5
#define SB_BUF_BC       6

// --- T037: Position Health Watchdog (PHW) Constants ---
const bool   PHW_Enable            = true;
const int    PHW_FailBurstN          = 3;
const int    PHW_FailBurstWindowSec  = 15;
const int    PHW_SpreadSpikePoints   = 500;
const int    PHW_CooldownMinSec      = 60;
const int    PHW_CooldownMaxSec      = 900;
const double PHW_BackoffMultiplier   = 1.8;
const int    PHW_ResetHour           = 0;

// --- T038: Equity Curve Feedback (ECF) Constants ---
const bool   ECF_Enable           = true;
const int    ECF_MinTradesForBoost  = 10;
const int    ECF_EMA_Trades         = 10;
const double ECF_MaxUpMult          = 1.10;
const double ECF_MaxDnMult          = 0.85;
const double ECF_DD_SoftPct         = 5.0;
const double ECF_DD_HardPct         = 12.0;
const bool   ECF_HardBlock          = false;
const bool   ECF_LogVerbose         = false;

// --- T039: SL Cluster Micro-Cooldowns (SLC) Constants ---
const bool   SLC_Enable           = true;
const int    SLC_MinEvents          = 2;
const int    SLC_ClusterPoints      = 40;
const int    SLC_ClusterWindowSec   = 180;
const int    SLC_CooldownMinSec     = 120;
const int    SLC_CooldownMaxSec     = 900;
const double SLC_BackoffMultiplier  = 1.6;
const int    SLC_ResetHour          = 0;
const bool   SLC_DirSpecific        = true;
const int    SLC_History            = 12;
const bool   SLC_LogVerbose         = false;

// --- T040: Execution Analytics & Adaptive Slippage (EA+AS) ---
const bool   EA_Enable           = true;
const int    EA_EwmaTrades       = 12;
const int    EA_BaseDeviationPts = 8;
const int    EA_MinDeviationPts  = 4;
const int    EA_MaxDeviationPts  = 40;
const double EA_DevVsSlipMul     = 1.20;
const double EA_DevVsSpreadFrac  = 0.60;
const int    EA_RejBumpPts       = 4;
enum { EA_RejWindowTrades = 8 };
const int    EA_LatBumpMs        = 250;
const int    EA_LatBumpPts       = 2;
const bool   EA_LogVerbose       = false;

// --- T041: Market State Model (MSM) Constants ---
// Window sizes (compile-time)
enum {
   MSM_ATR_Period      = 14,
   MSM_ADX_Period      = 14,
   MSM_EMA_Fast        = 20,
   MSM_EMA_Slow        = 50,
   MSM_ATR_PctlWindow  = 200,    // ATR history for percentile
   MSM_Brk_Period      = 20      // Donchian breakout lookback (excl. current bar)
};
// Tunables
const bool   MSM_Enable          = true;
const double MSM_PctlVolatile    = 0.70;  // ATR percentile >= 70% -> volatile
const double MSM_PctlQuiet       = 0.30;  // ATR percentile <= 30% -> quiet
const double MSM_ADX_TrendThresh = 22.0;  // ADX >= 22 -> trending
const double MSM_ADX_RangeThresh = 18.0;  // ADX <= 18 -> ranging bias
const double MSM_MaxUpMult       = 1.08;  // cap boost
const double MSM_MaxDnMult       = 0.90;  // cap penalty
const double MSM_MisalignedTrend = 0.92;  // penalty when signal vs trend disagree
const double MSM_RangePenalty    = 0.96;  // small mean-reversion bias
const double MSM_VolatPenalty    = 0.93;  // higher noise -> caution
const double MSM_QuietPenalty    = 0.96;  // low ATR -> slip/fill risk
const bool   MSM_LogVerbose      = false; // throttle to <=1/bar

// --- T042: Telemetry v2 Constants ---
enum { TEL_STRLEN = 256 };
const bool   TEL_Enable    = true;
const int    TEL_EmitEveryN  = 0;
const bool   TEL_LogVerbose  = false;
const string TEL_Prefix      = "TEL";

// --- T043: Backtest/Live Parity Harness (PTH) Constants ---
enum { PTH_STRLEN = 256, PTH_RING = 64 };
const bool   PTH_Enable      = true;    // harness active internally; printing still gated by EveryN
const int    PTH_EmitEveryN  = 0;       // 0 = no PAR prints; N>0 => print every N closed bars
const bool   PTH_LogVerbose  = false;   // add a few extra fields when true
const string PTH_Prefix      = "PAR";   // log tag

// --- T044: State Persistence (SP v1) Constants ---
enum { SP_STRLEN = 384 };
const bool   SP_Enable         = true;
const bool   SP_LoadInTester   = false;
const bool   SP_OnDeinitWrite  = true;
const int    SP_WriteEveryN    = 0;
const string SP_FilePrefix     = "AAI_STATE";
const int    SP_Version        = 1;
const bool   SP_LogVerbose     = false;

// --- T045: Multi-Symbol Orchestration (MSO v1) Constants ---
enum { MSO_STRLEN = 128 };
const bool   MSO_Enable                  = true;   // module toggle
const int    MSO_LockTTLms               = 750;    // global lock TTL
const int    MSO_MaxSendsPerSec          = 4;      // global budget
const int    MSO_MinMsBetweenSymbolSends = 300;    // fairness gap per symbol
const bool   MSO_LogVerbose              = false;  // once/bar throttled logs

// --- AAI Regime descriptors (volatility + MSM) --------------------
enum ENUM_AAI_VOL_REGIME
  {
   AAI_VOL_LOW = 0,
   AAI_VOL_MID = 1,
   AAI_VOL_HIGH = 2
  };

enum ENUM_AAI_MSM_REGIME
  {
   AAI_MSM_TREND_GOOD = 0,
   AAI_MSM_RANGE_GOOD = 1,
   AAI_MSM_CHAOS_BAD = 2
  };

// Current regimes (updated once per bar)
int AAI_regime_vol = AAI_VOL_MID;
int AAI_regime_msm = AAI_MSM_CHAOS_BAD;

string AAI_VolRegimeName(const int r)
  {
   switch(r)
     {
      case AAI_VOL_LOW:  return "LOW";
      case AAI_VOL_HIGH: return "HIGH";
      default:           return "MID";
     }
  }

string AAI_MSMRegimeName(const int r)
  {
   switch(r)
     {
      case AAI_MSM_TREND_GOOD: return "TREND";
      case AAI_MSM_RANGE_GOOD: return "RANGE";
      default:                 return "CHAOS";
     }
  }
// --- Regime-level risk multiplier --------------------------------
double AAI_RegimeRiskMult()
  {
   int v = AAI_regime_vol;
   int m = AAI_regime_msm;

   // Defaults
   double mult = 1.0;

   if(m == AAI_MSM_TREND_GOOD)
     {
      // Trends: fairly friendly, but respect high vol
      if(v == AAI_VOL_LOW)      mult = 1.00;
      else if(v == AAI_VOL_MID) mult = 1.10;
      else                      mult = 0.90; // HIGH
     }
   else if(m == AAI_MSM_RANGE_GOOD)
     {
      // Ranges: OK but whippier
      if(v == AAI_VOL_LOW)      mult = 0.90;
      else if(v == AAI_VOL_MID) mult = 0.80;
      else                      mult = 0.70; // HIGH
     }
   else // AAI_MSM_CHAOS_BAD
     {
      // Chaos: we still trade, but smaller
      if(v == AAI_VOL_LOW)      mult = 0.80;
      else if(v == AAI_VOL_MID) mult = 0.70;
      else                      mult = 0.60; // HIGH
     }

   return mult;
  }


// --- EA Fixes (Part B): Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) // already prefixed
      return name;
   return AAI_IND_PREFIX + name;
}

// --- TICKET T021: Bar-Change Cache ---
struct SBReadCache {
  datetime closed_bar_time;
  int      sig;      // SB_BUF_SIGNAL
  double   conf;     // SB_BUF_CONF
  int      reason;   // SB_BUF_REASON
  double   ze;       // SB_BUF_ZE
  int      smc_sig;  // SB_BUF_SMC_SIG
  double   smc_conf; // SB_BUF_SMC_CONF
  int      bc;       // SB_BUF_BC
  bool     valid;
};
static SBReadCache g_sb;
//////////////////////////// fixing sendfail errors
enum ENUM_OSR_FillMode { OSR_FILL_IOC, OSR_FILL_FOK, OSR_FILL_DEFAULT };
/////////////////////

// --- T006: HUD Object Name ---
const string HUD_OBJECT_NAME = "AAI_HUD";
#include "inc/AAI_Utils.mqh"


#include "inc/AAI_EvaluateEntry.mqh"


// Subfolders under MQL5/Files (no trailing backslash)
string   g_dir_base   = "AlfredAI";
string   g_dir_intent = "AlfredAI\\intents";
string   g_dir_cmds   = "AlfredAI\\cmds";

// Pending intent state
string   g_pending_id = "";
datetime g_pending_ts = 0;

// Store last computed order params for approval placement
string   g_last_side  = "";
double   g_last_entry = 0.0, g_last_sl = 0.0, g_last_tp = 0.0, g_last_vol = 0.0;
double   g_last_rr    = 0.0, g_last_conf_raw = 0.0, g_last_conf_eff = 0.0, g_last_ze = 0.0;
string   g_last_comment = "";


//--- Helper Enums
#ifdef REASON_NONE
  #undef REASON_NONE
#endif
enum ENUM_REASON_CODE
{
    REASON_NONE,
    REASON_BUY_HTF_CONTINUATION,
    REASON_SELL_HTF_CONTINUATION,
    REASON_BUY_LIQ_GRAB_ALIGNED,
    REASON_SELL_LIQ_GRAB_ALIGNED,
    REASON_NO_ZONE,
    REASON_LOW_ZONE_STRENGTH,
    REASON_BIAS_CONFLICT,
    REASON_TEST_SCENARIO
};
enum ENUM_EXECUTION_MODE { SignalsOnly, AutoExecute };
enum ENUM_ENTRY_MODE { FirstBarOrEdge, EdgeOnly };
enum ENUM_OVEREXT_MODE { HardBlock, WaitForBand };
enum ENUM_ZE_GATE_MODE { ZE_OFF=0, ZE_PREFERRED=1, ZE_REQUIRED=2 };
enum ENUM_BC_ALIGN_MODE { BC_OFF = 0, BC_PREFERRED = 1, BC_REQUIRED = 2 };
// T032: Confidence-to-Risk Curve Mode
enum ENUM_CRC_Mode { CRC_OFF=0, CRC_LINEAR=1, CRC_QUADRATIC=2, CRC_LOGISTIC=3, CRC_PIECEWISE=4 };
// T033: SL/TP Auto-Adjust Mode
enum ENUM_SLTA_Mode {
  SLTA_OFF=0,
  SLTA_ADJUST_TP_KEEP_RR=1,
  SLTA_ADJUST_SL_ONLY=2,
  SLTA_SCALE_BOTH=3
};
// T034: Post-Fill Harmonizer Mode
enum ENUM_HM_Mode { HM_OFF=0, HM_ONESHOT_IMMEDIATE=1, HM_DELAYED_RETRY=2 };
// T035: Trailing/BE Mode
enum ENUM_TRL_Mode { TRL_OFF=0, TRL_BE_ONLY=1, TRL_ATR=2, TRL_CHANDELIER=3, TRL_SWING=4 };
// T036: Partial Take-Profit SL Adjustment Mode
// T036: Partial Take-Profit SL Adjustment Mode
enum ENUM_PT_SLA { 
    PT_SLA_NONE=0, 
    PT_SLA_TO_BE=1, 
    PT_SLA_LOCK_OFFSET=2,
    // --- ADD THIS NEW VALUE ---
    PT_SLA_TO_TARGET=3   // Move SL to the price level of this PT
    // --- END OF NEW VALUE ---
};

//--- EA Inputs-----------------------------------------------////////////////////////-----
//
//                             //////EA INPUTS//////
//
//-------------------------------------------------------------////////////////////////----

input group "Core Functions"
input bool Hybrid_RequireApproval = false;
input int  Hybrid_TimeoutSec      = 600;
input ENUM_EXECUTION_MODE ExecutionMode = SignalsOnly;
input ENUM_ENTRY_MODE     EntryMode     = FirstBarOrEdge;
input ulong  MagicNumber         = 1337;
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input int SB_ReadShift = 1;
input int WarmupBars = 200;

//--- Risk Management Inputs ---
input group "Risk Management"
input int    SL_Buffer_Points  = 8;
input int    CooldownAfterSLBars = 2;
//--- Entry Filter Inputs (M15 Baseline) ---
input double Inp_MinConf_Min  = 45.0;
input int    MinConfidence        = 20; 
///////////////MinConfidence is the MAIN CONFIDENCE
input double Inp_MinConf_Max  = 75.0;
// --- Management safety ---
input int    InpMgmt_MaxSpreadPts = 120;  // veto PT/TRL/HM modifies when spread > this (0=disabled)
input bool InpT49_EnableBarLock = false;  
// T49: one new trade per bar per account
// optional: control scope / behavior




// --- Trailing / Break-Even (T035) ---
input group "Trailing / Break-Even"
input bool          InpTRL_Enable            = true;
input ENUM_TRL_Mode InpTRL_Mode              = TRL_ATR;
input bool          InpTRL_OnBarClose        = true;
input int           InpTRL_MinSecondsBetween = 10;
input bool          InpTRL_BE_Enable         = true;
input double        InpTRL_BE_TriggerRR      = 1.4;
input int           InpTRL_BE_TriggerPts     = 0;
input int           InpTRL_BE_OffsetPts      = 1;
input ENUM_TIMEFRAMES InpTRL_ATR_Timeframe   = PERIOD_CURRENT;
input int           InpTRL_ATR_Period        = 14;
input double        InpTRL_ATR_Mult          = 2.0;
input double        InpTRL_ATR_Mult_AfterPT2 = 0.0; 
// e.g., 1.5 (0.0 = disabled)
input double        InpTRL_ATR_Mult_AfterPT3 = 0.0; 
// e.g., 1.2 (0.0 = disabled)
input int           InpTRL_SwingLookbackBars = 50;
input int           InpTRL_SwingLeg          = 2;
input int           InpTRL_SwingBufferPts    = 6;
input int           InpTRL_MinBumpPts        = 3;
input int           InpTRL_MaxDailyMoves     = 20;
input bool          InpTRL_LogVerbose        = false;
input bool          InpTRL_WaitForPT1        = false; 
// Wait for PT1 to be hit before starting trail
input bool          InpTRL_WaitForPT2        = false; 
// Wait for PT2 to be hit before starting trail
// --- BE arming controls ---
input bool   InpTRL_BE_AfterPT1Only      = true;   
// require PT1 before BE
input int    InpTRL_BE_WaitSecAfterPT1   = 30;     
// delay after PT1 before BE (0 = no delay)
input double InpTRL_BE_MinMFE_ATR        = 0.20;   
// require MFE >= X * fast ATR before BE (0 = off)

// --- BE cushion (choose one or both)
input int    InpTRL_BE_CushionPts        = 0;      
// extra pts past entry when moving to BE
input double InpTRL_BE_CushionATR        = 0.15;   
// or % of fast ATR as cushion

// --- TRL guard ---
input int    InpTRL_MinHoldSecAfterEntry = 0;   
// 0 = off, e.g. 60 = wait 1 minute before TRL logic  

input group "Time-Stop"
input bool InpTS_Enable          = true;
input int  InpTS_MaxMinutes      = 25;     
// scalp timeout
input bool InpTS_AllowSwingPromo = true;   
// allow extending winners
input int  InpTS_MinHoldMinutes  = 5;      
// don’t time-stop instantly
input double InpTS_PromoMinRR    = 0.8;    
// promote if >= this RR (or PT1 done)




// --- Partial Take-Profit Ladder (T036) ---
input group "Partial Take-Profit Ladder"
input bool        InpPT_Enable          = true;
input bool        InpPT_OnBarClose      = false;      
// evaluate on closed bars when true
input int         InpPT_MinSecondsBetween = 8;        
// throttle per-symbol between actions
input bool        InpPT_BlockSameBarChain = false; 
// (Optional) prevent PT1->PT2 in same bar
input bool        InpPT_FreezeAfterPT1  = false;  
// Freeze PT2/PT3 targets once PT1 hits
// Step 1
input bool        InpPT1_Enable         = true;
input double      InpPT1_TriggerRR      = 2.00;      
// trigger when RR >= this (uses initial SL distance)
input int         InpPT1_TriggerPts     = 0;         
// OR when raw profit >= this (points); 0=off
input double      InpPT1_ClosePct       = 20;      
// % of ORIGINAL entry lots to close
input ENUM_PT_SLA InpPT1_SLA            = PT_SLA_TO_BE;
input int         InpPT1_SLA_OffsetPts  = 1;         
// used for TO_BE / LOCK_OFFSET
// Step 2
input bool        InpPT2_Enable         = true;
input double      InpPT2_TriggerRR      = 4;
input int         InpPT2_TriggerPts     = 0;
input double      InpPT2_ClosePct       = 30;
input ENUM_PT_SLA InpPT2_SLA            = PT_SLA_LOCK_OFFSET;
input int         InpPT2_SLA_OffsetPts  = 8;
// Step 3
input bool        InpPT3_Enable         = true;
input double      InpPT3_TriggerRR      = 2.00;
input int         InpPT3_TriggerPts     = 0;
input double      InpPT3_ClosePct       = 50.0;
input ENUM_PT_SLA InpPT3_SLA            = PT_SLA_LOCK_OFFSET;
input int         InpPT3_SLA_OffsetPts  = 16;
// Logging
input bool        InpPT_LogVerbose      = false;
input bool InpPT_DirectModify = true;   // if true, PT moves SL directly (bypasses HM)
// --- PT guard ---
input int    InpPT_MinHoldSecAfterEntry  = 0;   
// 0 = off, e.g. 60 = wait 1 minute before PT logic
input bool InpPT_DrawGhostLevels = true;


// === Volatility-aware management (VAPT) ===
input group "Volatility-Aware Management"
input bool   InpVAPT_Enable          = true;
input int    InpVAPT_HotBps          = 35;      
// bps threshold for "hot" regime on Signal TF
input double InpVAPT_PTScaleHot      = 1.25;    
// multiply PT RR when hot (e.g., 0.5R -> 0.625R)
input double InpVAPT_BEScaleHot      = 1.25;    
// multiply BE RR when hot
input int    InpVAPT_ArmAfterSec     = 15;      
// min seconds after entry before PT/BE can arm
input double InpVAPT_MinMFE_ATR      = 0.30;    
// require this MFE in ATRs before arming (0=off)
// --- VAPT stability / hysteresis ---
input int    InpVAPT_HystChecksOn  = 3;   
// require this many consecutive 'hot' checks to flip ON
input int    InpVAPT_HystChecksOff = 3;   
// ... and this many 'cool' checks to flip OFF



input group "Partrial - ATR - VAPT"
input bool   InpPT_VolAdaptive   = true;   
// enable ATR-aware PT
input double InpPT_ATR1_Mult     = 0.60;   
// step1 >= 0.60 * ATRfast
input double InpPT_ATR2_Mult     = 1.00;  
 // step2 >= 1.00 * ATRfast
input double InpPT_ATR3_Mult     = 1.50;  
 // step3 >= 1.50 * ATRfast
input int    InpPT_MinStepPts    = 6;      
// never smaller than this
input bool   InpPT_SLA_UseATR    = true;   
// make SLA offset scale to ATR
input double InpPT_SLA_ATR_Mult  = 0.70;   
// SLA offset >= 0.70 * ATRfast
input int    InpPT_SLA_MinGapPts = 15;     
// floor for SLA offset


// --- Victory Lap (Profit Lock) ---
input group "Victory Lap (Profit Lock)"
input bool   InpPL_Enable      = true;    
// Enable profit locking

input double InpPL_TriggerPct  = 0.5;     
// Hard Level

input double InpPL_SnapATRMult = 0.10;    
// Super-tight ATR for hard level

input int InpPL_MinPTStage = 2;  
// 1,2,3 – min partial stage for choke

input bool InpPL_DisableNewPartials = false;

input double InpPL_SoftTriggerPct  = 0.0;  
// 0 = off
input double InpPL_SoftATRMult     = 0.50; 
// e.g. half normal ATR


input group "Equity Cliff Prevention"
input bool   InpStreak_Enable        = true;
input int    InpStreak_MaxLossTrades = 3;     
// trigger on this many consecutive losses
input double InpStreak_MaxDropPct    = 2.0;   
// or if local eq drops this % from peak
input int    InpStreak_CooldownHours = 4;     
// pause new entries for this many hours


// --- Strength Add-On (SAO) Module ---
input group "Strength Add-On (SAO)"
input bool   InpSAO_Enable           = false;
input int    InpSAO_MinPTStage       = 2;    // Trade must be past this PT stage
input int    InpSAO_MaxAdds          = 1;    // Max add-ons per parent trade
input double InpSAO_RiskFrac         = 0.5;  // Multiplier of ORIGINAL lots (0.5 = half size)
input int    InpSAO_CooldownBars     = 5;    // Bars to wait BETWEEN adds (not from entry)
input bool   InpSAO_HardInvariant    = true; // REQUIRE Parent SL to be in profit


// --- Confidence -> Risk Curve (T032) ---
input group "Confidence -> Risk Curve"
input bool          InpCRC_Enable        = true;
input ENUM_CRC_Mode InpCRC_Mode          = CRC_LINEAR;
input double        InpCRC_MinRiskPct    = 0.80;
input double        InpCRC_MaxRiskPct    = 3.00;
input double        InpCRC_MinLots       = 0.5;
input double        InpCRC_MaxLots       = 5.0;
input double        InpCRC_MaxRiskMoney  = 0.00;
input int           InpCRC_MinConfidence = 20;
input double        InpCRC_QuadAlpha     = 1.00;
input double        InpCRC_LogisticMid   = 50.0;
input double        InpCRC_LogisticSlope = 0.15;
input int           InpCRC_PW_C1         = 50;
input double        InpCRC_PW_R1         = 0.40;
input int           InpCRC_PW_C2         = 90;
input double        InpCRC_PW_R2         = 0.95;
input int           InpCRC_PW_C3         = 100;
input double        InpCRC_PW_R3         = 1.5;



// --- SL/TP Safety & MinStops Auto-Adjust (T033) ---
input group "SL/TP Safety & MinStops Auto-Adjust"
input bool           InpSLTA_Enable        = true;
input ENUM_SLTA_Mode InpSLTA_Mode          = SLTA_ADJUST_TP_KEEP_RR;
input double         InpSLTA_TargetRR      = 3;
input double         InpSLTA_MinRR         = 1.50;
input int            InpSLTA_ExtraBufferPts = 2;
input double         InpSLTA_MaxWidenFrac  = 0.50;
input int            InpSLTA_MaxTPPts      = 0;
input bool           InpSLTA_StrictCancel  = true;
input bool           InpSLTA_LogVerbose    = false;
input bool   InpSLTA_SpikeGuard   = true;
input int    InpSLTA_ATRFast      = 7;     
// optional fast ATR
// include last-bar True Range multiplier (0=off)




// --- Global Risk Guard (T030) ---
input group "Global Risk Guard"
enum ENUM_RG_Mode { RG_OFF=0, RG_REQUIRED=1, RG_PREFERRED=2 };
input bool         InpRG_Enable            = true;
input ENUM_RG_Mode InpRG_Mode              = RG_PREFERRED;
input int          InpRG_ResetHourServer   = 0;
input double       InpRG_MaxDailyLossPct   = 0;
input double       InpRG_MaxDailyLossMoney = 3500;
input int          InpRG_MaxSLHits         = 0;
input int          InpRG_MaxConsecLosses   = 0;
enum ENUM_RG_BlockUntil { RG_BLOCK_TIL_END_OF_DAY=0, RG_BLOCK_FOR_HOURS=1 };
input ENUM_RG_BlockUntil InpRG_BlockUntil    = RG_BLOCK_TIL_END_OF_DAY;
input int          InpRG_BlockHours        = 0;
input int          InpRG_PrefPenalty       = 3;
// add near other RG inputs
input bool InpRG_ResetOnWin = false;   
// if true, a winning exit clears RG block immediately
input int  InpRG_BlockHoursAfterTrip = 8;  
// 0 = no timed unblock (optional)


//--- Confluence Module Inputs (M15 Baseline) ---
input group "Confluence Modules"
input ENUM_BC_ALIGN_MODE BC_AlignMode      = BC_PREFERRED;
input ENUM_ZE_GATE_MODE  ZE_Gate           = ZE_PREFERRED;
input int                ZE_MinStrength    = 4;

enum SMCMode { SMC_OFF=0, SMC_PREFERRED=1, SMC_REQUIRED=2 };
input SMCMode SMC_Mode = SMC_PREFERRED;
input int   SMC_MinConfidence = 4;

// --- TICKET T023: Inputs to control SignalBrain's confluence model ---
input group "SignalBrain Confluence Model";
enum ENUM_SB_ConfModel { SB_CONF_ADDITIVE=0, SB_CONF_GEOMETRIC=1 };
input ENUM_SB_ConfModel InpSB_ConfModel = SB_CONF_GEOMETRIC;
input double InpSB_W_BASE = 1.0;
input double InpSB_W_BC   = 1.0;
input double InpSB_W_ZE   = 1.0;
input double InpSB_W_SMC  = 1.0;
input double InpSB_ConflictPenalty = 0.80;
input bool InpSB_DynWeights_Enable = true;  


// --- All Pass-Through Inputs for the new SignalBrain ---
input group "SignalBrain Pass-Through Inputs";
// Core SB Settings
input bool   SB_SafeTest         = false;
input bool   SB_UseZE            = true;
input bool   SB_UseBC            = true;
input bool   SB_UseSMC           = true;
input int    SB_WarmupBars       = 150;
input int    SB_FastMA           = 5;
input int    SB_SlowMA           = 12;
input int    SB_MinZoneStrength  = 3;
input bool   SB_EnableDebug      = false;
// SB Confidence Model (Additive Path)
input int    SB_Bonus_ZE         = 8;
input int    SB_Bonus_BC         = 8;
input int    SB_Bonus_SMC        = 8;
input int    SB_BaseConf         = 8;
// BC Pass-Through
input int    SB_BC_FastMA        = 5;
input int    SB_BC_SlowMA        = 12;
// ZE Pass-Through
input double SB_ZE_MinImpulseMovePips = 8.0;
// SMC Pass-Through
input bool   SB_SMC_UseFVG       = true;
input bool   SB_SMC_UseOB        = true;
input bool   SB_SMC_UseBOS       = true;
input double SB_SMC_FVG_MinPips  = 0.8;
input int    SB_SMC_OB_Lookback  = 20;
input int    SB_SMC_BOS_Lookback = 50;


//--- Telegram Alerts ---
input group "Telegram Alerts"
input bool   UseTelegramFromEA = true;
input string TelegramToken       = "";
input string TelegramChatID      = "";
input bool   AlertsDryRun      = false;

input group " Session Inputs"
//--- Session Inputs (idempotent) ---
#ifndef AAI_SESSION_INPUTS_DEFINED
#define AAI_SESSION_INPUTS_DEFINED
input bool SessionEnable = true;
input int  InpSession_BlockNewEntriesMins = 60; // 0=off, >0 = block new entries N mins before session end
#endif


#ifndef AAI_HYBRID_INPUTS_DEFINED
#define AAI_HYBRID_INPUTS_DEFINED
// Auto-trading window (server time). Outside -> alerts only.
input string AutoHourRanges = "7:00-15:25,15:35-21:00";   // comma-separated hour ranges
// Day mask for auto-trading (server time): Sun=0..Sat=6
input bool AutoSun=false, AutoMon=true, AutoTue=true, AutoWed=true, AutoThu=true, AutoFri=true, AutoSat=false;
// Alert channels + throttle
#endif

//////////////
#ifndef AAI_STR_TRIM_DEFINED
#define AAI_STR_TRIM_DEFINED
void AAI_Trim(string &s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
}
#endif




// -- Anti-Zombie Controls (AZ)
input group "Anti-Zombie Controls (AZ)"
input bool   InpAZ_TTL_Enable        = true;     
// Enable max trade lifetime (Time-To-Live)
input int    InpAZ_TTL_Hours         = 22;        
// Max age of any position in hours
input bool   InpAZ_SessionForceFlat  = false;     
// Force-close all positions outside the session window
input int    InpAZ_PrefExitMins      = 10;       
// Minutes before session end to start closing


// --- Playbook: scenario-level dials (all neutral by default) ---------
input group "---------PLAYBOOK Scenarios + Regime----------////////////"
// --- Playbook / risk debug --------------------------------------
input bool InpPB_DebugRiskLog = false;   
// if true, log per-entry risk breakdown (AAI_RISK lines)
input int InpPB_Def_MinConfExtra = 2;   
// extra MinConf in DEFENSIVE scenario (0 = disable)
input int InpPB_Opp_MinConfDelta = 0;   
// ^LEGACY(?) MinConf adjustment in OPPORTUNITY scenario (0 = no change)

input group "-----ScnRiskMult-----"
input double InpPB_ScnRiskMult_BASELINE    = 1.0;
input double InpPB_ScnRiskMult_DEFENSIVE   = 1.0;
input double InpPB_ScnRiskMult_OPPORTUNITY = 1.0;
input double InpPB_ScnRiskMult_RISK_OFF    = 1.0;
input group "-----ScnMinConfDelta-----"
input int    InpPB_ScnMinConfDelta_BASELINE    = 0;
input int    InpPB_ScnMinConfDelta_DEFENSIVE   = 0;
input int    InpPB_ScnMinConfDelta_OPPORTUNITY = 0;
input int    InpPB_ScnMinConfDelta_RISK_OFF    = 0;
input group "-----ScnAllowEntries-----"
input bool   InpPB_ScnAllowEntries_BASELINE    = true;
input bool   InpPB_ScnAllowEntries_DEFENSIVE   = true;
input bool   InpPB_ScnAllowEntries_OPPORTUNITY = true;
input bool   InpPB_ScnAllowEntries_RISK_OFF    = false;   
// set RISK_OFF to false later if you want RISK_OFF to hard-block entries

// --- Playbook: regime-level dials (all neutral by default) --------

// Extra risk multipliers per VOL × MSM regime.
// Defaults = 1.0  → no change vs current behaviour.
input group "-----RegimeRiskMult-----"
input double InpPB_RegimeRiskMult_LOW_TREND    = 1.0;
input double InpPB_RegimeRiskMult_LOW_RANGE    = 1.0;
input double InpPB_RegimeRiskMult_LOW_CHAOS    = 1.0;

input double InpPB_RegimeRiskMult_MID_TREND    = 1.0;
input double InpPB_RegimeRiskMult_MID_RANGE    = 1.0;
input double InpPB_RegimeRiskMult_MID_CHAOS    = 1.0;

input double InpPB_RegimeRiskMult_HIGH_TREND   = 1.0;
input double InpPB_RegimeRiskMult_HIGH_RANGE   = 1.0;
input double InpPB_RegimeRiskMult_HIGH_CHAOS   = 1.0;

// Extra MinConf deltas per VOL × MSM regime.
// Defaults = 0 → no change vs current behaviour.
input group "-----RegimeMinConfDelta-----"

input int    InpPB_RegimeMinConfDelta_LOW_TREND    = 0;
input int    InpPB_RegimeMinConfDelta_LOW_RANGE    = 0;
input int    InpPB_RegimeMinConfDelta_LOW_CHAOS    = 0;

input int    InpPB_RegimeMinConfDelta_MID_TREND    = 0;
input int    InpPB_RegimeMinConfDelta_MID_RANGE    = 0;
input int    InpPB_RegimeMinConfDelta_MID_CHAOS    = 0;

input int    InpPB_RegimeMinConfDelta_HIGH_TREND   = 0;
input int    InpPB_RegimeMinConfDelta_HIGH_RANGE   = 0;
input int    InpPB_RegimeMinConfDelta_HIGH_CHAOS   = 0;

// --- Playbook: confidence-band risk multipliers (neutral by default) ---
// Bands correspond to AAI_ConfBandIndex / AAI_ConfBandLabel:
// 0: 40_50, 1: 50_60, 2: 60_70, 3: 70_80, 4: 80_90, 5: 90_100
input group "-----BandRiskMult-----"

input double InpPB_BandRiskMult_20_30  = 1.0;
input double InpPB_BandRiskMult_30_40  = 1.0;
input double InpPB_BandRiskMult_40_50  = 1.0;
input double InpPB_BandRiskMult_50_60  = 1.0;
input double InpPB_BandRiskMult_60_70  = 1.0;
input double InpPB_BandRiskMult_70_80  = 1.0;
input double InpPB_BandRiskMult_80_90  = 1.0;
input double InpPB_BandRiskMult_90_100 = 1.0;

// --- Playbook: Exit Profiles (optional) ----------------------------
input group "-----PLAYBOOK Exit Profiles-----////////////"

// Map scenarios → exit profile id.
// 0 = baseline (use base InpSLTA_TargetRR)
// 1,2 = extra profiles (only used if you map scenarios to them).
input int InpPB_ExitProfile_BASELINE    = 0;
input int InpPB_ExitProfile_DEFENSIVE   = 0;
input int InpPB_ExitProfile_OPPORTUNITY = 0;
input int InpPB_ExitProfile_RISK_OFF    = 0;

// Per-profile multipliers applied to InpSLTA_TargetRR.
// All 1.0 by default → no change vs current behaviour.
input double InpEP_TargetRRMult_Profile0 = 1.0;
input double InpEP_TargetRRMult_Profile1 = 1.0;
input double InpEP_TargetRRMult_Profile2 = 1.0;


// Trailing: ATR multiplier
input double InpEP_TRL_ATRMult_Profile0        = 1.0;
input double InpEP_TRL_ATRMult_Profile1        = 1.0;
input double InpEP_TRL_ATRMult_Profile2        = 1.0;

// Trailing: BE trigger RR
input double InpEP_TRL_BE_TriggerRRMult_Profile0 = 1.0;
input double InpEP_TRL_BE_TriggerRRMult_Profile1 = 1.0;
input double InpEP_TRL_BE_TriggerRRMult_Profile2 = 1.0;

// Partial Take-Profits: RR trigger (PT1–PT3)
input double InpEP_PT_TriggerRRMult_Profile0   = 1.0;
input double InpEP_PT_TriggerRRMult_Profile1   = 1.0;
input double InpEP_PT_TriggerRRMult_Profile2   = 1.0;

//////////

// --- Regime Shift / Env Scenario Override ---
input group "Regime Shift / Env Scenario Override"
input bool   InpRS_EnvScenarioOverride        = true;
input bool   InpRS_ChaosToDefensive           = true;
input bool   InpRS_HighVolChaosToRiskOff      = true;

input bool   InpRS_EnableTransitionGuard      = true;
input int    InpRS_TransitionCooldownBars     = 12;   // ~1 hour on M5
input double InpRS_TransitionRiskMult         = 0.55; // reduce risk during transition
input int    InpRS_TransitionMinConfAdd       = 6;    // require higher confidence
input bool   InpRS_BlockSAOInTransition       = true;
input bool InpRS_BlockEntriesInChaos = true;




// --- Smart Exit (Thesis Decay) ---
input group "Smart Exit (Thesis Decay)"
input bool   InpSE_Enable          = true;
input int    InpSE_DecayBars       = 3;    
// Number of consecutive bars with low confidence
input int    InpSE_ConfThreshold   = 40;   
// Below this confidence = "Decay" state
input bool   InpSE_RequireReversal = true; 
// True = wait for opposite signal; False = close on decay alone



input group "T50 Circuit Breaker"
input bool InpT50_EnableFailGuard    = false; 
// T50 master switch
input int  InpT50_WindowBars         = 10;    
// lookback window
input int  InpT50_MaxFailsInWindow   = 3;     
// threshold
input int  InpT50_SuspendBars        = 20;    
// how long to suspend


//--- Trade Management Inputs ---
input group "Trade Management"
input bool   PerBarDebounce      = true;

input int    MaxSpreadPoints     = 100;
input int    MaxSlippagePoints   = 50;
input int    FridayCloseHour     = 22;
input bool   EnableLogging       = true;



//--- T022: Volatility Regime Inputs ---
input group "Volatility Regime"
input bool           InpVR_Enable      = true;
input int            InpVR_ATR_Period  = 14;
input int            InpVR_MinBps      = 6;   
input int            InpVR_MaxBps      = 70;  
enum ENUM_VR_Mode { VR_OFF=0, VR_REQUIRED=1, VR_PREFERRED=2 };
input ENUM_VR_Mode InpVR_Mode = VR_PREFERRED;
input int            InpVR_PrefPenalty = 3;  

//--- News/Event Gate Inputs (T024) ---
input group "News/Event Gate"
input bool           InpNews_Enable      = false;
input string         InpNews_CsvName     = "AAI_News.csv";   // From Common Files
input ENUM_NEWS_Mode InpNews_Mode = NEWS_PREFERRED;
input bool           InpNews_TimesAreUTC = true;
input bool           InpNews_FilterHigh  = true;
input bool           InpNews_FilterMedium= true;
input bool           InpNews_FilterLow   = false;
input int            InpNews_PrefPenalty = 5;

//--- Structure Proximity Gate Inputs (T027) ---
input group "Structure Proximity"
enum ENUM_SP_Mode { SP_OFF=0, SP_REQUIRED=1, SP_PREFERRED=2 };
input ENUM_SP_Mode InpSP_Mode              = SP_PREFERRED;
input bool         InpSP_Enable              = true;
input bool         InpSP_UseATR              = true;
input int          InpSP_ATR_Period          = 14;
input double       InpSP_ATR_Mult            = 0.4;
input int          InpSP_AbsPtsThreshold     = 120;
input bool         InpSP_CheckRoundNumbers   = true;
input int          InpSP_RoundGridPts        = 500;
input int          InpSP_RoundOffsetPts      = 0;
input bool         InpSP_CheckYesterdayHighLow = true;
input int          InpSP_YHYL_BufferPts      = 0;
input bool         InpSP_CheckWeeklyOpen     = true;
input int          InpSP_WOpen_BufferPts     = 0;
input bool         InpSP_CheckSwings         = true;
input int          InpSP_SwingLookbackBars   = 50;
input int          InpSP_SwingLeg            = 2;
input int          InpSP_PrefPenalty         = 2;

// --- Adaptive Spread (T028) ---
input group "Adaptive Spread"
enum ENUM_AS_Mode { AS_OFF=0, AS_REQUIRED=1, AS_PREFERRED=2 };
input bool         InpAS_Enable          = true;
input ENUM_AS_Mode InpAS_Mode            = AS_PREFERRED;
input int          InpAS_SampleEveryNTicks = 3;
input int          InpAS_SamplesPerBarMax  = 400;
input int          InpAS_WindowBars      = 20;
input double       InpAS_SafetyPct       = 0.05;
input int          InpAS_SafetyPts       = 1;
input bool         InpAS_ClampToFixedMax = true;
input int          InpAS_PrefPenalty     = 2;

// --- Inter-Market Confirmation (T029) ---
input group "Inter-Market Confirmation"
enum ENUM_IMC_Mode  { IMC_OFF=0, IMC_REQUIRED=1, IMC_PREFERRED=2 };
enum ENUM_IMC_Rel   { IMC_ALIGN=1, IMC_CONTRA=-1 };
enum ENUM_IMC_Method { IMC_ROC=0 };
input bool          InpIMC_Enable         = true;
input ENUM_IMC_Mode InpIMC_Mode           = IMC_PREFERRED;
input string        InpIMC1_Symbol        = "";
input ENUM_TIMEFRAMES InpIMC1_Timeframe   = PERIOD_H1;
input ENUM_IMC_Rel  InpIMC1_Relation      = IMC_CONTRA;
input int           InpIMC1_LookbackBars  = 10;
input double        InpIMC1_MinAbsRocBps  = 0.0;
input string        InpIMC2_Symbol        = "";
input ENUM_TIMEFRAMES InpIMC2_Timeframe   = PERIOD_H1;
input ENUM_IMC_Rel  InpIMC2_Relation      = IMC_ALIGN;
input int           InpIMC2_LookbackBars  = 10;
input double        InpIMC2_MinAbsRocBps  = 0.0;
input double        InpIMC1_Weight        = 1.0;
input double        InpIMC2_Weight        = 1.0;
input double        InpIMC_MinSupport     = 0.40;
input int           InpIMC_PrefPenalty    = 2;


// --- Hedging & Pyramiding ---
input group "Hedging & Pyramiding"
input bool   InpHEDGE_AllowMultiple        = false;   
 // allow many positions per symbol (hedging)
input bool   InpHEDGE_AllowOpposite        = false;   
 // allow long+short at same time
input int    InpHEDGE_MaxPerSymbol         = 1;       
// cap all positions on symbol (this EA's magic)
input int    InpHEDGE_MaxLongPerSymbol     = 1;       
// cap longs
input int    InpHEDGE_MaxShortPerSymbol    = 1;       
// cap shorts
input int    InpHEDGE_MinStepPips          = 18;      
// min distance between entries on same side
input bool   InpHEDGE_SplitRiskAcrossPyr   = false;   
// divide risk across the pyramid
input double InpHEDGE_MaxAggregateRiskPct  = 0;     
// cap total risk % on this symbol (optional)





// --- Post-Fill Harmonizer (T034) ---
input group "Post-Fill Harmonizer"
input bool         InpHM_Enable        = true;
input ENUM_HM_Mode InpHM_Mode          = HM_DELAYED_RETRY;
input int          InpHM_DelayMs       = 300;
input int          InpHM_MaxRetries    = 3;
input int          InpHM_BackoffMs     = 400;
input int          InpHM_MinChangePts  = 2;
input bool         InpHM_RespectFreeze = true;
input bool         InpHM_LogVerbose    = false;

// --- T011: Over-extension Inputs ---
input group "Over-extension Guard"
input ENUM_OVEREXT_MODE OverExtMode = WaitForBand;
input int    OverExt_MA_Period  = 20;
input int    OverExt_ATR_Period = 14;
input double OverExt_ATR_Mult   = 2.0;
input int    OverExt_WaitBars   = 1;


// --- Order Send Robustness & Retry (T031) ---
input group "Order Send Robustness & Retry"
input bool                 InpOSR_Enable         = true;
input int                  InpOSR_MaxRetries     = 2;
input int                  InpOSR_RetryDelayMs   = 100;
input bool                 InpOSR_RepriceOnRetry = true;
input int                  InpOSR_SlipPtsInitial = 5;
input int                  InpOSR_SlipPtsStep    = 5;
input int                  InpOSR_SlipPtsMax     = 25;
enum ENUM_OSR_PriceMode { OSR_USE_LAST=0, OSR_USE_CURRENT=1 };
input ENUM_OSR_PriceMode InpOSR_PriceMode = OSR_USE_CURRENT;
input ENUM_OSR_FillMode  InpOSR_FillMode       = OSR_FILL_FOK; 
input bool                 InpOSR_LogVerbose     = false;


//--- Journaling Inputs ---
input group "Journaling"
input bool   EnableJournaling      = false;        
input string JournalFileName       = "AlfredAI_Journal.csv";
input bool   JournalUseCommonFiles = false;        

// --- Decision Journaling (T026) ---
input group "Decision Journaling"
input bool   InpDJ_Enable      = false;
input string InpDJ_FileName    = "AAI_Decisions.csv";
input bool   InpDJ_Append      = true;



//--- Exit Strategy Inputs (M15 Baseline) ---
input group "Exit Strategy"
input bool   Exit_FixedRR        = true;
input double Fixed_RR            = 2;
input double Partial_Pct         = 0;
input double Partial_R_multiple  = 0;
input int    BE_Offset_Points    = 0;




//--- Globals
CTrade   trade;
string   symbolName;
double   point;
static ulong g_logged_positions[]; // For duplicate journal entry prevention
int      g_logged_positions_total = 0;
AAI_NewsGate g_newsGate;
// --- T011: Over-extension State ---
static int g_overext_wait = 0;
// --- TICKET #3: Over-extension timing fix ---
static datetime g_last_overext_dec_sigbar = 0;
// --- Simplified Persistent Indicator Handles ---
int sb_handle = INVALID_HANDLE;
int g_hATR = INVALID_HANDLE;
int g_hOverextMA = INVALID_HANDLE;
int g_hATR_VR = INVALID_HANDLE; // T022: New handle for Volatility Regime
int g_hATR_SP = INVALID_HANDLE; // T027: New handle for Structure Proximity
int g_hATR_TRL = INVALID_HANDLE; // T035
// T041
int g_hMSM_ATR = INVALID_HANDLE;
int g_hMSM_ADX = INVALID_HANDLE;
int g_hMSM_EMA_Fast = INVALID_HANDLE;
int g_hMSM_EMA_Slow = INVALID_HANDLE;
int g_hATR_fast    = INVALID_HANDLE;   ////fast ATR for SpikeGuard

/// --- Streak
int      AAI_streak_loss_count   = 0;
double   AAI_streak_eq_peak      = 0.0;
double   AAI_streak_eq_cur       = 0.0;
double   AAI_streak_dd_pct       = 0.0;
datetime AAI_streak_cooldown_until = 0;
bool     AAI_streak_softlanding_armed = false;

// --- SAO State Management (Hardened) ---
string SAO_GetGVKeyCount(ulong parent_ticket) {
   return StringFormat("AAI_SAO_C_%d_%I64u", (int)MagicNumber, parent_ticket);
}

string SAO_GetGVKeyTime(ulong parent_ticket) {
   return StringFormat("AAI_SAO_T_%d_%I64u", (int)MagicNumber, parent_ticket);
}

int SAO_GetAddCount(ulong parent_ticket) {
   string key = SAO_GetGVKeyCount(parent_ticket);
   if(!GlobalVariableCheck(key)) return 0;
   return (int)GlobalVariableGet(key);
}

void SAO_IncrementAddCount(ulong parent_ticket) {
   string key = SAO_GetGVKeyCount(parent_ticket);
   int current = 0;
   if(GlobalVariableCheck(key)) current = (int)GlobalVariableGet(key);
   GlobalVariableSet(key, current + 1);
}

datetime SAO_GetLastAddTime(ulong parent_ticket) {
   string key = SAO_GetGVKeyTime(parent_ticket);
   if(!GlobalVariableCheck(key)) return 0;
   return (datetime)GlobalVariableGet(key);
}

void SAO_SetLastAddTime(ulong parent_ticket, datetime t) {
   GlobalVariableSet(SAO_GetGVKeyTime(parent_ticket), (double)t);
}
// --- Fix for Missing Helper ---
int PT_GetStageGV(const ulong ticket)
{
   // Stage is derived from the per-ticket step latches (restart-safe)
   if(PT_IsLatchedGV(3, ticket)) return 3;
   if(PT_IsLatchedGV(2, ticket)) return 2;
   if(PT_IsLatchedGV(1, ticket)) return 1;
   return 0;
}

// --- Alfred context snapshot -------------------------------------
struct AAI_Context
{
   string          symbol;
   ENUM_TIMEFRAMES tf;
   int    mode;              // DEF/NORM/AGG
   int    vol_regime;        // LOW/MID/HIGH
   int    msm_regime;        // TREND/RANGE/CHAOS

   int      loss_streak;
   double   streak_dd_pct;
   datetime streak_cd_until;
   int      rg_trips;
   int      t50_trips;

   // Derived / state flags
   bool     streak_cooldown_active;  // true while streak cooldown is in effect
   bool     streak_softland_active;  // true when soft-landing is armed (if you track this)
   bool     daily_rg_block_active;   // true when Daily RiskGuard is blocking new entries
};

void AAI_FillContext(AAI_Context &ctx)
  {
   ctx.symbol        = _Symbol;
   ctx.tf            = (ENUM_TIMEFRAMES)_Period;  // keep consistent with existing logs

   ctx.mode          = AAI_mode_current;
   ctx.vol_regime    = AAI_regime_vol;
   ctx.msm_regime    = AAI_regime_msm;

   ctx.loss_streak   = AAI_streak_loss_count;
   ctx.streak_dd_pct = AAI_streak_dd_pct;
   ctx.streak_cd_until = AAI_streak_cooldown_until;

   ctx.rg_trips      = AAI_rg_trips;
   ctx.t50_trips     = AAI_t50_trips;
 
    // --- Derived flags --------------------------------------------

   // Streak cooldown is active while cooldown time is in the future
   ctx.streak_cooldown_active =
      (ctx.streak_cd_until > 0 && ctx.streak_cd_until > TimeCurrent());

   // If you have an explicit "softland armed" flag, wire it here.
   // Otherwise, set to false for now (behaviour-neutral).
   ctx.streak_softland_active = false;
   // Example (if such a global exists):
   // ctx.streak_softland_active = g_AAI_StreakSoftlandArmed;

   // Daily RiskGuard block status (stub currently returns false)
   ctx.daily_rg_block_active = AAI_DailyRiskGuardIsBlocking();
  
   
  }
// Map current context -> a coarse scenario (logging + playbook input)
ENUM_AAI_SCENARIO AAI_MapScenario(const AAI_Context &ctx)
  {
   // --- 1) RISK_OFF: hard brakes --------------------------------
   // If either streak cooldown is active OR Daily RiskGuard is blocking,
   // we consider the environment "risk off" regardless of mode.
   if(ctx.streak_cooldown_active || ctx.daily_rg_block_active)
      return AAI_SCN_RISK_OFF;

   // --- 2) DEFENSIVE: soft brakes / recovery mode ----------------
   // DEF mode always maps to DEFENSIVE.
   // Optionally also treat an explicit softlanding flag as defensive.
   if(ctx.mode == AAI_MODE_DEFENSIVE || ctx.streak_softland_active)
      return AAI_SCN_DEFENSIVE;
// Environment-driven scenario override (align scenarios to price/regime)
if(InpRS_EnvScenarioOverride)
{
   if(InpRS_EnableTransitionGuard && g_rs_transition_active)
      return AAI_SCN_DEFENSIVE;

   if(ctx.msm_regime == AAI_MSM_CHAOS_BAD)
   {
      if(InpRS_HighVolChaosToRiskOff && ctx.vol_regime == AAI_VOL_HIGH)
         return AAI_SCN_RISK_OFF;

      if(InpRS_ChaosToDefensive)
         return AAI_SCN_DEFENSIVE;
   }
}

   // --- 3) OPPORTUNITY: only when not stressed -------------------
   // Simple definition for now:
   // - Mode is NORMAL or AGGRESSIVE
   // - No active streak drawdown
   // - Daily RG is not blocking (already checked above)
   bool streak_stressed =
      (ctx.loss_streak > 0 || ctx.streak_dd_pct > 0.0 || ctx.rg_trips > 0);

   bool mode_normal_or_agg =
      (ctx.mode == AAI_MODE_NORMAL || ctx.mode == AAI_MODE_AGGRESSIVE);

   if(mode_normal_or_agg && !streak_stressed && !ctx.daily_rg_block_active)
      return AAI_SCN_OPPORTUNITY;

   // --- 4) BASELINE: default -------------------------------------
   return AAI_SCN_BASELINE;
  }

void AAI_LogEntryContext(const ulong deal_ticket,
                         const datetime deal_time,
                         const AAI_Context &ctx)
  {
   // Streak cooldown string
   string streak_cd_until_str =
      (ctx.streak_cd_until > 0)
      ? TimeToString(ctx.streak_cd_until, TIME_DATE|TIME_MINUTES)
      : "-";

   // Scenario for this context
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   // --- Playbook + MinConf info for logging ----------------------

   // Fill playbook for this context + scenario
   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   // Effective MinConfidence (uses current playbook internally)
   double minconf_eff = AAI_EffectiveMinConf();

   // Decomposed risk multipliers
   double pb_rm_mode = pb.risk_mult_mode;
   double pb_rm_reg  = pb.risk_mult_regime;
   double pb_rm_scn  = pb.risk_mult_scenario;
   double pb_rm_all  = pb_rm_mode * pb_rm_reg * pb_rm_scn;

   // --- Log line --------------------------------------------------
   PrintFormat(
      "AAI_ENTRY_CTX|ticket=%I64u|time=%s|sym=%s|tf=%s"
      "|mode=%s|regime_vol=%s|regime_msm=%s"
      "|streak_loss=%d|streak_dd=%.2f|streak_cd_until=%s"
      "|rg_trips=%d|t50_trips=%d|scenario=%s"
      "|minconf_eff=%.1f"
      "|pb_rm_mode=%.3f|pb_rm_reg=%.3f|pb_rm_scn=%.3f|pb_rm_all=%.3f",
      deal_ticket,
      TimeToString(deal_time, TIME_DATE|TIME_MINUTES),
      ctx.symbol,
      EnumToString(ctx.tf),
      AAI_ModeName(ctx.mode),
      AAI_VolRegimeName(ctx.vol_regime),
      AAI_MSMRegimeName(ctx.msm_regime),
      ctx.loss_streak,
      ctx.streak_dd_pct,
      streak_cd_until_str,
      ctx.rg_trips,
      ctx.t50_trips,
      AAI_ScenarioName(scn),
      minconf_eff,
      pb_rm_mode,
      pb_rm_reg,
      pb_rm_scn,
      pb_rm_all
   );
  }

// --- AAI Playbook: how we derive risk & MinConf from context/scenario ----
struct AAI_Playbook
  {
   // Core multipliers
   double risk_mult_mode;       // from AAI_ModeRiskMult()
   double risk_mult_regime;     // from AAI_RegimeRiskMult()
   double risk_mult_scenario;   // from scenario dials

   // MinConf deltas
   double minconf_delta_mode;       // from AAI_ModeMinConfDelta()
   double minconf_delta_regime;     // from AAI_RegimeMinConfDelta()
   double minconf_delta_scenario;   // from scenario dials

   // Behaviour flags
   bool   allow_entries;        // scenario-level entry permission (not yet enforced)
   int    exit_profile_id;      // reserved for future exit routing
  };

// Scenario-specific helpers for playbook routing
double AAI_PlaybookScenarioRiskMult(const ENUM_AAI_SCENARIO scn)
  {
   switch(scn)
     {
      case AAI_SCN_DEFENSIVE:   return InpPB_ScnRiskMult_DEFENSIVE;
      case AAI_SCN_OPPORTUNITY: return InpPB_ScnRiskMult_OPPORTUNITY;
      case AAI_SCN_RISK_OFF:    return InpPB_ScnRiskMult_RISK_OFF;
      default:                  return InpPB_ScnRiskMult_BASELINE;
     }
  }

double AAI_PlaybookScenarioMinConfDelta(const ENUM_AAI_SCENARIO scn)
  {
   switch(scn)
     {
      case AAI_SCN_DEFENSIVE:   return (double)InpPB_ScnMinConfDelta_DEFENSIVE;
      case AAI_SCN_OPPORTUNITY: return (double)InpPB_ScnMinConfDelta_OPPORTUNITY;
      case AAI_SCN_RISK_OFF:    return (double)InpPB_ScnMinConfDelta_RISK_OFF;
      default:                  return (double)InpPB_ScnMinConfDelta_BASELINE;
     }
  }

bool AAI_PlaybookScenarioAllowEntries(const ENUM_AAI_SCENARIO scn)
  {
   switch(scn)
     {
      case AAI_SCN_DEFENSIVE:   return InpPB_ScnAllowEntries_DEFENSIVE;
      case AAI_SCN_OPPORTUNITY: return InpPB_ScnAllowEntries_OPPORTUNITY;
      case AAI_SCN_RISK_OFF:    return InpPB_ScnAllowEntries_RISK_OFF;
      default:                  return InpPB_ScnAllowEntries_BASELINE;
     }
  }
  


// NEW: scenario → exit profile mapping (0..2)
int AAI_PlaybookScenarioExitProfile(const ENUM_AAI_SCENARIO scn)
  {
   int id;
   switch(scn)
     {
      case AAI_SCN_DEFENSIVE:   id = InpPB_ExitProfile_DEFENSIVE;   break;
      case AAI_SCN_OPPORTUNITY: id = InpPB_ExitProfile_OPPORTUNITY; break;
      case AAI_SCN_RISK_OFF:    id = InpPB_ExitProfile_RISK_OFF;    break;
      default:                  id = InpPB_ExitProfile_BASELINE;    break;
     }

   // Clamp to [0..2] for now (3 profiles)
   if(id < 0) id = 0;
   if(id > 2) id = 2;
   return id;
  }
  
// Map VOL × MSM regime index to extra risk multiplier for the playbook.
// Assumes ctx.vol_regime, ctx.msm_regime use 0=LOW/MID/HIGH and 0=TREND/RANGE/CHAOS.
// If your enum ordering differs, adjust the mapping below.
double AAI_PlaybookRegimeRiskMultExtra(const int vol_reg, const int msm_reg)
  {
   if(vol_reg == 0) // LOW
     {
      if(msm_reg == 0) return InpPB_RegimeRiskMult_LOW_TREND;
      if(msm_reg == 1) return InpPB_RegimeRiskMult_LOW_RANGE;
      if(msm_reg == 2) return InpPB_RegimeRiskMult_LOW_CHAOS;
     }
   else if(vol_reg == 1) // MID
     {
      if(msm_reg == 0) return InpPB_RegimeRiskMult_MID_TREND;
      if(msm_reg == 1) return InpPB_RegimeRiskMult_MID_RANGE;
      if(msm_reg == 2) return InpPB_RegimeRiskMult_MID_CHAOS;
     }
   else if(vol_reg == 2) // HIGH
     {
      if(msm_reg == 0) return InpPB_RegimeRiskMult_HIGH_TREND;
      if(msm_reg == 1) return InpPB_RegimeRiskMult_HIGH_RANGE;
      if(msm_reg == 2) return InpPB_RegimeRiskMult_HIGH_CHAOS;
     }

   // Fallback: no change
   return 1.0;
  }

// Map VOL × MSM regime index to extra MinConf delta for the playbook.
double AAI_PlaybookRegimeMinConfDeltaExtra(const int vol_reg, const int msm_reg)
  {
   if(vol_reg == 0) // LOW
     {
      if(msm_reg == 0) return (double)InpPB_RegimeMinConfDelta_LOW_TREND;
      if(msm_reg == 1) return (double)InpPB_RegimeMinConfDelta_LOW_RANGE;
      if(msm_reg == 2) return (double)InpPB_RegimeMinConfDelta_LOW_CHAOS;
     }
   else if(vol_reg == 1) // MID
     {
      if(msm_reg == 0) return (double)InpPB_RegimeMinConfDelta_MID_TREND;
      if(msm_reg == 1) return (double)InpPB_RegimeMinConfDelta_MID_RANGE;
      if(msm_reg == 2) return (double)InpPB_RegimeMinConfDelta_MID_CHAOS;
     }
   else if(vol_reg == 2) // HIGH
     {
      if(msm_reg == 0) return (double)InpPB_RegimeMinConfDelta_HIGH_TREND;
      if(msm_reg == 1) return (double)InpPB_RegimeMinConfDelta_HIGH_RANGE;
      if(msm_reg == 2) return (double)InpPB_RegimeMinConfDelta_HIGH_CHAOS;
     }

   // Fallback: no change
   return 0.0;
  }

// Fill a playbook struct based on current context & scenario.
// Currently this preserves previous behaviour when all InpPB_Scn* dials
// are left at their neutral defaults.
void AAI_FillPlaybook(const AAI_Context &ctx,
                      const ENUM_AAI_SCENARIO scn,
                      AAI_Playbook &pb)
  {
   // Base defaults
   pb.exit_profile_id = 0;

   // --- Base: mode/regime risk multipliers (same as before) ------
   pb.risk_mult_mode     = AAI_ModeRiskMult();
   pb.risk_mult_regime   = AAI_RegimeRiskMult();
   pb.risk_mult_scenario = AAI_PlaybookScenarioRiskMult(scn);

   // --- Base: mode/regime MinConf adjustments (same as before) ---
   pb.minconf_delta_mode     = AAI_ModeMinConfDelta();
   pb.minconf_delta_regime   = AAI_RegimeMinConfDelta();
   pb.minconf_delta_scenario = AAI_PlaybookScenarioMinConfDelta(scn);

   // --- NEW: regime-specific playbook extras (currently neutral) --
   double regime_mult_extra =
      AAI_PlaybookRegimeRiskMultExtra(ctx.vol_regime, ctx.msm_regime);
   double regime_minconf_extra =
      AAI_PlaybookRegimeMinConfDeltaExtra(ctx.vol_regime, ctx.msm_regime);

   pb.risk_mult_regime   *= regime_mult_extra;
   pb.minconf_delta_regime += regime_minconf_extra;

   // --- Preserve existing scenario-specific MinConf tweaks --------
   if(scn == AAI_SCN_DEFENSIVE && InpPB_Def_MinConfExtra != 0)
     {
      pb.minconf_delta_mode += (double)InpPB_Def_MinConfExtra;
     }

   if(scn == AAI_SCN_OPPORTUNITY && InpPB_Opp_MinConfDelta != 0)
     {
      pb.minconf_delta_mode += (double)InpPB_Opp_MinConfDelta;
     }
   // Scenario-level entry permission
   pb.allow_entries = AAI_PlaybookScenarioAllowEntries(scn);
   // Hard environment safety: don't trade during CHAOS (even if transition ended)
if(InpRS_BlockEntriesInChaos && ctx.msm_regime == AAI_MSM_CHAOS_BAD)
   pb.allow_entries = false;

// Transition defense (anti-wipeout during regime shifts)
if(InpRS_EnableTransitionGuard && g_rs_transition_active)
{
   pb.risk_mult_regime     *= InpRS_TransitionRiskMult;
   pb.minconf_delta_regime += (double)InpRS_TransitionMinConfAdd;
}

   // Exit profile id for this context/scenario
   pb.exit_profile_id = AAI_PlaybookScenarioExitProfile(scn);

  }



#define AAI_POSAGG_MAX  64   // max concurrent positions to track

ulong  AAI_posagg_id[AAI_POSAGG_MAX];
double AAI_posagg_net[AAI_POSAGG_MAX];

// Convenience helpers to get combined multipliers/deltas
double AAI_PlaybookRiskMult(const AAI_Context &ctx)
  {
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);
   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   // Final risk multiplier = mode × regime × scenario
   return (pb.risk_mult_mode * pb.risk_mult_regime * pb.risk_mult_scenario);
  }

double AAI_PlaybookMinConfDelta(const AAI_Context &ctx)
  {
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);
   AAI_Playbook pb;
   AAI_FillPlaybook(ctx, scn, pb);

   // Final MinConf delta = mode + regime + scenario (plus legacy tweaks already baked in)
   return (pb.minconf_delta_mode + pb.minconf_delta_regime + pb.minconf_delta_scenario);
  }

// --- Block log dedupe (once per bar per reason)
datetime g_lastBlockBarTime = 0;
string   g_lastBlockReason  = "";
int      g_lastBlockCode    = -1;

// --- AAI metrics (lightweight) ---
double g_aai_net = 0.0, g_aai_gross_pos = 0.0, g_aai_gross_neg = 0.0;
int    g_aai_trades = 0, g_aai_wins = 0, g_aai_losses = 0;
double g_aai_equity_peak = 0.0, g_aai_max_dd = 0.0;

// --- State Management Globals ---
static datetime g_lastBarTime = 0;
static datetime g_last_suppress_log_time = 0;
static datetime g_last_telegram_alert_bar = 0;
static ulong    g_tickCount   = 0;
static int  g_barIndex = 0;

static int  g_rs_transition_until_bar = -1;
static bool g_rs_transition_active    = false;
static bool g_rs_transition_prev      = false;


static datetime g_last_ea_warmup_log_time = 0;
static datetime g_last_per_bar_journal_time = 0;
bool g_bootstrap_done = false;
static datetime g_last_entry_bar_buy = 0, g_last_entry_bar_sell = 0;
static ulong    g_last_send_sig_hash = 0;
static ulong g_last_send_ms = 0;
static datetime g_cool_until_buy = 0, g_cool_until_sell = 0;

// --- Victory Lap (Profit Lock) State ---
double g_pl_growth_pct  = 0.0;
bool   g_pl_soft_active = false;
bool   g_pl_hard_active = false;
bool   g_victory_lap_active = false;   // alias for "hard" active

// --- T042: Telemetry State ---
static int      g_tel_barcount = 0;
static datetime g_tel_lastbar  = 0;


// --- T043: Parity Harness State ---
static bool     g_pth_is_tester = false;
static bool     g_pth_is_opt    = false;
static bool     g_pth_init      = false;
static datetime g_pth_stamp     = 0;
static int      g_pth_barcount  = 0;

// --- T044: State Persistence State ---
static int      g_sp_barcount = 0;
static datetime g_sp_lastbar  = 0;

// --- T026/T027/T029: Per-bar flags for decision journaling ---
static int    g_vr_flag_for_bar   = 0;
static int    g_news_flag_for_bar = 0;
static bool   g_sp_hit_for_bar    = false;
static bool   g_imc_flag_for_bar  = false;
static double g_imc_support       = 0.0;
static bool   g_rg_flag_for_bar   = false;


// --- T028: Adaptive Spread State ---
int      g_as_tick_ctr         = 0;
double   g_as_samples[];
datetime g_as_forming_bar_time = 0;
double   g_as_bar_medians[];
int      g_as_hist_count       = 0;
int      g_as_hist_pos         = 0;
bool     g_as_exceeded_for_bar = false;
double   g_as_cap_pts_last     = 0.0;

// --- T030: Global Risk Guard State ---
datetime g_rg_day_anchor_time   = 0;
double   g_rg_day_start_balance = 0.0;
double   g_rg_day_realized_pl   = 0.0;
int      g_rg_day_sl_hits       = 0;
int      g_rg_consec_losses     = 0;
bool     g_rg_block_active      = false;
datetime g_rg_block_until       = 0;

// --- T034: Harmonizer State ---
class HM_Task : public CObject {
public:
  string   symbol;
  long     pos_ticket;
  double   sl_target;
  double   tp_target;
  int      retries_left;
  datetime next_try_time;
  HM_Task(): pos_ticket(0), sl_target(0), tp_target(0), retries_left(0), next_try_time(0) {}
};
CArrayObj g_hm_tasks;
datetime  g_hm_last_tick_ts = 0;

// --- T035 & T036: Trailing and Partial TP State ---
class TRL_State : public CObject {
public:
  string   symbol;
  ulong    ticket;

  int      direction;
  double   entry_price;
  double   entry_sl_pts;

  // T036 fields
  double   entry_lots;
  double   pt_closed_lots;
  bool     pt1_done, pt2_done, pt3_done;

  // Per-position PT/chain/freeze helpers
  datetime pt1_hit_time;
  datetime pt2_hit_time;
  datetime last_close_bar_time;
  bool     pt_frozen;
  double   pt2_frozen_price;
  double   pt3_frozen_price;

  // T035 fields
  bool     be_done;
  int      moves_today;
  datetime last_mod_time;
  datetime day_anchor;

  TRL_State(): symbol(""), ticket(0),
               direction(0), entry_price(0), entry_sl_pts(0),
               entry_lots(0.0), pt_closed_lots(0.0),
               pt1_done(false), pt2_done(false), pt3_done(false),
               pt1_hit_time(0), pt2_hit_time(0), last_close_bar_time(0),
               pt_frozen(false), pt2_frozen_price(EMPTY_VALUE), pt3_frozen_price(EMPTY_VALUE),
               be_done(false),
               moves_today(0), last_mod_time(0), day_anchor(0) {}
};
CArrayObj g_trl_states;

// --- T036: PT Freeze State ---
datetime g_PT1_LastHitTime   = 0;
datetime g_PT2_LastHitTime    =0;
double  g_PT2_FrozenPrice = EMPTY_VALUE;
double  g_PT3_FrozenPrice = EMPTY_VALUE;
bool    g_PT_Frozen       = false;
ulong   g_PT_FreezeTicket = 0;        // position ticket to auto-reset between trades
datetime g_PT_LastCloseBarTime = 0;   // (Optional) for same-bar chain block

// --- T037: Position Health Watchdog State ---
static datetime g_phw_fail_timestamps[];
static int      g_phw_fail_count = 0;
static datetime g_phw_day_anchor = 0;
static int      g_phw_repeats_today = 0;
static datetime g_phw_cool_until = 0;
static datetime g_phw_last_trigger_ts = 0;

// --- T038: Equity Curve Feedback State ---
static double   g_ecf_ewma = 0.0;
static datetime g_stamp_ecf = 0;

// --- T039: SL Cluster State ---
struct SLC_Event {
    double   price;
    datetime time;
};
static SLC_Event  g_slc_history_buy[];
static SLC_Event  g_slc_history_sell[];
static int        g_slc_head_buy = 0;
static int        g_slc_head_sell = 0;
static int        g_slc_count_buy = 0;
static int        g_slc_count_sell = 0;
static datetime   g_slc_cool_until_buy = 0;
static datetime   g_slc_cool_until_sell = 0;
static int        g_slc_repeats_buy = 0;
static int        g_slc_repeats_sell = 0;
static datetime   g_slc_day_anchor = 0;

// --- T040: Execution Analytics State ---
struct EA_State {
    double   ewma_slip_pts;
    double   ewma_latency_ms;
    int      rej_history[EA_RejWindowTrades]; // Ring buffer: 1=reject, 0=ok
    int      rej_head;
    int      rej_count;   // Total valid entries in history
    ulong    last_send_ticks;
    double   last_req_price;  // Requested price for slippage calc
};
static EA_State g_ea_state;
static int      g_last_dev_pts = 0; // T042: store last deviation for telemetry

// --- T041: Market State Model State ---
static datetime g_stamp_msm = 0;
// ATR history for percentile
static double   g_msm_atr_hist[MSM_ATR_PctlWindow];
static int      g_msm_atr_head = 0;
static int      g_msm_atr_count = 0;
// Last computed features (for optional logs/debug)
static double   g_msm_atr         = 0.0;
static double   g_msm_adx         = 0.0;
static double   g_msm_pctl        = 0.0;   // 0..1 percentile
static int      g_msm_state       = 0;     // 0=unknown,1=TREND_UP,2=TREND_DN,3=RANGE,...
static double   g_msm_mult        = 1.0;

// MSM smoothing / hysteresis
static double g_msm_adx_ema              = 0.0;
static int    g_msm_regime_last          = AAI_MSM_CHAOS_BAD;
static int    g_msm_regime_pending       = AAI_MSM_CHAOS_BAD;
static int    g_msm_regime_pending_count = 0;

// Smoothing and hysteresis tunables
const double  MSM_ADX_EMA_Alpha        = 0.25; // 0..1, higher = more reactive
const int     MSM_RegimeHysteresisBars = 3;    // bars of consistent signal needed to switch


// Volatility regime hysteresis state (to avoid flapping)
static int g_vr_last_regime    = AAI_VOL_MID;
static int g_vr_pending_regime = AAI_VOL_MID;
static int g_vr_pending_count  = 0;

// Hysteresis: how many consecutive bars a new regime must persist
// before we accept the change.
const int VR_HysteresisBars   = 3;

// Minimum ATR samples required before we trust percentile-based
// volatility classification. Below this, we fall back to static
// ATR bps thresholds.
const int MSM_MinPctlSamples  = 20;


// --- T012: Summary Counters ---
static long g_entries     = 0;
static long g_wins        = 0;
static long g_losses      = 0;
static long g_blk_ze      = 0;
static long g_blk_bc      = 0;
static long g_blk_imc     = 0; // T029
static long g_blk_risk    = 0; // T030
static long g_blk_over    = 0;
static long g_blk_spread  = 0;
static long g_blk_aspread = 0; // T028
static long g_blk_smc     = 0;
static long g_blk_vr      = 0;
static long g_blk_news    = 0;
static long g_blk_sp      = 0; // T027
static long g_blk_phw     = 0; // T037
static long g_blk_slc     = 0; // T039
static bool g_summary_printed = false;
// --- Once-per-bar stamps for block counters ---
datetime g_stamp_conf  = 0;
datetime g_stamp_ze    = 0;
datetime g_stamp_bc    = 0;
datetime g_stamp_imc   = 0; // T029
datetime g_stamp_risk  = 0; // T030
datetime g_stamp_over  = 0;
datetime g_stamp_sess  = 0;
datetime g_stamp_spd   = 0;
datetime g_stamp_aspd  = 0; // T028
datetime g_stamp_atr   = 0;
datetime g_stamp_cool  = 0;
datetime g_stamp_bar   = 0;
datetime g_stamp_smc   = 0;
datetime g_stamp_vr    = 0;
datetime g_stamp_news  = 0;
datetime g_stamp_sp    = 0; // T027
datetime g_stamp_phw   = 0; // T037
datetime g_stamp_slc   = 0; // T039
datetime g_stamp_mso   = 0; // T045
datetime g_stamp_none  = 0;
datetime g_stamp_approval = 0;

// ... modified the counting of trade duration.
double GetAverageTradeDuration()
{
   datetime from = 0;
   datetime to   = TimeCurrent();
   HistorySelect(from, to);

   const int deals = HistoryDealsTotal();
   if(deals <= 0) return 0.0;

   ulong    pos_ids[];
   datetime t_in[];
   datetime t_out[];
   ArrayResize(pos_ids, 0);
   ArrayResize(t_in,    0);
   ArrayResize(t_out,   0);

   for(int i=0; i<deals; i++)
   {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;

      // Filter to this EA + symbol (optional but recommended)
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)MagicNumber) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;

      const ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(pid == 0) continue;

      const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      const datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);

      int idx = -1;
      for(int k=0; k<ArraySize(pos_ids); k++)
      {
         if(pos_ids[k] == pid) { idx = k; break; }
      }
      if(idx < 0)
      {
         const int n = ArraySize(pos_ids);
         ArrayResize(pos_ids, n+1);
         ArrayResize(t_in,    n+1);
         ArrayResize(t_out,   n+1);
         pos_ids[n] = pid;
         t_in[n]    = 0;
         t_out[n]   = 0;
         idx        = n;
      }

      if(entry == DEAL_ENTRY_IN)
      {
         if(t_in[idx] == 0 || t < t_in[idx]) t_in[idx] = t;
      }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      {
         if(t > t_out[idx]) t_out[idx] = t;
      }
   }

   double sum = 0.0;
   int    cnt = 0;

   for(int i=0; i<ArraySize(pos_ids); i++)
   {
      if(t_in[i] > 0 && t_out[i] > t_in[i])
      {
         sum += (double)(t_out[i] - t_in[i]);
         cnt++;
      }
   }

   return (cnt > 0 ? sum / cnt : 0.0);
}

// === PT cleanup (safe to paste as-is) ======================================
void PT_ClearGV(const ulong ticket)
{
   // assumes you already have PT_Key(kind, ticket)
   string keys[] = {
      PT_Key("S1", ticket), PT_Key("S2", ticket), PT_Key("S3", ticket),
      PT_Key("ENTRYLOTS", ticket), PT_Key("CLOSEDLOTS", ticket),
      PT_Key("LASTMOD", ticket)
   };
   for(int i=0;i<ArraySize(keys);++i)
      if(GlobalVariableCheck(keys[i])) GlobalVariableDel(keys[i]);
}
// ===========================================================================


// --- T_AZ: Auto-Zone Globals ---
static int g_ttl_secs;
static int g_pref_exit_secs;

#include "inc/AAI_HybridState.mqh"

double OnTester()
{
   // Built-ins
   double profit      = (double)TesterStatistics(STAT_PROFIT);
   double dd_rel_pct  = (double)TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double pf          = (double)TesterStatistics(STAT_PROFIT_FACTOR);
   double sharpe      = (double)TesterStatistics(STAT_SHARPE_RATIO);
double avg_sec = GetAverageTradeDuration();
   double trades      = (double)TesterStatistics(STAT_TRADES);

// Avoid "everything rejected" during optimization. Keep only a basic guard.
if(trades < 10) return -1.0;

// Soft clamp instead of hard-fail
if(avg_sec <= 0) avg_sec = 0;
if(pf < 0) pf = 0;
if(dd_rel_pct < 0) dd_rel_pct = 0;


   // Normalize & cap tails
   double dd_pen   = 1.0 / (1.0 + dd_rel_pct/10.0);     // lower DD ? higher score
   double pf_term  = MathMin(pf,    3.0) / 3.0;
   double sh_term  = MathMin(sharpe,3.0) / 3.0;
   double dur_bonus= MathMax(0.0, 1.0 - (avg_sec/(8.0*3600.0)));

   // Weighted blend
   return 0.40*sh_term + 0.25*pf_term + 0.20*dd_pen + 0.15*dur_bonus;
}


//+------------------------------------------------------------------+
//| T012: Print Golden Summary                                       |
//+------------------------------------------------------------------+
void PrintSummary()
{
    if(g_summary_printed) return;
    PrintFormat("AAI_SUMMARY|entries=%d|wins=%d|losses=%d|ze_blk=%d|bc_blk=%d|smc_blk=%d|overext_blk=%d|spread_blk=%d|aspread_blk=%d|vr_blk=%d|news_blk=%d|sp_blk=%d|imc_blk=%d|risk_blk=%d|phw_blk=%d|slc_blk=%d",
                g_entries,
                g_wins,
                g_losses,
                g_blk_ze,
                g_blk_bc,
                g_blk_smc,
                g_blk_over,
                g_blk_spread,
                g_blk_aspread,
                g_blk_vr,
                g_blk_news,
                g_blk_sp,
                g_blk_imc,
                g_blk_risk,
                g_blk_phw,
                g_blk_slc);
    g_summary_printed = true;
}

//--- TICKET T021: New Caching Helper ---
bool UpdateSBCacheIfNewBar()
{
const int sb_shift = MathMax(1, SB_ReadShift);
datetime t = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, sb_shift);
  if(t == 0) return false;       // no history yet
// new: same bar ? nothing to do; only return true on a NEW bar
if(g_sb.valid && g_sb.closed_bar_time == t)
    return false;

  // Read all 7 buffers for sb_shift in one shot
  double v;
  // Signal
  if(!Read1(sb_handle, 0, sb_shift, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.sig = (int)MathRound(v);
  // Confidence
  if(!Read1(sb_handle, 1, sb_shift, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.conf = v;
  // Reason
  if(!Read1(sb_handle, 2, sb_shift, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.reason = (int)MathRound(v);
  // ZE
  if(!Read1(sb_handle, 3, sb_shift, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.ze = v;
  // SMC signal
  if(!Read1(sb_handle, 4, sb_shift, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.smc_sig = (int)MathRound(v);
  // SMC conf
  if(!Read1(sb_handle, 5, sb_shift, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.smc_conf = v;
  // BC
  if(!Read1(sb_handle, 6, sb_shift, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.bc = (int)MathRound(v);

  g_sb.closed_bar_time = t;
  g_sb.valid = true;
  return true;
}
inline bool ReadATRFastPts(double &out_pts)
{
   out_pts = 0.0;
   if(g_hATR_fast == INVALID_HANDLE) return false;

   const int sb_shift = MathMax(1, SB_ReadShift);

   double b[1];
   if(CopyBuffer(g_hATR_fast, 0, sb_shift, 1, b) != 1) return false;
   if(b[0] <= 0) return false;

   out_pts = b[0] / _Point;
   return true;
}


#include "inc/AAI_Journal.mqh"
double VR_BpsLastBar(){
  double a[1]; if(CopyBuffer(g_hATR_VR,0,1,1,a)!=1 || a[0]<=0) return 0.0;
  MqlRates r[]; if(CopyRates(_Symbol,(ENUM_TIMEFRAMES)SignalTimeframe,1,1,r)!=1 || r[0].close<=0) return 0.0;
  return 10000.0 * (a[0] / r[0].close);
}
bool VR_IsHot(){ return (InpVAPT_Enable && VR_BpsLastBar() >= InpVAPT_HotBps); }

bool VAPT_Armed(const int dir, const double entry){
  if(!InpVAPT_Enable) return true;
  if((TimeCurrent() - (datetime)PositionGetInteger(POSITION_TIME)) < InpVAPT_ArmAfterSec) return false;
  if(InpVAPT_MinMFE_ATR>0){
    double px = (dir>0 ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                       : SymbolInfoDouble(_Symbol,SYMBOL_ASK));
    double a[1]; if(CopyBuffer(g_hATR,0,1,1,a)!=1 || a[0]<=0) return true; // fail-open
    double mfe_px  = MathMax(0.0, (dir>0 ? px-entry : entry-px));
    return (mfe_px >= InpVAPT_MinMFE_ATR * a[0]);
  }
  return true;
}

// MSM ATR in basis points on the last closed bar
double MSM_AtrBpsLastBar()
  {
   if(g_hMSM_ATR == INVALID_HANDLE)
      return 0.0;

   double a[1];
   if(CopyBuffer(g_hMSM_ATR, 0, 1, 1, a) != 1 || a[0] <= 0.0)
      return 0.0;

   MqlRates r[];
   if(CopyRates(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, 1, r) != 1 || r[0].close <= 0.0)
      return 0.0;

   return 10000.0 * (a[0] / r[0].close);
  }

// Update ATR history and percentile (0..1) for MSM
double MSM_UpdateAtrPercentile(const double bps)
  {
   g_msm_atr = bps;

   if(bps <= 0.0)
     {
      g_msm_pctl = 0.0;
      return g_msm_pctl;
     }

   // Push into ring buffer
   g_msm_atr_hist[g_msm_atr_head] = bps;
   g_msm_atr_head = (g_msm_atr_head + 1) % MSM_ATR_PctlWindow;
   if(g_msm_atr_count < MSM_ATR_PctlWindow)
      g_msm_atr_count++;

   // If we don't yet have enough history, just report neutral percentile
   if(g_msm_atr_count <= 1)
     {
      g_msm_pctl = 0.5;
      return g_msm_pctl;
     }

   int less_eq = 0;
   for(int i = 0; i < g_msm_atr_count; i++)
     {
      if(g_msm_atr_hist[i] <= bps)
         less_eq++;
     }

   g_msm_pctl = (double)less_eq / (double)g_msm_atr_count;  // 0..1
   return g_msm_pctl;
  }

//+------------------------------------------------------------------+
//| T004: Logs a single line with the state of the last closed bar.  |
//| T005: Persists the log to a daily rotating CSV file.             |
//+------------------------------------------------------------------+
void LogPerBarStatus(int sig, double conf, int reason, double ze, int bc)
{
    const int readShift = 1;
    datetime closedBarTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, readShift);
    if (closedBarTime == g_last_per_bar_journal_time || closedBarTime == 0)
        return;
    g_last_per_bar_journal_time = closedBarTime;

    string tfStr = CurrentTfLabel();

    // ------------------ T005: Daily CSV ------------------
    MqlDateTime __dt;
    TimeToStruct(closedBarTime, __dt);
    string ymd = StringFormat("%04d%02d%02d", __dt.year, __dt.mon, __dt.day);
    string filename = "AAI_Journal_" + ymd + ".csv";

    int handle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ | FILE_ANSI, ',');
    if (handle != INVALID_HANDLE)
    {
        if (FileSize(handle) == 0)
            FileWriteString(handle, "t,sym,tf,sig,conf,reason,ze,bc,mode\n");
        FileSeek(handle, 0, SEEK_END);
        string csvRow = StringFormat(
            "%s,%s,%s,%d,%.0f,%d,%.1f,%d,%s\n",
            TimeToString(closedBarTime, TIME_DATE | TIME_SECONDS),
            _Symbol,
            tfStr,
            sig,
            conf,
            reason,
            ze,
            bc,
            EnumToString(ExecutionMode)
        );
        FileWriteString(handle, csvRow);
        FileClose(handle);
    }
    else
    {
        PrintFormat("[ERROR] T005: Could not open daily journal file %s", filename);
    }

    // ------------------ T004: Per-bar heartbeat ------------------
string logLine = StringFormat(
    "AAI|t=%s|sym=%s|tf=%s|sig=%d|conf=%.0f|reason=%d|ze=%.1f|bc=%d|mode=%s",
        TimeToString(closedBarTime, TIME_DATE | TIME_SECONDS),
        _Symbol,
        tfStr,
        sig,
        conf,
        reason,
        ze,
        bc,
        EnumToString(ExecutionMode)
    );
AAI_AppendJournal(logLine);
}

//+------------------------------------------------------------------+
//| Push SignalBrain config into globals for the SB indicator        |
//+------------------------------------------------------------------+
void AAI_PushSignalBrainGlobals()
{
   GlobalVariableSet("AAI/SB/ConfModel",        (double)InpSB_ConfModel);
   GlobalVariableSet("AAI/SB/W_BASE",          InpSB_W_BASE);
   GlobalVariableSet("AAI/SB/W_BC",            InpSB_W_BC);
   GlobalVariableSet("AAI/SB/W_ZE",            InpSB_W_ZE);
   GlobalVariableSet("AAI/SB/W_SMC",           InpSB_W_SMC);
   GlobalVariableSet("AAI/SB/ConflictPenalty", InpSB_ConflictPenalty);

   PrintFormat("[SB_GLOBALS] model=%d W_BASE=%.2f W_BC=%.2f W_ZE=%.2f W_SMC=%.2f cpen=%.2f",
               (int)InpSB_ConfModel,
               InpSB_W_BASE,
               InpSB_W_BC,
               InpSB_W_ZE,
               InpSB_W_SMC,
               InpSB_ConflictPenalty);
}


//+------------------------------------------------------------------+
//| T042: Telemetry v2 Emitter                                       |
//+------------------------------------------------------------------+
void Telemetry_OnBar()
{
    if(!TEL_Enable) return;
    if(g_sb.valid && g_sb.closed_bar_time == g_tel_lastbar) return;
    if(g_sb.valid) g_tel_lastbar = g_sb.closed_bar_time;
    g_tel_barcount++;

    if(TEL_EmitEveryN <= 0) return;
    if((g_tel_barcount % TEL_EmitEveryN) != 0) return;

    // --- Assemble a compact line
    const int    spr    = CurrentSpreadPoints();
    const double dd_abs = AAI_peak - AAI_curve;
    const double denom  = (AAI_peak != 0.0 ? MathAbs(AAI_peak) : 1.0);
    const double dd_pct = (denom > 0.0 ? 100.0 * (dd_abs / denom) : 0.0);
    const double rejr   = EA_RecentRejectRate();
    const int    devpts = g_last_dev_pts;

    // ECF multiplier calculation (mirrored from GateECF)
    double ecf_mult = 1.0;
    if(ECF_Enable) {
        if(dd_pct >= ECF_DD_SoftPct) {
            double t = MathMin(1.0, (dd_pct - ECF_DD_SoftPct) / MathMax(1e-9, (ECF_DD_HardPct - ECF_DD_SoftPct)));
            ecf_mult = 1.0 - t * (1.0 - ECF_MaxDnMult);
        } else if(AAI_trades >= ECF_MinTradesForBoost && g_ecf_ewma > 0.0) {
            double boost = (1.0 - MathMin(1.0, dd_pct / ECF_DD_SoftPct)) * (ECF_MaxUpMult - 1.0);
            ecf_mult = 1.0 + boost;
        }
    }

    string s = StringFormat("%s|t=%s|sym=%s|tf=%s|spr=%d|dev=%d|rej=%.2f|slip=%.1f|lat=%.0f|dd=%.2f|msm=%d:%.2f|ecf=%.2f",
                            TEL_Prefix,
                            TimeToString(g_sb.closed_bar_time, TIME_DATE|TIME_SECONDS),
                            _Symbol,
                            CurrentTfLabel(),
                            spr,
                            devpts,
                            rejr,
                            g_ea_state.ewma_slip_pts,
                            g_ea_state.ewma_latency_ms,
                            dd_pct,
                            g_msm_state, g_msm_mult,
                            ecf_mult
                           );

    if(TEL_LogVerbose) {
        int rem_phw = (int)MathMax(0, (long)g_phw_cool_until - TimeCurrent());
        int rem_slc = (int)MathMax(0, (long)MathMax(g_slc_cool_until_buy, g_slc_cool_until_sell) - TimeCurrent());
        s = StringFormat("%s|phw=%d|slc=%d|atrp=%.2f|adx=%.1f",
                         s, rem_phw, rem_slc, g_msm_pctl, g_msm_adx);
    }
    Print(s);
}

//+------------------------------------------------------------------+
//| T043: Parity Harness Emitter                                     |
//+------------------------------------------------------------------+
void ParityHarness_OnBar(const int direction,
                         const double conf_pre_gate,
                         const bool   allowed,
                         const string reason_id,
                         const int    dev_pts)
{
    if(!PTH_Enable) return;
    if(g_sb.closed_bar_time == g_pth_stamp) return; // once/bar
    g_pth_stamp = g_sb.closed_bar_time;
    g_pth_barcount++;

    if(PTH_EmitEveryN <= 0) return;
    if((g_pth_barcount % PTH_EmitEveryN) != 0) return;

    if(!g_pth_init) {
        g_pth_is_tester = (bool)MQLInfoInteger(MQL_TESTER);
        g_pth_is_opt    = (bool)MQLInfoInteger(MQL_OPTIMIZATION);
        g_pth_init = true;
    }

    // Stable, shift=1 data from MQL5 arrays
    double c1[1], h1[1], l1[1];
    CopyClose(_Symbol, _Period, 1, 1, c1);
    CopyHigh(_Symbol, _Period, 1, 1, h1);
    CopyLow(_Symbol, _Period, 1, 1, l1);
   
    const int spr = CurrentSpreadPoints();
    const string env = g_pth_is_tester ? (g_pth_is_opt ? "TEST_OPT" : "TEST") : "LIVE";

    // Pull existing module signals (already stored globally by prior tickets)
    const int    msm_state = g_msm_state;
    const double msm_mult  = g_msm_mult;
    const double dd_abs = AAI_peak - AAI_curve;
    const double denom  = (AAI_peak!=0.0 ? MathAbs(AAI_peak) : 1.0);
    const double dd_pct = (denom>0.0 ? 100.0*(dd_abs/denom) : 0.0);

    // One-line core (keep order stable)
    string core = StringFormat("t=%s|env=%s|sym=%s|tf=%s|c1=%.5f|h1=%.5f|l1=%.5f|spr=%d|pt=%.5f|dir=%d|conf=%.1f|msm=%d:%.3f|dd=%.2f|dev=%d|allow=%d|rsn=%s",
      TimeToString(g_sb.closed_bar_time, TIME_DATE|TIME_SECONDS),
      env, _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
      c1[0], h1[0], l1[0], spr, _Point, direction, conf_pre_gate, msm_state, msm_mult, dd_pct, dev_pts, (int)allowed, reason_id);

    uint hash = FNV1a32(core);
   
    string final_log_string;
    if(PTH_LogVerbose) {
        final_log_string = StringFormat("%s|%s|hash=0x%08X", PTH_Prefix, core, hash);
    } else {
        // Short version as requested
        string short_core = StringFormat("t=%s|env=%s|c1=%.5f|spr=%d|dir=%d|conf=%.1f|msm=%d:%.3f|dd=%.2f|dev=%d|alw=%d|rsn=%s",
            TimeToString(g_sb.closed_bar_time, TIME_SECONDS),
            env, c1[0], spr, direction, conf_pre_gate, msm_state, msm_mult, dd_pct, dev_pts, (int)allowed, reason_id);
        final_log_string = StringFormat("%s|%s|h=0x%08X", PTH_Prefix, short_core, hash);
    }
    Print(final_log_string);
}


//+------------------------------------------------------------------+
//| T026: Decision Journaling CSV Helper                             |
//+------------------------------------------------------------------+
void DJ_Write(const int direction,
              const double conf_eff,
              const int sb_reason,
              const double ze_strength,
              const int bc_bias,
              const int smc_sig,
              const double smc_conf,
              const int vr_flag,
              const int news_flag,
              const int sp_flag,
              const int as_flag,
              const double as_cap_pts,
              const int as_hist_n,
              const int imc_flag,
              const double imc_support,
              const int rg_flag,
              const double rg_dd_pct,
              const double rg_dd_abs,
              const int rg_sls,
              const int rg_seq,
              const double spread_pts,
              const double lots,
              const double sl_pts,
              const double tp_pts,
              const double rr,
              const string entry_mode)
{
  if(!InpDJ_Enable) return;

  int flags = FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON;
  int h = FileOpen(InpDJ_FileName, flags);
  if(h == INVALID_HANDLE) return;

  // Write header if file is empty or we’re not appending
  if(FileSize(h) == 0 || !InpDJ_Append){
    FileSeek(h, 0, SEEK_SET);
    string header = "time,symbol,tf,dir,conf,sb_reason,ze_strength,bc_bias,smc_sig,smc_conf,vr_flag,news_flag,sp_flag,as_flag,as_cap_pts,as_histN,imc_flag,imc_support,rg_flag,rg_dd_pct,rg_dd_abs,rg_sls,rg_seq,spread_pts,lots,sl_pts,tp_pts,rr,entry_mode\r\n";
    FileWriteString(h, header);
  }

  // Always append a row at end
  FileSeek(h, 0, SEEK_END);

  datetime t = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1); // closed bar time
  string tf  = TfLabel((ENUM_TIMEFRAMES)SignalTimeframe);

  string row = StringFormat("%s,%s,%s,%d,%.0f,%d,%.1f,%d,%d,%.1f,%d,%d,%d,%d,%.0f,%d,%d,%.2f,%d,%.2f,%.2f,%d,%d,%.0f,%.2f,%.0f,%.0f,%.2f,%s\r\n",
    TimeToString(t, TIME_DATE|TIME_SECONDS),
    _Symbol,
    tf,
    direction,
    conf_eff,
    sb_reason,
    ze_strength,
    bc_bias,
    smc_sig,
    smc_conf,
    vr_flag,
    news_flag,
    sp_flag,
    as_flag,
    as_cap_pts,
    as_hist_n,
    imc_flag,
    imc_support,
    rg_flag,
    rg_dd_pct,
    rg_dd_abs,
    rg_sls,
    rg_seq,
    spread_pts,
    lots,
    sl_pts,
    tp_pts,
    rr,
    entry_mode
  );

  FileWriteString(h, row);
  FileClose(h);
}


//+------------------------------------------------------------------+
//| HYBRID Approval Helper Functions                                 |
//+------------------------------------------------------------------+
bool WriteText(const string path, const string text)
{
    int h = FileOpen(path, FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(h==INVALID_HANDLE){ PrintFormat("[HYBRID] FileOpen write fail %s (%d)", path, GetLastError()); return false; }
    FileWriteString(h, text);
    FileClose(h);
    return true;
}

string ReadAll(const string path)
{
    int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI);
    if(h==INVALID_HANDLE) return "";
    string s = FileReadString(h, (int)FileSize(h));
    FileClose(h);
    return s;
}

string JsonGetStr(const string json, const string key)
{
    string pat="\""+key+"\":\"";
    int p=StringFind(json, pat); if(p<0) return "";
    p+=StringLen(pat);
    int q=StringFind(json,"\"",p);
    if(q<0) return "";
    return StringSubstr(json, p, q-p);
}



#include "inc/AAI_SessionTime.mqh"




//+------------------------------------------------------------------+
//| Journal a decision to skip a trade                               |
//+------------------------------------------------------------------+
void JournalDecision(string reason)
{
    // Deprecated by AAI_Block which now handles its own journaling logic.
    // This function is kept for backward compatibility if called elsewhere, but should be empty.
}

//+------------------------------------------------------------------+
//| Centralized block counting and logging                           |
//+------------------------------------------------------------------+
void AAI_Block(const string reason)
{
    // Deprecated by new Gate functions which handle their own logging/counting
}

//+------------------------------------------------------------------+
//| Pip Math Helpers                                                 |
//+------------------------------------------------------------------+
inline double PipSize()
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10 * _Point : _Point;
}

inline double PriceFromPips(double pips)
{
   return pips * PipSize();
}

//+------------------------------------------------------------------+
//| Simple string to ulong hash (for duplicate guard)                |
//+------------------------------------------------------------------+
ulong StringToULongHash(string s)
{
    ulong hash = 5381;
    int len = StringLen(s);
    for(int i = 0; i < len; i++)
    {
        hash = ((hash << 5) + hash) + (ulong)StringGetCharacter(s, i);
    }
    return hash;
}

#include "inc/AAI_RiskCurve.mqh"

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(const int confidence, const double sl_distance_price)
  {
   // 0) Convert SL distance from price to points
   const double sl_pts = sl_distance_price / _Point;
   if(sl_pts <= 0.0)
      return 0.0;

   // 1) Base risk from CRC (confidence -> % risk)
   double risk_pct  = CRC_MapConfToRisk(confidence);
   const double risk_base = risk_pct;

   // No risk -> no trade
   if(risk_pct <= 0.0)
      return 0.0;

   // 2) Context: fill AAI_Context (mode, vol_regime, msm_regime, streak, etc.)
   AAI_Context ctx;
   AAI_FillContext(ctx);

   // 3) Playbook risk multiplier (mode × scenario × regime)
   const double risk_mult_pb = AAI_PlaybookRiskMult(ctx);

   // 4) Confidence-band multiplier (SB buckets: 20–30, 50–60, ...)
   const double risk_mult_band = AAI_ConfBandRiskMultFromConf((double)confidence);

   // 5) Apply multipliers
   risk_pct *= risk_mult_pb;
   risk_pct *= risk_mult_band;

   const double risk_pre_cap = risk_pct;

   // 6) Final safety cap vs. InpCRC_MaxRiskPct (if set > 0)
   if(InpCRC_MaxRiskPct > 0.0)
      risk_pct = MathMin(risk_pct, InpCRC_MaxRiskPct);

   // Optional detailed breakdown logging
   if(InpPB_DebugRiskLog)
     {
      const int band_idx    = AAI_ConfBandIndex((double)confidence);
      const string band_lbl = AAI_ConfBandLabel(band_idx);
      const ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

      PrintFormat(
         "AAI_RISK|conf=%d|band=%s"
         "|risk_base=%.3f|risk_mult_pb=%.3f|risk_mult_band=%.3f"
         "|risk_pre_cap=%.3f|risk_final=%.3f"
         "|mode=%s|regime_vol=%s|regime_msm=%s|scenario=%s",
         confidence,
         band_lbl,
         risk_base,
         risk_mult_pb,
         risk_mult_band,
         risk_pre_cap,
         risk_pct,
         AAI_ModeName(ctx.mode),
         AAI_VolRegimeName(ctx.vol_regime),
         AAI_MSMRegimeName(ctx.msm_regime),
         AAI_ScenarioName(scn)
      );
     }

   // 7) Pyramiding: split risk across existing positions on the same side
   if(InpHEDGE_AllowMultiple && InpHEDGE_SplitRiskAcrossPyr && g_sb.sig != 0)
     {
      int L = 0, S = 0;
      CountMyPositions(_Symbol, (long)MagicNumber, L, S);

      const int sideCount = (g_sb.sig > 0 ? L : S);
      if(sideCount > 0)
         risk_pct = risk_pct / (1.0 + sideCount);
     }

   // If risk got driven to zero by caps / splitting, bail
   if(risk_pct <= 0.0)
      return 0.0;

   // 8) Convert final risk% and SL distance to lots
   return LotsFromRiskAndSL(risk_pct, sl_pts);
  }
  
  
  

#include "inc/AAI_RiskGuard.mqh"

#include "inc/AAI_ExecAnalytics.mqh"

//+------------------------------------------------------------------+
//| T_AZ: Helper to check if we are inside the session window        |
//| Uses g_session_windows (AAI_ParseSessionRanges)                  |
//+------------------------------------------------------------------+
bool AZ_IsInsideSession(int &seconds_to_end)
{
    seconds_to_end = 2147483647; // Max int

    // If sessions aren't used, treat as always inside (keep behaviour)
    if(!SessionEnable)
        return true;

    datetime now = TimeCurrent();

    // Are we in any configured session window?
    if(!AAI_SessionIsOpen(now, g_session_windows))
        return false;

    // How long until this session window ends?
    int mins_to_cutoff = AAI_MinutesToSessionCutoff(now, g_session_windows);

    if(mins_to_cutoff < 0)
    {
        // We are in a window but couldn't compute cutoff for some reason.
        // Treat as "inside with unknown end" -> keep seconds_to_end huge.
        return true;
    }

    seconds_to_end = mins_to_cutoff * 60;
    return true;
}

//+------------------------------------------------------------------+
//| Failsafe Exit Logic to catch orphaned trades                     |
//+------------------------------------------------------------------+
void FailsafeExitChecks()
{
    // Initialize CTrade object for this function's scope
    trade.SetExpertMagicNumber(MagicNumber);
    
    // Check session status once per call
    int seconds_to_end;
    bool is_inside_session = AZ_IsInsideSession(seconds_to_end);
    if(InpTS_Enable)
{
   ulong tickets[];
   if(GetMyPositionTickets(_Symbol, (long)MagicNumber, tickets) > 0)
   {
      for(int i=ArraySize(tickets)-1; i>=0; --i)
      {
         const ulong ticket = tickets[i];
         if(!PositionSelectByTicket(ticket)) continue;

         const datetime t0 = (datetime)PositionGetInteger(POSITION_TIME);
         const int age_min = (int)((TimeCurrent() - t0) / 60);

         if(age_min < InpTS_MinHoldMinutes) continue;
         if(age_min <= InpTS_MaxMinutes)   continue;

         // Promotion logic: allow “swinging” only if clearly working
         bool allow_extend = false;

         if(InpTS_AllowSwingPromo)
         {
            TRL_State *st = TRL_GetState(_Symbol, ticket, false);
            const bool pt1_done = (st!=NULL && st.pt1_done) || PT_IsLatchedGV(1, ticket);

            // crude RR proxy: (floating profit in points) / (initial SL points)
            const double op = PositionGetDouble(POSITION_PRICE_OPEN);
            const int dir = ((int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? +1 : -1);
            const double px = (dir>0 ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK));
            const double profit_pts = dir * (px - op) / _Point;

            double sl_pts = 0.0;
            if(st!=NULL && st.entry_sl_pts>0) sl_pts = st.entry_sl_pts;
            if(sl_pts <= 0.0) sl_pts = MathMax(1.0, SL_Buffer_Points); // fallback

            const double rr = profit_pts / sl_pts;

            if(pt1_done || rr >= InpTS_PromoMinRR)
               allow_extend = true;
         }

         if(!allow_extend)
         {
            PrintFormat("[TIME_STOP] Closing ticket %I64u age=%dmin", ticket, age_min);
            trade.PositionClose(ticket);
         }
      }
   }
}


    // Loop through all open positions to apply hard-exit rules
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i); // Safe way to get ticket
        if(PositionSelectByTicket(ticket))   // Safe way to select position
        {
            // Only manage positions for this symbol and magic number
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && (long)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                // --- AZ Failsafe 1: Time-To-Live (Max Duration) ---
                if(InpAZ_TTL_Enable && g_ttl_secs > 0)
                {
                    long open_time = PositionGetInteger(POSITION_TIME);
                    if((TimeCurrent() - open_time) >= g_ttl_secs)
                    {
                         PrintFormat("[AZ_TTL] Closing position #%d. Exceeded max duration of %d hours.", ticket, InpAZ_TTL_Hours);
                         if(!trade.PositionClose(ticket)) { PHW_LogFailure(trade.ResultRetcode()); }
                         continue; // Position is closed, move to the next one
                    }
                }

                // --- AZ Failsafe 2: Session Force-Flat ---
                if(InpAZ_SessionForceFlat)
                {
                    // Close if we are completely outside the session OR if we are inside but near the end
                    if(!is_inside_session || (is_inside_session && seconds_to_end <= g_pref_exit_secs))
                    {
                        PrintFormat("[AZ_SESSION] Closing position #%d. Outside session or within pre-exit window.", ticket);
                        if(!trade.PositionClose(ticket)) { PHW_LogFailure(trade.ResultRetcode()); }
                        continue; // Position is closed, move to the next one
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
#include "inc/AAI_OSR.mqh"
//+------------------------------------------------------------------+
//| Friday close: force-flat after configured hour                   |
//+------------------------------------------------------------------+
void CheckFridayClose()
{
   MqlDateTime loc;
   TimeToStruct(TimeCurrent(), loc);

   // Friday Close Logic
   if(loc.day_of_week == FRIDAY && loc.hour >= FridayCloseHour)
   {
      // Respect MSO guard
      if(!MSO_MaySend(_Symbol))
      {
         if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
         {
            PrintFormat("[MSO] defer Close sym=%s reason=guard", _Symbol);
            g_stamp_mso = g_sb.closed_bar_time;
         }
         return; // Defer action
      }

      // Loop and close all Alfred positions for this symbol/magic
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
            continue;

         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

         if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;

         PrintFormat("[FRIDAY_CLOSE] Force closing ticket %d", ticket);

         if(!trade.PositionClose(ticket))
         {
            PHW_LogFailure(trade.ResultRetcode());
         }
      }
   }
}

// --- Victory Lap (Profit Lock) State Update ---
// Computes floating growth in % of balance and sets soft/hard flags with hysteresis.
void UpdateVictoryLapState()
{
   // Reset each tick
   g_pl_growth_pct  = 0.0;
   g_pl_soft_active = false;
   // NOTE: we do NOT reset g_pl_hard_active here; hysteresis depends on previous value

   if(!InpPL_Enable)
   {
      g_pl_hard_active     = false;
      g_victory_lap_active = false;
      return;
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0.0)
   {
      g_pl_hard_active     = false;
      g_victory_lap_active = false;
      return;
   }

   // Floating growth in percent
   g_pl_growth_pct = 100.0 * (equity - balance) / balance;

   // --- Soft level: no hysteresis, just a plain threshold ---
   if(InpPL_SoftTriggerPct > 0.0 && g_pl_growth_pct >= InpPL_SoftTriggerPct)
      g_pl_soft_active = true;
   else
      g_pl_soft_active = false;

   // --- Hard level: hysteresis ---
   // ON threshold: InpPL_TriggerPct  (e.g. 0.50)
   // OFF threshold: InpPL_SoftTriggerPct (e.g. 0.30), if > 0, otherwise same as ON
   double hard_off = (InpPL_SoftTriggerPct > 0.0 ? InpPL_SoftTriggerPct : InpPL_TriggerPct);

   // Turn hard ON if we were off and crossed the ON threshold
   if(!g_pl_hard_active && g_pl_growth_pct >= InpPL_TriggerPct)
      g_pl_hard_active = true;

   // Turn hard OFF if we were on and dropped below the OFF threshold
   if(g_pl_hard_active && g_pl_growth_pct <= hard_off)
      g_pl_hard_active = false;

   // Alias for backward compatibility / logs
   bool prev = g_victory_lap_active;
   g_victory_lap_active = g_pl_hard_active;

   if(g_victory_lap_active != prev && InpTRL_LogVerbose)
   {
      PrintFormat("[PL] Victory Lap %s (growth=%.2f%%, soft=%.2f%%, hard=%.2f%%)",
                  g_victory_lap_active ? "ON" : "OFF",
                  g_pl_growth_pct,
                  InpPL_SoftTriggerPct,
                  InpPL_TriggerPct);
   }
}


//+------------------------------------------------------------------+
//| Smart Exit: thesis-decay + optional reversal                     |
//+------------------------------------------------------------------+
void ManageSmartExits()
{
   if(!InpSE_Enable)
      return;

   // We work over all open positions, but only close this symbol/magic
   int total = PositionsTotal();
   if(total <= 0)
      return;

   // We need SignalBrain data for the lookback window
   int count = InpSE_DecayBars + 1; // last N closed bars + 1 for context
   if(count <= 0)
      return;

   double buf_conf[];
   double buf_sig[];

   ArraySetAsSeries(buf_conf, true);
   ArraySetAsSeries(buf_sig,  true);

   // Copy from SignalBrain:
   //  - buffer 1: confidence
   //  - buffer 0: direction signal
   // Use shift=1 (last CLOSED bar) as base
   if(CopyBuffer(sb_handle, 1, 1, count, buf_conf) < count)
      return;

   if(CopyBuffer(sb_handle, 0, 1, count, buf_sig) < count)
      return;
// For each Alfred position on this symbol, check decay + (optional) reversal
ulong tickets[];
if(GetMyPositionTickets(_Symbol, (long)MagicNumber, tickets) <= 0)
   return;

for(int j = ArraySize(tickets) - 1; j >= 0; --j)
{
   const ulong ticket = tickets[j];
   if(!PositionSelectByTicket(ticket))
      continue;

   // (symbol+magic already filtered by GetMyPositionTickets, so no need to re-check)

   ENUM_POSITION_TYPE ptype =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   int current_dir = 0;
   if(ptype == POSITION_TYPE_BUY)  current_dir = 1;
   if(ptype == POSITION_TYPE_SELL) current_dir = -1;

   if(current_dir == 0)
      continue;

   // 1) Check for sustained low confidence ("decay")
   bool decay = true;
   for(int k = 0; k < InpSE_DecayBars; ++k)
   {
      if(buf_conf[k] >= InpSE_ConfThreshold)
      {
         decay = false;
         break;
      }
   }
   if(!decay)
      continue;

   // 2) Optional: require reversal signal from SB
   bool hit_exit = false;

   if(InpSE_RequireReversal)
   {
      int sig_dir = 0;
      const double sig_val = buf_sig[0]; // last closed bar

      if(sig_val > 0.0)      sig_dir = 1;
      else if(sig_val < 0.0) sig_dir = -1;

      if(sig_dir != 0 && sig_dir != current_dir)
         hit_exit = true;
   }
   else
   {
      hit_exit = true;
   }

   if(hit_exit)
   {
      PrintFormat("[SMART_EXIT] Closing ticket %I64u: Conf < %d for %d bars%s",
                  ticket,
                  InpSE_ConfThreshold,
                  InpSE_DecayBars,
                  InpSE_RequireReversal ? " + reversal" : "");

      const bool ok = trade.PositionClose(ticket);
      const uint rc = trade.ResultRetcode();

      if(ok && rc == TRADE_RETCODE_DONE)
         AAI_se_trades++;
   }
}
}


#include "inc/AAI_Harmonizer.mqh"


// ============================================================================
// VAPT/ATR helpers (fast ATR available for SpikeGuard, PT VAPT, PT SLA)
// ============================================================================
bool EnsureFastATR()
{
   // Create/ensure the fast ATR handle if any feature needs it
   const bool need_fast_atr = (InpSLTA_SpikeGuard || InpPT_VolAdaptive || InpPT_SLA_UseATR);
   if(!need_fast_atr){ g_hATR_fast = INVALID_HANDLE; return(true); }
   if(g_hATR_fast != INVALID_HANDLE) return(true);

   g_hATR_fast = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpSLTA_ATRFast);
   if(g_hATR_fast == INVALID_HANDLE){
      Print(__FUNCTION__,": failed to create fast ATR handle");
      return(false);
   }
   return(true);
}

// Read current fast ATR converted into "points". Returns true on success.
// ============================================================================
// Management guards: spread & min-hold
// ============================================================================
bool Mgmt_SpreadOk()
{
   if(InpMgmt_MaxSpreadPts <= 0) return true;
   MqlTick tk; if(!SymbolInfoTick(_Symbol, tk)) return true;
   const int spread_pts = (int)((tk.ask - tk.bid) / _Point);
   return (spread_pts <= InpMgmt_MaxSpreadPts);
}

bool Mgmt_UnderMinHold(const int min_hold_sec)
{
   if(min_hold_sec <= 0) return false;
   if(!PositionSelect(_Symbol)) return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) return false;
   const datetime t0 = (datetime)PositionGetInteger(POSITION_TIME);
   return ((int)(TimeCurrent() - t0) < min_hold_sec);
}

// ============================================================================
// VAPT hysteresis: stabilize "hot" flag without needing raw bps
// We piggyback on your VR_IsHot() check and require consecutive confirmations.
// ============================================================================
bool VAPT_IsHotStableFlag()
{
   static bool last=false;
   static int  streak=0;

   const bool now_hot = (InpVAPT_Enable ? VR_IsHot() : false);

   if(now_hot == last) { streak = 0; return last; }

   ++streak;
   if(now_hot && streak >= InpVAPT_HystChecksOn)  { last=true;  streak=0; }
   if(!now_hot && streak >= InpVAPT_HystChecksOff){ last=false; streak=0; }
   return last;
}



#include "inc/AAI_Trailing.mqh"


#include "inc/AAI_Partials.mqh"

#include "inc/AAI_StatePersistence.mqh"



//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_entries = 0;
   g_wins = 0;
   g_losses = 0;
   g_blk_ze = 0;
   g_blk_bc = 0;
   g_blk_smc = 0;
   g_blk_over = 0;
   g_blk_spread = 0;
   g_blk_aspread = 0;
   g_blk_news = 0;
   g_blk_vr = 0;
   g_blk_sp = 0;
   g_blk_imc = 0;
   g_blk_risk = 0;
   g_blk_phw = 0; // T037
   g_blk_slc = 0; // T039
   g_summary_printed = false;
   g_sb.valid = false; // Initialize cache as invalid
   
      // Capture starting balance for AAI_METRICS
   AAI_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // ... inside OnInit() ...
// --- T_AZ: Initialize Auto-Zone cached variables ---
g_ttl_secs = InpAZ_TTL_Hours * 3600;
g_pref_exit_secs = InpAZ_PrefExitMins * 60;

// --- Initialize locals/state ---
symbolName = _Symbol;
point      = SymbolInfoDouble(symbolName, SYMBOL_POINT);
trade.SetExpertMagicNumber(MagicNumber);
g_overext_wait = 0;
g_last_entry_bar_buy  = 0;
g_last_entry_bar_sell = 0;
g_cool_until_buy  = 0;
g_cool_until_sell = 0;

// --- T028: Init Adaptive Spread state ---
ArrayResize(g_as_bar_medians, MathMax(1, InpAS_WindowBars));
g_as_hist_count = 0; g_as_hist_pos = 0;
ArrayResize(g_as_samples, 0);
g_as_tick_ctr = 0;
g_as_forming_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);

// --- T030: Init Risk Guard state ---
RG_ResetDay();
g_rg_consec_losses = 0; // Full reset on init

// --- T034: Init Harmonizer state ---
g_hm_tasks.Clear();

// --- T035: Init Trailing State ---
g_trl_states.Clear();

// --- T037: Init Position Health Watchdog state ---
g_phw_day_anchor = 0;
g_phw_cool_until = 0;
g_phw_repeats_today = 0;
ArrayResize(g_phw_fail_timestamps, 0);
g_phw_fail_count = 0;

// --- T038: Init Equity Curve Feedback state ---
g_ecf_ewma = 0.0;
g_stamp_ecf = 0;

// --- T039: Init SL Cluster state ---
ArrayResize(g_slc_history_buy, SLC_History);
ArrayResize(g_slc_history_sell, SLC_History);
g_slc_head_buy = 0; g_slc_head_sell = 0;
g_slc_count_buy = 0; g_slc_count_sell = 0;
g_slc_cool_until_buy = 0; g_slc_cool_until_sell = 0;
g_slc_repeats_buy = 0; g_slc_repeats_sell = 0;
g_slc_day_anchor = 0;

// --- T040: Init Execution Analytics state ---
g_ea_state.ewma_slip_pts = 0.0;
g_ea_state.ewma_latency_ms = 0.0;
ArrayInitialize(g_ea_state.rej_history, 0);
g_ea_state.rej_head = 0;
g_ea_state.rej_count = 0;
g_ea_state.last_send_ticks = 0;
g_ea_state.last_req_price = 0.0;

// --- T041: Init Market State Model ---
g_stamp_msm = 0;
g_msm_atr_head = 0;
g_msm_atr_count = 0;
ArrayInitialize(g_msm_atr_hist, 0.0);

g_aai_equity_peak = AccountInfoDouble(ACCOUNT_EQUITY);


// --- T044: Load persisted state ---
SP_Load();

PrintFormat("[EA_SB_INPUTS] base=%.1f bze=%.1f bbc=%.1f bsmc=%.1f model=%d wb=%.2f wbc=%.2f wze=%.2f wsmc=%.2f cpen=%.2f",
   SB_BaseConf, SB_Bonus_ZE, SB_Bonus_BC, SB_Bonus_SMC,
   (int)InpSB_ConfModel, InpSB_W_BASE, InpSB_W_BC, InpSB_W_ZE, InpSB_W_SMC, InpSB_ConflictPenalty
);

AAI_PushSignalBrainGlobals(); 
sb_handle = iCustom(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, AAI_Ind("AAI_Indicator_SignalBrain"),
   // Core SB Settings
   SB_SafeTest, SB_UseZE, SB_UseBC, SB_UseSMC,
   SB_WarmupBars, SB_FastMA, SB_SlowMA,
   SB_MinZoneStrength, SB_EnableDebug,
   // Additive bonuses
   SB_Bonus_ZE, SB_Bonus_BC, SB_Bonus_SMC,
   SB_BaseConf,
   // BC pass-through
   SB_BC_FastMA, SB_BC_SlowMA,
   // ZE pass-through
   SB_ZE_MinImpulseMovePips,
   // SMC pass-through
   SB_SMC_UseFVG, SB_SMC_UseOB, SB_SMC_UseBOS,
   SB_SMC_FVG_MinPips, SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback,

   // ✅ Confluence model (MUST be last if it's last in indicator inputs)
   InpSB_ConfModel,
   InpSB_W_BASE,
   InpSB_W_BC,
   InpSB_W_ZE,
   InpSB_W_SMC,
   InpSB_ConflictPenalty
);

PrintFormat("[PB_INPUTS] RegimeMinConfDelta MID_CHAOS=%d  RegimeRiskMult MID_CHAOS=%.2f",
            InpPB_RegimeMinConfDelta_MID_CHAOS,
            InpPB_RegimeRiskMult_MID_CHAOS);


if(sb_handle == INVALID_HANDLE)
{
    PrintFormat("%s handle(SB) invalid", INIT_ERROR);
    return(INIT_FAILED);
}


    // --- T011: Update handles for Over-extension ---
    g_hATR = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, OverExt_ATR_Period);
    if(g_hATR == INVALID_HANDLE){ PrintFormat("%s Failed to create ATR indicator handle", INIT_ERROR); return(INIT_FAILED); }

    g_hOverextMA = iMA(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, OverExt_MA_Period, 0, MODE_EMA, PRICE_CLOSE);
    if(g_hOverextMA == INVALID_HANDLE){ PrintFormat("%s Failed to create Overextension MA handle", INIT_ERROR); return(INIT_FAILED); }
    
    // --- SLTA SpikeGuard: fast ATR ---
if(InpSLTA_SpikeGuard)
{
    g_hATR_fast = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpSLTA_ATRFast);
    if(g_hATR_fast == INVALID_HANDLE)
    {
        PrintFormat("%s Failed to create SLTA fast ATR handle", INIT_ERROR);
        return(INIT_FAILED);
    }
}
else
{
    g_hATR_fast = INVALID_HANDLE;
}




    // --- T022: Initialize Volatility Regime handle ---
    g_hATR_VR = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpVR_ATR_Period);
    if(g_hATR_VR == INVALID_HANDLE) { PrintFormat("%s Failed to create Volatility Regime ATR handle", INIT_ERROR); return(INIT_FAILED); }
    

    // --- T027: Initialize Structure Proximity handle ---
    if(InpSP_Enable && InpSP_UseATR)
    {
      g_hATR_SP = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpSP_ATR_Period);
      if(g_hATR_SP == INVALID_HANDLE) { PrintFormat("%s Failed to create Structure Proximity ATR handle", INIT_ERROR); return(INIT_FAILED); }
    }

    // --- T035: Initialize Trailing ATR Handle ---
    if((InpTRL_Mode == TRL_ATR || InpTRL_Mode == TRL_CHANDELIER) && InpTRL_ATR_Timeframe == PERIOD_CURRENT)
    {
      g_hATR_TRL = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpTRL_ATR_Period);
      if(g_hATR_TRL == INVALID_HANDLE) { PrintFormat("%s Failed to create Trailing ATR handle", INIT_ERROR); return(INIT_FAILED); }
    }
   
    // --- T041: Initialize MSM handles ---
    g_hMSM_ATR = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_ATR_Period);
    if(g_hMSM_ATR == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM ATR handle", INIT_ERROR); return(INIT_FAILED); }

    g_hMSM_ADX = iADX(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_ADX_Period);
    if(g_hMSM_ADX == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM ADX handle", INIT_ERROR); return(INIT_FAILED); }

    g_hMSM_EMA_Fast = iMA(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    if(g_hMSM_EMA_Fast == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM Fast EMA handle", INIT_ERROR); return(INIT_FAILED); }

    g_hMSM_EMA_Slow = iMA(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    if(g_hMSM_EMA_Slow == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM Slow EMA handle", INIT_ERROR); return(INIT_FAILED); }

    if(Hybrid_RequireApproval)
    {
      FolderCreate(g_dir_base);
      FolderCreate(g_dir_intent);
      FolderCreate(g_dir_cmds);
      Print("[HYBRID] Approval mode active. Timer set to 2 seconds.");
      EventSetTimer(2);
    }
// Ensure fast ATR exists for PT VAPT / PT SLA (even when SpikeGuard is off)
if(!EnsureFastATR())
{
   return(INIT_FAILED);
}

// NEW: Parse session ranges with minute precision
    AAI_ParseSessionRanges(AutoHourRanges, g_session_windows);
    if(EnableLogging){
      string hrs="";
      int cnt=0;
      for(int h=0;h<24;++h){ if(g_auto_hour_mask[h]){ ++cnt; hrs += IntegerToString(h) + " "; } }
      PrintFormat("[HYBRID_INIT] AutoHourRanges='%s' hours_on=%d [%s]", AutoHourRanges, cnt, hrs);
    }

    // --- Initialize News Gate ---
    g_newsGate.Init(InpNews_Enable, InpNews_CsvName, InpNews_Mode, InpNews_TimesAreUTC,
                    InpNews_FilterHigh, InpNews_FilterMedium, InpNews_FilterLow, InpNews_PrefPenalty);

    // --- T006: Create HUD Object ---
    ObjectCreate(0, HUD_OBJECT_NAME, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_YDISTANCE, 20);
    ObjectSetString(0, HUD_OBJECT_NAME, OBJPROP_FONT, "Arial");
    ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_FONTSIZE, 10);
    ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_COLOR, clrSilver);
    ObjectSetString(0, HUD_OBJECT_NAME, OBJPROP_TEXT, "HUD: Initializing...");

    // At the end of OnInit()
    CheckInputLogic();
    AAI_RegimeStats_Reset();
    AAI_ScenarioStats_Reset();
    
    ArrayInitialize(AAI_posagg_id,  0);
ArrayInitialize(AAI_posagg_net, 0.0);
   AAI_PushSignalBrainGlobals();   // <--- add this

    return(INIT_SUCCEEDED);
}



void OnTesterDeinit() { PrintSummary(); }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)

{
SP_Save(true); // T044: Save state on deinit

for(int i = g_hm_tasks.Total()-1; i >= 0; --i){ delete (HM_Task*)g_hm_tasks.At(i); }
g_hm_tasks.Clear();

for(int i = g_trl_states.Total()-1; i >= 0; --i){ delete (TRL_State*)g_trl_states.At(i); }
g_trl_states.Clear();

    // --- Consolidated AAI_METRICS line (single schema for log parsing) ---
    if(AAI_trades > 0 || g_aai_trades > 0)
    {
        // AAI_ layer
        double PF = (AAI_gross_loss > 0.0
                     ? (AAI_gross_profit / AAI_gross_loss)
                     : (AAI_gross_profit > 0.0 ? DBL_MAX : 0.0));
        double WR = (AAI_trades > 0
                     ? 100.0 * (double)AAI_wins / (double)AAI_trades
                     : 0.0);
        double avg_win  = (AAI_win_count  > 0
                           ? AAI_sum_win      / (double)AAI_win_count
                           : 0.0);
        double avg_loss = (AAI_loss_count > 0
                           ? AAI_sum_loss_abs / (double)AAI_loss_count
                           : 0.0);
        double avg_dur_sec = (AAI_dur_count > 0
                              ? AAI_dur_sum_sec / (double)AAI_dur_count
                              : 0.0);

        int h = (int)(avg_dur_sec / 3600.0);
        int m = (int)((avg_dur_sec - h*3600) / 60.0);
        int s = (int)(avg_dur_sec - h*3600 - m*60);

        // g_aai_ layer
        double exp_payoff = (g_aai_trades > 0
                             ? g_aai_net / (double)g_aai_trades
                             : 0.0);
        double recovery   = (g_aai_max_dd > 0.0
                             ? g_aai_net / g_aai_max_dd
                             : 0.0);

        double end_bal = AccountInfoDouble(ACCOUNT_BALANCE);
        if(AAI_start_balance <= 0.0)
            AAI_start_balance = end_bal;

        double net_pct   = (AAI_start_balance > 0.0
                            ? (g_aai_net / AAI_start_balance) * 100.0
                            : 0.0);
        double maxdd_pct = (AAI_start_balance > 0.0
                            ? (g_aai_max_dd / AAI_start_balance) * 100.0
                            : 0.0);

PrintFormat(
    "AAI_METRICS|sym=%s|tf=%s|magic=%I64u"
    "|trades=%d|wins=%d|losses=%d"
    "|pf=%.2f|wr=%.1f"
    "|net_usd=%.2f|net_pct=%.2f"
    "|exp_payoff=%.2f|avg_win=%.2f|avg_loss=%.2f"
    "|maxdd_usd=%.2f|maxdd_pct=%.2f|recovery=%.2f"
    "|avg_dur=%02d:%02d:%02d"
    "|start_bal=%.2f|end_bal=%.2f"
    "|pt_trades=%d|trl_trades=%d|se_trades=%d"
    "|rg_trips=%d|t49_blocks=%d|t50_trips=%d"
    "|mode=%s|pf_win=%.2f|wr_win=%.1f|dd_cur_pct=%.2f|stress=%d"
    "|regime_vol=%s|regime_msm=%s",
    _Symbol,
    EnumToString(_Period),
    MagicNumber,
    AAI_trades, AAI_wins, AAI_losses,
    PF, WR,
    g_aai_net, net_pct,
    exp_payoff, avg_win, avg_loss,
    g_aai_max_dd, maxdd_pct, recovery,
    h, m, s,
    AAI_start_balance, end_bal,
    AAI_pt_trades, AAI_trl_trades, AAI_se_trades,
    AAI_rg_trips, AAI_t49_blocks, AAI_t50_trips,
    AAI_ModeName(AAI_mode_current),
    AAI_mode_pf_window, AAI_mode_wr_window,
    AAI_mode_dd_pct_cur, AAI_mode_stress,
    AAI_VolRegimeName(AAI_regime_vol),
    AAI_MSMRegimeName(AAI_regime_msm)
);
for(int i = 0; i < AAI_CB_BANDS; ++i)
  {
   if(AAI_cb_trades[i] <= 0)
      continue;

   double pf = 0.0;
   if(AAI_cb_neg[i] > 0.0)
      pf = AAI_cb_pos[i] / AAI_cb_neg[i];

   double wr = 0.0;
   if(AAI_cb_trades[i] > 0)
      wr = 100.0 * (double)AAI_cb_wins[i] / (double)AAI_cb_trades[i];

   double avg = AAI_cb_net[i] / (double)AAI_cb_trades[i];

   PrintFormat(
     "AAI_CONF_BAND|band=%s|trades=%d|wins=%d|losses=%d"
     "|pf=%.2f|wr=%.1f|net=%.2f|avg=%.2f",
     AAI_ConfBandLabel(i),
     AAI_cb_trades[i],
     AAI_cb_wins[i],
     AAI_cb_losses[i],
     pf,
     wr,
     AAI_cb_net[i],
     avg
   );
  }

// --- AAI: Regime performance stats --------------------------------
for(int bucket = 0; bucket < AAI_RG_BUCKETS; ++bucket)
  {
   if(AAI_rg_trades[bucket] <= 0)
      continue;

   int v_idx = bucket % AAI_RG_VBINS;  // 0=LOW,1=MID,2=HIGH
   int m_idx = bucket / AAI_RG_VBINS;  // 0=TREND,1=RANGE,2=CHAOS

   double pf = 0.0;
   if(AAI_rg_neg_sum[bucket] > 0.0)
      pf = AAI_rg_pos_sum[bucket] / AAI_rg_neg_sum[bucket];

   double wr = 0.0;
   if(AAI_rg_trades[bucket] > 0)
      wr = 100.0 * (double)AAI_rg_wins[bucket] / (double)AAI_rg_trades[bucket];

   double avg = AAI_rg_net[bucket] / (double)AAI_rg_trades[bucket];

   PrintFormat(
     "AAI_REGIME_STATS|vol=%s|msm=%s|trades=%d|wins=%d|losses=%d"
     "|pf=%.2f|wr=%.1f|net=%.2f|avg=%.2f",
     AAI_RegimeVolLabel(v_idx),
     AAI_RegimeMSMLabel(m_idx),
     AAI_rg_trades[bucket],
     AAI_rg_wins[bucket],
     AAI_rg_losses[bucket],
     pf,
     wr,
     AAI_rg_net[bucket],
     avg
   );
  }
  // --- AAI: Scenario performance stats ------------------------------
for(int bucket = 0; bucket < AAI_SCN_BUCKETS; ++bucket)
  {
   if(AAI_scn_trades[bucket] <= 0)
      continue;

   double pf = 0.0;
   if(AAI_scn_neg_sum[bucket] > 0.0)
      pf = AAI_scn_pos_sum[bucket] / AAI_scn_neg_sum[bucket];

   double wr = 0.0;
   if(AAI_scn_trades[bucket] > 0)
      wr = 100.0 * (double)AAI_scn_wins[bucket] / (double)AAI_scn_trades[bucket];

   double avg = AAI_scn_net[bucket] / (double)AAI_scn_trades[bucket];

   PrintFormat(
     "AAI_SCENARIO_STATS|scn=%s|trades=%d|wins=%d|losses=%d"
     "|pf=%.2f|wr=%.1f|net=%.2f|avg=%.2f",
     AAI_ScenarioName((ENUM_AAI_SCENARIO)bucket),
     AAI_scn_trades[bucket],
     AAI_scn_wins[bucket],
     AAI_scn_losses[bucket],
     pf,
     wr,
     AAI_scn_net[bucket],
     avg
   );
  }


    }


    if(Hybrid_RequireApproval)
      EventKillTimer();
    PrintFormat("%s Deinitialized. Reason=%d", EVT_INIT, reason);
    PrintSummary();

    // --- Release all handles ---
    if(sb_handle != INVALID_HANDLE) IndicatorRelease(sb_handle);
    if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
    if(g_hOverextMA != INVALID_HANDLE) IndicatorRelease(g_hOverextMA);
    if(g_hATR_VR != INVALID_HANDLE) IndicatorRelease(g_hATR_VR);
    if(g_hATR_SP != INVALID_HANDLE) IndicatorRelease(g_hATR_SP);
    if(g_hATR_TRL != INVALID_HANDLE) IndicatorRelease(g_hATR_TRL);
    // T041
    if(g_hMSM_ATR != INVALID_HANDLE) IndicatorRelease(g_hMSM_ATR);
    if(g_hMSM_ADX != INVALID_HANDLE) IndicatorRelease(g_hMSM_ADX);
    if(g_hMSM_EMA_Fast != INVALID_HANDLE) IndicatorRelease(g_hMSM_EMA_Fast);
    if(g_hMSM_EMA_Slow != INVALID_HANDLE) IndicatorRelease(g_hMSM_EMA_Slow);

// --- T006: Clean up HUD Object ---
ObjectDelete(0, HUD_OBJECT_NAME);

if(g_hATR_fast != INVALID_HANDLE) IndicatorRelease(g_hATR_fast);

// Clean up per-line HUD labels
ObjectsDeleteAll(0, "AAI_HUD_");
// Clean up ghost PT lines
ObjectsDeleteAll(0, "AAI_PT_GHOST_");

AAI_ClearSessionWindows(g_session_windows);

}

//+------------------------------------------------------------------+
//| HYBRID: Emit trade intent to file                                |
//+------------------------------------------------------------------+
bool EmitIntent(const string side, double entry, double sl, double tp, double volume,
                double rr_target, double conf_raw, double conf_eff, double ze_strength)
{
  g_pending_id = StringFormat("%s_%s_%I64d", _Symbol, EnumToString(_Period), (long)TimeCurrent());
  g_pending_ts = TimeCurrent();

  string fn_rel = g_dir_intent + "\\intent_" + g_pending_id + ".json";
  string json = StringFormat(
    "{\"id\":\"%s\",\"symbol\":\"%s\",\"timeframe\":\"%s\",\"side\":\"%s\","
    "\"entry\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"volume\":%.2f,"
    "\"rr_target\":%.2f,\"conf_raw\":%.2f,\"conf_eff\":%.2f,\"ze_strength\":%.2f,"
    "\"created_ts\":\"%s\"}",
    g_pending_id, _Symbol, EnumToString(_Period), side,
    entry, sl, tp, volume, rr_target, conf_raw, conf_eff, ze_strength,
    TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES)
  );
  if(WriteText(fn_rel, json))
  {
    string root = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\";
    PrintFormat("[HYBRID] intent written at: %s%s", root, fn_rel);
    string cmd_rel = g_dir_cmds + "\\cmd_" + g_pending_id + ".json";
    PrintFormat("[HYBRID] waiting for cmd at: %s%s", root, cmd_rel);
    return true;
  }
  return false;
}

//+------------------------------------------------------------------+
//| HYBRID: Execute order after approval                             |
//+------------------------------------------------------------------+
void PlaceOrderFromApproval()
{
    if(!MSO_MaySend(_Symbol))
    {
       if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
       {
          PrintFormat("[MSO] defer Hybrid sym=%s reason=guard", _Symbol);
          g_stamp_mso = g_sb.closed_bar_time;
       }
       return;
    }

    PrintFormat("[HYBRID] Executing approved trade. Side: %s, Vol: %.2f, Entry: Market, SL: %.5f, TP: %.5f",
                g_last_side, g_last_vol, g_last_sl, g_last_tp);
    trade.SetDeviationInPoints(MaxSlippagePoints);
    bool order_sent = false;

    if(g_last_side == "BUY")
    {
        order_sent = trade.Buy(g_last_vol, symbolName, 0, g_last_sl, g_last_tp, g_last_comment);
    }
    else if(g_last_side == "SELL")
    {
        order_sent = trade.Sell(g_last_vol, symbolName, 0, g_last_sl, g_last_tp, g_last_comment);
    }

if(order_sent && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_DONE_PARTIAL))
{
    g_entries++;

    double rvol   = trade.ResultVolume();
    double rprice = trade.ResultPrice();

    PrintFormat("%s HYBRID Signal:%s ? Executed %.2f lots @%.5f | SL:%.5f TP:%.5f",
                EVT_ENTRY, g_last_side,
                (rvol > 0 ? rvol : g_last_vol),
                (rprice > 0 ? rprice : 0.0),
                g_last_sl, g_last_tp);
    // >>> EXEC line to Journal (tester shows it)
    //double exec_lots = (rvol > 0.0 ? rvol : g_last_vol);
    //AAI_LogExec(g_last_side == "BUY" ? +1 : -1, exec_lots);  // optional 3rd arg: "Flow+"

    // Keep these after the log
    if(g_last_side == "BUY") g_last_entry_bar_buy = g_lastBarTime;
    else                     g_last_entry_bar_sell = g_lastBarTime;
}

    else
    {
        if(g_lastBarTime != g_last_suppress_log_time)
        {
            PrintFormat("%s reason=trade_send_failed details=retcode:%d", EVT_SUPPRESS, trade.ResultRetcode());
            g_last_suppress_log_time = g_lastBarTime;
        }
    }
}



//+------------------------------------------------------------------+
//| Timer function for HYBRID polling                                |
//+------------------------------------------------------------------+
void OnTimer()
{
  if(!Hybrid_RequireApproval || g_pending_id=="") return;

  if((TimeCurrent() - g_pending_ts) > Hybrid_TimeoutSec){
    Print("[HYBRID] intent timeout, discarding: ", g_pending_id);
    g_pending_id = "";
    return;
  }

  string cmd_rel = g_dir_cmds + "\\cmd_" + g_pending_id + ".json";
  static string last_id_printed = "";
  if(last_id_printed != g_pending_id){
    string root = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\";
    PrintFormat("[HYBRID] polling cmd: %s%s", root, cmd_rel);
    last_id_printed = g_pending_id;
  }

  if(!FileIsExist(cmd_rel)) return;

  string s = ReadAll(cmd_rel);
  if(s==""){ FileDelete(cmd_rel); return; }

  string id     = JsonGetStr(s, "id");
  string action = JsonGetStr(s, "action");
  StringToLower(action);
  if(id != g_pending_id) return;

  if(action=="approve"){
    Print("[HYBRID] APPROVED: ", id);
    PlaceOrderFromApproval();
  } else {
    Print("[HYBRID] REJECTED: ", id);
  }

  FileDelete(cmd_rel);
  g_pending_id = "";
}


#include "inc/AAI_SLCluster.mqh"



//+------------------------------------------------------------------+
//| Trade Transaction Event Handler                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
// --- PT: wipe GV when a position is fully closed ---
if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
{
   if(HistoryDealSelect(trans.deal))
   {
      const long entry = (long)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      {
const ulong pos_ticket = (ulong)trans.position; // transaction's position ticket (matches POSITION_TICKET)

// Only clear if the position no longer exists (not a partial close)
if(pos_ticket != 0 && !PositionSelectByTicket(pos_ticket))
   PT_ClearGV(pos_ticket);
      }
   }
}

    // --- T039: SL Cluster Event Capture ---
    if(SLC_Enable && trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
    {
        if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber &&
           HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT &&
           (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON) == DEAL_REASON_SL)
        {
            long closing_deal_type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            int original_direction = (closing_deal_type == DEAL_TYPE_SELL) ? 1 : -1; // A sell deal closes a buy position
            double sl_price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
            datetime sl_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
            SLC_ProcessEvent(original_direction, sl_price, sl_time);
        }
    }
   
      // --- T030: Update Risk Guard state on closed deals ---
      if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber &&
         HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
        datetime deal_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
        if(deal_time >= g_rg_day_anchor_time)
        {
        double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                        HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                        HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

        g_rg_day_realized_pl += profit;
        if(profit < 0) g_rg_consec_losses++; else g_rg_consec_losses = 0;
        

        if((ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON) == DEAL_REASON_SL)
        {
          g_rg_day_sl_hits++;
        }
        }
        // T035: Delete Trailing State on full close (per-position)
        ulong pos_ticket = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
if(pos_ticket == 0) pos_ticket = (ulong)trans.position; // fallback if broker/build doesn't populate DEAL_POSITION_ID

        if(pos_ticket != 0 && !PositionSelectByTicket(pos_ticket))
        {
           const string _sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
           for(int i = g_trl_states.Total() - 1; i >= 0; i--)
           {
              TRL_State *s = (TRL_State*)g_trl_states.At(i);
              if(s && s.symbol == _sym && s.ticket == pos_ticket)
              {
                 g_trl_states.Delete(i);
                 delete s;
              }
           }
        }
        else if(pos_ticket == 0)
        {
           // Legacy fallback: ticket missing, delete by symbol
           const string _sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
           for(int i = g_trl_states.Total() - 1; i >= 0; i--)
           {
              TRL_State *s = (TRL_State*)g_trl_states.At(i);
              if(s && s.symbol == _sym)
              {
                 g_trl_states.Delete(i);
                 delete s;
              }
           }
        }
}

      // EXEC on entry (print once)
if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
  {
   if(AAI_last_in_deal != trans.deal)
     {
      AAI_last_in_deal = trans.deal;

      // Position id for this deal (we'll reuse this in several places)
      const ulong pos_id = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

      // Remember last IN time (for duration calc)
      AAI_last_in_pos_id = (long)pos_id;
      AAI_last_in_time   = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);

      // --- Confidence band mapping for this entry ---
      double conf = -1.0;
      if(g_sb.valid)
         conf = g_sb.conf;

      // Use POSITION_ID as key (same for entry & exit)
      AAI_ConfBands_OnEntry(pos_id, conf);

      // --- Regime stats mapping (regime at entry time) ---
      AAI_RegimeStats_OnEntry(pos_id, AAI_regime_vol, AAI_regime_msm);
            // --- Scenario stats mapping (scenario at entry time) ---
      AAI_Context ctx;
      AAI_FillContext(ctx);
      ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);
      AAI_ScenarioStats_OnEntry(pos_id, (int)scn);

      // --- Log trade open snapshot (mode + regime + conf, etc.) ---
      AAI_LogTradeOpen(trans.deal);
            // NEW: log SignalBrain state for this ticket
      AAI_LogSBEntrySnapshot(trans.deal);

     }
  }


      // Metrics on exits (DEAL_ENTRY_OUT): accumulate closed-trade stats
      // Metrics on exits (DEAL_ENTRY_OUT): accumulate closed-trade stats
      else if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
        if(AAI_last_out_deal != trans.deal)
        {
         AAI_last_out_deal = trans.deal;

         double net = AAI_NetDealPL(trans.deal);

         // --- AAI_METRICS: per-deal stats (unchanged) --------------------
         AAI_trades++;
         if(net > 0.0)
           {
            AAI_wins++;
            AAI_win_count++;
            AAI_gross_profit += net;
            AAI_sum_win      += net;
           }
         else if(net < 0.0)
           {
            AAI_losses++;
            AAI_loss_count++;
            AAI_gross_loss   += -net;
            AAI_sum_loss_abs += -net;
           }

         // Closed-trade curve & drawdown
         AAI_UpdateCurve(net);

         // --- T038: Update ECF EWMA ---
         const double alpha = 2.0 / (ECF_EMA_Trades + 1.0);
         g_ecf_ewma = (1.0 - alpha) * g_ecf_ewma + alpha * net;

         // Duration estimate (seconds) using last known IN time
         datetime out_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
         if(AAI_last_in_time > 0 && out_time >= AAI_last_in_time)
           {
            AAI_dur_sum_sec += (double)(out_time - AAI_last_in_time);
            AAI_dur_count++;
           }

         // --- g_aai_* metrics (per-deal) ---------------------------------
         double deal_profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                            + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                            + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

         g_aai_net += deal_profit;
         g_aai_trades++;
         if(deal_profit > 0)
           {
            g_aai_wins++;
            g_aai_gross_pos += deal_profit;
           }
         else if(deal_profit < 0)
           {
            g_aai_losses++;
            g_aai_gross_neg += deal_profit;
           }

         // update equity-based max drawdown (approx, end-of-deal granularity)
         double eq = AccountInfoDouble(ACCOUNT_EQUITY);
         if(eq > g_aai_equity_peak) g_aai_equity_peak = eq;
         double dd = g_aai_equity_peak - eq;
         if(dd > g_aai_max_dd) g_aai_max_dd = dd;

         // Position id for analytics / duration
         long pos_id = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

         // --- NEW: aggregate per-position net for analytics --------------
         double full_net   = 0.0;
         bool   final_close = false;
         AAI_PosAgg_Update((ulong)pos_id, net, full_net, final_close);

         // Optional: duration estimate using last IN time if position ids align
         if(pos_id != AAI_last_in_pos_id)
           {
            // best-effort backscan for nearest IN of same position
            int      total      = HistoryDealsTotal();
            datetime nearest_in = 0;
            for(int i = total - 1; i >= 0 && i >= total - 200; --i) // scan recent deals window
              {
               ulong tk = (ulong)HistoryDealGetTicket(i);
               if(HistoryDealGetInteger(tk, DEAL_POSITION_ID) == pos_id &&
                  HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN)
                 {
                  nearest_in = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
                  break;
                 }
              }
            if(nearest_in > 0) AAI_last_in_time = nearest_in;
           }

         // --- AAI Mode Engine: update mode on closed deal (per-deal net) --
         AAI_Mode_OnClosedDeal(net);
         AAI_Streak_OnClosedDeal(net);

         // --- Analytics: CONF/REGIME/SCENARIO use full position PnL ------
         // Only when the position is fully closed (not on partials)
         if(final_close)
           {
            // Confidence band stats (use same pos_id as on entry)
            AAI_ConfBands_OnExit(pos_id, full_net);
            // Regime stats (using same pos_id key as on entry)
            AAI_RegimeStats_OnExit((ulong)pos_id, full_net);
            // Scenario stats (using same pos_id key as on entry)
            AAI_ScenarioStats_OnExit((ulong)pos_id, full_net);
           }
        }
      }

if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
    {
// replace the next block with this:
if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber &&
   HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
{
    ulong pos_id = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

    // only once per position close
    if(!IsPositionLogged(pos_id))
    {
        // (A) get P&L of the *closing deal* (ok if you don't use partials)
        double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                      + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                      + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

        // If you later enable partials, prefer computing full position P&L:
        // profit = ClosedPositionProfit(pos_id);   // optional helper below

        if(profit > 0.0)
        {
            g_wins++;
            g_rg_consec_losses = 0;
            if(InpRG_ResetOnWin)
            {
                g_rg_block_active = false;
                g_rg_block_until  = 0;
                Print("[RG_RESET] reason=win_after_trip");
            }
        }
        else if(profit < 0.0)
        {
            g_losses++;
            g_rg_consec_losses++;

            // hard trip when streak >= MaxConsecLosses
            if(InpRG_Mode == RG_REQUIRED && g_rg_consec_losses >= InpRG_MaxConsecLosses)
            {
                g_rg_block_active = true;
                if(InpRG_BlockHoursAfterTrip > 0)
                    g_rg_block_until = TimeCurrent() + InpRG_BlockHoursAfterTrip * 3600;
                PrintFormat("[RG_TRIP] streak=%d block_until=%s",
                            g_rg_consec_losses,
                            g_rg_block_until>0 ? TimeToString(g_rg_block_until) : "EOD/next reset");
                                // optional: start counting the next streak from scratch
    g_rg_consec_losses = 0;
            }
        }

        // your existing one-time journal + dedupe
        JournalClosedPosition(pos_id);
        AddToLoggedList(pos_id);
    }
}
}
    if (CooldownAfterSLBars > 0 && trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
    {
        if ((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber &&
            HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT &&
            HistoryDealGetInteger(trans.deal, DEAL_REASON) == DEAL_REASON_SL)
        {
            long closing_deal_type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            datetime bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0); // TICKET #3 Fix: Use SignalTimeframe
            datetime cooldown_end_time = bar_time + CooldownAfterSLBars * PeriodSeconds((ENUM_TIMEFRAMES)SignalTimeframe); // TICKET #3 Fix: Use SignalTimeframe
            if (closing_deal_type == DEAL_TYPE_SELL)
            {
                g_cool_until_buy = cooldown_end_time;
                PrintFormat("%s SL close side=BUY pause=%d bars until %s", EVT_COOLDOWN, CooldownAfterSLBars, TimeToString(g_cool_until_buy));
            }
            else if (closing_deal_type == DEAL_TYPE_BUY)
            {
                g_cool_until_sell = cooldown_end_time;
                PrintFormat("%s SL close side=SELL pause=%d bars until %s", EVT_COOLDOWN, CooldownAfterSLBars, TimeToString(g_cool_until_sell));
            }
        }
    }
}
void AAI_ConfBands_OnExit(const ulong id, const double net)
{
   int idx = -1;

   for(int i = 0; i < AAI_CB_MAX_OPEN; ++i)
   {
      if(AAI_cb_deal[i] == id)
      {
         idx = AAI_cb_band[i];
         AAI_cb_deal[i] = 0;
         AAI_cb_band[i] = -1;
         break;
      }
   }

   if(idx < 0 || idx >= AAI_CB_BANDS)
      return;

   AAI_cb_trades[idx]++;
   AAI_cb_net[idx] += net;

   if(net > 0.0)
   {
      AAI_cb_wins[idx]++;
      AAI_cb_pos[idx] += net;
   }
   else if(net < 0.0)
   {
      AAI_cb_losses[idx]++;
      AAI_cb_neg[idx] += -net;
   }
}
int AAI_VolRegimeIndex(const int vol_reg)
  {
   switch(vol_reg)
     {
      case AAI_VOL_LOW:  return 0;
      case AAI_VOL_MID:  return 1;
      case AAI_VOL_HIGH: return 2;
      default:           return -1;
     }
  }

int AAI_MSMRegimeIndex(const int msm_reg)
  {
   switch(msm_reg)
     {
      case AAI_MSM_TREND_GOOD:  return 0;
      case AAI_MSM_RANGE_GOOD:  return 1;
      case AAI_MSM_CHAOS_BAD:   return 2;
      default:                  return -1;
     }
  }

int AAI_RegimeBucketIndex(const int vol_reg, const int msm_reg)
  {
   int v = AAI_VolRegimeIndex(vol_reg);
   int m = AAI_MSMRegimeIndex(msm_reg);
   if(v < 0 || m < 0) return -1;
   return m * AAI_RG_VBINS + v;  // 0..8
  }

string AAI_RegimeVolLabel(const int v_idx)
  {
   switch(v_idx)
     {
      case 0: return "LOW";
      case 1: return "MID";
      case 2: return "HIGH";
      default: return "UNK";
     }
  }

string AAI_RegimeMSMLabel(const int m_idx)
  {
   switch(m_idx)
     {
      case 0: return "TREND";
      case 1: return "RANGE";
      case 2: return "CHAOS";
      default: return "UNK";
     }
  }
// --- Scenario stats helpers ---------------------------------------
int AAI_ScenarioBucketIndex(const int scenario)
  {
   // scenario is ENUM_AAI_SCENARIO cast to int
   if(scenario < 0 || scenario >= AAI_SCN_BUCKETS)
      return -1;
   return scenario;
  }

void AAI_ScenarioStats_Reset()
  {
   ArrayInitialize(AAI_scn_pos_id,  0);
   ArrayInitialize(AAI_scn_bucket,  0);

   ArrayInitialize(AAI_scn_trades,   0);
   ArrayInitialize(AAI_scn_wins,     0);
   ArrayInitialize(AAI_scn_losses,   0);
   ArrayInitialize(AAI_scn_net,      0.0);
   ArrayInitialize(AAI_scn_pos_sum,  0.0);
   ArrayInitialize(AAI_scn_neg_sum,  0.0);
  }

void AAI_ScenarioStats_OnEntry(const ulong pos_id, const int scenario)
  {
   int bucket = AAI_ScenarioBucketIndex(scenario);
   if(bucket < 0) return;

   for(int i = 0; i < AAI_SCN_MAX_OPEN; ++i)
     {
      if(AAI_scn_pos_id[i] == 0 || AAI_scn_pos_id[i] == pos_id)
        {
         AAI_scn_pos_id[i] = pos_id;
         AAI_scn_bucket[i] = bucket;
         return;
        }
     }
   // if full, silently give up; open-position count is small in practice
  }

void AAI_ScenarioStats_OnExit(const ulong pos_id, const double net)
  {
   int bucket = -1;

   for(int i = 0; i < AAI_SCN_MAX_OPEN; ++i)
     {
      if(AAI_scn_pos_id[i] == pos_id)
        {
         bucket = AAI_scn_bucket[i];
         AAI_scn_pos_id[i] = 0;
         AAI_scn_bucket[i] = 0;
         break;
        }
     }

   if(bucket < 0 || bucket >= AAI_SCN_BUCKETS)
      return;

   AAI_scn_trades[bucket]++;
   AAI_scn_net[bucket] += net;

   if(net > 0.0)
     {
      AAI_scn_wins[bucket]++;
      AAI_scn_pos_sum[bucket] += net;
     }
   else if(net < 0.0)
     {
      AAI_scn_losses[bucket]++;
      AAI_scn_neg_sum[bucket] += -net; // store as positive for PF denom
     }
  }

void AAI_RegimeStats_Reset()
  {
   ArrayInitialize(AAI_rg_pos_id,  0);
   ArrayInitialize(AAI_rg_vol_reg, 0);
   ArrayInitialize(AAI_rg_msm_reg, 0);

   ArrayInitialize(AAI_rg_trades,   0);
   ArrayInitialize(AAI_rg_wins,     0);
   ArrayInitialize(AAI_rg_losses,   0);
   ArrayInitialize(AAI_rg_net,      0.0);
   ArrayInitialize(AAI_rg_pos_sum,  0.0);
   ArrayInitialize(AAI_rg_neg_sum,  0.0);
  }
void AAI_RegimeStats_OnExit(const ulong pos_id, const double net)
  {
   // Look up stored regime for this pos_id
   int bucket = -1;

   for(int i = 0; i < AAI_RG_MAX_OPEN; ++i)
     {
      if(AAI_rg_pos_id[i] == pos_id)
        {
         int vol_reg = AAI_rg_vol_reg[i];
         int msm_reg = AAI_rg_msm_reg[i];
         bucket = AAI_RegimeBucketIndex(vol_reg, msm_reg);

         AAI_rg_pos_id[i]  = 0;
         AAI_rg_vol_reg[i] = 0;
         AAI_rg_msm_reg[i] = 0;
         break;
        }
     }

   if(bucket < 0 || bucket >= AAI_RG_BUCKETS)
      return;

   AAI_rg_trades[bucket]++;
   AAI_rg_net[bucket] += net;

   if(net > 0.0)
     {
      AAI_rg_wins[bucket]++;
      AAI_rg_pos_sum[bucket] += net;
     }
   else if(net < 0.0)
     {
      AAI_rg_losses[bucket]++;
      AAI_rg_neg_sum[bucket] += -net; // store as positive for PF denominator
     }
  }
  
  
  
  
  
#include "inc/AAI_AdaptiveSpread.mqh"




//+------------------------------------------------------------------+
//| OnTick: Event-driven logic                                       |
//+------------------------------------------------------------------+
void EvaluateClosedBar();

void OnTick()
{
   // 1. Always Run (Management & Failsafes)
   FailsafeExitChecks();      // AZ / TTL / zombie killer
   CheckFridayClose();        // Friday flat helper
   UpdateVictoryLapState();   // NEW: account-level profit-lock state
   AS_OnTickSample();         // T028 sampler
   HM_OnTick();               // T034 harmonizer worker
   PT_OnTick();               // T036 partial profit worker
   TRL_OnTick();              // T035 trailing worker
   g_tickCount++;
   SAO_OnTick();              // Strength Add-On Module     

   // 2. Data Ingestion: Update cache
   // We ONLY proceed if we successfully read data for a NEW closed bar.
   bool isNewBar = UpdateSBCacheIfNewBar();

   if(!isNewBar)
      return;                 // STOP HERE if not a new bar

// 3. New-bar logic (runs once per bar)
g_barIndex++;

RG_MaybeRollover();        // Daily risk guard rollover
UpdateMSM_State();         // Market State Machine update

const int prev_vol = AAI_regime_vol;
const int prev_msm = AAI_regime_msm;

AAI_UpdateVolRegime();     // Classify volatility regime
AAI_UpdateMSMRegime();     // Classify MSM regime

RS_UpdateTransition(prev_vol, prev_msm);
// Print EVERY regime change (not just transition toggles)
if(prev_vol != AAI_regime_vol || prev_msm != AAI_regime_msm)
{
   const datetime bt = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);

   PrintFormat("[REGIME_CHANGE] %s %s | vol %s->%s | msm %s->%s | transition=%s until_bar=%d now_bar=%d",
               _Symbol,
               TimeToString(bt, TIME_DATE|TIME_MINUTES),
               EnumToString((ENUM_AAI_VOL_REGIME)prev_vol),
               EnumToString((ENUM_AAI_VOL_REGIME)AAI_regime_vol),
               EnumToString((ENUM_AAI_MSM_REGIME)prev_msm),
               EnumToString((ENUM_AAI_MSM_REGIME)AAI_regime_msm),
               (g_rs_transition_active ? "ON" : "OFF"),
               g_rs_transition_until_bar,
               g_barIndex);
}

// Print transition toggle only (no spam)
if(g_rs_transition_active != g_rs_transition_prev)
{
   g_rs_transition_prev = g_rs_transition_active;

   const datetime bt = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
   PrintFormat("[REGIME_SHIFT] %s %s | transition=%s (%d bars) | vol=%s msm=%s",
               _Symbol,
               TimeToString(bt, TIME_DATE|TIME_MINUTES),
               (g_rs_transition_active ? "ON" : "OFF"),
               InpRS_TransitionCooldownBars,
               EnumToString((ENUM_AAI_VOL_REGIME)AAI_regime_vol),
               EnumToString((ENUM_AAI_MSM_REGIME)AAI_regime_msm));
}

AAI_UpdateSignalWeights(); // Signal Weights



   EvaluateClosedBar();       // Gates -> Entry logic
   ManageSmartExits();        // Thesis-decay exits


   UpdateHUD();               // Draw HUD
   Telemetry_OnBar();         // Per-bar telemetry/journal
}



#include "inc/AAI_StructureProximity.mqh"



//+------------------------------------------------------------------+
//| >>> T028 Adaptive Spread Helpers <<<                             |
//+------------------------------------------------------------------+
// Median of last 'count' elements from ring buffer
double AS_MedianOfHistory()
{
  const int N = g_as_hist_count;
  if(N <= 0) return 0.0;

  // Unroll ring into a linear temp
  double tmp[]; ArrayResize(tmp, N);
  int idx = (g_as_hist_pos - N + ArraySize(g_as_bar_medians)) % ArraySize(g_as_bar_medians);
  for(int i=0;i<N;i++){
    tmp[i] = g_as_bar_medians[(idx + i) % ArraySize(g_as_bar_medians)];
  }
  ArraySort(tmp);
  return (N%2!=0 ? tmp[N/2] : 0.5*(tmp[N/2-1] + tmp[N/2]));
}




#include "inc/AAI_IMC.mqh"


#include "inc/AAI_PHW.mqh"



#include "inc/AAI_Gates.mqh"

#include "inc/AAI_EvaluateEntry.mqh"
#include "inc/AAI_PositionMgmt.mqh"
#include "inc/AAI_HUD_Regime.mqh"
