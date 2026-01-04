#ifndef AAI_HYBRIDSTATE_MQH
#define AAI_HYBRIDSTATE_MQH

#ifndef AAI_HYBRID_STATE_DEFINED
#define AAI_HYBRID_STATE_DEFINED
bool g_auto_hour_mask[24];
datetime g_hyb_last_alert_bar = 0;
datetime g_hyb_last_alert_ts  = 0;
int g_blk_hyb = 0;        // count "alert-only" bars
datetime g_stamp_hyb = 0;     // once-per-bar stamp
#endif

#endif // AAI_HYBRIDSTATE_MQH
