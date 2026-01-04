#ifndef AAI_HUD_REGIME_MQH
#define AAI_HUD_REGIME_MQH

//+------------------------------------------------------------------+
//| HUD label helper                                                 |
//+------------------------------------------------------------------+
void HUD_Label(string name, int x, int y, string text, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  10);
      ObjectSetString (0, name, OBJPROP_FONT,      "Consolas");
   }

   ObjectSetString (0, name, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| AAI: draw/update ghost horizontal level (PT planning)            |
//+------------------------------------------------------------------+
void AAI_DrawGhostLevel(const string name, const double price, const color clr)
  {
   if(price <= 0.0)
      return;

   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
         return;

      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK,  true);
     }

   ObjectSetDouble (0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
//| Compact HUD (market state + last SB signal + Smart Exit status)  |
//+------------------------------------------------------------------+
void UpdateHUD()
{
   if(!g_sb.valid)
      return; // Don't draw if we have no SB data yet

   string prefix = "AAI_HUD_";
   int x    = 20;
   int y    = 40;
   int step = 20;

   // --- MSM Regime (TREND / RANGE / CHAOS) ------------------------
   string msm_txt = "MSM: DISABLED";
   color  msm_clr = clrGray;

   if(MSM_Enable)
     {
      if(AAI_regime_msm == AAI_MSM_TREND_GOOD)
        {
         msm_txt = "MSM: TREND";
         msm_clr = clrLimeGreen;
        }
      else if(AAI_regime_msm == AAI_MSM_RANGE_GOOD)
        {
         msm_txt = "MSM: RANGE";
         msm_clr = clrOrange;
        }
      else
        {
         msm_txt = "MSM: CHAOS";
         msm_clr = clrRed;
        }
     }

   // --- Volatility Regime (LOW / MID / HIGH) ----------------------
   string vol_txt = "VOL: MID";
   color  vol_clr = clrWhiteSmoke;

   if(AAI_regime_vol == AAI_VOL_LOW)
     {
      vol_txt = "VOL: LOW";
      vol_clr = clrSkyBlue;
     }
   else if(AAI_regime_vol == AAI_VOL_HIGH)
     {
      vol_txt = "VOL: HIGH";
      vol_clr = clrTomato;
     }

   // --- AAI Scenario (BASELINE / DEF / OPP / RISK_OFF) ------------
   AAI_Context ctx;
   AAI_FillContext(ctx);
   ENUM_AAI_SCENARIO scn = AAI_MapScenario(ctx);

   string scn_txt = "SCN: " + AAI_ScenarioName(scn);
   color  scn_clr = clrWhite;

   switch(scn)
     {
      case AAI_SCN_DEFENSIVE:
         scn_clr = clrOrange;
         break;
      case AAI_SCN_OPPORTUNITY:
         scn_clr = clrLimeGreen;
         break;
      case AAI_SCN_RISK_OFF:
         scn_clr = clrCrimson;
         break;
      default:
         scn_clr = clrWhite;
         break;
     }

   // --- Last SignalBrain signal -----------------------------------
   string sig_txt = "None";
   color  sig_clr = clrGray;

   if(g_sb.sig > 0)
     {
      sig_txt = "BUY";
      sig_clr = clrLime;
     }
   else if(g_sb.sig < 0)
     {
      sig_txt = "SELL";
      sig_clr = clrRed;
     }

   // --- Draw labels ------------------------------------------------
   HUD_Label(prefix + "1", x, y + 0*step, msm_txt, scn_clr);  // MSM regime (colored by scenario)
   HUD_Label(prefix + "2", x, y + 1*step, vol_txt, vol_clr);  // Vol regime LOW/MID/HIGH
   HUD_Label(prefix + "3", x, y + 2*step, scn_txt, scn_clr);  // Scenario (BASELINE/DEF/OPP/RISK_OFF)

   HUD_Label(prefix + "4", x, y + 3*step,
             StringFormat("ADX: %.1f", g_msm_adx),
             clrWhiteSmoke);

   HUD_Label(prefix + "5", x, y + 4*step,
             StringFormat("Last Sig: %s (Conf: %.0f)", sig_txt, g_sb.conf),
             sig_clr);

   if(InpSE_Enable)
      HUD_Label(prefix + "6", x, y + 5*step, "Smart Exit: ACTIVE", clrLightBlue);
}

//+------------------------------------------------------------------+
//| T041: ATR history + percentile helper for volatility regime      |
//+------------------------------------------------------------------+

// --- Volatility regime based on ATR bps and VR band --------------
void AAI_UpdateVolRegime()
  {
   // default: MID, fail-open
   AAI_regime_vol = AAI_VOL_MID;

   if(g_hATR_VR == INVALID_HANDLE)
      return;  // no handle => leave MID

   double bps = VR_BpsLastBar();   // uses g_hATR_VR internally
   if(bps <= 0.0)
      return;  // no data => leave MID

   // Update ATR history + percentile score
   double pctl = MSM_UpdateAtrPercentile(bps);

   int candidate = AAI_VOL_MID;

   // If we have a decent amount of history, use percentile-based bands.
   // Otherwise fall back to static Bps thresholds.
   if(g_msm_atr_count >= MSM_MinPctlSamples)
     {
      if(pctl <= MSM_PctlQuiet)
         candidate = AAI_VOL_LOW;
      else if(pctl >= MSM_PctlVolatile)
         candidate = AAI_VOL_HIGH;
      else
         candidate = AAI_VOL_MID;
     }
   else
     {
      if(bps < (double)InpVR_MinBps)
         candidate = AAI_VOL_LOW;
      else if(bps > (double)InpVR_MaxBps)
         candidate = AAI_VOL_HIGH;
      else
         candidate = AAI_VOL_MID;
     }

   // --- Hysteresis: require VR_HysteresisBars consecutive bars
   //     of a new candidate regime before switching.
   if(candidate == g_vr_last_regime)
     {
      // No change needed; reset pending state
      g_vr_pending_regime = candidate;
      g_vr_pending_count  = 0;
      AAI_regime_vol      = g_vr_last_regime;
      return;
     }

   // Candidate differs from current regime
   if(candidate == g_vr_pending_regime)
     {
      g_vr_pending_count++;
      if(g_vr_pending_count >= VR_HysteresisBars)
        {
         g_vr_last_regime   = candidate;
         AAI_regime_vol     = candidate;
         g_vr_pending_count = 0;
        }
      else
        {
         // Not yet persistent enough: stay in previous regime
         AAI_regime_vol = g_vr_last_regime;
        }
     }
   else
     {
      // New candidate; start counting persistence
      g_vr_pending_regime = candidate;
      g_vr_pending_count  = 1;
      AAI_regime_vol      = g_vr_last_regime;
     }
  }

//+------------------------------------------------------------------+
//| Market State Machine updater                                     |
//+------------------------------------------------------------------+
void UpdateMSM_State()
  {
   if(!MSM_Enable)
      return;

   // --- ADX (raw + EMA smoothing) ---
   double adx_buff[1];
   if(CopyBuffer(g_hMSM_ADX, 0, 1, 1, adx_buff) == 1)
     {
      g_msm_adx = adx_buff[0];

      // Smooth ADX with EMA to reduce noise
      if(g_msm_adx_ema <= 0.0)
         g_msm_adx_ema = g_msm_adx;
      else
         g_msm_adx_ema = MSM_ADX_EMA_Alpha * g_msm_adx
                       + (1.0 - MSM_ADX_EMA_Alpha) * g_msm_adx_ema;
     }

   // --- ATR percentile (volatility flavour for MSM) ---
   double atr_bps = MSM_AtrBpsLastBar();
   if(atr_bps > 0.0)
      MSM_UpdateAtrPercentile(atr_bps);

   // --- EMAs for trend direction ---
   double fast[1], slow[1];
   if(CopyBuffer(g_hMSM_EMA_Fast, 0, 1, 1, fast) == 1 &&
      CopyBuffer(g_hMSM_EMA_Slow, 0, 1, 1, slow) == 1)
     {
      if(fast[0] > slow[0])
         g_msm_state = 1;      // Uptrend
      else if(fast[0] < slow[0])
         g_msm_state = 2;      // Downtrend
      else
         g_msm_state = 0;      // Flat / neutral
     }

   if(MSM_LogVerbose)
      PrintFormat("[MSM] ADX=%.1f ADXema=%.1f ATRbps=%.1f ATRpctl=%.2f State=%d",
                  g_msm_adx,
                  g_msm_adx_ema,
                  g_msm_atr,
                  g_msm_pctl,
                  g_msm_state);
  }

// --- MSM regime based on EMA trend + smoothed ADX + ATR percentile + hysteresis ---
void AAI_UpdateMSMRegime()
  {
   int    s       = g_msm_state;
   double adx_eff = (g_msm_adx_ema > 0.0 ? g_msm_adx_ema : g_msm_adx);
   double pctl    = g_msm_pctl;   // 0..1, vs recent ATR history

   int candidate  = AAI_MSM_CHAOS_BAD;

   // --- 1) Trend states (1=up, 2=down) ---
   if(s == 1 || s == 2)
     {
      if(adx_eff >= MSM_ADX_TrendThresh)
        {
         // Clean trend: ADX strong. Extremely wild volatility can be treated as "chaotic trend"
         // For now we keep all strong trends as TREND_GOOD and let VOL regime / playbook
         // handle high vol sizing, unless ATR is EXTREMELY high.
         if(pctl >= 0.95)      // ultra-extreme vol? treat as chaos
            candidate = AAI_MSM_CHAOS_BAD;
         else
            candidate = AAI_MSM_TREND_GOOD;
        }
      else
        {
         // Trend direction but weak ADX -> not trustworthy
         candidate = AAI_MSM_CHAOS_BAD;
        }
     }
   else  // --- 2) Flat / neutral (range candidates) ---
     {
      if(adx_eff <= MSM_ADX_RangeThresh)
        {
         // Here we distinguish QUIET range vs WILD range:
         // - quiet (low ATR percentile) -> RANGE_GOOD
         // - mid ATR percentile        -> still RANGE_GOOD
         // - high ATR percentile       -> CHAOS_BAD (choppy, stop hunts)
         if(pctl <= MSM_PctlQuiet || g_msm_atr <= 0.0)
            candidate = AAI_MSM_RANGE_GOOD;    // nice, quiet range
         else if(pctl >= MSM_PctlVolatile)
            candidate = AAI_MSM_CHAOS_BAD;     // wild, choppy range
         else
            candidate = AAI_MSM_RANGE_GOOD;    // mid-vol range
        }
      else
        {
         // Neither clearly trending nor clearly ranging -> treat as chaos
         candidate = AAI_MSM_CHAOS_BAD;
        }
     }

   // --- 3) Hysteresis: require MSM_RegimeHysteresisBars consecutive bars
   //         of the new candidate before switching, to avoid flapping.
   if(candidate == g_msm_regime_last)
     {
      // No change; reset pending
      g_msm_regime_pending       = candidate;
      g_msm_regime_pending_count = 0;
      AAI_regime_msm             = g_msm_regime_last;
     }
   else if(candidate == g_msm_regime_pending)
     {
      g_msm_regime_pending_count++;
      if(g_msm_regime_pending_count >= MSM_RegimeHysteresisBars)
        {
         g_msm_regime_last          = candidate;
         AAI_regime_msm             = candidate;
         g_msm_regime_pending_count = 0;
        }
      else
        {
         // Not yet stable: stay in last regime
         AAI_regime_msm = g_msm_regime_last;
        }
     }
   else
     {
      // New candidate regime: start tracking its persistence
      g_msm_regime_pending       = candidate;
      g_msm_regime_pending_count = 1;
      AAI_regime_msm             = g_msm_regime_last;
     }

   // Snapshot multiplier for telemetry (combines VOL × MSM logic)
   g_msm_mult = AAI_RegimeRiskMult();
  }
  
  void RS_UpdateTransition(const int prev_vol, const int prev_msm)
{
   if(!InpRS_EnableTransitionGuard)
   {
      g_rs_transition_active = false;
      return;
   }

   if(prev_vol != AAI_regime_vol || prev_msm != AAI_regime_msm)
      g_rs_transition_until_bar = g_barIndex + MathMax(0, InpRS_TransitionCooldownBars);
// Optional: consider CHAOS as an ongoing transition environment
if(AAI_regime_msm == AAI_MSM_CHAOS_BAD)
   g_rs_transition_until_bar = MathMax(g_rs_transition_until_bar, g_barIndex + MathMax(0, InpRS_TransitionCooldownBars));

   g_rs_transition_active =
      (g_rs_transition_until_bar >= 0 && g_barIndex <= g_rs_transition_until_bar);
}

// --- T048: Dynamic Signal Weighting ------------------------------
void AAI_UpdateSignalWeights()
  {
   if(!InpSB_DynWeights_Enable)
      return;

   // Base weights from inputs
   double w_base = InpSB_W_BASE;
   double w_bc   = InpSB_W_BC;
   double w_ze   = InpSB_W_ZE;
   double w_smc  = InpSB_W_SMC;

   // --- Adapt based on MSM Regime ---
   if(AAI_regime_msm == AAI_MSM_TREND_GOOD)
     {
      // Trend regime: lean into BC, dim ZE a bit
      w_bc *= 2.5;
      w_ze *= 0.4;
     }
   else if(AAI_regime_msm == AAI_MSM_RANGE_GOOD)
     {
      // Range regime: lean into ZE, dim BC
      w_bc *= 0.3;
      w_ze *= 2.5;
     }
   else // CHAOS_BAD or unknown
     {
      // In chaos, downweight indicator-style signals, slightly upweight SMC
      w_bc  *= 0.2;
      w_ze  *= 0.2;
      w_smc *= 1.5;
     }

   // Optional: light clamping to avoid crazy values if user inputs are large
   double maxW = 5.0;
   w_base = MathMin(w_base, maxW);
   w_bc   = MathMin(w_bc,   maxW);
   w_ze   = MathMin(w_ze,   maxW);
   w_smc  = MathMin(w_smc,  maxW);

   // Push dynamic weights for SignalBrain
   GlobalVariableSet("AAI/SB/W_BASE", w_base);
   GlobalVariableSet("AAI/SB/W_BC",   w_bc);
   GlobalVariableSet("AAI/SB/W_ZE",   w_ze);
   GlobalVariableSet("AAI/SB/W_SMC",  w_smc);

   // Optional debug
  // PrintFormat("[DYN_WEIGHTS] msm=%s base=%.2f bc=%.2f ze=%.2f smc=%.2f",
              // AAI_MSMRegimeName(AAI_regime_msm), w_base, w_bc, w_ze, w_smc);
  }

#endif // AAI_HUD_REGIME_MQH
