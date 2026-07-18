# The XAUT/wstGBP Pool — a plain-English guide

*For traders and liquidity providers. Companion to the developer docs
(`SECURITY_XAUT_WSTGBP.md`, deploy runbook `DEPLOY.md`). **Live on mainnet since 2026-07-17**
(addresses in §8).*

## TL;DR

- It's a normal Uniswap v4 pool for swapping **XAUT ↔ wstGBP** — the first on-chain gold/sterling
  market — with one twist: the trading fee is decided per-swap by a small "hook" contract instead
  of being a fixed tier.
- The fee = a **base fee** that depends on direction, plus a **surcharge** that only applies when
  your trade closes a gap between the pool's price and the fair price (computed from the Chainlink
  XAU/USD and GBP/USD feeds and wstGBP's official NAV).
- **The gold feed prices bullion, not the token.** XAUt (the token) trades at a small premium or
  discount to spot gold (within ~±0.5% — and the sign has flipped in 2026), so the pool's resting
  point sits slightly off the feed's fair — that is normal, and the two directions price
  differently there: whichever direction reads as *closing* the token–metal gap pays a ramp
  surcharge on top of its base; the other pays base only. At the ~0.5% discount the venue was
  designed around that means **selling XAUT at rest pays the low base only** while **selling
  wstGBP pays base + surcharge (~0.9% all-in)**; at the small premium measured in July 2026 the
  sides flip and the resting surcharge is only a few bps — a deliberate parameter choice, not a
  bug (see §2 and the FAQ).
- Quotes you see in wallets/routers are exact: the hook is "fee-only", so the standard Uniswap
  quoter simulates it perfectly.
- Nothing about the hook can ever block a swap. Oracle problems or an owner pause only change the
  fee to a flat fallback value.

## 1. The tokens

- **XAUT** — Tether Gold, 6 decimals; one token represents one troy ounce of vaulted London gold.
  Like most issuer-backed tokens (USDC included), its issuer can blacklist addresses and upgrade
  the token contract — the standard trust you accept by holding XAUt anywhere (see §6).
- **wstGBP** — a wrapped, yield-accruing GBP token. Its official value (NAV) is set by its own
  protocol and **ratchets upward** roughly weekly (~4–5%/yr). You can always mint it for tGBP at
  `mintcost` or redeem it at `burncost` (~25bps apart) directly with the wrapper — that
  mint/redeem band is what anchors the sterling leg of this pool.

The pool's price is "how many wstGBP for one XAUT" — roughly 2,300–3,100 at 2026 prices. It moves
with gold and with cable (gold-in-GBP is a genuinely volatile pair: ~37% annualized, about 6×
cable), plus a permanent gentle drift: because the NAV only goes up, one XAUT costs slightly
*fewer* wstGBP every week (~0.09%). Arbitrageurs re-align the pool after each NAV step by buying
wstGBP from the pool and redeeming it with the wrapper. That loop is expected, healthy flow — the
hook's fee schedule is tuned to toll it fairly, not to stop it.

## 2. How the fee is decided

Every swap, the hook:

1. Reads the fair price: `fair = (XAU/USD ÷ GBP/USD) ÷ NAV` (wstGBP per XAUT).
2. Compares the pool's current price to fair → a signed deviation `d` (in ppm; 100 ppm = 1bp).
3. Charges: `fee = directionalBase + surcharge`, where the surcharge is
   `min(slope × (|d| − threshold), cap)` and applies ONLY to trades that push the pool *toward*
   fair (informed flow). Trades pushing away, or inside the threshold band, pay base only.

Direction of the base fee: **selling wstGBP** (the "mint side") pays the higher base;
**selling XAUT** (the "redeem side") pays the lower base. The launch numbers come from the
parameter study in `sim/RESULTS_XAUT.md` — bases 0.50%/0.10%, threshold 10 bps, cap 1% — and can
be re-tuned by the owner (within hard-coded bounds — see §5).

One thing makes this pool different from its siblings: the feed in step 1 prices **spot bullion**,
while the pool trades the **token**, which changes hands at a small premium or discount to it
(the "basis" — estimated ~0.5% below spot at design time, measured ~0.1% *above* in July 2026:
small, and it moves, including through zero). So the pool's natural resting point is the token's
value, slightly off the computed fair — permanently. The parameter study resolved what to do
about that deliberately: the threshold sits *below* the basis magnitude, so at a resting point
beyond the threshold the two directions price very differently — the direction pushing the pool
*away* from the feed's fair pays base only (no threshold setting could surcharge it), while the
direction *closing* the gap pays its base plus a ramp surcharge. At the design-point discount
that meant XAUT-in low base / wstGBP-in ~0.9% all-in; at a premium the sides flip (and at the
small July-2026 premium the resting surcharge is only a few bps either way). The surcharge grows
further (up to the 1% cap) in real gold/cable dislocations, whatever the rest state.

Worked intuition: right after a weekly NAV step, wstGBP in the pool is briefly ~9bps too cheap.
The arb who buys it (XAUT in) always pays the redeem-side base — and also pays ramp surcharge
when the pool's feed-relative deviation is positive, including at a premium rest state. At a
quiet moment your swap pays what the resting point implies — which side carries the resting
surcharge depends on the basis sign at the time (see above). What pays the *full* capped
surcharge is flow sniping a genuine gap after a big gold or cable move.

## 3. When things go wrong (fail-soft, never fail-stop)

If either Chainlink feed (gold or cable) reverts, returns garbage, or goes stale — or wstGBP's NAV
oracle is paused — the hook charges a flat **fallback fee** in both directions and emits an
`OracleFallback` event. Swaps are NEVER blocked. The owner can also `setPaused(true)`, which
forces the same flat fee (again: pricing changes, availability doesn't).

## 4. As a trader

- Use any router/aggregator; quotes are exact (fee-only hook — the stock v4 Quoter simulates it).
- Fees at the resting point depend on your direction AND the current basis sign (§2, FAQ): at
  the design-point ~0.5% discount, **XAUT-in pays the low base (~0.1%)** and **wstGBP-in ~0.9%
  all-in**; at a small premium (the July-2026 measurement) wstGBP-in pays its ~0.5% base and
  XAUT-in ~0.1% plus a few bps of ramp. On top of that, avoid sniping fresh gaps — the surcharge
  ramps to its 1% cap on genuine dislocations.
- Large deviation-closing trades: splitting into slices reduces your total surcharge (each slice
  re-prices at the shrunk gap), but mainnet gas eats the advantage quickly — a full 1%
  realignment here is only ~1 XAUT (~$2,600), so slices get small fast.
- Weekends and the daily 22:00–23:00 UTC break: the gold market is closed and the feed typically
  freezes at the last close (it keeps "heartbeating" the frozen price). The pool keeps trading
  normally; weekend movement is just incremental drift around the resting point, so the
  direction-split fees above carry through the close unchanged. If the feed ever pauses
  outright for more than ~25h, the flat fallback fee applies until it resumes.

## 5. As a liquidity provider

- LP is open to everyone — it's a real AMM pool (unlike the tGBP/wstGBP backstop venue, which
  blocks LP). Standard Uniswap UI / PositionManager flow; tick spacing is 60 (~0.6% steps) —
  appropriate for a pair this volatile, where ranges are wide anyway.
- Center your range on where the **token** trades, not on the raw feed number: the pool rests at
  the token's value, within ~±0.5% of the feed's fair (§2). And mind the drift: the wstGBP price of XAUT
  declines ~5%/yr forever as the NAV ratchets (the reverse of the USDC venue, where wstGBP's
  price rises).
- What the hook does for you: flow closing genuine gold/cable dislocations pays extra, and that
  extra accrues to in-range LPs — and this pair produces ~6× cable's supply of such events. The
  routine weekly realignment always pays the redeem-side base; at a discount rest it is
  non-closing and pays no surcharge, while at a premium rest it is closing and also pays the
  ramp-bounded surcharge described in §2. What the hook can't do: remove inventory risk — you
  hold XAUT + wstGBP, and a gold-in-GBP move (or an XAUt issuer event) is your exposure like in
  any pool.
- The pool owner (a multisig) can re-tune fee parameters within hard bounds: fees can never
  exceed 10%, and the pause never traps funds. Parameter changes emit `FeeParamsSet` on-chain.

## 6. Trust model (what you rely on)

| You trust | For | Bounded by |
|---|---|---|
| Chainlink XAU/USD | the gold leg of fair — **prices bullion, not the token** | staleness window (25h) + fallback fee; the token–metal basis (within ~±0.5%, sign-unstable) is a designed, monitored rest state (§7) |
| Chainlink GBP/USD | the cable leg of fair | staleness window (25h) + fallback fee |
| wstGBP's NAV oracle | the NAV leg of fair | zero/absurd checks + fallback; no staleness signal (documented) |
| XAUt's issuer (Tether) | the token itself — blacklist / upgrade powers | same trust as holding XAUt anywhere; the hook holds no funds (FAQ below) |
| The owner multisig | fee re-tunes + pause | 10% hard fee ceiling; no upgradeability; no custody |

The hook holds no funds, has no upgrade path, and its only privileged surface is fee params +
pause.

## 7. FAQ

**Why doesn't the pool sit exactly at the gold price I see on the feed?** Because the feed prices
bullion and the pool trades the token: XAUt changes hands at a small premium or discount to spot
gold (custody/redemption friction — estimated ~0.5% below at design time, measured ~0.1% above in
July 2026; it moves, including through zero). The pool resting at the token's value is correct
pricing, not a mispricing. Note the fee consequence (§2): at the resting point, the direction
closing the token–metal gap pays base + a ramp surcharge while the other pays base only — and
which direction that is flips with the basis sign. The parameter study chose that split
deliberately. Full analysis: `SECURITY_XAUT_WSTGBP.md` §6.

**What happens on weekends?** Gold observes the FX calendar (closed weekends, plus a daily
22:00–23:00 UTC break). The feed typically keeps repeating its frozen closing price, the pool
keeps trading, and Monday's reopen gap is exactly the kind of event the surcharge exists for. If
the feed instead goes silent past its ~25h window, the flat fallback fee applies — swaps are never
blocked either way. Details: `SECURITY_XAUT_WSTGBP.md` §7.

**What if Tether blacklists an address or upgrades XAUt?** The same thing that would happen to any
XAUt holder — it's issuer risk you carry wherever the token sits. The hook itself never holds
XAUt, and swaps can't be blocked by the hook; LP inventory exposure is yours, as in every XAUt
pool. Full analysis: `SECURITY_XAUT_WSTGBP.md` §8.

**Why is the fee sometimes different from what I saw a block ago?** The deviation is recomputed
from the live pool price every swap, and fair moves when either feed commits a new answer
(XAU/USD updates on a 0.3% move or every 24h; GBP/USD on 0.15% or 24h) or when the NAV steps.

**Why did my quote match execution exactly?** By design — that property (stock-quoter parity to
the wei) is tested on every fee regime including fallback and paused.

**Is the weekly arb flow bad for LPs?** It's the pair's nature: wstGBP appreciates in steps, and
someone will always realign the pool. That flow always pays the redeem-side base — its toll. At
a discount rest it pays no surcharge; at a premium rest it also pays a ramp surcharge because it
closes the positive feed-relative deviation. The full capped surcharge remains reserved for
larger dislocations. The system-level economics (the wrapper protocol also earns 25bps per
mint/redeem round trip) are the same as the sibling venues'.

## 8. Addresses (mainnet)

| Thing | Address |
|---|---|
| `XautWstGbpHook` | `0x68cF17471aA0Fe54578747C6C7e66795bC8020C0` |
| Pool (v4 singleton — id, not address) | poolId `0xcc06806357a71e7af630dce38d74ee16ed8bf1e0055bc66789d7de4dedef8d8a` |
| wstGBP (currency0) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| XAUT (currency1) | `0x68749665FF8D2d112Fa859AA293F07A622782F38` |
| Chainlink XAU/USD | `0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6` |
| Chainlink GBP/USD | `0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5` |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| v4 Quoter (stock — quotes this hook exactly) | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Owner multisig | `0x846a655a4fA13d86B94966DFDf4D9a070e554f7c` |
