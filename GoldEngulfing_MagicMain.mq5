//+------------------------------------------------------------------+
//|                          GoldEngulfing_MagicMain                  |
//|                     WITH HISTORY RECONSTRUCTION                   |
//+------------------------------------------------------------------+

#property copyright "Your Name"
#property version   "2.30"
#property strict

// Include all module files
#include "IncludeMagic/Config.mqh"
#include "IncludeMagic/Utils.mqh"
#include "IncludeMagic/StorageSystem.mqh"
#include "IncludeMagic/VisualManager.mqh"
#include "IncludeMagic/OrderManager.mqh"
#include "IncludeMagic/SetupHelpers.mqh"
#include "IncludeMagic/SetupManager.mqh"
#include "IncludeMagic/TableLogger.mqh"
#include "IncludeMagic/EngulfingDetector.mqh"
#include "IncludeMagic/HistoryReconstructor.mqh"

// ✅ NEW INPUT: Enable history reconstruction
input group "=== Data Recovery ==="
input bool InpReconstructFromHistory = false;  // Rebuild from MT5 History on Start

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit() {   
   Print("\n╔════════════════════════════════════════════════════════════════╗");
   Print("║        Gold Engulfing EA Magic Ids v2.3 - STARTING               ║");
   Print("╚════════════════════════════════════════════════════════════════╝\n");
   
   // Validate inputs
   if(!ValidateInputs()) {
      return INIT_PARAMETERS_INCORRECT;
   }
   
   // Initialize storage system
   if(!InitializeStorage()) {
      Print("⚠️ Storage system initialization failed");
   }
   
   // Load saved setups
   LoadSetupsFromFile();
   Print("📂 Loaded ", ArraySize(g_allSetups), " setups from file\n");
   
   // ✅ NEW: Option to reconstruct from MT5 history
   if(InpReconstructFromHistory) {
      Print("🔨 RECONSTRUCTION MODE ENABLED");
      Print("   → Will rebuild ALL data from MT5 history (source of truth)\n");
      
      // Scan historical data first (to find all patterns)
      ScanHistoricalData();
      
      // Then reconstruct trade data from MT5 history
      ReconstructFromMT5History();
      
      Print("✅ Reconstruction complete - data is now accurate!\n");
      
   } else {
      Print("⚠️ NORMAL MODE: Using data from file");
      Print("   → To rebuild from MT5 history, set InpReconstructFromHistory = true\n");
      
      // Normal flow
      RevalidateUntappedSetups();
      ScanHistoricalData();
   }
   
   // Count setup states
   int untappedCount = 0;
   int tappedCount = 0;
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      if(g_allSetups[i].state == SETUP_UNTAPPED) untappedCount++;
      else if(g_allSetups[i].state == SETUP_TAPPED) tappedCount++;
   }
   
   // Restore visual lines
   RestoreVisualLines();
   
   // Place orders for untapped setups
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      if(g_allSetups[i].state == SETUP_UNTAPPED) {
         if(!g_allSetups[i].ordersPlacedFlag) {
            bool canPlace = CanPlaceOrdersForSetup(g_allSetups[i]);
            if(canPlace) {
               PlaceOrders(g_allSetups[i]);
               g_allSetups[i].ordersPlacedFlag = true;
            }
         }
      }
   }
   
   // Call ScanForNewEngulfingPattern on EA start/restart
   ScanForNewEngulfingPattern();
   
   // Call ScanAllCandlesWithLogging on EA start/restart
   ScanAllCandlesWithLogging(MAX_LOOKBACK_BARS, "📋 INITIAL CANDLE ANALYSIS (14 DAYS)");
   
   // Display summary
   DisplayCompactSummary();
   PrintSetupSummary();
   
   // Save state
   SaveSetupsToFile();
   
   // Set up timer for periodic checks (every 1 second)
   EventSetTimer(1);
   
   Print("\n✅ EA Initialization Complete\n");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   SaveSetupsToFile();
   DeleteAllEALines();
   Print("🧹 EA Removed - Chart completely cleaned");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick() {
   if(!IsNewBar()) return;
   
   Print("\n⏰ New H1 Bar - ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
   
   ScanForNewEngulfingPattern();
   CheckUntappedSetups();
   CheckTappedSetups();
   CheckManualCloses();
   UpdateAllUntappedLines();
   CleanupOldLines();
   SaveSetupsToFile();
   
   if(InpEnableTableLogs) {
      DisplayCompactSummary();
   }
}

//+------------------------------------------------------------------+
//| Expert timer function                                             |
//+------------------------------------------------------------------+
void OnTimer() {
   CheckUntappedSetupsRealTime();
   SyncVisualLinesWithState();
   
   static datetime lastRevalidationTime = 0;
   if(TimeCurrent() - lastRevalidationTime > 60) {
      CheckForOfflineTrades();
      lastRevalidationTime = TimeCurrent();
   }
}

// Keep all existing timer functions...
void CheckUntappedSetupsRealTime() {
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentPrice = (currentBid + currentAsk) / 2.0;
   
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      if(g_allSetups[i].state == SETUP_UNTAPPED) {
         if(IsPriceInRange(currentPrice, g_allSetups[i].rangeHigh, g_allSetups[i].rangeLow)) {
            Print("⚡ Real-time tap detected: ", g_allSetups[i].setupID);
            MarkSetupAsTapped(i);
            SaveSetupsToFile();
         }
      }
   }
}

void SyncVisualLinesWithState() {
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      color currentColor = clrNONE;
      if(ObjectFind(0, g_allSetups[i].lineHighName) >= 0) {
         currentColor = (color)ObjectGetInteger(0, g_allSetups[i].lineHighName, OBJPROP_COLOR);
      }
      
      color expectedColor = (g_allSetups[i].state == SETUP_UNTAPPED) ? InpUntappedLineColor : InpTappedLineColor;
      
      if(currentColor != expectedColor) {
         if(g_allSetups[i].state == SETUP_UNTAPPED) {
            DrawRangeLines(g_allSetups[i]);
         } else {
            RedrawTappedLines(g_allSetups[i]);
         }
      }
   }
}

void CheckForOfflineTrades() {
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      if(g_allSetups[i].state == SETUP_UNTAPPED && g_allSetups[i].ordersPlacedFlag) {
         bool hasTradeHistory = CheckSetupTradeHistory(g_allSetups[i]);
         
         if(hasTradeHistory) {
            Print("🔍 Offline trade detected for: ", g_allSetups[i].setupID);
            
            g_allSetups[i].state = SETUP_TAPPED;
            g_allSetups[i].tapped = true;
            g_allSetups[i].tradeStatus = TRADE_STATUS_TRADED;
            g_allSetups[i].wasTraded = true;
            g_allSetups[i].tappedTime = TimeCurrent();
            g_allSetups[i].lastActivityTime = TimeCurrent();
            g_totalSetupsTraded++;
            
            UpdateOrderCountsFromHistory(g_allSetups[i]);
            CalculateSetupProfit(g_allSetups[i]);
            RedrawTappedLines(g_allSetups[i]);
            
            SaveSetupsToFile();
         }
      }
   }
}