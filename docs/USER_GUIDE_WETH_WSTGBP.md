# The WETH/wstGBP Pool — User Guide

*For traders and liquidity providers who know their way around Uniswap but haven't met a v4 hook
before. Status: implemented and audited-internally, pre-deploy — the hook and pool addresses below
are filled in at launch.*

---

## TL;DR

- This is a **normal Uniswap v4 pool** for WETH/wstGBP. You swap in it and LP in it exactly like
  any other Uniswap pool — same UI, same routers, same position NFTs.
- The one difference: **the swap fee is not a fixed 0.30%**. A small attached program (a "hook")
  sets the fee for each swap individually, between 0.02% and 1.00%, based on which token you're
  selling and whether the pool's price has drifted away from a reference "fair" price.
- If you're trading **with** the drift (pushing the pool further from fair) or the pool is near
  fair, you pay a flat base fee: **0.30%** selling wstGBP, **0.05%** selling WETH.
- If you're trading **against** the drift (buying the temporarily-cheap asset — the profitable,
  arbitrage-like direction), you pay the base **plus a surcharge** that grows with the size of the
  drift, capped at +0.60%.
- If anything goes wrong with the price feeds, the pool doesn't stop — it just charges a flat
  0.30% both ways, i.e. it behaves exactly like a standard 0.30% pool until the feeds recover.
- The hook **never touches your tokens**, can **never block a swap**, and its logic is immutable.

---

## 1. The tokens

**WETH** — wrapped ETH, you know this one.

**wstGBP** (`0x57C3…B7aE`) — a yield-accruing wrapper over tGBP, a tokenized British-pound
instrument. Think of it as "GBP that slowly grows": each wstGBP is redeemable for an amount of tGBP
given by its **NAV** (net asset value), and that NAV ratchets upward over time as the underlying
yield accrues. One consequence worth internalizing: the "right" price of this pool drifts slowly
even if ETH/GBP doesn't move, because each wstGBP is quietly becoming worth slightly more GBP.

wstGBP also has its own primary market: anyone (not on the issuer's ban list) can **mint** wstGBP
with tGBP or **redeem** it back, at NAV-based prices about 0.25% apart. That built-in mint/redeem
spread is why this pool's two directions carry different base fees (explained below), and it's
served on-chain by a sibling pool — the tGBP/wstGBP *backstop* pool — that always quotes those
exact prices with unlimited depth.

## 2. What's a hook, and what does this one do?

Uniswap v4 lets a pool attach a small immutable contract — a **hook** — that the PoolManager calls
at fixed moments (before a swap, after a swap, etc.). Hooks can do a lot in general; **this one
deliberately does almost nothing**:

- Before each swap it computes **one number — the LP fee for that swap** — and hands it back.
- After each swap it emits an event recording the fee it charged and why.
- That's it. It holds no funds, takes no cut for itself, can't reorder or reject your trade, and
  has no special powers over LP positions. Every fee it sets goes to the pool's liquidity
  providers, exactly like the fee in any other Uniswap pool.

Because the hook does nothing but pick the fee number, everything else about the pool is stock
Uniswap: the standard Quoter quotes it **exactly**, aggregators route through it normally, and the
Uniswap web app manages LP positions on it like any other v4 pool.

## 3. How the fee is decided

### 3.1 The reference "fair" price

The hook computes what one WETH *should* be worth in wstGBP, from three public sources:

```
fair (wstGBP per WETH) = (Chainlink ETH/USD ÷ Chainlink GBP/USD) ÷ wstGBP NAV
```

ETH/USD divided by GBP/USD gives ETH's price in pounds; dividing by the NAV converts pounds into
wstGBP units. This fair price is read fresh at the first swap of every transaction.

### 3.2 The deviation

The hook then compares the **pool's current price** against fair:

```
deviation = pool price / fair price − 1
```

A positive deviation means the pool is paying more wstGBP per WETH than fair — WETH is "rich" in
this pool. A negative deviation means WETH is "cheap" here. Trading naturally pushes the pool
around fair; arbitrageurs pull it back.

### 3.3 The two ingredients of your fee

**Directional base fee.** Selling wstGBP into the pool costs a **0.30%** base; selling WETH costs a
**0.05%** base. The asymmetry isn't favoritism — it's symmetry. Recall that wstGBP's own
mint/redeem machinery carries a ~0.25% spread on the redeem side. Setting this pool's bases 25 bps
apart makes a round trip through *either* venue cost the same in total, so neither direction of the
arbitrage loop between the two pools is privileged.

**Toxicity surcharge.** If the pool has drifted more than **0.10%** from fair, swaps in the
*closing* direction — the ones buying the asset that's cheap versus fair, i.e. the trade an
arbitrageur would make — pay an extra fee on top of the base:

```
surcharge = 0.5 × (deviation beyond 0.10%), capped at 0.60%
```

Swaps in the other direction (pushing the pool further from fair), and all swaps inside the 0.10%
band, pay base only. There is no cliff: the surcharge starts at zero right at the band edge and
grows linearly.

The final fee is clamped to **[0.02%, 1.00%]** (with the current parameters the clamp never
actually binds — the worst case is base 0.30% + cap 0.60% = 0.90%).

### 3.4 Worked examples

Say fair is 1,900 wstGBP per WETH.

| Pool state | You sell wstGBP (buy WETH) | You sell WETH (buy wstGBP) |
|---|---|---|
| Pool at fair (within ±0.10%) | **0.30%** | **0.05%** |
| Pool 0.5% **above** fair (WETH rich) | 0.30% (you push it richer) | **0.25%** (0.05 + 0.5×0.4 — you're closing) |
| Pool 1.0% above fair | 0.30% | **0.50%** (0.05 + 0.5×0.9) |
| Pool 2.0% above fair | 0.30% | **0.65%** (surcharge capped at 0.60) |
| Pool 1.0% **below** fair (WETH cheap) | **0.75%** (0.30 + 0.45 — now *you're* closing) | 0.05% |
| Any oracle problem, or paused | **0.30%** | **0.30%** |

Two things to notice. First, **the surcharge only applies when you're buying the discounted
asset** — by definition you're getting a better-than-fair execution price, and the surcharge takes
a slice of that edge for the LPs who provided it. Ordinary traders near fair just pay the base.
Second, the direction you trade matters more than in a static pool: the same notional can cost
0.05% or 0.75% depending on which side of fair the pool sits and which way you're going.

### 3.5 Why bother? (what the surcharge fixes)

In a static-fee pool, the traders who systematically make money are arbitrageurs correcting the
price after the market moves — and their profit is exactly the LPs' loss (the effect known as LVR,
or "impermanent loss with extra steps"). A flat 0.30% charges a grandmother's weekly swap and a
high-frequency arb desk identically. This hook prices them differently: uninformed flow pays base,
deviation-closing (informed) flow pays for the edge it's extracting. In backtests over a trending
year (2021) and a choppy year (2024), this fee policy beat an otherwise-identical static 0.30% pool
by roughly **8–9 percentage points of LP PnL** in each period — and the asymmetric bases *without*
the surcharge actually did worse than static, so the surcharge is the whole point.

## 4. When things go wrong (they fail *soft*)

The hook's first design rule is **never brick the pool**. Every failure mode degrades pricing, not
availability:

| Situation | Effect |
|---|---|
| Chainlink ETH/USD or GBP/USD reverts, returns garbage, or goes stale (ETH: >75 min old, GBP: >25 h old) | Flat 0.30% fee both directions until the feed recovers. Swaps continue. |
| wstGBP NAV oracle paused (reads zero) | Same flat 0.30% fallback. |
| Owner hits the pause switch | Same flat 0.30% — pause changes *pricing*, it never blocks swaps. |
| Everything healthy | The full dynamic fee as described above. |

In other words: the pool's worst case **is** a standard 0.30% Uniswap pool. Fallback swaps are
flagged in the hook's events (`OracleFallback`, and `fallbackMode` on `SwapFee`) so anyone can
monitor how often it happens.

## 5. Using the pool as a trader

**Just trade it.** Any v4-capable interface works — the Uniswap web app, aggregators, routers.
There are no special approvals, tokens flow exactly as in any other pool.

- **Quotes are exact.** Because the hook is fee-only, the standard Uniswap v4 Quoter
  (`0x52F0…1203`) simulates it perfectly — the quoted amount is the amount you'll get if the pool
  state doesn't change before execution. Set slippage tolerance as you normally would; the fee
  itself is deterministic given the pool state.
- **Mind the direction.** Before a large trade it's worth knowing where the pool sits versus fair —
  if you're about to buy the discounted side of a large deviation, you'll pay a surcharge (though
  you're still buying at a discount). The quote already includes it.
- **Big closing trades can be split.** The fee is computed from the deviation *at the start of your
  swap*, on your whole amount. A large trade that closes a big deviation therefore pays the
  "top-of-the-ramp" rate on all of it; the same amount in several smaller swaps pays a declining
  rate as each slice shrinks the deviation. This is known, intentional, and bounded — the sliced
  total converges to the fee schedule's fair integral, and gas costs limit how finely splitting
  pays off. Casual sizes won't notice; if you're moving size into a large deviation, split (or use
  an aggregator that does).
- **Seeing what you paid.** Every swap emits the standard PoolManager `Swap` event whose `fee`
  field is the rate you were charged (note for the curious: the pool's `slot0.lpFee` always reads
  0 — per-swap override fees are never written there). The hook also emits
  `SwapFee(mintSide, fee, deviationPpm, fallbackMode)` alongside, which tells you the side, the
  deviation it measured, and whether fallback pricing applied.
- **Units, if you read the contracts:** everything on-chain is in **ppm** (parts per million).
  1 bp = 100 ppm; 0.30% = 3000 ppm.

## 6. Using the pool as a liquidity provider

**It's a standard v4 pool — LP is open to everyone.** Positions are ordinary PositionManager NFTs;
the Uniswap app's New position / Increase / Remove / Collect all work unchanged. tickSpacing is 60.

What the hook changes for you is only the **revenue side**:

- You earn the dynamic fee instead of a flat one. All of it — base and surcharge — accrues to
  in-range liquidity exactly like normal fees. The hook takes nothing.
- The surcharge is targeted LVR recapture: the flow that normally bleeds LPs (arbitrage correcting
  stale prices) is exactly the flow that pays extra here. That's where the backtested outperformance
  versus a static 0.30% pool comes from (§3.5).
- Fee revenue is direction-skewed by design: near fair, wstGBP-sellers pay 6× what WETH-sellers
  pay. Over time the mix depends on which way ETH/GBP flows.

What it does **not** change:

- Your risks are the standard ones: impermanent loss against the WETH↔wstGBP price (largely the
  ETH/GBP exchange rate, plus the slow NAV drift), and earning nothing while out of range. The
  hook cannot touch, lock, or migrate your position.
- One honest caveat: nothing prevents classic LP competition, including just-in-time liquidity
  around big surcharged swaps (measured impact: modest, bounded by the fee the swap pays — and the
  surcharge itself shrinks the JIT edge, since JIT absorbs the adverse price move it straddles).

The pool also contains **protocol-owned liquidity** (the issuer's treasury LPs here too, via the
same standard positions). It has no special rights; it earns and loses like you do.

Note the NAV drift when choosing a range: fair moves down slowly in wstGBP-per-WETH terms as NAV
rises (~the underlying GBP yield per year), on top of ETH/GBP itself. Wide ranges age better here.

## 7. Trust model — what can go wrong, who can do what

**The hook's logic is immutable.** No upgrades, no migrations, no custody. The complete list of
powers held by the owner (a multisig) is:

1. **Retune fee parameters** — bases, band, slope, cap, clamps, staleness windows. Every change is
   bounds-checked on-chain: no fee can ever exceed a hard-coded **10%** ceiling, and the full
   parameter set is emitted in an event on every change. (Current worst case: 0.90%.)
2. **Pause / unpause** — which, again, only switches pricing to the flat 0.30% fallback.

The malicious-owner worst case is therefore: fees pinned at 10% both directions — annoying,
loudly visible in events, and routed around by every aggregator within a block. Funds can't be
taken; trading can't be stopped.

**Oracle trust.** The fee logic (not your funds) depends on two Chainlink feeds and the wstGBP NAV
oracle. Feed failures fail soft (§4). One asymmetry to know: the Chainlink legs have on-chain
staleness checks, but the NAV leg only has a paused/absurd check — a stale-but-plausible NAV would
skew the *fair* estimate (and hence who pays the surcharge) until noticed. It cannot block swaps
or take funds; it's monitored off-chain.

**wstGBP itself** carries its issuer's trust model (a compliance ban list gates transfers, its
oracle prices the NAV). That's a property of the token, not of this pool — if you hold or LP
wstGBP anywhere, you already carry it.

## 8. Addresses

| What | Address |
|---|---|
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| wstGBP | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap v4 Quoter (stock — quotes this pool exactly) | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Chainlink ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink GBP/USD | `0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5` |
| Hook (`WethWstGbpHook`) | *filled in at deploy* |
| Pool ID | *filled in at pool init* |
| Owner multisig | `0x846a655a4fA13d86B94966DFDf4D9a070e554f7c` |

Pool parameters: currency0 = wstGBP, currency1 = WETH, dynamic-fee flag, tickSpacing 60.

## 9. FAQ

**Why did I pay a different fee than someone else in the same pool today?**
The fee depends on your direction and the pool-vs-fair deviation at that moment. Two swaps minutes
apart, or in opposite directions, can legitimately pay 0.05% and 0.75%.

**Is the surcharge a penalty?**
It's a toll on a profit opportunity. It only applies when you're buying the asset the pool is
selling below fair value — you keep most of that discount; LPs get a slice.

**My quote and my execution differed slightly — why?**
Same reason as any pool: state moved between quote and execution (someone traded, or an oracle
updated, changing the fee regime). Quotes are exact against unchanged state; use slippage bounds
as usual.

**Can trading ever be halted?**
No. There is no code path that blocks a swap — not oracle failure, not the pause switch, nothing.
The worst any actor or failure can do to a trader is a flat 0.30% fee.

**Where does the fee go?**
Entirely to in-range LPs, like any Uniswap pool. The hook and its owner take nothing.

**Can the owner rug LPs or traders?**
No custody, no upgrade, no block. The owner can set fees (≤10% hard cap, publicly evented) and
toggle fallback pricing. That's the entire surface.

**What's the relationship to the tGBP/wstGBP pool?**
That sibling pool ("the backstop") sells and buys wstGBP at its NAV-based mint/redeem prices with
effectively unlimited depth. Arbitrageurs run a loop between the two venues — this pool converts
ETH/GBP volatility into flow, the backstop anchors wstGBP's value. The fee bases here are chosen
so that loop is symmetric in both directions.

**Why is `slot0.lpFee` zero when I read the pool?**
Dynamic-fee pools with per-swap overrides never persist the fee to storage. Read the fee from the
`Swap` event (or quote — the Quoter includes it).

**I'm an integrator — anything special?**
No. Fee-only hook: the stock Quoter is exact, standard routers work, standard swap semantics. If
you cache pool metadata, remember the fee field of the PoolKey is the dynamic-fee flag
(`0x800000`), not a rate.
