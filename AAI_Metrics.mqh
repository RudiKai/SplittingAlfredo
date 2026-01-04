#ifndef AAI_METRICS_MQH
#define AAI_METRICS_MQH

// ====================== AAI METRICS (PF/WR/Avg/MaxDD/AvgDur) ======================
#ifndef AAI_METRICS_DEFINED
#define AAI_METRICS_DEFINED
#ifndef AAI_RTP_DEFINED
#define AAI_RTP_DEFINED
// --- T046: Runtime Profiles -----------------------------------------------
const int RTP_Profile = 0;          // 0=Prod, 1=Diagnostics, 2=Research
#define RTP_IS_DIAG      (RTP_Profile==1)
#define RTP_IS_RESEARCH  (RTP_Profile==2)
// --------------------------------------------------------------------------
#endif

int      AAI_trades = 0;
int      AAI_wins = 0, AAI_losses = 0;
double   AAI_gross_profit = 0.0;
// sum of positive net P&L
double   AAI_gross_loss   = 0.0;
// sum of negative net P&L (stored as positive abs)
double   AAI_sum_win      = 0.0;
// for avg win
double   AAI_sum_loss_abs = 0.0;         // for avg loss (abs)
int      AAI_win_count = 0, AAI_loss_count = 0;
double   AAI_curve = 0.0;                // equity curve (closed-trade increments)
double   AAI_peak  = 0.0;                // peak of curve
double   AAI_max_dd = 0.0;                 // max drawdown (abs) on closed-trade curve

// --- Module-level usage metrics -----------------------------------
int      AAI_pt_trades  = 0;             // trades where PT fired at least once
int      AAI_trl_trades = 0;             // trades where trailing/BE moved SL
int      AAI_se_trades  = 0;             // trades closed by SmartExit
int      AAI_rg_trips   = 0;             // times RG entered hard-block mode (hard block)
int      AAI_t49_blocks = 0;             // entries blocked by bar-lock (T49)
int      AAI_t50_trips  = 0;             // T50 suspension events

// optional helper storage for trailing to avoid double counting
ulong    AAI_trl_seen_tickets[];


double   AAI_start_balance = 0.0;         // captured in OnInit, used for net_pct / dd_pct

// --- AAI Mode Engine (DEF / NORM / AGG) ---------------------------------
enum ENUM_AAI_MODE
  {
   AAI_MODE_DEFENSIVE = 0,
   AAI_MODE_NORMAL    = 1,
   AAI_MODE_AGGRESSIVE= 2
  };
// --- AAI Scenario layer (mode + regimes + streak/RG state) ------
enum ENUM_AAI_SCENARIO
  {
   AAI_SCN_BASELINE    = 0, // default / normal
   AAI_SCN_DEFENSIVE   = 1, // DEF mode, not hard-blocked
   AAI_SCN_OPPORTUNITY = 2, // AGG mode (good periods)
   AAI_SCN_RISK_OFF    = 3  // streak cooldown / RG trips
  };

string AAI_ScenarioName(const ENUM_AAI_SCENARIO s)
  {
   switch(s)
     {
      case AAI_SCN_DEFENSIVE:   return "DEFENSIVE";
      case AAI_SCN_OPPORTUNITY: return "OPPORTUNITY";
      case AAI_SCN_RISK_OFF:    return "RISK_OFF";
      default:                  return "BASELINE";
     }
  }

// Static window for rolling PF/WR calculations.
// Adjust this constant if you want a longer memory, but keep it modest.
#define AAI_MODE_WINDOW 50

// Rolling net P&L for last deals
double AAI_mode_net_window[AAI_MODE_WINDOW];
int    AAI_mode_window_size = 0;
int    AAI_mode_window_pos  = 0;

// Last computed window stats (for logs / metrics line)
double AAI_mode_pf_window  = 0.0;
double AAI_mode_wr_window  = 0.0;
double AAI_mode_dd_pct_cur = 0.0;
int    AAI_mode_stress     = 0;

// Current mode (starts NORMAL)
int    AAI_mode_current    = AAI_MODE_NORMAL;

// Thresholds (tweakable in code; all in "per-30–50 trade window" mindset)
const int    AAI_MODE_MIN_TRADES      = 30;
const int    AAI_MODE_MIN_TRADES_AGG  = 50;

const double AAI_MODE_DEF_PF_ENTER    = 0.80;
const double AAI_MODE_DEF_PF_EXIT     = 1.00;
const double AAI_MODE_DEF_DD_ENTER    = 4.00;
const double AAI_MODE_DEF_DD_EXIT     = 3.00;
const int    AAI_MODE_DEF_STRESS_ENTER= 3;
const int    AAI_MODE_DEF_STRESS_EXIT = 1;

const double AAI_MODE_AGG_PF_ENTER    = 1.70;
const double AAI_MODE_AGG_PF_EXIT     = 1.40;
const double AAI_MODE_AGG_DD_ENTER    = 1.50;
const double AAI_MODE_AGG_DD_EXIT     = 2.50;
const int    AAI_MODE_AGG_STRESS_ENTER= 0;
const int    AAI_MODE_AGG_STRESS_EXIT = 1;

// Simple helper: human-readable name
string AAI_ModeName(const int m)
  {
   switch(m)
     {
      case AAI_MODE_DEFENSIVE: return "DEF";
      case AAI_MODE_AGGRESSIVE: return "AGG";
      default: return "NORM";
     }
  }

// Compute a simple stress score (can extend later with send_errors, PHW, etc.)
int AAI_Mode_StressScore()
  {
   // For now, treat RG trips + T50 suspensions as stress sources.
   return (AAI_rg_trips + AAI_t50_trips);
  }
  
 // --- AAI Streak Engine: track loss streak & local equity drop ----
void AAI_Streak_OnClosedDeal(const double net)
  {
   if(!InpStreak_Enable)
      return;

   // Current equity estimate (start + cumulative net)
   double eq = AAI_start_balance + g_aai_net;

   // Initialise local peak
   if(AAI_streak_eq_peak <= 0.0)
     {
      AAI_streak_eq_peak = eq;
      AAI_streak_eq_cur  = eq;
      AAI_streak_dd_pct  = 0.0;
     }

   AAI_streak_eq_cur = eq;

   if(eq > AAI_streak_eq_peak)
     {
      // New local peak -> reset DD
      AAI_streak_eq_peak = eq;
      AAI_streak_dd_pct  = 0.0;
     }
   else
     {
      double drop = AAI_streak_eq_peak - eq;
      if(AAI_streak_eq_peak > 0.0)
         AAI_streak_dd_pct = 100.0 * drop / AAI_streak_eq_peak;
     }

   // Update loss streak (treat <=0 as loss/breakeven)
   if(net <= 0.0)
      AAI_streak_loss_count++;
   else
      AAI_streak_loss_count = 0;

   bool trigger_loss = (InpStreak_MaxLossTrades > 0
                        && AAI_streak_loss_count >= InpStreak_MaxLossTrades);
   bool trigger_dd   = (InpStreak_MaxDropPct > 0.0
                        && AAI_streak_dd_pct >= InpStreak_MaxDropPct);

   // No trigger -> nothing to do
   if(!(trigger_loss || trigger_dd))
      return;

   datetime now        = TimeCurrent();
   bool     in_cd_now  = (AAI_streak_cooldown_until > now);

   // --- Soft landing path ------------------------------------------
   // First time we hit the threshold while NOT in cooldown and NOT
   // already armed and NOT already DEFENSIVE -> switch to DEF only.
   if(!in_cd_now &&
      !AAI_streak_softlanding_armed &&
      AAI_mode_current != AAI_MODE_DEFENSIVE)
     {
      int prev_mode = AAI_mode_current;
      AAI_mode_current = AAI_MODE_DEFENSIVE;
      AAI_streak_softlanding_armed = true;

      PrintFormat("AAI_STREAK|softland=1|from_mode=%s|to_mode=%s|loss_streak=%d|dd_pct=%.2f",
                  AAI_ModeName(prev_mode), AAI_ModeName(AAI_mode_current),
                  AAI_streak_loss_count, AAI_streak_dd_pct);

      // Reset streak counters and treat current equity as new local peak
      AAI_streak_loss_count = 0;
      AAI_streak_eq_peak    = eq;
      AAI_streak_dd_pct     = 0.0;
      AAI_streak_cooldown_until = 0;

      // No hard block yet: DEF mode is the soft landing
      return;
     }

   // --- Escalation path: full cooldown (hard block) ----------------
   AAI_streak_cooldown_until = now + InpStreak_CooldownHours * 3600;

   PrintFormat("AAI_STREAK|trigger=1|loss_streak=%d|dd_pct=%.2f|cooldown_until=%s",
               AAI_streak_loss_count, AAI_streak_dd_pct,
               TimeToString(AAI_streak_cooldown_until, TIME_DATE|TIME_MINUTES));

   // Reset loss streak, treat this as new local peak
   AAI_streak_loss_count        = 0;
   AAI_streak_eq_peak           = eq;
   AAI_streak_softlanding_armed = false;
  }


// Called on each closed deal (net = closed-trade P&L including costs)
void AAI_Mode_OnClosedDeal(const double net)
  {
   // 1) Update rolling window
   AAI_mode_net_window[AAI_mode_window_pos] = net;
   if(AAI_mode_window_size < AAI_MODE_WINDOW)
      AAI_mode_window_size++;
   AAI_mode_window_pos++;
   if(AAI_mode_window_pos >= AAI_MODE_WINDOW)
      AAI_mode_window_pos = 0;

   // 2) Compute PF / WR over window
   double gp = 0.0, gl = 0.0;
   int    w = 0, l = 0;
   for(int i = 0; i < AAI_mode_window_size; ++i)
     {
      double v = AAI_mode_net_window[i];
      if(v > 0.0)
        {
         gp += v;
         w++;
        }
      else if(v < 0.0)
        {
         gl += -v;
         l++;
        }
     }

   double pf = 0.0;
   if(gl > 0.0)
      pf = gp / gl;
   else if(gp > 0.0)
      pf = DBL_MAX;

   double wr = 0.0;
   int    tot = w + l;
   if(tot > 0)
      wr = 100.0 * (double)w / (double)tot;

   // 3) Compute current equity drawdown vs start balance (not max)
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd_abs = 0.0;
   if(g_aai_equity_peak > 0.0)
      dd_abs = g_aai_equity_peak - eq;
   if(dd_abs < 0.0) dd_abs = 0.0;

   double dd_pct = 0.0;
   if(AAI_start_balance > 0.0)
      dd_pct = (dd_abs / AAI_start_balance) * 100.0;

   // 4) Stress score
   int stress = AAI_Mode_StressScore();

   // Persist for later logs/metrics
   AAI_mode_pf_window  = pf;
   AAI_mode_wr_window  = wr;
   AAI_mode_dd_pct_cur = dd_pct;
   AAI_mode_stress     = stress;

   // 5) Decide mode (with hysteresis)
   int new_mode = AAI_mode_current;

   // Not enough data? stay NORMAL, but keep stats updated
   if(AAI_trades < AAI_MODE_MIN_TRADES)
     {
      AAI_mode_current = AAI_MODE_NORMAL;
      return;
     }

   switch(AAI_mode_current)
     {
      case AAI_MODE_NORMAL:
         {
          // Check for Defensive
          if(pf <= AAI_MODE_DEF_PF_ENTER ||
             dd_pct >= AAI_MODE_DEF_DD_ENTER ||
             stress >= AAI_MODE_DEF_STRESS_ENTER)
             new_mode = AAI_MODE_DEFENSIVE;
          // Or Aggressive
          else if(AAI_trades >= AAI_MODE_MIN_TRADES_AGG &&
                  pf >= AAI_MODE_AGG_PF_ENTER &&
                  dd_pct <= AAI_MODE_AGG_DD_ENTER &&
                  stress <= AAI_MODE_AGG_STRESS_ENTER)
             new_mode = AAI_MODE_AGGRESSIVE;
          break;
         }
      case AAI_MODE_DEFENSIVE:
         {
          // Leave DEF only when things clearly improve
          if(pf >= AAI_MODE_DEF_PF_EXIT &&
             dd_pct <= AAI_MODE_DEF_DD_EXIT &&
             stress <= AAI_MODE_DEF_STRESS_EXIT)
             new_mode = AAI_MODE_NORMAL;
          break;
         }
      case AAI_MODE_AGGRESSIVE:
         {
          // Fall back to NORMAL if edges erode a bit
          if(pf <= AAI_MODE_AGG_PF_EXIT ||
             dd_pct >= AAI_MODE_AGG_DD_EXIT ||
             stress >= AAI_MODE_AGG_STRESS_EXIT)
             new_mode = AAI_MODE_NORMAL;

          // Or straight to DEF if things deteriorate badly
          if(pf <= AAI_MODE_DEF_PF_ENTER ||
             dd_pct >= AAI_MODE_DEF_DD_ENTER ||
             stress >= AAI_MODE_DEF_STRESS_ENTER)
             new_mode = AAI_MODE_DEFENSIVE;
          break;
         }
     }

   if(new_mode != AAI_mode_current)
     {
      int prev = AAI_mode_current;
      AAI_mode_current = new_mode;
double eff_min = AAI_EffectiveMinConf();
PrintFormat("AAI_MODE|from=%s|to=%s|pf_win=%.2f|wr_win=%.1f|dd_cur=%.2f|stress=%d|trades=%d|minconf_eff=%.1f",
            AAI_ModeName(prev), AAI_ModeName(new_mode),
            pf, wr, dd_pct, stress, AAI_trades, eff_min);
     }
  }


long     AAI_last_in_pos_id = -1;
datetime AAI_last_in_time = 0;
ulong    AAI_last_out_deal = 0;  // dedupe out deals
ulong    AAI_last_in_deal  = 0;
// (reuses exec hook dedupe if present)

// --- Mode-level risk multiplier (used in CalculateLotSize) ------
double AAI_ModeRiskMult()
  {
   switch(AAI_mode_current)
     {
      case AAI_MODE_DEFENSIVE:  return 0.50;  // halve risk in DEF
      case AAI_MODE_AGGRESSIVE: return 1.20;  // +20% risk in AGG
      default:                  return 1.00;  // NORMAL
     }
  }


// Net P&L for a deal: profit + commission + swap
double AAI_NetDealPL(ulong deal_ticket)
{
   if(!HistoryDealSelect((long)deal_ticket)) return 0.0;
   double p  = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   double c  = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
   double sw = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   return p + c + sw;
}

// Update drawdown stats on closed-trade increments
void AAI_UpdateCurve(double net_pl)
{
   AAI_curve += net_pl;
   if(AAI_curve > AAI_peak) AAI_peak = AAI_curve;
   double dd = AAI_peak - AAI_curve;
   if(dd > AAI_max_dd) AAI_max_dd = dd;
}
#endif

double AAI_dur_sum_sec = 0.0;
int    AAI_dur_count   = 0;

// --- Per-trade log: trade open snapshot ---------------------------
void AAI_LogTradeOpen(const ulong deal_ticket)
  {
   if(!HistoryDealSelect((long)deal_ticket))
      return;

   long     type   = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   double   volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double   price  = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   datetime t      = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);

   string dir;
   if(type == DEAL_TYPE_BUY)
      dir = "BUY";
   else if(type == DEAL_TYPE_SELL)
      dir = "SELL";
   else
      dir = "UNK";

   double conf = -1.0;
   if(g_sb.valid)
      conf = g_sb.conf;

   // Existing per-trade open snapshot (unchanged behaviour)
   PrintFormat(
      "AAI_TRADE_OPEN|ticket=%I64u|time=%s|sym=%s|tf=%s"
      "|dir=%s|lots=%.2f|price=%.5f"
      "|conf=%.1f|mode=%s|regime_vol=%s|regime_msm=%s",
      deal_ticket,
      TimeToString(t, TIME_DATE|TIME_MINUTES),
      _Symbol,
      EnumToString(_Period),
      dir,
      volume,
      price,
      conf,
      AAI_ModeName(AAI_mode_current),
      AAI_VolRegimeName(AAI_regime_vol),
      AAI_MSMRegimeName(AAI_regime_msm)
   );

   // C1: use AAI_Context for the entry-context log (no behaviour change)
   AAI_Context ctx;
   AAI_FillContext(ctx);
   AAI_LogEntryContext(deal_ticket, t, ctx);
  }
// --- NEW: SignalBrain snapshot per entry (behaviour-neutral) ------
void AAI_LogSBEntrySnapshot(const ulong deal_ticket)
{
   // We need a valid deal and a matching MagicNumber
   if(!HistoryDealSelect((long)deal_ticket))
      return;

   if((ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != MagicNumber)
      return;

   // If SB cache is not valid for this bar, don't log
   if(!g_sb.valid)
      return;

   long     type   = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   double   volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double   price  = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   datetime t      = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);

   string dir = "UNK";
   if(type == DEAL_TYPE_BUY)
      dir = "BUY";
   else if(type == DEAL_TYPE_SELL)
      dir = "SELL";

   // g_sb.* = raw SB state at closed bar
   // g_last_conf_eff = effective confidence after gates / playbook
   PrintFormat(
      "AAI_SB_ENTRY|ticket=%I64u|time=%s|sym=%s|tf=%s"
      "|dir=%s|lots=%.2f|price=%.5f"
      "|sig=%d|conf_raw=%.1f|conf_eff=%.1f"
      "|ze=%.1f|bc=%d|smc_sig=%d|smc_conf=%.1f",
      deal_ticket,
      TimeToString(t, TIME_DATE|TIME_MINUTES),
      _Symbol,
      EnumToString(_Period),
      dir,
      volume,
      price,
      g_sb.sig,
      g_sb.conf,
      g_last_conf_eff,
      g_sb.ze,
      g_sb.bc,
      g_sb.smc_sig,
      g_sb.smc_conf
   );
}


// --- Regime (VOL x MSM) analytics ---------------------------------
// VOL: 0=LOW,1=MID,2=HIGH
// MSM: 0=TREND,1=RANGE,2=CHAOS
#define AAI_RG_MAX_OPEN   32      // max concurrently tracked positions
#define AAI_RG_VBINS       3      // LOW/MID/HIGH
#define AAI_RG_MBINS       3      // TREND/RANGE/CHAOS
#define AAI_RG_BUCKETS     (AAI_RG_VBINS * AAI_RG_MBINS)

// Mapping from open position -> regime at entry
ulong AAI_rg_pos_id[AAI_RG_MAX_OPEN];
int   AAI_rg_vol_reg[AAI_RG_MAX_OPEN];   // raw regime code at entry
int   AAI_rg_msm_reg[AAI_RG_MAX_OPEN];

// Aggregated stats per (vol, msm) bucket
int    AAI_rg_trades[AAI_RG_BUCKETS];
int    AAI_rg_wins[AAI_RG_BUCKETS];
int    AAI_rg_losses[AAI_RG_BUCKETS];
double AAI_rg_net[AAI_RG_BUCKETS];       // sum(net)
double AAI_rg_pos_sum[AAI_RG_BUCKETS];   // sum of positive profits
double AAI_rg_neg_sum[AAI_RG_BUCKETS];   // sum of abs(negative profits)
// --- Scenario analytics (playbook scenarios) ----------------------
#define AAI_SCN_MAX_OPEN   32       // max concurrently tracked positions
#define AAI_SCN_BUCKETS     4       // BASELINE, DEF, OPP, RISK_OFF

// Mapping from open position -> scenario at entry
ulong AAI_scn_pos_id[AAI_SCN_MAX_OPEN];
int   AAI_scn_bucket[AAI_SCN_MAX_OPEN];   // ENUM_AAI_SCENARIO as int

// Aggregated stats per scenario
int    AAI_scn_trades[AAI_SCN_BUCKETS];
int    AAI_scn_wins[AAI_SCN_BUCKETS];
int    AAI_scn_losses[AAI_SCN_BUCKETS];
double AAI_scn_net[AAI_SCN_BUCKETS];      // sum(net)
double AAI_scn_pos_sum[AAI_SCN_BUCKETS];  // sum of positive profits
double AAI_scn_neg_sum[AAI_SCN_BUCKETS];  // sum of abs(negative profits)

// --- Confidence band analytics ------------------------------------
#define AAI_CB_BANDS 8   // 20-30,30-40,40-50,...,90-100
#define AAI_CB_MAX_OPEN  32      // max open entries we're willing to track

// Mapping from entry deal -> band index (for open trades)
ulong AAI_cb_deal[AAI_CB_MAX_OPEN];
int   AAI_cb_band[AAI_CB_MAX_OPEN];

// Aggregated stats per band
int    AAI_cb_trades[AAI_CB_BANDS];
int    AAI_cb_wins[AAI_CB_BANDS];
int    AAI_cb_losses[AAI_CB_BANDS];
double AAI_cb_net[AAI_CB_BANDS];   // sum(net)
double AAI_cb_pos[AAI_CB_BANDS];   // sum(positive profits)
double AAI_cb_neg[AAI_CB_BANDS];   // sum(abs(negative profits))

// --- Mode-level MinConfidence adjustment --------------------------------
// Mode decides how picky we are:
//
// DEF  -> require higher MinConf
// NORM -> base MinConf
// AGG  -> allow slightly lower MinConf (within safe bounds)
double AAI_ModeMinConfDelta()
  {
   switch(AAI_mode_current)
     {
      case AAI_MODE_DEFENSIVE:  return  +5.0;  // more picky in DEF
      case AAI_MODE_AGGRESSIVE: return  -3.0;  // slightly less picky in AGG
      default:                  return   0.0;  // NORMAL
     }
  }

// Effective MinConfidence used by GateConfidence
double AAI_EffectiveMinConf()
  {
   double base = (double)MinConfidence;

   // Use current context + playbook to derive total MinConf delta.
   AAI_Context ctx;
   AAI_FillContext(ctx);

   double eff = base + AAI_PlaybookMinConfDelta(ctx);

// Treat 0 as "no clamp"
if(Inp_MinConf_Min > 0.0 && eff < Inp_MinConf_Min) eff = Inp_MinConf_Min;
if(Inp_MinConf_Max > 0.0 && eff > Inp_MinConf_Max) eff = Inp_MinConf_Max;
   return eff;
  }

// --- Regime-level MinConfidence adjustment -----------------------
double AAI_RegimeMinConfDelta()
  {
   int v = AAI_regime_vol;
   int m = AAI_regime_msm;

   double d = 0.0;

   if(m == AAI_MSM_TREND_GOOD)
     {
      if(v == AAI_VOL_LOW)      d = +1.0;
      else if(v == AAI_VOL_MID) d =  0.0;
      else                      d = +2.0;  // HIGH
     }
   else if(m == AAI_MSM_RANGE_GOOD)
     {
      if(v == AAI_VOL_LOW)      d = +2.0;
      else if(v == AAI_VOL_MID) d = +3.0;
      else                      d = +4.0;  // HIGH
     }
   else // CHAOS
     {
      if(v == AAI_VOL_LOW)      d = +4.0;
      else if(v == AAI_VOL_MID) d = +5.0;
      else                      d = +6.0;  // HIGH
     }

   return d;
  }


// ==================== /AAI METRICS ======================

#endif // AAI_METRICS_MQH
