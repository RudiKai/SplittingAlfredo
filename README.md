# AlfredAI (drop-in folder layout)

This package is arranged to be copied directly into a MetaTrader 5 terminal **MQL5/** directory.

## Install
1. Open your terminal data folder:
   - MT5: **File → Open Data Folder**
2. Copy/merge the **MQL5/** folder from this package into your terminal’s **MQL5/** folder (keep the same subfolders).

Resulting paths should look like:
- `MQL5/Experts/AlfredAI/AAI_EA_Trade_Manager.mq5`
- `MQL5/Indicators/AlfredAI/AAI_Indicator_SignalBrain.mq5`
- `MQL5/Include/AlfredAI/AAI_Include_News.mqh`
- `MQL5/Include/AlfredAI/inc/*.mqh`

3. Open **MetaEditor** and compile:
   - Compile the indicators in `MQL5/Indicators/AlfredAI/` first
   - Then compile `MQL5/Experts/AlfredAI/AAI_EA_Trade_Manager.mq5`

## Presets (.set)
If you have an EA preset `.set`, place it in:
- `MQL5/Presets/AlfredAI/`

(You can also keep presets anywhere, but this keeps AlfredAI self-contained.)

## What was fixed/cleaned
### RiskGuard (OnTradeTransaction)
- **Daily realized P/L** and **daily SL hits** are updated per **closing deal** (so partial closes are handled correctly).
- **Consecutive-loss streak** and **journal logging** are updated once per **fully closed position** (prevents double-counting when partial closes exist).
- **Trailing-state cleanup** now keys off the **position ticket from the transaction** (POSITION_TICKET), avoiding confusion with DEAL_POSITION_ID.
- **Reset-on-win** (`InpRG_ResetOnWin`) only clears an active RG block when a fully closed position ends in profit.

### GateRiskGuard duration
- If RiskGuard trips due to **consecutive losses** (`hit_seq`) and `InpRG_BlockHoursAfterTrip > 0`, that value is used for the hour-based block duration.

