//+------------------------------------------------------------------+
//|                                                    SuperTrendADX |
//|                                      Example Expert Advisor (EA) |
//|   A SuperTrend based trend-following system with ADX confirmation|
//|   and ATR-derived stop-loss management.                          |
//|                                                                  |
//|   This EA demonstrates how to combine the SuperTrend indicator   |
//|   with the Average Directional Index (ADX) to reduce lag in      |
//|   trend-following entries. Stop losses are derived from an ATR   |
//|   multiple to adapt to current volatility.                       |
//|                                                                  |
//|   The code is intentionally verbose and documented so it can     |
//|   serve as a foundation for further customization.               |
//+------------------------------------------------------------------+
#property copyright "OpenAI"
#property link      "https://openai.com"
#property version   "1.00"
#property strict

input double InpLots               = 0.10;   // Default lot size
input int    InpSuperTrendPeriod    = 10;     // SuperTrend ATR period
input double InpSuperTrendMult      = 3.0;    // SuperTrend multiplier
input int    InpADXPeriod           = 14;     // ADX calculation period
input double InpADXThreshold        = 20.0;   // Minimum ADX to allow trades
input int    InpATRPeriodSL         = 14;     // ATR period for stop-loss
input double InpATRMultiplierSL     = 2.5;    // ATR multiplier for stop-loss
input bool   InpUseTrailingStop     = true;   // Enable ATR trailing stop
input double InpTrailingMultiplier  = 1.5;    // ATR multiplier for trailing stop
input bool   InpAllowNewPositions   = true;   // Allow opening new positions
input int    InpMagicNumber         = 4242;   // Magic number for trade identification

//--- internal buffers for SuperTrend calculation
#define MAX_CALC_BARS 1000

double   g_upperBand[];
double   g_lowerBand[];
double   g_superTrend[];
int      g_trendDirection[];

datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   ArrayResize(g_upperBand, MAX_CALC_BARS);
   ArrayResize(g_lowerBand, MAX_CALC_BARS);
   ArrayResize(g_superTrend, MAX_CALC_BARS);
   ArrayResize(g_trendDirection, MAX_CALC_BARS);

   ArraySetAsSeries(g_upperBand, true);
   ArraySetAsSeries(g_lowerBand, true);
   ArraySetAsSeries(g_superTrend, true);
   ArraySetAsSeries(g_trendDirection, true);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(Bars <= InpSuperTrendPeriod + 5)
      return;

   if(Time[0] == g_lastBarTime)
      return;

   g_lastBarTime = Time[0];

   UpdateSuperTrend();
   ManagePositions();
  }

//+------------------------------------------------------------------+
//| Update SuperTrend buffers                                        |
//+------------------------------------------------------------------+
void UpdateSuperTrend()
  {
   int limit = MathMin(Bars - 1, MAX_CALC_BARS - 1);

   for(int i = limit; i >= 0; i--)
     {
      double atr = iATR(Symbol(), PERIOD_CURRENT, InpSuperTrendPeriod, i);
      double hl2 = (High[i] + Low[i]) / 2.0;
      double upperBasic = hl2 + InpSuperTrendMult * atr;
      double lowerBasic = hl2 - InpSuperTrendMult * atr;

      if(i == limit)
        {
         g_upperBand[i] = upperBasic;
         g_lowerBand[i] = lowerBasic;
         g_trendDirection[i] = (Close[i] >= hl2 ? 1 : -1);
        }
      else
        {
         int next = i + 1;

         if(Close[next] > g_upperBand[next])
            g_upperBand[i] = MathMin(upperBasic, g_upperBand[next]);
         else
            g_upperBand[i] = upperBasic;

         if(Close[next] < g_lowerBand[next])
            g_lowerBand[i] = MathMax(lowerBasic, g_lowerBand[next]);
         else
            g_lowerBand[i] = lowerBasic;

         if(g_trendDirection[next] == 1)
           {
            if(Close[i] < g_lowerBand[i])
               g_trendDirection[i] = -1;
            else
               g_trendDirection[i] = 1;
           }
         else if(g_trendDirection[next] == -1)
           {
            if(Close[i] > g_upperBand[i])
               g_trendDirection[i] = 1;
            else
               g_trendDirection[i] = -1;
           }
         else
            g_trendDirection[i] = g_trendDirection[next];
        }

      g_superTrend[i] = (g_trendDirection[i] == 1 ? g_lowerBand[i] : g_upperBand[i]);
     }
  }

//+------------------------------------------------------------------+
//| Manage positions based on current signals                        |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   int trendDir = g_trendDirection[0];
   double currentSuperTrend = g_superTrend[0];

   double adxValue = iADX(Symbol(), PERIOD_CURRENT, InpADXPeriod, PRICE_CLOSE, MODE_MAIN, 0);
   double plusDI   = iADX(Symbol(), PERIOD_CURRENT, InpADXPeriod, PRICE_CLOSE, MODE_PLUSDI, 0);
   double minusDI  = iADX(Symbol(), PERIOD_CURRENT, InpADXPeriod, PRICE_CLOSE, MODE_MINUSDI, 0);

   bool adxStrong = (adxValue >= InpADXThreshold);

   int directionSignal = 0;
   if(trendDir == 1 && adxStrong && plusDI > minusDI)
      directionSignal = 1;
   else if(trendDir == -1 && adxStrong && minusDI > plusDI)
      directionSignal = -1;

   RefreshRates();

   if(directionSignal == 1)
     {
      ClosePositions(-1);
      if(InpAllowNewPositions)
         OpenPosition(ORDER_TYPE_BUY, currentSuperTrend);
     }
   else if(directionSignal == -1)
     {
      ClosePositions(1);
      if(InpAllowNewPositions)
         OpenPosition(ORDER_TYPE_SELL, currentSuperTrend);
     }

   if(InpUseTrailingStop)
      ApplyTrailingStop();
  }

//+------------------------------------------------------------------+
//| Close positions of the specified direction                       |
//+------------------------------------------------------------------+
void ClosePositions(int directionToClose)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderMagicNumber() != InpMagicNumber || OrderSymbol() != Symbol())
         continue;

      if((directionToClose == 1 && OrderType() == OP_BUY) ||
         (directionToClose == -1 && OrderType() == OP_SELL) ||
         (directionToClose == 0))
        {
         bool closed = OrderClose(OrderTicket(), OrderLots(),
                                  (OrderType() == OP_BUY ? Bid : Ask),
                                  3, clrRed);
         if(!closed)
            Print("OrderClose failed: ", GetLastError());
        }
     }
  }

//+------------------------------------------------------------------+
//| Open a new position                                               |
//+------------------------------------------------------------------+
void OpenPosition(int orderType, double referencePrice)
  {
   // referencePrice is provided for potential custom placement logic.
   // When positive, it is incorporated into stop placement to keep the
   // parameter meaningful even for market executions.

   if(CountOpenPositions(orderType) > 0)
      return;

   double atr = iATR(Symbol(), PERIOD_CURRENT, InpATRPeriodSL, 0);
   double slDistance = atr * InpATRMultiplierSL;

   double lotSize = NormalizeLot(InpLots);
   if(lotSize <= 0)
     {
      Print("Lot size invalid after normalization.");
      return;
     }

   double price = (orderType == ORDER_TYPE_BUY ? Ask : Bid);
   double anchorPrice = (referencePrice > 0.0 ? referencePrice : price);
   double stopLoss = (orderType == ORDER_TYPE_BUY ? anchorPrice - slDistance : anchorPrice + slDistance);
   double takeProfit = 0.0;

   stopLoss = NormalizeDouble(stopLoss, Digits);

   int ticket = OrderSend(Symbol(),
                          (orderType == ORDER_TYPE_BUY ? OP_BUY : OP_SELL),
                          lotSize,
                          price,
                          3,
                          stopLoss,
                          takeProfit,
                          "SuperTrendADX",
                          InpMagicNumber,
                          0,
                          clrDodgerBlue);

   if(ticket < 0)
      Print("OrderSend failed with error ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Apply trailing stop based on ATR                                  |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
  {
   double atr = iATR(Symbol(), PERIOD_CURRENT, InpATRPeriodSL, 0);
   double trailDistance = atr * InpTrailingMultiplier;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderMagicNumber() != InpMagicNumber || OrderSymbol() != Symbol())
         continue;

      if(OrderType() == OP_BUY)
        {
         double newSL = Bid - trailDistance;
         if(newSL > OrderStopLoss())
            ModifyOrderStopLoss(newSL);
        }
      else if(OrderType() == OP_SELL)
        {
         double newSL = Ask + trailDistance;
         if(newSL < OrderStopLoss() || OrderStopLoss() == 0.0)
            ModifyOrderStopLoss(newSL);
        }
     }
  }

//+------------------------------------------------------------------+
//| Modify an order's stop loss                                       |
//+------------------------------------------------------------------+
void ModifyOrderStopLoss(double newSL)
  {
   newSL = NormalizeDouble(newSL, Digits);

   bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL,
                               OrderTakeProfit(), OrderExpiration(), clrYellow);
   if(!modified)
      Print("OrderModify failed: ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Count open positions in a direction                               |
//+------------------------------------------------------------------+
int CountOpenPositions(int orderType)
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderMagicNumber() != InpMagicNumber || OrderSymbol() != Symbol())
         continue;

      if((orderType == ORDER_TYPE_BUY && OrderType() == OP_BUY) ||
         (orderType == ORDER_TYPE_SELL && OrderType() == OP_SELL))
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Normalize lot size respecting broker constraints                  |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
  {
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   int steps = (int)MathFloor((lots - minLot) / lotStep + 0.5);
   double normalized = minLot + steps * lotStep;
   normalized = NormalizeDouble(normalized, 2);

   double marginCheck = AccountFreeMarginCheck(Symbol(), OP_BUY, normalized);
   if(marginCheck <= 0)
     {
      Print("Not enough free margin for lot size ", normalized);
      return(0.0);
     }

   return(normalized);
  }

//+------------------------------------------------------------------+
//| Constants for order type naming (compatibility helper)            |
//+------------------------------------------------------------------+
#define ORDER_TYPE_BUY  0
#define ORDER_TYPE_SELL 1
//+------------------------------------------------------------------+
