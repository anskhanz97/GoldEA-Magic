//+------------------------------------------------------------------+
//|                                            SetupManager.mqh      |
//|                    Gold Engulfing EA - Setup State Machine v2.30 |
//|                    FIXED: Proper offline trade detection         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check All UNTAPPED Setups - Have They Been Tapped?               |
//+------------------------------------------------------------------+
void CheckUntappedSetups() {
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentPrice = (currentBid + currentAsk) / 2.0;
   
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      if(g_allSetups[i].state == SETUP_UNTAPPED) {
         // Check if price has entered the range
         if(IsPriceInRange(currentPrice, g_allSetups[i].rangeHigh, g_allSetups[i].rangeLow)) {
            MarkSetupAsTapped(i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Mark Setup as TAPPED (Main State Transition)                     |
//+------------------------------------------------------------------+
void MarkSetupAsTapped(int index) {
   if(!IsValidSetupIndex(index)) return;
   
   // Update state
   g_allSetups[index].state = SETUP_TAPPED;
   g_allSetups[index].tapped = true;
   g_allSetups[index].tappedTime = TimeCurrent();
   g_allSetups[index].lastActivityTime = TimeCurrent();
   
   // Determine MISSED vs TRADED
   if(g_allSetups[index].ordersPlacedFlag) {
      // Orders were placed → TRADED
      g_allSetups[index].tradeStatus = TRADE_STATUS_TRADED;
      g_allSetups[index].wasTraded = true;
      g_totalSetupsTraded++;
      
      Print("🎯 Setup TAPPED (TRADED): ", g_allSetups[index].setupID, 
            " | Orders placed: ", g_allSetups[index].ordersPlaced);
      SendAlert("🎯 TAPPED-TRADED: " + g_allSetups[index].setupID);
      
   } else {
      // No orders were placed → MISSED
      g_allSetups[index].tradeStatus = TRADE_STATUS_MISSED;
      g_allSetups[index].wasMissed = true;
      g_totalSetupsMissed++;
      
      Print("⚠️ Setup TAPPED (MISSED): ", g_allSetups[index].setupID, 
            " | EA was not running when tapped");
      SendAlert("⚠️ TAPPED-MISSED: " + g_allSetups[index].setupID);
   }
   
   // Redraw lines as RED
   RedrawTappedLines(g_allSetups[index]);
   
   // Log to file
   WriteLog(StringFormat("Setup %s TAPPED | Status: %s | Time: %s", 
                        g_allSetups[index].setupID,
                        GetTradeStatusName(g_allSetups[index].tradeStatus),
                        TimeToString(g_allSetups[index].tappedTime, TIME_DATE|TIME_MINUTES)));
}

//+------------------------------------------------------------------+
//| Check TAPPED Setups - Monitor Trade Execution & Completion       |
//+------------------------------------------------------------------+
void CheckTappedSetups() {
   for(int i = ArraySize(g_allSetups) - 1; i >= 0; i--) {
      if(g_allSetups[i].state == SETUP_TAPPED) {
         
         // Skip MISSED setups (no orders to monitor)
         if(g_allSetups[i].tradeStatus == TRADE_STATUS_MISSED) {
            continue;
         }
         
         // For TRADED setups, monitor orders
         if(g_allSetups[i].tradeStatus == TRADE_STATUS_TRADED) {
            
            // Update order tracking
            UpdateOrderStatus(g_allSetups[i]);
            
            // Check if first TP hit
            if(!g_allSetups[i].firstTPHit) {
               if(CheckFirstTPHit(g_allSetups[i])) {
                  g_allSetups[i].firstTPHit = true;
                  g_allSetups[i].hadFirstTP = true;
                  g_allSetups[i].lastActivityTime = TimeCurrent();
                  
                  // Cancel remaining pending orders
                  int cancelled = CancelPendingOrders(g_allSetups[i].setupID);
                  g_allSetups[i].ordersCancelled += cancelled;
                  
                  Print("✅ First TP hit for ", g_allSetups[i].setupID, 
                        " | Cancelled ", cancelled, " pending orders");
                  SendAlert("✅ First TP Hit: " + g_allSetups[i].setupID);
                  
                  WriteLog(StringFormat("First TP hit: %s | Cancelled: %d orders", 
                                       g_allSetups[i].setupID, cancelled));
               }
            }
            
            // Calculate financial metrics
            CalculateSetupProfit(g_allSetups[i]);
            
            // Check if setup is complete
            if(AreAllOrdersHandled(g_allSetups[i])) {
               MarkSetupAsComplete(i);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Mark Setup as Complete (All orders closed/cancelled)             |
//+------------------------------------------------------------------+
void MarkSetupAsComplete(int index) {
   if(!IsValidSetupIndex(index)) return;
   
   // Already complete?
   if(g_allSetups[index].isComplete) return;
   
   // Update completion status
   g_allSetups[index].isComplete = true;
   g_allSetups[index].completedTime = TimeCurrent();
   g_allSetups[index].lastActivityTime = TimeCurrent();
   
   // Final metrics calculation
   CalculateSetupProfit(g_allSetups[index]);
   
   Print("✔ Setup COMPLETE: ", g_allSetups[index].setupID);
   Print(StringFormat("   Status: %s | Orders: %d/%d filled | P/L: $%.2f",
                     GetTradeStatusName(g_allSetups[index].tradeStatus),
                     g_allSetups[index].ordersFilled,
                     g_allSetups[index].ordersPlaced,
                     g_allSetups[index].totalProfit));
   
   SendAlert(StringFormat("✔ Complete: %s | $%.2f", 
                         g_allSetups[index].setupID, 
                         g_allSetups[index].totalProfit));
   
   WriteLog(StringFormat("Setup COMPLETE: %s | Status:%s | Filled:%d/%d | TP:%d SL:%d | P/L:$%.2f",
                        g_allSetups[index].setupID,
                        GetTradeStatusName(g_allSetups[index].tradeStatus),
                        g_allSetups[index].ordersFilled,
                        g_allSetups[index].ordersPlaced,
                        g_allSetups[index].tpHits,
                        g_allSetups[index].slHits,
                        g_allSetups[index].totalProfit));
}

//+------------------------------------------------------------------+
//| Check for Manual Position Close (Cancel Remaining Orders)        |
//+------------------------------------------------------------------+
void CheckManualCloses() {
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      if(g_allSetups[i].state == SETUP_TAPPED && 
         g_allSetups[i].tradeStatus == TRADE_STATUS_TRADED && 
         !g_allSetups[i].firstTPHit) {
         
         int previousOpen = g_allSetups[i].positionsOpen;
         UpdateOrderStatus(g_allSetups[i]);
         int currentOpen = g_allSetups[i].positionsOpen;
         
         // Check if positions decreased (manual close detected)
         if(currentOpen < previousOpen) {
            Print("🔧 Manual close detected for setup: ", g_allSetups[i].setupID);
            
            // Cancel remaining pending orders
            int cancelled = CancelPendingOrders(g_allSetups[i].setupID);
            g_allSetups[i].ordersCancelled += cancelled;
            
            if(cancelled > 0) {
               Print("🚫 Cancelled ", cancelled, " pending orders due to manual close");
               SendAlert("Manual close: Cancelled " + IntegerToString(cancelled) + " orders");
            }
            
            // Mark as complete if no orders remain
            if(AreAllOrdersHandled(g_allSetups[i])) {
               MarkSetupAsComplete(i);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Print Setup Summary                                              |
//+------------------------------------------------------------------+
void PrintSetupSummary() {
   int untappedCount = 0;
   int tappedCount = 0;
   int missedCount = 0;
   int tradedCount = 0;
   int completeCount = 0;
   
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      switch(g_allSetups[i].state) {
         case SETUP_UNTAPPED:  
            untappedCount++; 
            break;
            
         case SETUP_TAPPED:    
            tappedCount++;
            if(g_allSetups[i].tradeStatus == TRADE_STATUS_MISSED) {
               missedCount++;
            } else {
               tradedCount++;
            }
            if(g_allSetups[i].isComplete) {
               completeCount++;
            }
            break;
      }
   }
   
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║                     SETUP SUMMARY v2.1                         ║");
   Print("╠════════════════════════════════════════════════════════════════╣");
   Print(StringFormat("║ Total Setups:      %-4d                                     ║", ArraySize(g_allSetups)));
   Print(StringFormat("║ UNTAPPED:          %-4d  (Yellow lines, waiting)            ║", untappedCount));
   Print(StringFormat("║ TAPPED:            %-4d  (Red lines)                        ║", tappedCount));
   Print(StringFormat("║   - Missed:        %-4d  (EA was off)                       ║", missedCount));
   Print(StringFormat("║   - Traded:        %-4d  (Orders managed)                   ║", tradedCount));
   Print(StringFormat("║   - Complete:      %-4d  (All orders done)                  ║", completeCount));
   Print("╚════════════════════════════════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
//| Validate Setup Data Integrity                                    |
//+------------------------------------------------------------------+
bool ValidateSetupIntegrity() {
   bool allValid = true;
   
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      // Check for valid setup ID
      if(g_allSetups[i].setupID == "") {
         Print("ERROR: Setup at index ", i, " has empty ID");
         allValid = false;
      }
      
      // Check for valid range
      if(g_allSetups[i].rangeHigh <= g_allSetups[i].rangeLow) {
         Print("ERROR: Setup ", g_allSetups[i].setupID, " has invalid range");
         allValid = false;
      }
      
      // Check for valid magic number
      if(g_allSetups[i].magicNumber <= 0) {
         Print("ERROR: Setup ", g_allSetups[i].setupID, " has invalid magic number");
         allValid = false;
      }
      
      // Check state consistency (2-state system)
      if(g_allSetups[i].state != SETUP_UNTAPPED && g_allSetups[i].state != SETUP_TAPPED) {
         Print("ERROR: Setup ", g_allSetups[i].setupID, " has invalid state: ", g_allSetups[i].state);
         allValid = false;
      }
      
      // Check trade status for tapped setups
      if(g_allSetups[i].state == SETUP_TAPPED) {
         if(g_allSetups[i].tradeStatus != TRADE_STATUS_MISSED && 
            g_allSetups[i].tradeStatus != TRADE_STATUS_TRADED) {
            Print("ERROR: Setup ", g_allSetups[i].setupID, " has invalid trade status");
            allValid = false;
         }
      }
   }
   
   return allValid;
}

//+------------------------------------------------------------------+
//| ✅ IMPROVED: Re-validate Untapped Setups                         |
//| Now correctly identifies: TRADED vs MISSED vs EA-OFFLINE         |
//+------------------------------------------------------------------+
void RevalidateUntappedSetups() {
   Print("\n🔍 ===== REVALIDATION STARTED =====");
   
   int revalidatedCount = 0;
   int tradedCount = 0;
   int missedWithOrders = 0;
   int missedNoOrders = 0;
   
   for(int i = 0; i < ArraySize(g_allSetups); i++) {
      if(g_allSetups[i].state != SETUP_UNTAPPED) continue;
      
      revalidatedCount++;
      string setupID = g_allSetups[i].setupID;
      int magic = g_allSetups[i].magicNumber;
      
      Print("\n--- Checking: ", setupID, " (Magic: ", magic, ") ---");
      
      // Check if price tapped
      bool wasTapped = CheckIfRangeTappedSinceCreation(g_allSetups[i]);
      
      if(!wasTapped) {
         Print("   ✅ Still UNTAPPED");
         continue;
      }
      
      // Price DID tap - now determine what happened
      Print("   🔴 Price TAPPED the range");
      
      // Check for actual trade executions
      bool hasDeals = CheckSetupTradeHistory(g_allSetups[i]);
      
      // Check if orders were placed
      bool hasOrders = CheckOrdersPlacedButNotFilled(g_allSetups[i]);
      
      if(hasDeals) {
         // ✅ TRADES WERE EXECUTED
         Print("   ✅ TRADES FOUND → Marking as TRADED");
         
         g_allSetups[i].state = SETUP_TAPPED;
         g_allSetups[i].tapped = true;
         g_allSetups[i].tradeStatus = TRADE_STATUS_TRADED;
         g_allSetups[i].wasTraded = true;
         g_totalSetupsTraded++;
         tradedCount++;
         
         UpdateOrderCountsFromHistory(g_allSetups[i]);
         CalculateSetupProfit(g_allSetups[i]);
         
         Print("   📊 Result: ", g_allSetups[i].ordersFilled, "/", 
               g_allSetups[i].ordersPlaced, " filled | P/L: $", 
               DoubleToString(g_allSetups[i].totalProfit, 2));
         
      } else if(hasOrders) {
         // ⚠️ ORDERS PLACED BUT NOT FILLED
         Print("   ⚠️ ORDERS PLACED BUT NOT FILLED → Marking as MISSED");
         
         g_allSetups[i].state = SETUP_TAPPED;
         g_allSetups[i].tapped = true;
         g_allSetups[i].tradeStatus = TRADE_STATUS_MISSED;
         g_allSetups[i].wasMissed = true;
         g_totalSetupsMissed++;
         missedWithOrders++;
         
         UpdateOrderCountsFromHistory(g_allSetups[i]);
         Print("   📊 ", g_allSetups[i].ordersPlaced, " orders placed, 0 filled");
         
      } else {
         // ❌ NO ORDERS, NO TRADES - EA WAS OFFLINE
         Print("   ❌ NO ORDERS FOUND → EA was offline, marking as MISSED");
         
         g_allSetups[i].state = SETUP_TAPPED;
         g_allSetups[i].tapped = true;
         g_allSetups[i].tradeStatus = TRADE_STATUS_MISSED;
         g_allSetups[i].wasMissed = true;
         g_totalSetupsMissed++;
         missedNoOrders++;
      }
      
      RedrawTappedLines(g_allSetups[i]);
   }
   
   Print("\n🔍 ===== REVALIDATION COMPLETE =====");
   Print("Total Checked: ", revalidatedCount);
   Print("  ✅ TRADED: ", tradedCount);
   Print("  ⚠️ MISSED (orders placed): ", missedWithOrders);
   Print("  ❌ MISSED (EA offline): ", missedNoOrders);
   Print("====================================\n");
}


//+------------------------------------------------------------------+
//| ✅ FIXED: Update Order Counts from History                       |
//| Critical Fix: Count DEALS (executions), not order states         |
//+------------------------------------------------------------------+
void UpdateOrderCountsFromHistory(EngulfingSetup &setup) {
   if(!HistorySelect(setup.createdTime, TimeCurrent())) {
      Print("⚠️ Cannot select history for: ", setup.setupID);
      return;
   }
   
   int placedCount = 0;
   int filledCount = 0;
   
   // STEP 1: Count orders PLACED in history
   for(int i = 0; i < HistoryOrdersTotal(); i++) {
      ulong ticket = HistoryOrderGetTicket(i);
      if(ticket <= 0) continue;
      
      long orderMagic = HistoryOrderGetInteger(ticket, ORDER_MAGIC);
      string orderSymbol = HistoryOrderGetString(ticket, ORDER_SYMBOL);
      
      if(orderMagic == setup.magicNumber && orderSymbol == _Symbol) {
         placedCount++;
      }
   }
   
   // STEP 2: Count orders FILLED by counting ENTRY deals
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      
      long dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      string dealSymbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      
      if(dealMagic == setup.magicNumber && dealSymbol == _Symbol) {
         // Only count ENTRY deals (position opened)
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
            filledCount++;
         }
      }
   }
   
   // Update counters
   setup.ordersPlaced = placedCount;
   setup.ordersFilled = filledCount;
   
   if(placedCount > 0) {
      setup.ordersPlacedFlag = true;
   }
   
   Print("📊 ", setup.setupID, " (Magic:", setup.magicNumber, ") | Placed:", placedCount, " Filled:", filledCount);
}
//+------------------------------------------------------------------+
//| ✅ FIXED: Check if Setup Has Trade History                       |
//| Returns TRUE only if actual DEALS exist                          |
//+------------------------------------------------------------------+
bool CheckSetupTradeHistory(EngulfingSetup &setup) {
   if(!HistorySelect(setup.createdTime, TimeCurrent())) {
      return false;
   }
   
   // Check for ENTRY deals (actual trade executions)
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      
      long dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      string dealSymbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      
      if(dealMagic == setup.magicNumber && dealSymbol == _Symbol) {
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
            return true; // Found execution
         }
      }
   }
   
   return false; // No executions found
}

//+------------------------------------------------------------------+
//| ✅ NEW: Check if Orders Were Placed But Never Filled             |
//+------------------------------------------------------------------+
bool CheckOrdersPlacedButMissed(EngulfingSetup &setup) {
   if(!HistorySelect(setup.createdTime, TimeCurrent())) {
      return false;
   }
   
   bool hasOrders = false;
   bool hasDeals = false;
   
   // Check for orders in history
   for(int i = 0; i < HistoryOrdersTotal(); i++) {
      ulong ticket = HistoryOrderGetTicket(i);
      if(ticket <= 0) continue;
      
      if(HistoryOrderGetInteger(ticket, ORDER_MAGIC) == setup.magicNumber &&
         HistoryOrderGetString(ticket, ORDER_SYMBOL) == _Symbol) {
         hasOrders = true;
         break;
      }
   }
   
   // Check for deals
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == setup.magicNumber &&
         HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
         hasDeals = true;
         break;
      }
   }
   
   // Orders were placed but never filled = MISSED opportunity
   return (hasOrders && !hasDeals);
}

//+------------------------------------------------------------------+
//| ✅ NEW: Check if Orders Were Placed (but not filled)             |
//+------------------------------------------------------------------+
bool CheckOrdersPlacedButNotFilled(EngulfingSetup &setup) {
   if(!HistorySelect(setup.createdTime, TimeCurrent())) {
      return false;
   }
   
   bool hasOrders = false;
   bool hasDeals = false;
   
   // Check for orders
   for(int i = 0; i < HistoryOrdersTotal(); i++) {
      ulong ticket = HistoryOrderGetTicket(i);
      if(ticket <= 0) continue;
      
      if(HistoryOrderGetInteger(ticket, ORDER_MAGIC) == setup.magicNumber &&
         HistoryOrderGetString(ticket, ORDER_SYMBOL) == _Symbol) {
         hasOrders = true;
         break;
      }
   }
   
   // Check for deals
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == setup.magicNumber &&
         HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
         hasDeals = true;
         break;
      }
   }
   
   // Orders placed but not filled = setup was tapped but missed
   return (hasOrders && !hasDeals);
}


//+------------------------------------------------------------------+
//| Check if Range Was Tapped Since Setup Creation                   |
//| Scans price history from setup creation to now                   |
//+------------------------------------------------------------------+
bool CheckIfRangeTappedSinceCreation(EngulfingSetup &setup) {
   // Get the bar index when setup was created
   int startBar = iBarShift(_Symbol, PERIOD_H1, setup.engulfingTime);
   if(startBar == -1) {
      DebugPrint("Cannot find bar for setup: " + setup.setupID);
      return false;
   }
   
   // Scan from setup creation to current bar
   for(int i = startBar; i >= 0; i--) {
      datetime barTime = iTime(_Symbol, PERIOD_H1, i);
      
      // Skip the engulfing candle itself
      if(barTime == setup.engulfingTime) continue;
      
      double high = iHigh(_Symbol, PERIOD_H1, i);
      double low = iLow(_Symbol, PERIOD_H1, i);
      
      // Check if this bar touched the range
      if(low <= setup.rangeHigh && high >= setup.rangeLow) {
         setup.tappedTime = barTime;
         return true;
      }
   }
   
   return false;
}
//+------------------------------------------------------------------+