//+------------------------------------------------------------------+
//|                                                      bot_v3.mq5  |
//|  XAUUSD Adaptive Regime / Event-Score EA                         |
//|                                                                  |
//|  Architecture (per spec):                                        |
//|    MARKET -> DETECTION -> REGIME -> HTF CONTEXT -> STRUCTURE/ZONES|
//|           -> EVENT ENGINE -> DYNAMIC SCORE (BUY vs SELL)         |
//|           -> EXECUTION (2 LEGS) -> PROFIT LOCK -> STRUCTURE TRAIL |
//|           -> BREAKOUT RUNNER -> EXIT ENGINE -> RE-EVALUATE       |
//|                                                                  |
//|  The v2 Bollinger-wick core and its hard boolean filter chain are|
//|  replaced by an additive score engine so detection stays         |
//|  sensitive while the DECISION is what gets strict.               |
//|                                                                  |
//|  CHANGELOG                                                       |
//|  r1  (3.00) initial regime + event-score rewrite of v2           |
//|  r2  (3.05) anti-chase: freshness-scaled event weights, chase    |
//|             guard, fresh-trigger gate, loss cooldown, RANGE      |
//|             edge-fade bonus/mid penalty, zone-state + draw fixes |
//|  r3  (3.10) hold-winners + protect-profit round (A/B/C/D):       |
//|             pip-based locks, M15 structure trail, give-back cap, |
//|             TREND-allowed runner, exit-score gated before trail  |
//|  r4  (3.20) hold-longer + entry-quality + safety round:          |
//|             - SL: structural swing on InpSL_SwingTF (M5), skip   |
//|               trade when the true stop is wider than the cap     |
//|             - trend-aware give-back + wider trail so winners run |
//|             - zone flip / reclaim / failed-retest events scored  |
//|             - session filter, news/volatility-spike guard,       |
//|               log-only mode, single-manager lock (2nd chart RO)  |
//|  r5  (3.30) economics fix ("$10 then breakeven"):               |
//|             - risk-% sizing by default (InpUseFixedLot=false,    |
//|               1.5%/signal) so $-risk/$-reward is consistent      |
//|             - TP1 pushed 1.0R -> 1.5R (bank less early)          |
//|             - InpTriggerMinTF (M5) => cleaner entries on big TF  |
//|  r6  (3.40) entry SENSITIVITY + multi-frame confluence:          |
//|             - loosen entry gate so it actually fires:            |
//|               InpScoreEntry 75->55, InpScoreMinMargin 20->8,     |
//|               Watch/Setup/Strong 40/60/90 -> 30/45/75            |
//|             - trigger gate easier: freshness 6->15 min,          |
//|               InpTriggerMinTF M5->M1, loss cooldown 20->5 min    |
//|             - NEW multi-frame confluence bonus: when >=3 frames  |
//|               agree with the direction (H4/H1/M30/regime-EMA/    |
//|               M5-trigger) add a stacked score bonus so aligned   |
//|               multi-TF setups push the score over the entry bar  |
//+------------------------------------------------------------------+
#property strict
#property version   "3.60"
#property description "Adaptive regime + stateful event engine + dynamic BUY/SELL score. Two-leg TP1+runner or single-leg positions, profit-lock state machine, structure trailing, breakout runner, positive pyramiding/DCA, smart exit engine, full decision logging."

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// INPUTS
//==================================================================
input group "=== Mode / identity ==="
input long          InpMagic             = 300700;      // Magic number

enum ENUM_MIN_LOT_GUARD
  {
   GUARD_NONE = 0,    // NONE: Always allow min lot (Risky)
   GUARD_SAFE = 1     // SAFE: Limit min lot risk to InpMaxMinLotRiskPct
  };
input ENUM_MIN_LOT_GUARD InpMinLotGuard = GUARD_NONE; // Min-Lot Safety Guard
input double             InpMaxMinLotRiskPct = 2.0;   //   Max % risk allowed if SAFE

input bool          InpSkipWideSL        = false;       // [4] FALSE: Clamp SL to max cap. TRUE: Skip trade if SL > cap.
input bool          InpAutoTrade         = true;        // Allow live order execution (attach to a chart to manage)

enum ENUM_POSITIVE_DCA_MODE
  {
   DCA_OFF      = 0,
   DCA_POSITIVE = 1
  };
input ENUM_POSITIVE_DCA_MODE InpPositiveDCAMode = DCA_OFF; // 3rd input: RUNNER_ONLY positive DCA/pyramiding

enum ENUM_ENTRY_EXIT_MODE
  {
   ENTRY_BOTH        = 0,  // BOTH: open TP1 + Runner
   ENTRY_TP_ONLY     = 1,  // TP ONLY: open TP1 only
   ENTRY_RUNNER_ONLY = 2   // RUNNER ONLY: open runner only
  };
input ENUM_ENTRY_EXIT_MODE InpEntryExitMode = ENTRY_RUNNER_ONLY; // >>> CHOOSE: BOTH / TP_ONLY / RUNNER_ONLY
input int           InpDCA_MaxAdds            = 2;          // Maximum positive pyramid adds per root runner
input double        InpDCA_FirstAtR           = 4.0;        // First add after root runner reaches this R
input double        InpDCA_StepR              = 3.0;        // Additional R required for each next add
input double        InpDCA_LotFactor          = 0.50;       // DCA lot = root/current runner lot * factor
input double        InpDCA_MaxLossPctProfit   = 25.0;       // New DCA worst-case loss <= this % of root runner floating profit
input bool          InpDCA_RequireTrend       = true;       // Require aligned TREND/BREAKOUT before adding
input bool          InpManagePositions   = true;        // This instance manages open tickets (keep ONE manager)
input bool          InpShowDashboard     = true;        // Show status dashboard
input bool          InpVerboseLog        = true;        // Print every scored decision (audit trail)
input bool          InpWriteCSV          = false;       // Also append decisions to MQL5/Files/bot_v3_log.csv

input group "=== Risk / sizing ==="
input bool          InpUseFixedLot      = false;        // Use fixed lot (else risk-%). FALSE = risk-% so $-risk is consistent
input double        InpFixedLot         = 0.01;         // Lot per leg when fixed
input double        InpRiskPerOrderPct  = 1.0;          // % equity risked per signal (both legs) when not fixed
input double        InpMaxLot           = 2.0;          // Hard lot cap per leg
input bool          InpAllowMinLot      = true;         // Fall back to broker min lot on small accounts
input int           InpMaxOpenPositions = 2;            // Max EA positions total (avoid correlated churn)
input int           InpMaxSpreadPoints  = 400;          // Reject entries above this spread (points)
input int           InpMaxSlippagePoints= 50;           // Execution slippage (points)
input double        InpDailyLossStopPct = 4.0;          // Halt new entries after this daily drawdown % (0=off)

input group "=== SL / legs ==="
input double        InpGoldPipSize      = 0.01;         // One XAU pip in price units
input bool          InpUseSmartSL       = true;         // Smart invalidation: HTF OB/FVG + swing + liquidity sweep
input double        InpSmartSL_ZoneATR  = 0.60;         // Max distance from current price for a zone to be considered a reaction/retest
input double        InpSmartSL_BufferATR= 0.20;         // Extra breathing room beyond the invalidation extreme
input double        InpSmartSL_MinATR   = 0.65;         // Minimum stop distance when Smart SL is used
input double        InpSmartSL_MaxATR   = 4.50;         // Maximum stop distance before skip/clamp
input bool          InpSmartSL_UseSweep = true;         // Include recent HTF liquidity sweep as invalidation candidate
input bool          InpSmartSL_UseFVG   = false;        // Use FVG edge as a secondary invalidation candidate
input double        InpSL_ATR_Buffer    = 0.25;         // Fallback SL buffer beyond structure extreme (ATR mult)
input double        InpMinSLPips        = 400.0;        // Minimum structural stop (pips) (400 pips = $4)
input double        InpMaxSLPips        = 600.0;        // Maximum structural stop (pips) (600 pips = $6 at 0.01 lot)
input double        InpTP1_RR           = 1.25;         // TP target in R when TP leg is enabled
input bool          InpUseBrokerSLTP    = true;         // Send real SL/TP to broker
input bool          InpRetryRunner      = true;          // Retry runner if broker rejects the first request
input int           InpRunnerRetryMs    = 150;           // Delay between runner retries (ms)
input bool          InpRequireBothLegs  = true;          // BOTH mode: if either leg fails, close the other leg
input double        InpBothRiskFraction = 0.50;          // Risk fraction per leg in BOTH mode (0.50 = total risk ~= configured risk)
input ENUM_TIMEFRAMES InpSL_SwingTF     = PERIOD_M5;    // TF for the structural SL swing (M1 is too noisy/easily swept)

input group "=== Profit protection state machine (R-based or Fixed Points) ==="
input bool          InpUseFixedPointsProtect = true;    // Use fixed points (e.g. 4.0 = $4 on 0.01 lot) instead of R-based
input double        InpProtectAtPoints  = 6.0;          // Protect after this many points (6.0 = $6 on 0.01 lot)
input double        InpProtectLockPoints= 0.5;          // Lock this many points (0.5 = $0.50 on 0.01 lot)
input double        InpProtectAtR       = 2.00;         // Do NOT tighten before runner reaches this R (if not using Fixed Points)
input double        InpProtectLockR     = 0.25;         // At ProtectAtR, lock only this R (room to breathe)
input double        InpLockAtR          = 3.00;         // Stronger lock after this R
input double        InpLockProfitR      = 0.75;         // Lock this much R above/below entry
input double        InpTrailArmR        = 3.00;         // Structure trail starts here
input double        InpRunnerArmR       = 4.00;         // Breakout runner mode starts here
input bool          InpUseStructureTrail= true;         // Trail SL under HH/HL (BUY) or over LH/LL (SELL)
input double        InpTrailATRBuffer   = 1.50;         // Structure trail buffer (ATR mult)
input double        InpTrailMinATR      = 0.75;         // Minimum live price-to-SL distance while trailing
input ENUM_TIMEFRAMES InpTrailTF        = PERIOD_H4;    // Timeframe for structure trail HH/HL (BUY) or LH/LL (SELL)
input int           InpGiveBackPct      = 0;           // Max % of peak floating profit to give back before closing (0=off)
input double        InpGiveBackMinUSD   = 999999.0;          // Min peak floating $ before give-back rule applies
input bool          InpHoldLonger       = true;         // Let winners run: trend-aware give-back + wider trail while aligned TREND/BREAKOUT
input int           InpGiveBackPctTrend = 0;           // Give-back % allowed while runner is in an aligned TREND/BREAKOUT (looser = hold longer)
input double        InpTrailBufferTrend = 0.90;

input bool          InpPeakTrailOn      = false;      // Trail SL behind the peak price (secures profits as price advances)
input double        InpPeakTrailATR     = 1.50;       // SL distance behind peak extreme, in ATR

input group "=== Exit engine (spec 16-18) ==="
input int           InpExitWarnScore    = 999;           // Exit score against runner => tighten SL (WARNING)
input int           InpExitCloseScore   = 999;           // Exit score against runner => close it (REVERSAL)
input bool          InpExitOnlyBeforeTrail = true;      // Exit-score close only while stage<3 (trail decides after)
input bool          InpExitOnHTFReversal= false;         // Close runner on confirmed HTF structure reversal

input group "=== Session / news / logging / safety ==="
input bool          InpUseSessionFilter = false;        // Only enter inside the session window below (server time)
input int           InpSessionStartHour = 7;            // Session start hour (server, inclusive)
input int           InpSessionEndHour   = 20;           // Session end hour (server, exclusive)
input bool          InpBlockNewsSpike   = true;         // Block new entries on an abnormal M1 volatility / spread spike
input double        InpNewsSpikeATR     = 3.0;          // Last closed M1 bar range > this*ATR => treat as news spike
input double        InpNewsSpreadMult   = 2.0;          // Live spread > this*smoothed-average => treat as news spike (0=off)
input bool          InpLogOnlyMode      = false;        // Score+log every decision but NEVER place orders (backtest data collection)
input bool          InpSingleManagerLock= true;         // Prevent a 2nd chart (same magic+symbol) from managing the same tickets

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTFContextMajor= PERIOD_H4;     // Major context
input ENUM_TIMEFRAMES InpTFContext     = PERIOD_H1;     // Market context
input ENUM_TIMEFRAMES InpTFStructure   = PERIOD_M30;    // Intermediate structure
input ENUM_TIMEFRAMES InpTFSetup       = PERIOD_M15;    // Setup / location
input ENUM_TIMEFRAMES InpTFConfirm     = PERIOD_M5;     // Confirmation
input ENUM_TIMEFRAMES InpTFTrigger     = PERIOD_M1;     // Entry trigger
input ENUM_TIMEFRAMES InpTFRegime      = PERIOD_M15;    // Regime classification timeframe

input group "=== Score thresholds (spec section 8) ==="
input int           InpScoreWatch        = 30;          // >= WATCH
input int           InpScoreSetup        = 45;          // >= SETUP
input int           InpScoreEntry        = 55;          // >= ENTRY (fires a trade)
input int           InpScoreStrong       = 75;          // >= STRONG ENTRY
input int           InpScoreMinMargin    = 8;           // Winning side must beat losing side by this
input double        InpScoreDecayMinutes = 25.0;        // Event confidence decays over this many minutes

input group "=== Score weights (positive) ==="
input int           InpW_HTFContext      = 15;          // H1/H4 bias aligned with direction
input int           InpW_RegimeTrend     = 12;          // Regime TREND aligned
input int           InpW_RegimeBreakout  = 15;          // Regime BREAKOUT aligned
input int           InpW_RegimeRange     = 8;           // Regime RANGE fade-from-edge aligned
input int           InpW_Structure       = 10;          // M30 structure (BOS) aligned
input int           InpW_ZoneOB          = 8;           // Fresh/tested OB in favour
input int           InpW_ZoneFVG         = 8;           // Fresh/tested FVG in favour
input int           InpW_BOS             = 12;          // BOS event (M5/M15)
input int           InpW_CHOCH           = 12;          // CHOCH event supporting direction
input int           InpW_Displacement    = 15;          // Displacement event
input int           InpW_Sweep           = 10;          // Liquidity sweep then reversal
input int           InpW_Volume          = 8;           // Volume expansion
input int           InpW_Trigger         = 10;          // M1 reaction/trigger
input int           InpW_EMA             = 5;           // EMA alignment

input group "=== Score weights (negative) ==="
input int           InpN_HTFAgainst      = 20;          // HTF supply/demand reaction against
input int           InpN_CHOCHAgainst    = 15;          // CHOCH against direction
input int           InpN_ZoneInvalid     = 15;          // Supporting zone failed/invalidated
input int           InpN_FailedBreakout  = 20;          // Failed breakout against
input int           InpN_WeakVolume      = 8;           // Weak volume on a breakout attempt
input int           InpN_ExtremeSpread   = 20;          // Spread beyond limit

input group "=== Entry quality guards (anti-chase) ==="
input int           InpTriggerFreshMinutes = 15;        // Events younger than this = fresh trigger (full weight)
input double        InpContextEventScale   = 0.5;       // Older events count at this fraction (context, not trigger)
input double        InpMaxChaseATR         = 2.2;       // Block same-dir entry if price beyond this*ATR from EMA with no zone
input int           InpW_RangeEdge         = 10;        // RANGE: bonus fading FROM a Bollinger edge
input int           InpRangeMidPenalty     = 6;         // RANGE: penalty when mid-band (nothing to fade)
input bool          InpRequireFreshTrigger = true;      // Require a fresh M1/M5 event in entry dir (set false if too few trades)
input ENUM_TIMEFRAMES InpTriggerMinTF   = PERIOD_M1;    // Fresh trigger must be on this TF or higher (M1 = more/faster; M5 = cleaner)
input int           InpTransitionPenalty   = 10;        // TRANSITION regime penalty unless fresh CHOCH in dir (0=off)
input int           InpLossCooldownMin     = 5;         // Block same-dir re-entry this many minutes after a loss (0=off)
input int           InpWinCooldownMin      = 60;        // NEW: Block same-dir re-entry after manual close or TP profit (minutes)
input group "=== Multi-frame confluence (NEW r6) ==="
input bool          InpUseMTFConfluence  = true;        // Reward when several timeframes agree with the direction
input int           InpMTFMinFrames      = 3;           // Frames agreeing before the bonus starts (H4,H1,M30,M15-EMA,M5-trigger)
input int           InpW_MTFConfluence   = 8;           // Bonus per agreeing frame at/above InpMTFMinFrames
input int           InpMTFMaxBonus       = 24;          // Cap on the total confluence bonus

input group "=== Regime classification (spec section 4) ==="
input int           InpADXPeriod         = 14;          // ADX period for trend strength
input double        InpADXTrendMin       = 22.0;        // ADX above this => trending
input double        InpADXRangeMax       = 18.0;        // ADX below this => ranging
input int           InpBBPeriod          = 20;          // Bollinger period (regime width)
input double        InpBBDev             = 2.0;         // Bollinger deviation
input double        InpCompressionWidth  = 0.60;        // BB width / ATR below this => COMPRESSION
input double        InpExpansionATRMult  = 1.30;        // Bar range > this*ATR => expansion impulse
input double        InpDisplacementATR   = 1.10;        // Body > this*ATR => displacement
input int           InpSwingLookback     = 40;          // Bars scanned for swing highs/lows
input int           InpSwingStrength     = 3;           // Fractal strength (bars each side)
input double        InpTrendSlopeATR     = 0.50;        // EMA slope over N bars, in ATR, to call direction

input group "=== Zones (FVG / OB) ==="
input int           InpZoneLookback      = 120;         // Bars scanned per TF for zones
input int           InpMaxZonesPerTF     = 6;           // Keep nearest N zones per timeframe
input double        InpZoneProximityATR  = 0.35;        // Price within this*ATR of a zone counts as "at zone"
input bool          InpDrawZones         = true;        // Draw active FVG/OB zones
input color         InpColorDemand       = C'120,200,140';
input color         InpColorSupply       = C'220,130,130';


//==================================================================
// ENUMS / STRUCTS
//==================================================================
enum EnumRegime
  {
   REGIME_UNKNOWN     = 0,
   REGIME_TREND       = 1,
   REGIME_RANGE       = 2,
   REGIME_BREAKOUT    = 3,
   REGIME_COMPRESSION = 4,
   REGIME_TRANSITION  = 5
  };

enum EnumEventType
  {
   EV_NONE=0, EV_BOS, EV_CHOCH, EV_SWEEP, EV_DISPLACEMENT,
   EV_FVG_NEW, EV_OB_NEW, EV_VOLUME, EV_VOLATILITY,
   EV_BREAKOUT, EV_FAILED_BREAKOUT, EV_REJECTION
  };

enum EnumZoneKind { ZONE_FVG=0, ZONE_OB=1 };

// FVG: FRESH -> TESTED -> MITIGATED -> FAILED
// OB : FRESH -> TESTED -> MITIGATED -> BROKEN -> FLIPPED -> INVALID
enum EnumZoneState
  {
   ZS_FRESH=0, ZS_TESTED, ZS_MITIGATED, ZS_FAILED,
   ZS_BROKEN, ZS_FLIPPED, ZS_INVALID
  };

struct MarketEvent
  {
   int              type;        // EnumEventType
   int              direction;   // +1 bull, -1 bear
   ENUM_TIMEFRAMES  tf;
   double           price;
   double           strength;    // 0..1
   double           confidence;  // 0..1 (decays with age)
   datetime         time;
  };

struct Zone
  {
   int              kind;        // EnumZoneKind
   int              dir;         // +1 demand/bullish, -1 supply/bearish (post-flip aware)
   ENUM_TIMEFRAMES  tf;
   double           hi;
   double           lo;
   datetime         formed;
   int              state;       // EnumZoneState
   int              touches;
   bool             drawn;
   string           objName;
  };

struct SwingPoint
  {
   double           price;
   datetime         time;
   bool             isHigh;
  };

struct VirtualPos
  {
   ulong            ticket;
   int              dir;          // +1 buy, -1 sell
   bool             isRunner;
   bool             isDCA;
   ulong            parentTicket;
   double           entryPrice;
   double           virtualSL;
   double           virtualTP;    // 0 => none
   double           riskDistance; // entry-SL, positive
   int              stage;        // 0 INITIAL,1 PROTECTED,2 PROFIT_LOCK,3 STRUCTURE_TRAIL,4 BREAKOUT_RUNNER
   datetime         openTime;
   datetime         group;        // ties LEG A and LEG B of one signal
   ulong            pairTicket;
   bool             pairTP1Banked;
   double           trailAnchor;  // last swing used for structure trailing
   datetime         lastTrailBar;
   double           peakProfit;   // peak floating profit seen (give-back rule)
   double           peakExtreme;  // extreme price seen since entry (peak-price trail)
  };

//==================================================================
// GLOBALS
//==================================================================
double   g_point=0.0;
int      g_digits=0;
string   g_prefix="BV3_";

int      h_atr[];        // ATR handles indexed by TF slot
ENUM_TIMEFRAMES g_tfs[]; // the TF list we track
int      g_tfCount=0;

// Named handles
int      h_adx_regime=INVALID_HANDLE;
int      h_bb_regime =INVALID_HANDLE;
int      h_atr_regime=INVALID_HANDLE;
int      h_ema_fast  =INVALID_HANDLE;   // on regime TF
int      h_ema_slow  =INVALID_HANDLE;   // on regime TF
int      h_atr_trigger=INVALID_HANDLE;

MarketEvent g_events[];   // active detected events (rolling)
Zone        g_zones[];    // active zones across TFs
VirtualPos  g_vpos[];

// Per-tick computed market snapshot
struct Snapshot
  {
   EnumRegime regime;
   int        regimeDir;      // +1/-1/0 dominant direction
   double     regimeStrength; // 0..1
   double     atrRegime;
   double     atrTrigger;
   double     bbWidth;        // (upper-lower)/atr
   double     bbUpper;
   double     bbLower;
   double     adx;
   double     plusDI;
   double     minusDI;
   double     emaFast;
   double     emaSlow;
   int        htfBiasMajor;   // H4
   int        htfBias;        // H1
   int        structBias;     // M30
   double     bid;
   double     ask;
   double     spreadPoints;
   int        buyScore;
   int        sellScore;
   int        exitBuy;        // exit pressure against a BUY runner (higher = more bearish)
   int        exitSell;       // exit pressure against a SELL runner
   string     buyReasons;
   string     sellReasons;
  };
Snapshot g_snap;

datetime g_lastTriggerBar=0;
datetime g_lastRegimeBar=0;
datetime g_dayStart=0;
double   g_dayEquityStart=0.0;
bool     g_dailyStop=false;
int      g_logHandle=INVALID_HANDLE;
string   g_lastDecision="init";
datetime g_lastLossBuy=0;    // time of last closed loss in BUY dir (cooldown)
datetime g_lastLossSell=0;   // time of last closed loss in SELL dir (cooldown)
datetime g_lastWinBuy=0;     // time of last closed win/manual in BUY dir
datetime g_lastWinSell=0;    // time of last closed win/manual in SELL dir
int      g_zoneObjCount=0;
double   g_spreadEMA=0.0;     // smoothed live spread for the news-spike guard
bool     g_isManager=true;    // false if another live instance owns the manager lock
string   g_lockKey="";        // GlobalVariable name of the single-manager lock

// Cached swing points per TF slot for BOS/CHOCH
SwingPoint g_swings[];   // flattened: [tfSlot*MAXSW + i]
#define MAXSW 60

//==================================================================
// SMALL HELPERS
//==================================================================
double NPrice(double p){ return NormalizeDouble(p,g_digits); }

int TfSlot(ENUM_TIMEFRAMES tf)
  {
   for(int i=0;i<g_tfCount;i++) if(g_tfs[i]==tf) return i;
   return -1;
  }

double ATR(ENUM_TIMEFRAMES tf,int shift=0)
  {
   int h=(tf==InpTFRegime)?h_atr_regime:((tf==InpTFTrigger)?h_atr_trigger:INVALID_HANDLE);
   int slot=TfSlot(tf);
   if(h==INVALID_HANDLE && slot>=0) h=h_atr[slot];
   if(h==INVALID_HANDLE) return 0.0;
   double b[1];
   if(CopyBuffer(h,0,shift,1,b)<1) return 0.0;
   return b[0];
  }

double EmaVal(int handle,int shift=0)
  {
   if(handle==INVALID_HANDLE) return 0.0;
   double b[1];
   if(CopyBuffer(handle,0,shift,1,b)<1) return 0.0;
   return b[0];
  }

bool SpreadOK(){ return g_snap.spreadPoints<=InpMaxSpreadPoints; }

double CurrentSpreadPoints()
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return (g_point>0?(ask-bid)/g_point:0.0);
  }

int CountEA()
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) c++;
     }
   return c;
  }

double BasketFloating()
  {
   double s=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic)
         s+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return s;
  }

bool IsTradeAllowed()
  {
   if(!InpAutoTrade) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return false;
   return true;
  }

double NormalizeLot(double lot)
  {
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   lot=MathFloor(lot/step)*step;
   lot=MathMax(minLot,MathMin(maxLot,lot));
   if(InpMaxLot>0) lot=MathMin(lot,InpMaxLot);
   return NormalizeDouble(lot,2);
  }

// Money lost if price travels 'distance' for 'lot'
double TickLossPerLot(double distance)
  {
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0) return 0.0;
   return distance/ts*tv;
  }

double CalcLotByRisk(double riskMoney,double distance)
  {
   if(distance<=0||riskMoney<=0) return 0.0;
   double perLot=TickLossPerLot(distance);
   if(perLot<=0) return 0.0;
   return riskMoney/perLot;
  }

string RegimeStr(EnumRegime r)
  {
   switch(r)
     {
      case REGIME_TREND:       return "TREND";
      case REGIME_RANGE:       return "RANGE";
      case REGIME_BREAKOUT:    return "BREAKOUT";
      case REGIME_COMPRESSION: return "COMPRESSION";
      case REGIME_TRANSITION:  return "TRANSITION";
     }
   return "UNKNOWN";
  }

string BiasStr(int b){ return b>0?"BULL":(b<0?"BEAR":"NEUTRAL"); }

//==================================================================
// DAILY BASELINE / LOSS GUARD
//==================================================================
string DailyKey(){ return g_prefix+"DAY_"+IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"_"+IntegerToString((int)InpMagic)+"_"+_Symbol; }

void InitializeDailyBaseline()
  {
   datetime now=TimeCurrent();
   MqlDateTime dt; TimeToStruct(now,dt);
   dt.hour=0;dt.min=0;dt.sec=0;
   g_dayStart=StructToTime(dt);
   string k=DailyKey();
   if(GlobalVariableCheck(k+"_D") && (datetime)GlobalVariableGet(k+"_D")==g_dayStart)
     {
      g_dayEquityStart=GlobalVariableGet(k+"_E");
      g_dailyStop=(GlobalVariableCheck(k+"_S")&&GlobalVariableGet(k+"_S")>0.5);
     }
   else
     {
      g_dayEquityStart=AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyStop=false;
      GlobalVariableSet(k+"_D",(double)g_dayStart);
      GlobalVariableSet(k+"_E",g_dayEquityStart);
      GlobalVariableSet(k+"_S",0.0);
     }
  }

void CheckLossGuards()
  {
   if(InpDailyLossStopPct<=0||g_dayEquityStart<=0) return;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double dd=(g_dayEquityStart-eq)/g_dayEquityStart*100.0;
   if(dd>=InpDailyLossStopPct && !g_dailyStop)
     {
      g_dailyStop=true;
      GlobalVariableSet(DailyKey()+"_S",1.0);
      PrintFormat("[BV3] Daily loss stop armed at %.2f%% drawdown. New entries halted.",dd);
     }
  }

//==================================================================
// SWING / STRUCTURE
//==================================================================
// Detect fractal swings on a TF into g_swings slot. Newest first ordering not
// required; we keep chronological and scan as needed.
void BuildSwings(ENUM_TIMEFRAMES tf,int slot)
  {
   int need=InpSwingLookback+InpSwingStrength*2+4;
   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,tf,0,need,r)<need) return;
   int s=InpSwingStrength;
   int base=slot*MAXSW;
   int cnt=0;
   // r[] is series: r[0] newest. Iterate from oldest valid to newest.
   for(int i=need-1-s;i>=s && cnt<MAXSW-1;i--)
     {
      bool isHigh=true,isLow=true;
      for(int k=1;k<=s;k++)
        {
         if(r[i].high<=r[i-k].high||r[i].high<=r[i+k].high) isHigh=false;
         if(r[i].low >=r[i-k].low ||r[i].low >=r[i+k].low ) isLow=false;
        }
      if(isHigh){ g_swings[base+cnt].price=r[i].high;g_swings[base+cnt].time=r[i].time;g_swings[base+cnt].isHigh=true;cnt++; }
      if(isLow && cnt<MAXSW-1){ g_swings[base+cnt].price=r[i].low;g_swings[base+cnt].time=r[i].time;g_swings[base+cnt].isHigh=false;cnt++; }
     }
   // terminator
   g_swings[base+cnt].time=0;g_swings[base+cnt].price=0;g_swings[base+cnt].isHigh=false;
  }

// Most recent swing high/low on a TF slot
bool LastSwingHigh(int slot,double &price,datetime &time)
  {
   int base=slot*MAXSW; price=0;time=0;
   for(int i=0;i<MAXSW;i++)
     {
      if(g_swings[base+i].time==0) break;
      if(g_swings[base+i].isHigh && g_swings[base+i].time>time){ time=g_swings[base+i].time;price=g_swings[base+i].price; }
     }
   return time>0;
  }
bool LastSwingLow(int slot,double &price,datetime &time)
  {
   int base=slot*MAXSW; price=0;time=0;
   for(int i=0;i<MAXSW;i++)
     {
      if(g_swings[base+i].time==0) break;
      if(!g_swings[base+i].isHigh && g_swings[base+i].time>time){ time=g_swings[base+i].time;price=g_swings[base+i].price; }
     }
   return time>0;
  }
// Second-most-recent (previous) swing for HH/HL detection
bool PrevSwingHigh(int slot,double &price)
  {
   int base=slot*MAXSW; double last=0,prev=0; datetime lt=0;
   for(int i=0;i<MAXSW;i++)
     {
      if(g_swings[base+i].time==0) break;
      if(g_swings[base+i].isHigh)
        {
         if(g_swings[base+i].time>lt){ prev=last;last=g_swings[base+i].price;lt=g_swings[base+i].time; }
        }
     }
   price=prev; return prev>0;
  }
bool PrevSwingLow(int slot,double &price)
  {
   int base=slot*MAXSW; double last=0,prev=0; datetime lt=0;
   for(int i=0;i<MAXSW;i++)
     {
      if(g_swings[base+i].time==0) break;
      if(!g_swings[base+i].isHigh)
        {
         if(g_swings[base+i].time>lt){ prev=last;last=g_swings[base+i].price;lt=g_swings[base+i].time; }
        }
     }
   price=prev; return prev>0;
  }

//==================================================================
// HTF BIAS  (close vs EMA + swing direction)
//==================================================================
int CalcHTFBias(ENUM_TIMEFRAMES tf)
  {
   int eF=iMA(_Symbol,tf,20,0,MODE_EMA,PRICE_CLOSE);
   int eS=iMA(_Symbol,tf,50,0,MODE_EMA,PRICE_CLOSE);
   if(eF==INVALID_HANDLE||eS==INVALID_HANDLE) return 0;
   double f[1],s[1];
   if(CopyBuffer(eF,0,1,1,f)<1||CopyBuffer(eS,0,1,1,s)<1){ IndicatorRelease(eF);IndicatorRelease(eS);return 0; }
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,tf,1,1,r)<1){ IndicatorRelease(eF);IndicatorRelease(eS);return 0; }
   int bias=0;
   if(r[0].close>f[0]&&f[0]>s[0]) bias=1;
   else if(r[0].close<f[0]&&f[0]<s[0]) bias=-1;
   IndicatorRelease(eF);IndicatorRelease(eS);
   return bias;
  }

//==================================================================
// REGIME ENGINE (spec section 4)
//==================================================================
void ClassifyRegime()
  {
   // ADX / DI
   double adxB[3],pdi[1],mdi[1];
   if(CopyBuffer(h_adx_regime,0,0,3,adxB)>=3){ g_snap.adx=adxB[0]; }
   if(CopyBuffer(h_adx_regime,1,0,1,pdi)>=1) g_snap.plusDI=pdi[0];
   if(CopyBuffer(h_adx_regime,2,0,1,mdi)>=1) g_snap.minusDI=mdi[0];

   // BB width relative to ATR
   double up[1],lo[1],mid[1];
   CopyBuffer(h_bb_regime,1,0,1,up);   // upper
   CopyBuffer(h_bb_regime,2,0,1,lo);   // lower
   CopyBuffer(h_bb_regime,0,0,1,mid);  // middle
   double atr=g_snap.atrRegime;
   g_snap.bbWidth=(atr>0?(up[0]-lo[0])/atr:0.0);
   g_snap.bbUpper=up[0];
   g_snap.bbLower=lo[0];

   double ef=EmaVal(h_ema_fast,1), es=EmaVal(h_ema_slow,1);
   double efPrev=EmaVal(h_ema_fast,10);
   g_snap.emaFast=ef; g_snap.emaSlow=es;
   double slope=(atr>0?(ef-efPrev)/atr:0.0);

   // Directional intent
   int dir=0;
   if(slope> InpTrendSlopeATR) dir=1;
   else if(slope< -InpTrendSlopeATR) dir=-1;
   else if(g_snap.plusDI>g_snap.minusDI+4) dir=1;
   else if(g_snap.minusDI>g_snap.plusDI+4) dir=-1;
   g_snap.regimeDir=dir;

   // Latest closed bar expansion test
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,InpTFRegime,1,3,r)<3) return;
   double body=MathAbs(r[0].close-r[0].open);
   double range=r[0].high-r[0].low;
   bool expansion=(atr>0 && range>=InpExpansionATRMult*atr);
   bool displacement=(atr>0 && body>=InpDisplacementATR*atr &&
                      ((r[0].close>r[0].open&&dir>=0)||(r[0].close<r[0].open&&dir<=0)));

   // COMPRESSION: narrow band, low atr, no expansion
   bool compression=(g_snap.bbWidth>0 && g_snap.bbWidth<InpCompressionWidth && !expansion);

   EnumRegime reg=REGIME_UNKNOWN;
   double strength=0.0;

   if(compression)
     {
      // If an expansion just fired out of compression => BREAKOUT, else COMPRESSION
      if(expansion&&displacement&&dir!=0){ reg=REGIME_BREAKOUT; strength=MathMin(1.0,range/(atr*2.0)); }
      else { reg=REGIME_COMPRESSION; strength=MathMin(1.0,(InpCompressionWidth-g_snap.bbWidth)/MathMax(0.0001,InpCompressionWidth)); }
     }
   else if(g_snap.adx>=InpADXTrendMin && dir!=0)
     {
      reg=REGIME_TREND;
      strength=MathMin(1.0,(g_snap.adx-InpADXTrendMin)/30.0+ (displacement?0.25:0.0));
      // A fresh expansion impulse inside a trend can be treated as breakout continuation
      if(expansion&&displacement) { reg=REGIME_BREAKOUT; strength=MathMin(1.0,strength+0.2); }
     }
   else if(g_snap.adx<=InpADXRangeMax)
     {
      reg=REGIME_RANGE;
      strength=MathMin(1.0,(InpADXRangeMax-g_snap.adx)/InpADXRangeMax);
     }
   else
     {
      // Between thresholds: TRANSITION (structure changing) or weak trend
      reg=REGIME_TRANSITION;
      strength=0.4;
     }

   // TRANSITION override: a very recent CHOCH + sweep means direction is flipping
   for(int i=0;i<ArraySize(g_events);i++)
      if(g_events[i].type==EV_CHOCH && (TimeCurrent()-g_events[i].time)<PeriodSeconds(InpTFRegime)*3)
        { reg=REGIME_TRANSITION; g_snap.regimeDir=g_events[i].direction; strength=MathMax(strength,0.6); break; }

   g_snap.regime=reg;
   g_snap.regimeStrength=strength;
  }

//==================================================================
// EVENT ENGINE (spec sections 5-6)
//==================================================================
void ClearEventsOlderThan(int minutes)
  {
   datetime cutoff=TimeCurrent()-minutes*60;
   for(int i=ArraySize(g_events)-1;i>=0;i--)
      if(g_events[i].time<cutoff)
        {
         int last=ArraySize(g_events)-1;
         if(i<last) g_events[i]=g_events[last];
         ArrayResize(g_events,last);
        }
  }

void AddEvent(int type,int dir,ENUM_TIMEFRAMES tf,double price,double strength)
  {
   int n=ArraySize(g_events);
   ArrayResize(g_events,n+1);
   g_events[n].type=type;
   g_events[n].direction=dir;
   g_events[n].tf=tf;
   g_events[n].price=NPrice(price);
   g_events[n].strength=MathMax(0.0,MathMin(1.0,strength));
   g_events[n].confidence=g_events[n].strength;
   g_events[n].time=TimeCurrent();
  }

// Scan a TF for BOS / CHOCH / sweep / displacement / breakout on the last closed bars
void ScanStructureEvents(ENUM_TIMEFRAMES tf,int slot)
  {
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,tf,0,6,r)<6) return;
   double atr=ATR(tf,1); if(atr<=0) atr=g_snap.atrRegime;
   double sh=0,ph=0,sl=0,pl=0; datetime sht,slt;
   bool hasH=LastSwingHigh(slot,sh,sht);
   bool hasL=LastSwingLow(slot,sl,slt);
   PrevSwingHigh(slot,ph); PrevSwingLow(slot,pl);

   MqlRates c=r[1]; // last closed bar
   double body=MathAbs(c.close-c.open);
   double range=c.high-c.low;

   // Displacement
   if(atr>0 && body>=InpDisplacementATR*atr)
     {
      int d=(c.close>c.open?1:-1);
      AddEvent(EV_DISPLACEMENT,d,tf,c.close,MathMin(1.0,body/(atr*2.0)));
     }

   // BOS: close beyond last swing in the swing's breakout direction
   if(hasH && c.close>sh)
     {
      double str=atr>0?MathMin(1.0,(c.close-sh)/atr):0.5;
      AddEvent(EV_BOS,1,tf,sh,MathMax(0.5,str));
     }
   if(hasL && c.close<sl)
     {
      double str=atr>0?MathMin(1.0,(sl-c.close)/atr):0.5;
      AddEvent(EV_BOS,-1,tf,sl,MathMax(0.5,str));
     }

   // CHOCH: break of the swing AGAINST the dominant prior structure
   // Approximation: bullish close beyond last swing high while EMA slope was down => CHOCH up
   double ef=EmaVal(h_ema_fast,1),efp=EmaVal(h_ema_fast,6);
   if(hasH && c.close>sh && ef<efp) AddEvent(EV_CHOCH,1,tf,sh,0.7);
   if(hasL && c.close<sl && ef>efp) AddEvent(EV_CHOCH,-1,tf,sl,0.7);

   // Liquidity sweep: wick pierces a swing but close returns inside
   if(hasH && c.high>sh && c.close<sh)
      AddEvent(EV_SWEEP,-1,tf,sh,atr>0?MathMin(1.0,(c.high-sh)/atr+0.4):0.6);
   if(hasL && c.low<sl && c.close>sl)
      AddEvent(EV_SWEEP,1,tf,sl,atr>0?MathMin(1.0,(sl-c.low)/atr+0.4):0.6);

   // Failed breakout: sweep immediately followed by opposite displacement
   // (handled implicitly by SWEEP + DISPLACEMENT scoring)

   // Volume expansion
   long vol=c.tick_volume;
   long vsum=0; int vcnt=0;
   for(int i=2;i<22&&i<ArraySize(r);i++){ vsum+=r[i].tick_volume; vcnt++; }
   double vavg=(vcnt>0?(double)vsum/(double)vcnt:0.0);
   if(vavg>0 && vol>=1.6*vavg)
      AddEvent(EV_VOLUME,(c.close>=c.open?1:-1),tf,c.close,MathMin(1.0,(vol/vavg-1.0)));

   // Volatility expansion
   if(atr>0 && range>=InpExpansionATRMult*atr)
      AddEvent(EV_VOLATILITY,(c.close>=c.open?1:-1),tf,c.close,MathMin(1.0,range/(atr*2.0)));

   // Rejection (long wick against move)
   if(range>0)
     {
      double upperW=c.high-MathMax(c.open,c.close);
      double lowerW=MathMin(c.open,c.close)-c.low;
      if(upperW>=range*0.55 && upperW>lowerW) AddEvent(EV_REJECTION,-1,tf,c.high,upperW/range);
      if(lowerW>=range*0.55 && lowerW>upperW) AddEvent(EV_REJECTION,1,tf,c.low,lowerW/range);
     }
  }

// ---- Zone detection: FVG + OB with state machine -----------------
int ZoneIndex(int kind,ENUM_TIMEFRAMES tf,double hi,double lo)
  {
   for(int i=0;i<ArraySize(g_zones);i++)
      if(g_zones[i].kind==kind&&g_zones[i].tf==tf&&
         MathAbs(g_zones[i].hi-hi)<g_point&&MathAbs(g_zones[i].lo-lo)<g_point)
         return i;
   return -1;
  }

void AddOrUpdateZone(int kind,int dir,ENUM_TIMEFRAMES tf,double hi,double lo,datetime formed)
  {
   int idx=ZoneIndex(kind,tf,hi,lo);
   if(idx<0)
     {
      int n=ArraySize(g_zones);
      int sameTF=0, oldest=-1; datetime oldestTime=0;
      for(int z=0;z<n;z++)
        {
         if(g_zones[z].tf!=tf) continue;
         sameTF++;
         if(oldest<0 || g_zones[z].formed<oldestTime){ oldest=z; oldestTime=g_zones[z].formed; }
        }
      if(sameTF>=InpMaxZonesPerTF)
        {
         if(oldest<0 || formed<=oldestTime) return;
         if(g_zones[oldest].drawn && g_zones[oldest].objName!="") ObjectDelete(0,g_zones[oldest].objName);
         idx=oldest;
        }
      else
        {
         ArrayResize(g_zones,n+1);
         idx=n;
        }
      g_zones[idx].kind=kind;g_zones[idx].tf=tf;g_zones[idx].hi=hi;g_zones[idx].lo=lo;
      g_zones[idx].formed=formed;g_zones[idx].state=ZS_FRESH;g_zones[idx].touches=0;
      g_zones[idx].drawn=false;g_zones[idx].objName="";g_zones[idx].dir=dir;
     }
  }

void DetectZones(ENUM_TIMEFRAMES tf)
  {
   int look=InpZoneLookback+3;
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,tf,0,look,r)<look) return;
   for(int i=look-3;i>=1;i--)
     {
      // FVG (3-candle imbalance): r[i+1] older ... r[i-1] newer in series terms
      // series: r[i-1] is newer than r[i], r[i+1] older
      if(i-1<0||i+1>=ArraySize(r)) continue;
      MqlRates newer=r[i-1], mid=r[i], older=r[i+1];
      // Bullish FVG: low of newer > high of older (gap up)
      if(newer.low>older.high)
         AddOrUpdateZone(ZONE_FVG,1,tf,newer.low,older.high,mid.time);
      // Bearish FVG: high of newer < low of older (gap down)
      if(newer.high<older.low)
         AddOrUpdateZone(ZONE_FVG,-1,tf,older.low,newer.high,mid.time);

      // OB: last opposite candle before a displacement in mid
      double atr=ATR(tf,i); if(atr<=0) atr=g_snap.atrRegime;
      double midBody=MathAbs(mid.close-mid.open);
      if(atr>0 && midBody>=InpDisplacementATR*atr)
        {
         if(mid.close>mid.open && older.close<older.open) // bull displacement preceded by down candle
            AddOrUpdateZone(ZONE_OB,1,tf,older.high,older.low,older.time);
         if(mid.close<mid.open && older.close>older.open) // bear displacement preceded by up candle
            AddOrUpdateZone(ZONE_OB,-1,tf,older.high,older.low,older.time);
        }
     }
  }

// Update zone states against current price + emit zone events on retest/break
void UpdateZoneStates()
  {
   double bid=g_snap.bid, atr=g_snap.atrRegime;
   for(int i=ArraySize(g_zones)-1;i>=0;i--)
     {
      double hi=g_zones[i].hi, lo=g_zones[i].lo;
      bool touched=(bid<=hi && bid>=lo);
      bool above=(bid>hi), below=(bid<lo);

      // state transitions
      if(touched)
        {
         if(g_zones[i].state==ZS_FRESH){ g_zones[i].state=ZS_TESTED; g_zones[i].touches++;
            AddEvent(g_zones[i].kind==ZONE_OB?EV_OB_NEW:EV_FVG_NEW,g_zones[i].dir,g_zones[i].tf,(hi+lo)/2.0,0.6); }
         else if(g_zones[i].state==ZS_TESTED){ g_zones[i].touches++; }
         else if(g_zones[i].state==ZS_FLIPPED && g_zones[i].touches==0)
           {
            // failed retest / reclaim: price came back to the broken zone and is
            // expected to reject in the flip direction (old S<->R now reversed).
            g_zones[i].touches++;
            AddEvent(EV_REJECTION,g_zones[i].dir,g_zones[i].tf,(hi+lo)/2.0,0.55);
           }
        }

      // mitigation: price traded fully through the zone
      bool mitigated=(g_zones[i].dir>0? below : above);
      if((g_zones[i].state==ZS_FRESH||g_zones[i].state==ZS_TESTED) && mitigated)
        {
         // OB can break then flip (S<->R). FVG becomes failed.
         if(g_zones[i].kind==ZONE_OB)
           {
            g_zones[i].state=ZS_BROKEN;
            // flip direction: broken demand becomes supply
            g_zones[i].dir=-g_zones[i].dir;
            g_zones[i].state=ZS_FLIPPED;
            g_zones[i].touches=0;   // arm the reclaim / failed-retest detector
            // an OB breaking is a structure shift in the new (break) direction
            AddEvent(EV_CHOCH,g_zones[i].dir,g_zones[i].tf,(hi+lo)/2.0,0.60);
           }
         else
           {
            g_zones[i].state=ZS_FAILED;
            // price traded fully through the FVG => a break against its direction
            AddEvent(EV_BOS,-g_zones[i].dir,g_zones[i].tf,(hi+lo)/2.0,0.50);
           }
        }

      // drop dead zones after they've been consumed and price moved far away
      double dist=atr>0?MathAbs(bid-(hi+lo)/2.0)/atr:999;
      if((g_zones[i].state==ZS_FAILED||g_zones[i].state==ZS_MITIGATED) && dist>5.0)
        {
         if(g_zones[i].drawn&&g_zones[i].objName!="") ObjectDelete(0,g_zones[i].objName);
         int last=ArraySize(g_zones)-1;
         if(i<last) g_zones[i]=g_zones[last];
         ArrayResize(g_zones,last);
        }
     }
  }

// Is price at a zone favouring 'dir'? returns best zone strength or 0
double ZoneSupportForDir(int dir,ENUM_TIMEFRAMES tf,bool &hadFreshZone)
  {
   double best=0.0; hadFreshZone=false;
   double atr=ATR(tf,1); if(atr<=0) atr=g_snap.atrRegime;
   double bid=g_snap.bid;
   for(int i=0;i<ArraySize(g_zones);i++)
     {
      if(g_zones[i].tf!=tf) continue;
      if(g_zones[i].dir!=dir) continue;
      if(g_zones[i].state==ZS_FAILED||g_zones[i].state==ZS_INVALID||g_zones[i].state==ZS_MITIGATED) continue;
      double dist=atr>0?MathAbs(bid-(g_zones[i].hi+g_zones[i].lo)/2.0)/atr:999;
      if(dist<=InpZoneProximityATR)
        {
         double s=1.0-dist/MathMax(0.0001,InpZoneProximityATR);
         if(g_zones[i].state==ZS_FRESH) hadFreshZone=true;
         if(s>best) best=s;
        }
     }
   return best;
  }

//==================================================================
// DECAY EVENT CONFIDENCE
//==================================================================
void DecayEvents()
  {
   double life=MathMax(1.0,InpScoreDecayMinutes)*60.0;
   for(int i=0;i<ArraySize(g_events);i++)
     {
      double age=(double)(TimeCurrent()-g_events[i].time);
      double f=1.0-age/life; if(f<0)f=0;
      g_events[i].confidence=g_events[i].strength*f;
     }
   ClearEventsOlderThan((int)(InpScoreDecayMinutes*2));
  }

// Sum of confidence for an event type & direction. Fresh events (younger than
// InpTriggerFreshMinutes) count at full weight as TRIGGERS; older events are
// down-weighted to CONTEXT so stale momentum cannot cause late "chasing" entries.
double EventWeight(int type,int dir,ENUM_TIMEFRAMES tfMin=PERIOD_CURRENT)
  {
   double s=0.0;
   datetime freshCut=TimeCurrent()-InpTriggerFreshMinutes*60;
   for(int i=0;i<ArraySize(g_events);i++)
     {
      if(g_events[i].type!=type||g_events[i].direction!=dir) continue;
      if(tfMin!=PERIOD_CURRENT && g_events[i].tf!=tfMin) continue;
      double w=g_events[i].confidence;
      if(g_events[i].time<freshCut) w*=InpContextEventScale;
      s+=w;
     }
   return MathMin(1.5,s);
  }

//==================================================================
// SCORE ENGINE (spec sections 8, 18, 19)
//==================================================================
// Count how many independent timeframes agree with 'dir' (multi-frame confluence).
// Frames checked: H4 bias, H1 bias, M30 structure, M15 regime/EMA, fresh M5/M1 trigger.
int CountMTFAgree(int dir)
  {
   if(dir==0) return 0;
   int n=0;
   if((dir>0&&g_snap.htfBiasMajor>0)||(dir<0&&g_snap.htfBiasMajor<0)) n++;   // H4
   if((dir>0&&g_snap.htfBias>0)||(dir<0&&g_snap.htfBias<0)) n++;             // H1
   if(g_snap.structBias==dir) n++;                                           // M30
   if(g_snap.regimeDir==dir) n++;                                            // M15 regime
   if((dir>0&&g_snap.emaFast>g_snap.emaSlow)||(dir<0&&g_snap.emaFast<g_snap.emaSlow)) n++; // M15 EMA
   if(HasFreshTrigger(dir)) n++;                                             // M5/M1 trigger
   return n;
  }

// Fast intrabar trigger. HTF structure remains context; this only allows
// a genuine live M1 breakout/reclaim before the candle closes.
bool HasLiveTrigger(int dir)
  {
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,InpTFTrigger,0,12,r)<12) return false;
   double atr=ATR(InpTFTrigger,1); if(atr<=0) return false;
   double px=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
   double prevHigh=r[1].high, prevLow=r[1].low, curOpen=r[0].open;
   double curBody=MathAbs(px-curOpen);
   long vsum=0; int n=0;
   for(int i=2;i<12;i++){ vsum+=r[i].tick_volume; n++; }
   double vavg=(n>0?(double)vsum/n:0.0);
   bool volOK=(vavg<=0 || r[0].tick_volume>=vavg*1.10);
   if(dir>0)
     {
      bool breakout=(px>prevHigh+0.05*atr);
      bool reclaim=(r[0].low<=prevLow+0.15*atr && px>curOpen+0.20*atr);
      return volOK&&(breakout||reclaim)&&curBody>=0.15*atr;
     }
   else
     {
      bool breakout=(px<prevLow-0.05*atr);
      bool reclaim=(r[0].high>=prevHigh-0.15*atr && px<curOpen-0.20*atr);
      return volOK&&(breakout||reclaim)&&curBody>=0.15*atr;
     }
  }

int ScoreDirection(int dir,string &reasons)
  {
   int score=0; reasons="";
   // --- HTF context ---
   if((dir>0&&g_snap.htfBias>0)||(dir<0&&g_snap.htfBias<0)){ score+=InpW_HTFContext; reasons+="HTF+ "; }
   if((dir>0&&g_snap.htfBiasMajor>0)||(dir<0&&g_snap.htfBiasMajor<0)){ score+=InpW_HTFContext/2; reasons+="H4+ "; }
   if((dir>0&&g_snap.htfBias<0)||(dir<0&&g_snap.htfBias>0)){ score-=InpN_HTFAgainst; reasons+="HTF- "; }

   // --- Regime ---
   if(g_snap.regimeDir==dir)
     {
      if(g_snap.regime==REGIME_TREND){ score+=InpW_RegimeTrend; reasons+="TREND+ "; }
      if(g_snap.regime==REGIME_BREAKOUT){ score+=InpW_RegimeBreakout; reasons+="BRK+ "; }
     }
   if(g_snap.regime==REGIME_RANGE)
     {
      // Mean reversion: only favour FADING from a band edge; penalise mid-band
      // and penalise chasing INTO the edge you are already at.
      double atrR=g_snap.atrRegime;
      bool atLower=(atrR>0&&(g_snap.bid-g_snap.bbLower)<=0.8*atrR);
      bool atUpper=(atrR>0&&(g_snap.bbUpper-g_snap.bid)<=0.8*atrR);
      if(atLower&&dir>0){ score+=InpW_RangeEdge; reasons+="EDGE+ "; }
      else if(atUpper&&dir<0){ score+=InpW_RangeEdge; reasons+="EDGE+ "; }
      else if(atLower&&dir<0){ score-=InpW_RangeEdge; reasons+="EDGEchase- "; }
      else if(atUpper&&dir>0){ score-=InpW_RangeEdge; reasons+="EDGEchase- "; }
      else { score-=InpRangeMidPenalty; reasons+="MID- "; }
     }
   if(g_snap.regime==REGIME_COMPRESSION){ /* watch only: no directional bonus */ }

   // TRANSITION is the noisiest regime: penalise both sides unless a fresh
   // CHOCH in this direction confirms the flip.
   if(g_snap.regime==REGIME_TRANSITION&&InpTransitionPenalty>0)
     {
      datetime freshCut=TimeCurrent()-InpTriggerFreshMinutes*60;
      bool freshChoch=false;
      for(int i=0;i<ArraySize(g_events);i++)
         if(g_events[i].type==EV_CHOCH&&g_events[i].direction==dir&&g_events[i].time>=freshCut){freshChoch=true;break;}
      if(!freshChoch){ score-=InpTransitionPenalty; reasons+="TRANS- "; }
     }

   // --- Structure (M30) ---
   if(g_snap.structBias==dir){ score+=InpW_Structure; reasons+="STRUCT+ "; }

   // --- Zones ---
   bool fresh=false;
   double zSetup=ZoneSupportForDir(dir,InpTFSetup,fresh);
   if(zSetup>0){ score+=(int)(InpW_ZoneOB*zSetup)+(fresh?3:0); reasons+="ZONE+ "; }
   double zConf=ZoneSupportForDir(dir,InpTFConfirm,fresh);
   if(zConf>0){ score+=(int)(InpW_ZoneFVG*zConf); reasons+="ZCONF+ "; }

   // --- Events ---
   double bos=EventWeight(EV_BOS,dir);
   if(bos>0){ score+=(int)(InpW_BOS*MathMin(1.0,bos)); reasons+="BOS+ "; }
   double choch=EventWeight(EV_CHOCH,dir);
   if(choch>0){ score+=(int)(InpW_CHOCH*MathMin(1.0,choch)); reasons+="CHOCH+ "; }
   double disp=EventWeight(EV_DISPLACEMENT,dir);
   if(disp>0){ score+=(int)(InpW_Displacement*MathMin(1.0,disp)); reasons+="DISP+ "; }
   double sweep=EventWeight(EV_SWEEP,dir);
   if(sweep>0){ score+=(int)(InpW_Sweep*MathMin(1.0,sweep)); reasons+="SWEEP+ "; }
   double vol=EventWeight(EV_VOLUME,dir);
   if(vol>0){ score+=(int)(InpW_Volume*MathMin(1.0,vol)); reasons+="VOL+ "; }
   double rej=EventWeight(EV_REJECTION,dir);
   if(rej>0){ score+=(int)(InpW_Trigger*MathMin(1.0,rej)); reasons+="REJ+ "; }

   // --- EMA alignment on regime TF ---
   if((dir>0&&g_snap.emaFast>g_snap.emaSlow)||(dir<0&&g_snap.emaFast<g_snap.emaSlow)){ score+=InpW_EMA; reasons+="EMA+ "; }
   // Live trigger is a small bonus, never a standalone signal.
   if(HasLiveTrigger(dir)){ score+=8; reasons+="LIVE+8 "; }


   // --- Negatives from opposing events ---
   double chochAg=EventWeight(EV_CHOCH,-dir);
   if(chochAg>0){ score-=(int)(InpN_CHOCHAgainst*MathMin(1.0,chochAg)); reasons+="cCHOCH- "; }
   double sweepAg=EventWeight(EV_SWEEP,-dir);
   if(sweepAg>0){ score-=(int)(InpW_Sweep*MathMin(1.0,sweepAg)); reasons+="cSWEEP- "; }
   double dispAg=EventWeight(EV_DISPLACEMENT,-dir);
   if(dispAg>0){ score-=(int)(InpW_Displacement*0.6*MathMin(1.0,dispAg)); reasons+="cDISP- "; }

   // --- Spread penalty ---
   if(!SpreadOK()){ score-=InpN_ExtremeSpread; reasons+="SPREAD- "; }

   // --- Multi-frame confluence (r6): reward when several TFs line up ---
   if(InpUseMTFConfluence&&InpW_MTFConfluence>0)
     {
      int frames=CountMTFAgree(dir);
      if(frames>=InpMTFMinFrames)
        {
         int bonus=(frames-InpMTFMinFrames+1)*InpW_MTFConfluence;
         if(bonus>InpMTFMaxBonus) bonus=InpMTFMaxBonus;
         score+=bonus; reasons+=StringFormat("MTFx%d+%d ",frames,bonus);
        }
     }

   if(score<0) score=0;
   return score;
  }

// Exit pressure against an open runner in 'posDir'. Higher => more reason to exit.
int ExitPressure(int posDir,string &reasons)
  {
   reasons="";
   int s=0;
   int opp=-posDir;
   double choch=EventWeight(EV_CHOCH,opp);
   double bos=EventWeight(EV_BOS,opp);
   double disp=EventWeight(EV_DISPLACEMENT,opp);
   double vol=EventWeight(EV_VOLUME,opp);
   if(choch>0){ s+=(int)(20*MathMin(1.0,choch)); reasons+="CHOCH- "; }
   if(bos>0){ s+=(int)(30*MathMin(1.0,bos)); reasons+="BOS- "; }
   if(disp>0){ s+=(int)(15*MathMin(1.0,disp)); reasons+="DISP- "; }
   if(vol>0){ s+=(int)(10*MathMin(1.0,vol)); reasons+="VOL- "; }
   if((posDir>0&&g_snap.htfBias<0)||(posDir<0&&g_snap.htfBias>0)){ s+=15; reasons+="HTFrev- "; }
   return s;
  }

//==================================================================
// VIRTUAL POSITION MANAGEMENT (reused pattern from v2)
//==================================================================
int FindVPos(ulong ticket)
  {
   for(int i=0;i<ArraySize(g_vpos);i++) if(g_vpos[i].ticket==ticket) return i;
   return -1;
  }
string VKey(ulong t,string f){ return g_prefix+"V_"+IntegerToString((long)t)+"_"+f; }

void SaveVPos(int i)
  {
   if(i<0||i>=ArraySize(g_vpos)) return;
   ulong t=g_vpos[i].ticket;
   GlobalVariableSet(VKey(t,"D"),(double)g_vpos[i].dir);
   GlobalVariableSet(VKey(t,"R"),g_vpos[i].riskDistance);
   GlobalVariableSet(VKey(t,"S"),(double)g_vpos[i].stage);
   GlobalVariableSet(VKey(t,"O"),(double)g_vpos[i].openTime);
   GlobalVariableSet(VKey(t,"G"),(double)g_vpos[i].group);
   GlobalVariableSet(VKey(t,"PB"),g_vpos[i].pairTP1Banked?1.0:0.0);
   GlobalVariableSet(VKey(t,"TA"),g_vpos[i].trailAnchor);
   GlobalVariableSet(VKey(t,"DC"),g_vpos[i].isDCA?1.0:0.0);
   GlobalVariableSet(VKey(t,"PT"),(double)g_vpos[i].parentTicket);
  }

void AddVPos(ulong ticket,int dir,bool runner,double entry,double sl,double tp,double risk,datetime group,bool dca=false,ulong parentTicket=0)
  {
   int n=ArraySize(g_vpos);
   ArrayResize(g_vpos,n+1);
   g_vpos[n].ticket=ticket;g_vpos[n].dir=dir;g_vpos[n].isRunner=runner;g_vpos[n].isDCA=dca;g_vpos[n].parentTicket=parentTicket;
   g_vpos[n].entryPrice=entry;g_vpos[n].virtualSL=NPrice(sl);g_vpos[n].virtualTP=NPrice(tp);
   g_vpos[n].riskDistance=risk;g_vpos[n].stage=0;g_vpos[n].openTime=TimeCurrent();
   g_vpos[n].group=group;g_vpos[n].pairTicket=0;g_vpos[n].pairTP1Banked=false;
   g_vpos[n].trailAnchor=0.0;g_vpos[n].lastTrailBar=0;
   g_vpos[n].peakProfit=0.0;
   g_vpos[n].peakExtreme=entry;
   SaveVPos(n);
  }

void RemoveVPos(int idx)
  {
   if(idx<0||idx>=ArraySize(g_vpos)) return;
   ulong t=g_vpos[idx].ticket;
   GlobalVariableDel(VKey(t,"D"));GlobalVariableDel(VKey(t,"R"));GlobalVariableDel(VKey(t,"S"));
   GlobalVariableDel(VKey(t,"O"));GlobalVariableDel(VKey(t,"G"));GlobalVariableDel(VKey(t,"PB"));
   GlobalVariableDel(VKey(t,"TA"));GlobalVariableDel(VKey(t,"DC"));GlobalVariableDel(VKey(t,"PT"));
   int last=ArraySize(g_vpos)-1;
   if(idx<last) g_vpos[idx]=g_vpos[last];
   ArrayResize(g_vpos,last);
  }

// Net realized P/L of a closed position (for the loss-cooldown guard)
double ClosedNetProfit(ulong ticket)
  {
   if(!HistorySelectByPosition(ticket)) return 0.0;
   double net=0.0;
   for(int d=0;d<HistoryDealsTotal();d++)
     {
      ulong deal=HistoryDealGetTicket(d);
      if(deal==0) continue;
      net+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);
     }
   return net;
  }

void SyncVPos()
  {
   for(int i=ArraySize(g_vpos)-1;i>=0;i--)
     {
      if(!PositionSelectByTicket(g_vpos[i].ticket))
        {
         // record a loss or win for the same-direction cooldown guard
         double net = ClosedNetProfit(g_vpos[i].ticket);
         if(net<0.0)
           {
            if(g_vpos[i].dir>0) g_lastLossBuy=TimeCurrent();
            else g_lastLossSell=TimeCurrent();
           }
         else if(net>0.0)
           {
            if(g_vpos[i].dir>0) g_lastWinBuy=TimeCurrent();
            else g_lastWinSell=TimeCurrent();
           }
         // Position closed by broker SL/TP or externally: bank TP1 for its runner pair
         if(!g_vpos[i].isRunner && g_vpos[i].group>0)
            for(int j=0;j<ArraySize(g_vpos);j++)
               if(g_vpos[j].group==g_vpos[i].group&&g_vpos[j].isRunner)
                 { g_vpos[j].pairTP1Banked=true; ProtectRunnerAfterTP1(j); SaveVPos(j); }
         RemoveVPos(i);
        }
     }
  }

void RecoverOpenPositions()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(FindVPos(t)>=0) continue;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      if(sl<=0){ PrintFormat("[BV3] #%I64u has no broker SL; skipping recovery.",t); continue; }
      long side=PositionGetInteger(POSITION_TYPE);
      int dir=(side==POSITION_TYPE_BUY?1:-1);
      string cm=PositionGetString(POSITION_COMMENT);
      bool dca=(StringFind(cm,"DCA")>=0);
      bool runner=(StringFind(cm,"RUN")>=0);
      ulong parent=(GlobalVariableCheck(VKey(t,"PT"))?(ulong)GlobalVariableGet(VKey(t,"PT")):0);
      datetime grp=(GlobalVariableCheck(VKey(t,"G"))?(datetime)GlobalVariableGet(VKey(t,"G")):(datetime)PositionGetInteger(POSITION_TIME));
      AddVPos(t,dir,runner,entry,sl,tp,MathAbs(entry-sl),grp,dca,parent);
      int idx=FindVPos(t);
      if(idx>=0)
        {
         if(GlobalVariableCheck(VKey(t,"S"))) g_vpos[idx].stage=(int)GlobalVariableGet(VKey(t,"S"));
         if(GlobalVariableCheck(VKey(t,"O"))) g_vpos[idx].openTime=(datetime)GlobalVariableGet(VKey(t,"O"));
         if(GlobalVariableCheck(VKey(t,"PB"))) g_vpos[idx].pairTP1Banked=(GlobalVariableGet(VKey(t,"PB"))>0.5);
         if(GlobalVariableCheck(VKey(t,"TA"))) g_vpos[idx].trailAnchor=GlobalVariableGet(VKey(t,"TA"));
         if(GlobalVariableCheck(VKey(t,"DC"))) g_vpos[idx].isDCA=(GlobalVariableGet(VKey(t,"DC"))>0.5);
         if(GlobalVariableCheck(VKey(t,"PT"))) g_vpos[idx].parentTicket=(ulong)GlobalVariableGet(VKey(t,"PT"));
         SaveVPos(idx);
        }
      PrintFormat("[BV3] Recovered %s #%I64u entry=%.2f SL=%.2f",runner?"runner":"TP1",t,entry,sl);
     }
  }

//==================================================================
// EXECUTION (2 legs)
//==================================================================
double PlanLotForRisk(double distance,double riskFraction,double &why_ok)
  {
   why_ok=1.0;
   if(InpUseFixedLot) return NormalizeLot(InpFixedLot);
   riskFraction=MathMax(0.0,MathMin(1.0,riskFraction));
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPerOrderPct*riskFraction/100.0;
   double raw=CalcLotByRisk(riskMoney,distance);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(raw<minLot)
     {
      if(InpAllowMinLot)
        {
         if(InpMinLotGuard == GUARD_NONE) raw=minLot;
         else if(TickLossPerLot(distance)*minLot<=AccountInfoDouble(ACCOUNT_EQUITY)*(InpMaxMinLotRiskPct/100.0)) raw=minLot;
         else { why_ok=0.0; return 0.0; }
        }
      else { why_ok=0.0; return 0.0; }
     }
   return NormalizeLot(raw);
  }

double PlanLot(double distance,double &why_ok)
  {
   double frac=(InpEntryExitMode==ENTRY_BOTH?InpBothRiskFraction:1.0);
   return PlanLotForRisk(distance,frac,why_ok);
  }

bool OpenLeg(int dir,double sl,double tp,double lot,datetime group,bool runner,string &why,bool dca=false,ulong parentTicket=0)
  {
   double price=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
   string cmt=(dca?"BV3DCA ":(runner?"BV3RUN ":"BV3TP1 "))+RegimeStr(g_snap.regime);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);
   trade.SetAsyncMode(false);
   trade.SetTypeFillingBySymbol(_Symbol);
   ResetLastError();
   bool ok=false;
   if(dir>0) ok=trade.Buy(lot,_Symbol,0.0,InpUseBrokerSLTP?sl:0.0,InpUseBrokerSLTP?tp:0.0,cmt);
   else      ok=trade.Sell(lot,_Symbol,0.0,InpUseBrokerSLTP?sl:0.0,InpUseBrokerSLTP?tp:0.0,cmt);
   if(!ok||(trade.ResultRetcode()!=TRADE_RETCODE_DONE&&trade.ResultRetcode()!=TRADE_RETCODE_PLACED))
     {
      why=StringFormat("order failed rc=%d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
      return false;
     }
   // Position ticket = DEAL_POSITION_ID of the fill (works for hedging & netting)
   ulong ticket=trade.ResultOrder();
   ulong deal=trade.ResultDeal();
   if(deal>0&&HistoryDealSelect(deal))
     {
      ulong posId=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(posId>0) ticket=posId;
     }
   for(int k=0;k<10&&!PositionSelectByTicket(ticket);k++) Sleep(20);
   double fill=(trade.ResultPrice()>0?trade.ResultPrice():price);
   if(PositionSelectByTicket(ticket)) fill=PositionGetDouble(POSITION_PRICE_OPEN);
   AddVPos(ticket,dir,runner,fill,sl,tp,MathAbs(fill-sl),group,dca,parentTicket);
   PrintFormat("[BV3] OPEN %s %s lot=%.2f entry=%.2f SL=%.2f TP=%s regime=%s score=%d",
               dca?"DCA":(runner?"RUNNER":"TP1"),dir>0?"BUY":"SELL",lot,fill,sl,
               tp>0?DoubleToString(tp,g_digits):"none",RegimeStr(g_snap.regime),
               dir>0?g_snap.buyScore:g_snap.sellScore);
   return true;
  }

void OpenSignal(int dir,double sl)
  {
   double entry=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
   double distance=MathAbs(entry-sl);
   if(distance<=0) return;

   double ok=1.0;
   double lot=PlanLot(distance,ok);
   if(ok<=0||lot<=0){ LogDecision(dir,0,"LOT_TOO_SMALL"); return; }

   datetime group=TimeCurrent();
   double tp1=(InpTP1_RR>0?(dir>0?entry+distance*InpTP1_RR:entry-distance*InpTP1_RR):0.0);
   string why="";

   // BOTH = TP1 leg + runner leg. TP_ONLY/RUNNER_ONLY = single leg.
   if(InpEntryExitMode==ENTRY_TP_ONLY)
     {
      double singleOK=1.0;
      double lotSingle=PlanLotForRisk(distance,1.0,singleOK);
      if(singleOK<=0||lotSingle<=0){ LogDecision(dir,0,"LOT_TOO_SMALL"); return; }
      if(!OpenLeg(dir,sl,tp1,lotSingle,group,false,why))
        { LogDecision(dir,0,"TP_ONLY_FAILED: "+why); return; }
      LogDecision(dir,1,"ENTRY_FIRED_TP_ONLY");
      return;
     }

   if(InpEntryExitMode==ENTRY_RUNNER_ONLY)
     {
      double singleOK=1.0;
      double lotSingle=PlanLotForRisk(distance,1.0,singleOK);
      if(singleOK<=0||lotSingle<=0){ LogDecision(dir,0,"LOT_TOO_SMALL"); return; }
      bool runnerOK=false; string runnerWhy="";
      int tries=(InpRetryRunner?3:1);
      for(int attempt=0;attempt<tries;attempt++)
        {
         if(attempt>0) Sleep(MathMax(20,InpRunnerRetryMs));
         runnerWhy="";
         if(OpenLeg(dir,sl,0.0,lotSingle,group,true,runnerWhy)) { runnerOK=true; break; }
        }
      if(!runnerOK)
        { PrintFormat("[BV3] !!! RUNNER_ONLY FAILED after %d attempts. Last error: %s",tries,runnerWhy); LogDecision(dir,0,"RUNNER_ONLY_FAILED: "+runnerWhy); return; }
      LogDecision(dir,1,"ENTRY_FIRED_RUNNER_ONLY");
      return;
     }

   // BOTH: two separate legs on a hedging account: TP1 + runner.
   // On a netting account MT5 merges same-symbol same-direction orders into one position.
   // The history will still contain two deals, but the terminal cannot display two
   // independent positions. For truly separate legs, use a HEDGING account/tester.
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("[BV3] BOTH mode: account is not HEDGING; same-direction legs may be merged into one net position.");
   string tpWhy="";
   if(!OpenLeg(dir,sl,tp1,lot,group,false,tpWhy))
     { LogDecision(dir,0,"BOTH_TP1_FAILED: "+tpWhy); return; }

   bool runnerOK=false; string runnerWhy="";
   int tries=(InpRetryRunner?3:1);
   for(int attempt=0;attempt<tries;attempt++)
     {
      if(attempt>0) Sleep(MathMax(20,InpRunnerRetryMs));
      runnerWhy="";
      if(OpenLeg(dir,sl,0.0,lot,group,true,runnerWhy)) { runnerOK=true; break; }
     }
   if(!runnerOK)
     {
      PrintFormat("[BV3] !!! BOTH runner failed after %d attempts: %s",tries,runnerWhy);
      if(InpRequireBothLegs)
        {
         for(int i=ArraySize(g_vpos)-1;i>=0;i--)
           {
            if(g_vpos[i].group!=group || g_vpos[i].isRunner) continue;
            if(PositionSelectByTicket(g_vpos[i].ticket))
              { trade.SetExpertMagicNumber(InpMagic); trade.SetDeviationInPoints(InpMaxSlippagePoints); trade.PositionClose(g_vpos[i].ticket,InpMaxSlippagePoints); }
            break;
           }
        }
      LogDecision(dir,0,"BOTH_FAILED_RUNNER: "+runnerWhy);
      return;
     }

   int tpIdx=-1,runIdx=-1;
   for(int i=0;i<ArraySize(g_vpos);i++)
     {
      if(g_vpos[i].group!=group) continue;
      if(g_vpos[i].isRunner) runIdx=i; else tpIdx=i;
     }
   if(tpIdx>=0 && runIdx>=0)
     {
      g_vpos[tpIdx].pairTicket=g_vpos[runIdx].ticket;
      g_vpos[runIdx].pairTicket=g_vpos[tpIdx].ticket;
      SaveVPos(tpIdx); SaveVPos(runIdx);
     }
   LogDecision(dir,1,"ENTRY_FIRED_BOTH_TP1_RUNNER");
  }

//==================================================================
// SMART STRUCTURAL SL ENGINE
//
// Initial SL is an invalidation level, not a fixed ATR distance.
// Priority:
//   1) relevant HTF OB/FVG edge around the current reaction/retest
//   2) recent liquidity sweep extreme in the trade direction
//   3) latest structural swing
// ATR is used only for breathing room + sanity limits.
//==================================================================
double SmartZoneWeight(ENUM_TIMEFRAMES tf)
  {
   if(tf==PERIOD_H4)  return 4.0;
   if(tf==PERIOD_H1)  return 3.5;
   if(tf==PERIOD_M30) return 3.0;
   if(tf==PERIOD_M15) return 2.0;
   if(tf==PERIOD_M5)  return 1.0;
   return 0.5;
  }

bool FindSmartZoneExtreme(int dir,double price,double atr,double &extreme,ENUM_TIMEFRAMES &bestTF,int &bestKind)
  {
   extreme=0.0; bestTF=PERIOD_CURRENT; bestKind=-1;
   double bestScore=-1e9;
   double maxDist=atr*MathMax(0.10,InpSmartSL_ZoneATR);

   for(int i=0;i<ArraySize(g_zones);i++)
     {
      Zone z=g_zones[i];
      if(z.dir!=dir) continue;
      if(z.kind==ZONE_FVG && !InpSmartSL_UseFVG) continue;
      if(z.state==ZS_FAILED || z.state==ZS_INVALID || z.state==ZS_BROKEN) continue;

      double mid=(z.hi+z.lo)*0.5;
      double dist=MathAbs(price-mid);
      // A retest can approach the zone from outside or sit inside it.
      // Do not let a remote old zone dictate the initial stop.
      if(dist>maxDist) continue;

      double candidate=(dir>0?z.lo:z.hi);
      if((dir>0 && candidate>=price) || (dir<0 && candidate<=price)) continue;

      double score=SmartZoneWeight(z.tf);
      if(z.kind==ZONE_OB) score+=1.25; // OB is the primary invalidation zone
      else score+=0.50;
      if(z.state==ZS_FRESH) score+=0.60;
      else if(z.state==ZS_TESTED) score+=0.35;
      if(z.touches<=1) score+=0.20;
      score-=dist/MathMax(atr,0.00001);

      if(score>bestScore)
        {
         bestScore=score;
         extreme=candidate;
         bestTF=z.tf;
         bestKind=z.kind;
        }
     }
   return bestScore>-1e8;
  }

bool FindRecentSweepExtreme(int dir,double price,double atr,double &extreme,ENUM_TIMEFRAMES &bestTF)
  {
   extreme=0.0; bestTF=PERIOD_CURRENT;
   if(!InpSmartSL_UseSweep) return false;
   datetime now=TimeCurrent();
   double maxAge=(double)(MathMax(5,InpTriggerFreshMinutes)*60);
   double maxDist=atr*1.50;
   double bestScore=-1e9;

   for(int i=ArraySize(g_events)-1;i>=0;i--)
     {
      MarketEvent e=g_events[i];
      if(e.type!=EV_SWEEP || e.direction!=dir) continue;
      double age=(double)(now-e.time);
      if(age<0 || age>maxAge) continue;
      double dist=MathAbs(price-e.price);
      if(dist>maxDist) continue;

      double score=SmartZoneWeight(e.tf)+e.strength*2.0-age/MathMax(1.0,maxAge);
      if(score>bestScore)
        {
         bestScore=score;
         extreme=e.price;
         bestTF=e.tf;
        }
     }
   return bestScore>-1e8;
  }

// Smart initial SL: the market's invalidation point decides the stop.
// For SELL: above supply/OB/sweep/swing. For BUY: below demand/OB/sweep/swing.
double StructuralSL(int dir)
  {
   int slot=TfSlot(InpSL_SwingTF);
   if(slot<0) slot=TfSlot(InpTFTrigger);
   if(slot<0) slot=TfSlot(InpTFConfirm);

   double atr=ATR(InpSL_SwingTF,1);
   if(atr<=0) atr=ATR(InpTFTrigger,1);
   if(atr<=0) atr=g_snap.atrRegime;
   if(atr<=0) return 0.0;

   double price=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
   if(price<=0) return 0.0;

   double swing=0.0; datetime swingTime=0;
   bool gotSwing=(dir>0?LastSwingLow(slot,swing,swingTime):LastSwingHigh(slot,swing,swingTime));

   // Base invalidation starts from the latest valid swing.
   double extreme=0.0;
   bool haveExtreme=false;
   if(gotSwing && ((dir>0 && swing<price) || (dir<0 && swing>price)))
     { extreme=swing; haveExtreme=true; }

   string basis=(gotSwing?"SWING":"ATR_FALLBACK");

   if(InpUseSmartSL)
     {
      double zoneExt=0.0; ENUM_TIMEFRAMES ztf=PERIOD_CURRENT; int zkind=-1;
      if(FindSmartZoneExtreme(dir,price,atr,zoneExt,ztf,zkind))
        {
         if(!haveExtreme || (dir>0?zoneExt<extreme:zoneExt>extreme))
           extreme=zoneExt;
         haveExtreme=true;
         basis=(zkind==ZONE_OB?"HTF_OB":"HTF_FVG");
        }

      double sweepExt=0.0; ENUM_TIMEFRAMES stf=PERIOD_CURRENT;
      if(FindRecentSweepExtreme(dir,price,atr,sweepExt,stf))
        {
         if(!haveExtreme || (dir>0?sweepExt<extreme:sweepExt>extreme))
           extreme=sweepExt;
         haveExtreme=true;
         basis+="+SWEEP";
        }
     }

   // If the selected structure is on the wrong side, fall back safely.
   if(!haveExtreme || (dir>0 && extreme>=price) || (dir<0 && extreme<=price))
     {
      double fallbackGap=atr*MathMax(InpSmartSL_MinATR,0.80);
      extreme=(dir>0?price-fallbackGap:price+fallbackGap);
      haveExtreme=true;
      basis="ATR_FALLBACK";
     }

   double buffer=atr*(InpUseSmartSL?MathMax(0.0,InpSmartSL_BufferATR):InpSL_ATR_Buffer);
   double spreadPrice=MathMax(0.0,SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID));
   // A little spread-aware room prevents the initial stop sitting exactly on the
   // executable quote during a live spread expansion.
   buffer=MathMax(buffer,spreadPrice*1.50);

   double gap;
   if(dir>0)
     {
      // BUY invalidation is below the chosen demand/swing/sweep extreme.
      gap=(price-extreme)+buffer;
     }
   else
     {
      // SELL invalidation is above the chosen supply/swing/sweep extreme.
      gap=(extreme-price)+buffer;
     }

   double minGap=atr*(InpUseSmartSL?MathMax(0.10,InpSmartSL_MinATR):0.80);
   if(InpMinSLPips>0) minGap=MathMax(minGap,InpMinSLPips*InpGoldPipSize);
   gap=MathMax(gap,minGap);

   double maxGap=atr*(InpUseSmartSL?MathMax(0.50,InpSmartSL_MaxATR):2.80);
   if(InpMaxSLPips>0) maxGap=MathMin(maxGap,InpMaxSLPips*InpGoldPipSize);

   if(gap>maxGap && InpSkipWideSL)
     {
      if(InpVerboseLog)
         PrintFormat("[BV3] SMART SL REJECT dir=%s basis=%s gap=%.2f ATR=%.2f max=%.2f",dir>0?"BUY":"SELL",basis,gap,atr,maxGap);
      return 0.0;
     }
   if(gap>maxGap) gap=maxGap;

   double sl=(dir>0?price-gap:price+gap);
   sl=NPrice(sl);
   if(InpVerboseLog)
      PrintFormat("[BV3] SMART SL dir=%s basis=%s entry=%.2f invalidation=%.2f gap=%.2f ATR=%.2f SL=%.2f",dir>0?"BUY":"SELL",basis,price,extreme,gap,atr,sl);
   return sl;
  }

//==================================================================
// PROFIT PROTECTION STATE MACHINE (spec 11-14)
//==================================================================
double FloatingUSD(int i)
  {
   if(!PositionSelectByTicket(g_vpos[i].ticket)) return 0.0;
   return PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
  }

void MoveSL(int i,double newSL,string label)
  {
   newSL=NPrice(newSL);
   int dir=g_vpos[i].dir;
   bool improves=(dir>0?newSL>g_vpos[i].virtualSL:newSL<g_vpos[i].virtualSL);
   if(!improves) return;
   g_vpos[i].virtualSL=newSL;
   if(InpUseBrokerSLTP&&InpManagePositions&&PositionSelectByTicket(g_vpos[i].ticket))
     {
      trade.SetExpertMagicNumber(InpMagic);
      trade.PositionModify(g_vpos[i].ticket,newSL,g_vpos[i].virtualTP);
     }
   SaveVPos(i);
   if(InpVerboseLog) PrintFormat("[BV3] #%I64u SL -> %.2f (%s)",g_vpos[i].ticket,newSL,label);
  }

void ProtectRunnerAfterTP1(int j)
  {
   // TP1 banking must NOT instantly move the runner to BE/profit.
   // The runner keeps its original structural SL until the R-based
   // protection engine reaches InpProtectAtR.
   if(j<0||j>=ArraySize(g_vpos)) return;
   g_vpos[j].pairTP1Banked=true;
   if(InpVerboseLog)
      PrintFormat("[BV3] #%I64u TP1 banked; runner keeps initial SL until %.2fR",
                  g_vpos[j].ticket,InpProtectAtR);
   SaveVPos(j);
  }

void TryPositiveDCA(int parentIdx)
  {
   if(parentIdx<0||parentIdx>=ArraySize(g_vpos)) return;
   if(!g_vpos[parentIdx].isRunner || g_vpos[parentIdx].isDCA) return;
   if(InpPositiveDCAMode!=DCA_POSITIVE) return;
   if(InpEntryExitMode!=ENTRY_RUNNER_ONLY) return; // explicitly runner-only feature
   if(InpDCA_MaxAdds<=0) return;
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      if(InpVerboseLog) Print("[BV3] POSITIVE_DCA skipped: requires HEDGING account so each add remains an independent runner.");
      return;
     }
   if(!PositionSelectByTicket(g_vpos[parentIdx].ticket)) return;

   int adds=0;
   double lastAddR=0.0;
   string kCount=VKey(g_vpos[parentIdx].ticket,"DCA_N");
   string kLast =VKey(g_vpos[parentIdx].ticket,"DCA_R");
   if(GlobalVariableCheck(kCount)) adds=(int)GlobalVariableGet(kCount);
   if(GlobalVariableCheck(kLast)) lastAddR=GlobalVariableGet(kLast);

   if(adds>=InpDCA_MaxAdds) return;

   double R=g_vpos[parentIdx].riskDistance;
   if(R<=0) return;
   int dir=g_vpos[parentIdx].dir;
   double px=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK));
   double move=(dir>0?px-g_vpos[parentIdx].entryPrice:g_vpos[parentIdx].entryPrice-px);
   double currentR=move/R;
   double nextR=InpDCA_FirstAtR + adds*MathMax(0.25,InpDCA_StepR);
   if(currentR<nextR) return;

   // The root runner must already have a genuinely profitable SL.
   double minPositiveR=0.20;
   double slProfitR=(dir>0?(g_vpos[parentIdx].virtualSL-g_vpos[parentIdx].entryPrice)
                           :(g_vpos[parentIdx].entryPrice-g_vpos[parentIdx].virtualSL))/R;
   if(slProfitR<minPositiveR) return;

   bool aligned=(g_snap.regimeDir==dir &&
                 (g_snap.regime==REGIME_TREND || g_snap.regime==REGIME_BREAKOUT));
   if(InpDCA_RequireTrend && !aligned) return;

   if(lastAddR>0 && currentR<lastAddR+MathMax(0.25,InpDCA_StepR)) return;
   if(CountEA()>=InpMaxOpenPositions) return;

   double parentLot=PositionGetDouble(POSITION_VOLUME);
   if(parentLot<=0) return;
   double lot=NormalizeLot(parentLot*MathMax(0.01,InpDCA_LotFactor));

   // DCA risk is capped by a fraction of the root runner's current floating profit.
   double rootProfit=FloatingUSD(parentIdx);
   if(rootProfit<=0) return;
   double dcaSL=g_vpos[parentIdx].virtualSL;
   double dcaEntry=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
   double dcaDist=MathAbs(dcaEntry-dcaSL);
   if(dcaDist<=0) return;
   double maxLoss=rootProfit*MathMax(1.0,InpDCA_MaxLossPctProfit)/100.0;
   double perLot=TickLossPerLot(dcaDist);
   if(perLot<=0) return;
   double capLot=maxLoss/perLot;
   if(capLot<SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
     {
      if(InpVerboseLog) PrintFormat("[BV3] POSITIVE_DCA skipped: min lot would risk %.2f > cap %.2f",TickLossPerLot(dcaDist)*SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),maxLoss);
      return;
     }
   lot=NormalizeLot(MathMin(lot,capLot));
   if(lot<SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)) return;

   datetime group=g_vpos[parentIdx].group;
   string why="";
   if(OpenLeg(dir,dcaSL,0.0,lot,group,true,why,true,g_vpos[parentIdx].ticket))
     {
      adds++;
      GlobalVariableSet(kCount,(double)adds);
      GlobalVariableSet(kLast,currentR);
      if(InpVerboseLog)
         PrintFormat("[BV3] POSITIVE_DCA #%d parent=%I64u at %.2fR lot=%.2f SL=%.2f rootProfit=%.2f",
                     adds,g_vpos[parentIdx].ticket,currentR,lot,dcaSL,rootProfit);
     }
   else if(InpVerboseLog)
      PrintFormat("[BV3] POSITIVE_DCA failed: %s",why);
  }

void ManageRunner(int i)
  {
   if(i<0||i>=ArraySize(g_vpos)) return;
   if(!g_vpos[i].isRunner) return;

   double floatUSD=FloatingUSD(i);
   int dir=g_vpos[i].dir;
   double R=g_vpos[i].riskDistance;
   if(R<=0) return;

   double px=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK));
   double move=(dir>0?px-g_vpos[i].entryPrice:g_vpos[i].entryPrice-px);
   double currentR=move/R;
   if(floatUSD>g_vpos[i].peakProfit) g_vpos[i].peakProfit=floatUSD;
   if(dir>0){ if(px>g_vpos[i].peakExtreme) g_vpos[i].peakExtreme=px; }
   else     { if(px<g_vpos[i].peakExtreme) g_vpos[i].peakExtreme=px; }

   // RUNNER RULE: do not touch the initial structural SL while the trade is
   // still in normal noise. No BE, no warning-tighten, no micro-lock.
   // Protection starts only after a meaningful move.
   if(g_vpos[i].stage<1)
     {
      bool triggered = false;
      double lockDist = 0;
      if(InpUseFixedPointsProtect)
        {
         if(move >= InpProtectAtPoints)
           {
            triggered = true;
            lockDist = InpProtectLockPoints;
           }
        }
      else
        {
         if(currentR >= InpProtectAtR)
           {
            triggered = true;
            lockDist = R * MathMax(0.0,InpProtectLockR);
           }
        }

      if(triggered)
        {
         double target=(dir>0?g_vpos[i].entryPrice+lockDist
                             :g_vpos[i].entryPrice-lockDist);
         MoveSL(i,target,"PROTECT_STAGE_1");
         g_vpos[i].stage=1;
        }
     }

   if(!InpUseFixedPointsProtect && g_vpos[i].stage<2 && currentR>=InpLockAtR)
     {
      double target=(dir>0?g_vpos[i].entryPrice+R*InpLockProfitR
                          :g_vpos[i].entryPrice-R*InpLockProfitR);
      MoveSL(i,target,"R_LOCK_3.0R");
      g_vpos[i].stage=2;
     }

   if(g_vpos[i].stage<3)
     {
      bool armTrail = false;
      if(InpUseFixedPointsProtect) armTrail = (move >= InpProtectAtPoints * 1.5);
      else armTrail = (currentR >= InpTrailArmR);
      
      if(armTrail) g_vpos[i].stage=3;
     }

   bool alignedTrend=(g_snap.regimeDir==dir &&
                      (g_snap.regime==REGIME_TREND||g_snap.regime==REGIME_BREAKOUT));
   if(g_vpos[i].stage<4 && currentR>=InpRunnerArmR && alignedTrend)
     {
      g_vpos[i].stage=4;
      if(InpVerboseLog) PrintFormat("[BV3] #%I64u entered BREAKOUT_RUNNER mode at %.2fR",g_vpos[i].ticket,currentR);
     }

   if(InpPeakTrailOn && g_vpos[i].stage >= 2)
     {
      double atr=ATR(InpTFTrigger,1); if(atr<=0) atr=g_snap.atrRegime;
      if(atr>0)
        {
         if(dir>0)
           {
            double cand = g_vpos[i].peakExtreme - atr * InpPeakTrailATR;
            if(cand > g_vpos[i].virtualSL) MoveSL(i, cand, "PEAK_TRAIL");
           }
         else
           {
            double cand = g_vpos[i].peakExtreme + atr * InpPeakTrailATR;
            if(cand < g_vpos[i].virtualSL || g_vpos[i].virtualSL == 0.0) MoveSL(i, cand, "PEAK_TRAIL");
           }
        }
     }

   // R15: NO floating-profit giveback close. A runner is allowed to breathe
   // through deep pullbacks; only the structural SL engine can take it out.
   // This is intentional: a 10R/20R move must be able to remain open.

   // Structure trailing starts only after 2.5R. The candidate must also leave
   // at least 0.75 ATR between executable price and the broker SL.
   if(g_vpos[i].stage>=3 && InpUseStructureTrail)
     {
      int slot=TfSlot(InpTrailTF); if(slot<0) slot=TfSlot(InpTFConfirm);
      double atr=ATR(InpTrailTF,1); if(atr<=0) atr=g_snap.atrRegime;
      if(atr<=0) return;

      double buf=InpTrailATRBuffer;
      if(InpHoldLonger && alignedTrend && InpTrailBufferTrend>buf) buf=InpTrailBufferTrend;
      double minGap=atr*InpTrailMinATR;
      double sp=0; datetime tt;

      if(dir>0 && LastSwingLow(slot,sp,tt))
        {
         double cand=sp-atr*buf;
         if(cand<=px-minGap)
           {
            if(cand>g_vpos[i].trailAnchor) g_vpos[i].trailAnchor=cand;
            if(g_vpos[i].trailAnchor>0 && g_vpos[i].trailAnchor<=px-minGap)
               MoveSL(i,g_vpos[i].trailAnchor,"STRUCTURE_TRAIL_3.0R");
           }
        }
      else if(dir<0 && LastSwingHigh(slot,sp,tt))
        {
         double cand=sp+atr*buf;
         if(cand>=px+minGap)
           {
            if(g_vpos[i].trailAnchor==0||cand<g_vpos[i].trailAnchor) g_vpos[i].trailAnchor=cand;
            if(g_vpos[i].trailAnchor>0 && g_vpos[i].trailAnchor>=px+minGap)
               MoveSL(i,g_vpos[i].trailAnchor,"STRUCTURE_TRAIL_3.0R");
           }
        }
      SaveVPos(i);
     }

   // Positive pyramiding is evaluated after the root runner's protection/trailing
   // state has been updated, so a new add can only happen from a protected winner.
   if(!g_vpos[i].isDCA) TryPositiveDCA(i);
  }

// Exit engine: close/tighten runners by exit pressure (spec 16-18)
void EvaluateExits()
  {
   // R15: runners are NOT closed by score/reversal/profit-giveback logic.
   // Their lifecycle is: initial structural SL -> R protection -> M15 structure trail.
   // This deliberately allows a 5R/10R/20R move to continue while structure holds.
   // TP_ONLY positions are still handled by their virtual/broker TP elsewhere.
   return;
  }

void CheckVirtualSLTP()
  {
   for(int i=ArraySize(g_vpos)-1;i>=0;i--)
     {
      ulong t=g_vpos[i].ticket;
      if(!PositionSelectByTicket(t)) continue;
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      int dir=g_vpos[i].dir;
      bool hitSL=(dir>0?bid<=g_vpos[i].virtualSL:ask>=g_vpos[i].virtualSL);
      bool hitTP=(g_vpos[i].virtualTP>0 && (dir>0?bid>=g_vpos[i].virtualTP:ask<=g_vpos[i].virtualTP));
      if((hitSL||hitTP)&&InpManagePositions&&IsTradeAllowed())
        {
         trade.SetExpertMagicNumber(InpMagic);
         if(trade.PositionClose(t,InpMaxSlippagePoints))
            PrintFormat("[BV3] Virtual %s #%I64u closed at bid=%.2f ask=%.2f",hitTP?"TP":"SL",t,bid,ask);
        }
     }
  }

void SyncBrokerSLTP()
  {
   if(!InpUseBrokerSLTP||!InpManagePositions||!IsTradeAllowed()) return;
   for(int i=0;i<ArraySize(g_vpos);i++)
     {
      ulong t=g_vpos[i].ticket;
      if(!PositionSelectByTicket(t)) continue;
      double bsl=PositionGetDouble(POSITION_SL);
      int dir=g_vpos[i].dir;
      if(MathAbs(bsl-g_vpos[i].virtualSL)>g_point)
        {
         // MANUAL SL GUARD: If the broker SL is tighter/better than virtual SL (user moved it),
         // adopt it as the new virtualSL instead of fighting the user.
         bool isManualBetter = false;
         if(bsl > 0.0)
           {
            if(dir > 0 && bsl > g_vpos[i].virtualSL) isManualBetter = true;
            if(dir < 0 && (bsl < g_vpos[i].virtualSL || g_vpos[i].virtualSL <= 0.0)) isManualBetter = true;
           }
           
         if(isManualBetter)
           {
            g_vpos[i].virtualSL = bsl;
            SaveVPos(i);
            if(InpVerboseLog) PrintFormat("[BV3] Adopted manual SL for #%I64u at %.2f", t, bsl);
           }
         else
           {
            trade.SetExpertMagicNumber(InpMagic); trade.PositionModify(t,g_vpos[i].virtualSL,g_vpos[i].virtualTP); 
           }
        }
     }
  }

void ManagePositions()
  {
   for(int i=0;i<ArraySize(g_vpos);i++) ManageRunner(i);
   EvaluateExits();
  }

//==================================================================
// ENTRY GATING
//==================================================================
bool HasOpenInDir(int dir)
  {
   for(int i=0;i<ArraySize(g_vpos);i++) if(g_vpos[i].dir==dir) return true;
   return false;
  }

// A fresh (recent) structural event in 'dir' on InpTriggerMinTF or higher = a real
// trigger, not stale context. ENUM_TIMEFRAMES values increase M1<M5<M15<M30<H1,
// so tf>=InpTriggerMinTF cleanly enforces "this timeframe or bigger".
bool HasFreshTrigger(int dir)
  {
   datetime freshCut=TimeCurrent()-InpTriggerFreshMinutes*60;
   ENUM_TIMEFRAMES minTF=(InpTriggerMinTF==PERIOD_CURRENT?InpTFTrigger:InpTriggerMinTF);
   for(int i=0;i<ArraySize(g_events);i++)
     {
      if(g_events[i].direction!=dir) continue;
      if(g_events[i].tf<minTF) continue;
      if(g_events[i].tf>InpTFStructure) continue;   // ignore HTF-only context as a trigger
      if(g_events[i].time<freshCut) continue;
      int t=g_events[i].type;
      if(t==EV_DISPLACEMENT||t==EV_BOS||t==EV_CHOCH||t==EV_SWEEP||t==EV_REJECTION) return true;
     }
   return false;
  }

// True if current server time is inside the configured session window.
bool InSessionWindow()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int h=dt.hour;
   int s=InpSessionStartHour, e=InpSessionEndHour;
   if(s==e) return true;                 // 0-length window => no filtering
   if(s<e)  return (h>=s && h<e);        // same-day window
   return (h>=s || h<e);                 // window wraps midnight
  }

// True if the last closed M1 bar shows an abnormal range, or the live spread has
// spiked far above its smoothed average => treat as a news event, avoid entering.
bool IsNewsSpike()
  {
   double atrM1=ATR(InpTFTrigger,1);
   if(atrM1>0 && InpNewsSpikeATR>0)
     {
      double hi=iHigh(_Symbol,InpTFTrigger,1);
      double lo=iLow(_Symbol,InpTFTrigger,1);
      if(hi>0&&lo>0&&(hi-lo)>InpNewsSpikeATR*atrM1) return true;
     }
   if(InpNewsSpreadMult>0 && g_spreadEMA>0)
     {
      double cur=g_snap.spreadPoints;
      if(cur>g_spreadEMA*InpNewsSpreadMult && cur>InpMaxSpreadPoints*0.5) return true;
     }
   return false;
  }

void TryEntry()
  {
   // decide side
   int dir=0; int win=0,los=0; string reasons="";
   if(g_snap.buyScore>=InpScoreEntry && g_snap.buyScore-g_snap.sellScore>=InpScoreMinMargin){ dir=1;win=g_snap.buyScore;los=g_snap.sellScore;reasons=g_snap.buyReasons; }
   else if(g_snap.sellScore>=InpScoreEntry && g_snap.sellScore-g_snap.buyScore>=InpScoreMinMargin){ dir=-1;win=g_snap.sellScore;los=g_snap.buyScore;reasons=g_snap.sellReasons; }
   if(dir==0) return;

   string why="";
   if(!SpreadOK()) why="spread";
   else if(g_dailyStop) why="daily stop";
   else if(!IsTradeAllowed()) why="trade not allowed";
   else if(CountEA()>=InpMaxOpenPositions) why="max positions";
   else if(HasOpenInDir(dir)) why="already exposed same dir";
   else if(g_snap.regime==REGIME_COMPRESSION) why="compression watch-only";
   else if(InpUseSessionFilter&&!InSessionWindow()) why="outside session";
   else if(InpBlockNewsSpike&&IsNewsSpike()) why="news/volatility spike";

   // Anti-chase: if price is already extended far from the regime EMA in the
   // entry direction AND there is no nearby zone to lean on, the move has
   // already happened -> do not chase it. Wait for a pullback/zone instead.
   if(why=="")
     {
      double atrC=g_snap.atrRegime;
      if(atrC>0&&g_snap.emaSlow>0)
        {
         double px=(dir>0?g_snap.ask:g_snap.bid);
         double ext=(dir>0?(px-g_snap.emaSlow):(g_snap.emaSlow-px))/atrC;
         bool fz=false;
         double zs=ZoneSupportForDir(dir,InpTFSetup,fz);
         double zc=ZoneSupportForDir(dir,InpTFConfirm,fz);
         if(ext>InpMaxChaseATR&&zs<=0&&zc<=0)
            why=StringFormat("chase guard: %.1f ATR from EMA, no zone",ext);
        }
     }

   // Fresh-trigger gate: only enter on a real, recent M1/M5 structural event in
   // the entry direction. Stale context alone must not open a trade.
   if(why==""&&InpRequireFreshTrigger&&!HasFreshTrigger(dir)&&!HasLiveTrigger(dir))
       why="no fresh M1/M5/live trigger";

   // Loss cooldown: do not re-enter the same direction right after a loss
   if(why==""&&InpLossCooldownMin>0)
     {
      datetime last=(dir>0?g_lastLossBuy:g_lastLossSell);
      if(last>0&&(TimeCurrent()-last)<InpLossCooldownMin*60)
         why=StringFormat("cooldown %dm after loss",InpLossCooldownMin);
     }

   // Win cooldown: do not re-enter the same direction right after a win
   if(why==""&&InpWinCooldownMin>0)
     {
      datetime last=(dir>0?g_lastWinBuy:g_lastWinSell);
      if(last>0&&(TimeCurrent()-last)<InpWinCooldownMin*60)
         why=StringFormat("cooldown %dm after win",InpWinCooldownMin);
     }

   if(why!=""){ LogDecision(dir,0,"BLOCKED:"+why); return; }

   double sl=StructuralSL(dir);
   if(sl<=0.0){ LogDecision(dir,0,"SL too wide (skipped)"); return; }
   double entry=(dir>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
   if((dir>0&&sl>=entry)||(dir<0&&sl<=entry)){ LogDecision(dir,0,"BAD_SL"); return; }

   // Log-only mode: record the decision we WOULD take, but never touch the market.
   if(InpLogOnlyMode){ LogDecision(dir,1,"LOG_ONLY would-enter sl="+DoubleToString(sl,g_digits)); return; }

   OpenSignal(dir,sl);
  }

//==================================================================
// LOGGING (spec section 21)
//==================================================================
void LogDecision(int dir,int fired,string note)
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   string line=StringFormat("%04d.%02d.%02d %02d:%02d:%02d | dir=%s fired=%d regime=%s H4=%s H1=%s M30=%s | buy=%d sell=%d | atrR=%.2f atrT=%.2f spread=%.0f | %s | %s",
      dt.year,dt.mon,dt.day,dt.hour,dt.min,dt.sec,
      dir>0?"BUY":(dir<0?"SELL":"NONE"),fired,RegimeStr(g_snap.regime),
      BiasStr(g_snap.htfBiasMajor),BiasStr(g_snap.htfBias),BiasStr(g_snap.structBias),
      g_snap.buyScore,g_snap.sellScore,g_snap.atrRegime,g_snap.atrTrigger,g_snap.spreadPoints,
      note,(dir>0?g_snap.buyReasons:g_snap.sellReasons));
   g_lastDecision=line;
   if(InpVerboseLog) Print("[BV3] "+line);
   if(InpWriteCSV&&g_logHandle!=INVALID_HANDLE)
     {
      string csv=StringFormat("%04d.%02d.%02d %02d:%02d;%s;%d;%s;%d;%d;%.2f;%.0f;%s\n",
         dt.year,dt.mon,dt.day,dt.hour,dt.min,dir>0?"BUY":(dir<0?"SELL":"NONE"),fired,
         RegimeStr(g_snap.regime),g_snap.buyScore,g_snap.sellScore,g_snap.atrRegime,g_snap.spreadPoints,note);
      FileWriteString(g_logHandle,csv);
      FileFlush(g_logHandle);
     }
  }

//==================================================================
// DASHBOARD
//==================================================================
double CurrencyMultiplier()
  {
   string curr = AccountInfoString(ACCOUNT_CURRENCY);
   StringToUpper(curr);
   if(StringFind(curr, "USC") >= 0 || StringFind(curr, "CENT") >= 0) return 0.01;
   return 1.0;
  }

double BotPnL(datetime fromTime)
  {
   double pnl = BasketFloating();
   if(HistorySelect(fromTime, TimeCurrent()))
     {
      int deals = HistoryDealsTotal();
      for(int i=0; i<deals; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal > 0)
           {
            if(HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(deal, DEAL_MAGIC) == InpMagic)
              {
               pnl += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
              }
           }
        }
     }
   return pnl;
  }

void SetRow(int row,string label,string value,color clr)
  {
   string n1=g_prefix+"DB_L"+IntegerToString(row);
   string n2=g_prefix+"DB_V"+IntegerToString(row);
   if(ObjectFind(0,n1)<0){ ObjectCreate(0,n1,OBJ_LABEL,0,0,0); ObjectSetInteger(0,n1,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,n1,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,n1,OBJPROP_XDISTANCE,240);ObjectSetInteger(0,n1,OBJPROP_YDISTANCE,24+row*18);
      ObjectSetInteger(0,n1,OBJPROP_FONTSIZE,9);ObjectSetString(0,n1,OBJPROP_FONT,"Consolas"); ObjectSetInteger(0,n1,OBJPROP_ZORDER,10); }
   if(ObjectFind(0,n2)<0){ ObjectCreate(0,n2,OBJ_LABEL,0,0,0); ObjectSetInteger(0,n2,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,n2,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,n2,OBJPROP_XDISTANCE,130);ObjectSetInteger(0,n2,OBJPROP_YDISTANCE,24+row*18);
      ObjectSetInteger(0,n2,OBJPROP_FONTSIZE,9);ObjectSetString(0,n2,OBJPROP_FONT,"Consolas"); ObjectSetInteger(0,n2,OBJPROP_ZORDER,10); }
   ObjectSetString(0,n1,OBJPROP_TEXT,label);ObjectSetInteger(0,n1,OBJPROP_COLOR,clrWhite);
   ObjectSetString(0,n2,OBJPROP_TEXT,value);ObjectSetInteger(0,n2,OBJPROP_COLOR,clr);
  }

void Dashboard()
  {
   if(!InpShowDashboard) return;
   
   string bgName=g_prefix+"DB_BG";
   if(ObjectFind(0,bgName)<0)
     {
      ObjectCreate(0,bgName,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,bgName,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,bgName,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,bgName,OBJPROP_BGCOLOR,clrBlack);
      ObjectSetInteger(0,bgName,OBJPROP_COLOR,clrBlack); 
      ObjectSetInteger(0,bgName,OBJPROP_BACK,false); 
      ObjectSetInteger(0,bgName,OBJPROP_ZORDER,0); 
     }
   ObjectSetInteger(0,bgName,OBJPROP_XDISTANCE,250);
   ObjectSetInteger(0,bgName,OBJPROP_YDISTANCE,15);
   ObjectSetInteger(0,bgName,OBJPROP_XSIZE,240); 

   int r=0;
   SetRow(r++,"BOT v3 r14","XAUUSD adaptive",clrGold);
   SetRow(r++,"Regime",RegimeStr(g_snap.regime)+" "+BiasStr(g_snap.regimeDir),
          g_snap.regime==REGIME_TREND?clrLime:(g_snap.regime==REGIME_BREAKOUT?clrAqua:clrOrange));
   SetRow(r++,"ADX",DoubleToString(g_snap.adx,1),clrWhite);
   SetRow(r++,"H4 / H1",BiasStr(g_snap.htfBiasMajor)+" / "+BiasStr(g_snap.htfBias),clrWhite);
   SetRow(r++,"M30 struct",BiasStr(g_snap.structBias),clrWhite);
   SetRow(r++,"BUY score",IntegerToString(g_snap.buyScore),g_snap.buyScore>=InpScoreEntry?clrLime:clrWhite);
   SetRow(r++,"SELL score",IntegerToString(g_snap.sellScore),g_snap.sellScore>=InpScoreEntry?clrTomato:clrWhite);
   SetRow(r++,"Entry thr",IntegerToString(InpScoreEntry),clrWhite);
   SetRow(r++,"Events",IntegerToString(ArraySize(g_events))+"  Zones "+IntegerToString(ArraySize(g_zones)),clrWhite);
   SetRow(r++,"Positions",IntegerToString(CountEA()),clrWhite);
   SetRow(r++,"Spread",DoubleToString(g_snap.spreadPoints,0),SpreadOK()?clrWhite:clrTomato);
   string runnerState="-";
   for(int i=0;i<ArraySize(g_vpos);i++) if(g_vpos[i].isRunner){ runnerState=StringFormat("st%d %s",g_vpos[i].stage,g_vpos[i].dir>0?"BUY":"SELL"); break; }
   SetRow(r++,"Runner",runnerState,clrAqua);
   
   double mult = CurrencyMultiplier();
   double dailyPnL = BotPnL(g_dayStart) * mult;
   
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.day = 1; dt.hour = 0; dt.min = 0; dt.sec = 0;
   double monthlyPnL = BotPnL(StructToTime(dt)) * mult;
   
   SetRow(r++,"Daily PnL", "$"+DoubleToString(dailyPnL,2), dailyPnL>=0?clrLime:clrTomato);
   SetRow(r++,"Monthly PnL", "$"+DoubleToString(monthlyPnL,2), monthlyPnL>=0?clrLime:clrTomato);
   
   ObjectSetInteger(0,bgName,OBJPROP_YSIZE,r*18 + 15);
   
   ChartRedraw();
  }

//==================================================================
// ZONE DRAWING
//==================================================================
void DrawZones()
  {
   if(!InpDrawZones) return;
   datetime now=TimeCurrent();
   for(int i=0;i<ArraySize(g_zones);i++)
     {
      if(g_zones[i].state==ZS_FAILED||g_zones[i].state==ZS_INVALID||g_zones[i].state==ZS_MITIGATED) continue;
      string nm=g_prefix+"Z_"+IntegerToString((long)g_zones[i].formed)+"_"+IntegerToString(g_zones[i].kind)+"_"+IntegerToString((int)g_zones[i].tf);
      if(ObjectFind(0,nm)<0)
        {
         ObjectCreate(0,nm,OBJ_RECTANGLE,0,g_zones[i].formed,g_zones[i].hi,now+PeriodSeconds(InpTFSetup)*6,g_zones[i].lo);
         ObjectSetInteger(0,nm,OBJPROP_COLOR,g_zones[i].dir>0?InpColorDemand:InpColorSupply);
         ObjectSetInteger(0,nm,OBJPROP_FILL,false);ObjectSetInteger(0,nm,OBJPROP_BACK,true);
         ObjectSetInteger(0,nm,OBJPROP_WIDTH,1);
        }
      else ObjectMove(0,nm,1,now+PeriodSeconds(InpTFSetup)*6,g_zones[i].lo);
     }
  }

void ClearZoneObjects()
  {
   ObjectsDeleteAll(0,g_prefix);
  }

//==================================================================
// SNAPSHOT REFRESH
//==================================================================
void RefreshATR()
  {
   g_snap.atrRegime=ATR(InpTFRegime,1);
   g_snap.atrTrigger=ATR(InpTFTrigger,1);
   if(g_snap.atrRegime<=0) g_snap.atrRegime=g_snap.atrTrigger;
  }

void RefreshSnapshot(bool newRegimeBar,bool newTriggerBar)
  {
   g_snap.bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   g_snap.ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   g_snap.spreadPoints=CurrentSpreadPoints();

   if(newRegimeBar)
     {
      for(int s=0;s<g_tfCount;s++) BuildSwings(g_tfs[s],s);
      g_snap.htfBiasMajor=CalcHTFBias(InpTFContextMajor);
      g_snap.htfBias=CalcHTFBias(InpTFContext);
      RefreshATR();
      ClassifyRegime();
      // M30 structure bias by EMA cross on the structure timeframe
      int eF=iMA(_Symbol,InpTFStructure,20,0,MODE_EMA,PRICE_CLOSE);
      int eS=iMA(_Symbol,InpTFStructure,50,0,MODE_EMA,PRICE_CLOSE);
      double f[1],s[1];
      g_snap.structBias=0;
      if(CopyBuffer(eF,0,1,1,f)>=1&&CopyBuffer(eS,0,1,1,s)>=1)
         g_snap.structBias=(f[0]>s[0]?1:(f[0]<s[0]?-1:0));
      IndicatorRelease(eF);IndicatorRelease(eS);

      // zone detection on setup + confirm + structure TFs
      DetectZones(InpTFStructure);
      DetectZones(InpTFSetup);
      DetectZones(InpTFConfirm);
     }

   // events scan on each new trigger bar (fast) for M1/M5, plus regime TF
   if(newTriggerBar)
     {
      int s1=TfSlot(InpTFTrigger); if(s1>=0) ScanStructureEvents(InpTFTrigger,s1);
      int s2=TfSlot(InpTFConfirm); if(s2>=0) ScanStructureEvents(InpTFConfirm,s2);
      // keep M5 zones fresh every trigger bar so the boxes track fast moves
      DetectZones(InpTFConfirm);
     }
   if(newRegimeBar)
     {
      int s3=TfSlot(InpTFSetup); if(s3>=0) ScanStructureEvents(InpTFSetup,s3);
      int s4=TfSlot(InpTFStructure); if(s4>=0) ScanStructureEvents(InpTFStructure,s4);
     }

   DecayEvents();
   UpdateZoneStates();

   g_snap.buyScore=ScoreDirection(1,g_snap.buyReasons);
   g_snap.sellScore=ScoreDirection(-1,g_snap.sellReasons);
  }

//==================================================================
// INIT / DEINIT
//==================================================================
int TFArray(ENUM_TIMEFRAMES &out[])
  {
   ENUM_TIMEFRAMES list[6];
   list[0]=InpTFStructure;list[1]=InpTFSetup;list[2]=InpTFConfirm;list[3]=InpTFTrigger;
   list[4]=InpTFContext;list[5]=InpTFContextMajor;
   ArrayResize(out,6);
   int n=0;
   for(int i=0;i<6;i++)
     {
      bool dup=false;
      for(int j=0;j<n;j++) if(out[j]==list[i]) dup=true;
      if(!dup){ out[n]=list[i];n++; }
     }
   return n;
  }

//==================================================================
// SINGLE-MANAGER LOCK (one live chart per magic+symbol trades/manages)
//==================================================================
string LockKey(){ return g_prefix+"LOCK_"+IntegerToString((int)InpMagic)+"_"+_Symbol; }
string LockHB() { return LockKey()+"_HB"; }

bool ClaimManagerLock()
  {
   if(!InpSingleManagerLock) return true;              // feature off => always manager
   string k=LockKey();
   double myChart=(double)ChartID();
   datetime now=TimeCurrent();
   if(GlobalVariableCheck(k))
     {
      double owner=GlobalVariableGet(k);
      datetime hb=(GlobalVariableCheck(LockHB())?(datetime)GlobalVariableGet(LockHB()):0);
      bool stale=(now-hb)>60;                          // owner hasn't beat in 60s
      if(owner!=myChart && !stale) return false;       // another LIVE chart owns it
     }
   GlobalVariableSet(k,myChart);
   GlobalVariableSet(LockHB(),(double)now);
   return true;
  }

void BeatManagerLock()
  {
   if(!InpSingleManagerLock||!g_isManager) return;
   if(GlobalVariableCheck(LockKey()) && GlobalVariableGet(LockKey())==(double)ChartID())
      GlobalVariableSet(LockHB(),(double)TimeCurrent());
  }

void ReleaseManagerLock()
  {
   if(!InpSingleManagerLock) return;
   if(GlobalVariableCheck(LockKey()) && GlobalVariableGet(LockKey())==(double)ChartID())
     { GlobalVariableDel(LockKey()); if(GlobalVariableCheck(LockHB())) GlobalVariableDel(LockHB()); }
  }

int OnInit()
  {
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ENUM_TIMEFRAMES tmp[]; g_tfCount=TFArray(tmp);
   ArrayResize(g_tfs,g_tfCount);
   ArrayResize(h_atr,g_tfCount);
   ArrayResize(g_swings,g_tfCount*MAXSW);
   for(int i=0;i<g_tfCount;i++){ g_tfs[i]=tmp[i]; h_atr[i]=iATR(_Symbol,tmp[i],14); }

   h_adx_regime =iADX(_Symbol,InpTFRegime,InpADXPeriod);
   h_bb_regime  =iBands(_Symbol,InpTFRegime,InpBBPeriod,0,InpBBDev,PRICE_CLOSE);
   h_atr_regime =iATR(_Symbol,InpTFRegime,14);
   h_atr_trigger=iATR(_Symbol,InpTFTrigger,14);
   h_ema_fast   =iMA(_Symbol,InpTFRegime,9,0,MODE_EMA,PRICE_CLOSE);
   h_ema_slow   =iMA(_Symbol,InpTFRegime,21,0,MODE_EMA,PRICE_CLOSE);

   if(h_adx_regime==INVALID_HANDLE||h_bb_regime==INVALID_HANDLE||h_atr_regime==INVALID_HANDLE)
     { Print("[BV3] indicator handle creation failed"); return INIT_FAILED; }

   InitializeDailyBaseline();
   if(InpWriteCSV)
     {
      g_logHandle=FileOpen("bot_v3_log.csv",FILE_WRITE|FILE_CSV|FILE_ANSI,',');
      if(g_logHandle!=INVALID_HANDLE)
         FileWriteString(g_logHandle,"time;dir;fired;regime;buy;sell;atr;spread;note\n");
     }

   // Single-manager lock: only one live chart per magic+symbol may trade/manage.
   g_isManager=ClaimManagerLock();
   if(!g_isManager)
      Print("[BV3] Another live instance owns management for this magic+symbol. This chart is READ-ONLY (scores/dashboard only).");

   if(InpManagePositions&&g_isManager) RecoverOpenPositions();

   EventSetMillisecondTimer(500);
   PrintFormat("[BV3] Account mode=%d (0=netting,1=exchange,2=hedging), EntryMode=%s, lot=%.2f",
               (int)AccountInfoInteger(ACCOUNT_MARGIN_MODE),
               InpEntryExitMode==ENTRY_BOTH?"BOTH":(InpEntryExitMode==ENTRY_TP_ONLY?"TP_ONLY":"RUNNER_ONLY"), InpFixedLot);
   Print("[BV3] OnInit OK. Regime/Event/Score engine ready. Detection stays sensitive; the score gate makes the decision strict.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ReleaseManagerLock();
   ClearZoneObjects();
   if(g_logHandle!=INVALID_HANDLE) FileClose(g_logHandle);
   ChartRedraw();
  }

//==================================================================
// MAIN LOOPS
//==================================================================
void OnTimer()
  {
   BeatManagerLock();
   // management runs frequently even between bars so profit protection is timely
   if(InpManagePositions&&g_isManager)
     {
      SyncVPos();
      CheckVirtualSLTP();
      ManagePositions();
      SyncBrokerSLTP();
      CheckLossGuards();
     }
  }

void OnTick()
  {
   datetime now=TimeCurrent();
   MqlDateTime dt; TimeToStruct(now,dt);
   datetime today=now-(dt.hour*3600+dt.min*60+dt.sec);
   if(today!=g_dayStart) InitializeDailyBaseline();

   // bar gates
   datetime trigBar=iTime(_Symbol,InpTFTrigger,0);
   datetime regBar =iTime(_Symbol,InpTFRegime,0);
   bool newTriggerBar=(trigBar!=g_lastTriggerBar);
   bool newRegimeBar =(regBar!=g_lastRegimeBar);
   if(newTriggerBar) g_lastTriggerBar=trigBar;
   if(newRegimeBar)  g_lastRegimeBar=regBar;

   if(newTriggerBar||newRegimeBar||ArraySize(g_events)==0)
      RefreshSnapshot(newRegimeBar,newTriggerBar);
   else
     {
      // Keep live prices and score inputs fresh without rescanning history.
      g_snap.bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      g_snap.ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      g_snap.spreadPoints=CurrentSpreadPoints();
      DecayEvents();
      UpdateZoneStates();
      g_snap.buyScore=ScoreDirection(1,g_snap.buyReasons);
      g_snap.sellScore=ScoreDirection(-1,g_snap.sellReasons);
     }

   // smooth the live spread for the news-spike guard
   double curSpread=CurrentSpreadPoints();
   g_spreadEMA=(g_spreadEMA<=0.0)?curSpread:(g_spreadEMA*0.99+curSpread*0.01);

   if(InpManagePositions&&g_isManager)
     {
      SyncVPos();
      CheckVirtualSLTP();
      ManagePositions();
      SyncBrokerSLTP();
     }

   if(InpDrawZones&&(newRegimeBar||newTriggerBar)) DrawZones();
   Dashboard();

   // A non-manager chart is read-only: it shows scores but never trades/manages.
   if(!g_isManager) return;
   BeatManagerLock();

   // Evaluate on every tick, but at most once per trigger bar.
   // HasLiveTrigger() can therefore enter before the M1 candle closes.
   static datetime lastEntryBar=0;
   if(newTriggerBar) lastEntryBar=0;
   if(lastEntryBar!=trigBar)
     {
      int before=CountEA();
      TryEntry();
      if(CountEA()!=before) lastEntryBar=trigBar;
     }
  }
//+------------------------------------------------------------------+
