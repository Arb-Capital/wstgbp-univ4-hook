// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Iwsgem} from "../core/interfaces/Iwsgem.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {WethWstGbpHook} from "./WethWstGbpHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title POLCompounder
/// @notice Holds the WETH/wstGBP pool's protocol-owned liquidity DIRECTLY in the PoolManager (its own
///         `IUnlockCallback` locker; position keyed `(this, tickLower, tickUpper, salt 0)` — no
///         PositionManager NFT) and compounds accrued fees back into the position on keeper demand.
///
/// @dev `compound()` runs poke -> gather -> (oracle-bounded rebalance) -> add -> settle inside ONE
///      unlock, netted by flash accounting:
///      1. poke: `modifyLiquidity(.., 0)` credits accrued fees as positive transient deltas (skipped
///         while the position is empty — that IS the bootstrap path: fund the contract and call
///         `compound()` to mint the initial position).
///      2. gather: available = transient deltas + own ERC-20 balances (prior dust / seed funds).
///         STRUCTURAL INVARIANT: principal never leaves the pool during a compound, so the rebalance
///         swap is capped at fees + dust by construction — no cap parameter needed.
///      3. rebalance: if the availables are off the range's ratio, swap the surplus through the pool
///         itself (the dynamic fee it pays accrues right back to this position — circular, near-free
///         at the consolidated level). Execution price is bounded against the SAME OracleLib fair
///         value the hook uses, ± `toleranceBps`: a sandwich can only degrade execution, so an
///         out-of-bounds fill reverts the whole compound (keeper retries later). In oracle fallback
///         the rebalance is skipped (never trade against pool spot without an oracle bound); the
///         balanced portion still compounds and the rest carries as dust.
///      4. add max liquidity from the availables; residue settles back and is retained as dust for
///         the next round.
///
///      Ops note: the compounder holds/transfers wstGBP, so it must stay off the tGBP ban list
///      (compliance is a permissive-default blacklist; see the README trust model).
contract POLCompounder is IUnlockCallback, Ownable2Step {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // ---------------------------------------------------------------- immutables

    IPoolManager public immutable poolManager;
    Currency public immutable currency0; // wstGBP for the real pair
    Currency public immutable currency1; // WETH
    uint24 public immutable fee; // LPFeeLibrary.DYNAMIC_FEE_FLAG
    int24 public immutable tickSpacing;
    IHooks public immutable hooks; // the WethWstGbpHook
    int24 public immutable tickLower; // range fixed at construction; migration = withdraw + redeploy
    int24 public immutable tickUpper;
    PoolId public immutable poolId;
    uint160 public immutable sqrtLowerX96;
    uint160 public immutable sqrtUpperX96;
    // Same oracle wiring as the hook (shared OracleLib => identical fallback semantics).
    IAggregatorV3 public immutable ethUsdFeed;
    IAggregatorV3 public immutable gbpUsdFeed;
    Iwsgem public immutable wrapper;
    /// @dev Orientation for the oracle bound: input is wstGBP iff `zeroForOne == wstGbpIsCurrency0`.
    bool public immutable wstGbpIsCurrency0;

    bytes32 public constant POSITION_SALT = bytes32(0);
    uint16 public constant MAX_TOLERANCE_BPS = 500;
    /// @dev Rebalance swaps below this share of the total compoundable value are skipped as dust.
    uint256 public constant REBALANCE_EPSILON_BPS = 10;

    // ---------------------------------------------------------------- storage

    mapping(address => bool) public isKeeper;
    uint16 public toleranceBps = 50;
    uint32 public ethUsdStalenessSec = 4500;
    uint32 public gbpUsdStalenessSec = 90_000;

    // ---------------------------------------------------------------- events / errors

    event Compounded(uint256 amount0Used, uint256 amount1Used, uint128 liquidityAdded, uint256 dust0, uint256 dust1);
    event RebalanceSwap(bool zeroForOne, uint256 amountIn, uint256 amountOut);
    event RebalanceSkipped(uint8 reason); // 1 = oracle fallback, 2 = below dust epsilon, 3 = no pool liquidity
    event LiquidityWithdrawn(uint128 liquidity, uint256 amount0, uint256 amount1, address to);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event KeeperSet(address indexed keeper, bool allowed);
    event ToleranceSet(uint16 bps);
    event StalenessSet(uint32 ethWindow, uint32 gbpWindow);

    error NotKeeper();
    error NotPoolManager();
    error PriceOutOfBounds();
    error NothingToCompound();
    error ToleranceTooHigh();
    error WithdrawSlippage();
    error InvalidRange();
    error PoolKeyMismatch();
    error TransferFailed();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        PoolKey memory _key,
        int24 _tickLower,
        int24 _tickUpper,
        IAggregatorV3 _ethUsd,
        IAggregatorV3 _gbpUsd,
        Iwsgem _wrapper,
        address _weth,
        address _owner
    ) Ownable(_owner) {
        if (_tickLower >= _tickUpper || _tickLower % _key.tickSpacing != 0 || _tickUpper % _key.tickSpacing != 0) {
            revert InvalidRange();
        }
        // The key is not trusted: this contract custodies funds against it and prices its rebalance
        // off the WETH/wstGBP oracle wiring, so the key must BE the WETH/wstGBP dynamic-fee pool.
        // Currencies must be the sorted pair, the fee the dynamic flag, and the key's hook must be
        // wired to the exact same feeds/wrapper/WETH this compounder was given.
        {
            (address c0, address c1) =
                address(_wrapper) < _weth ? (address(_wrapper), _weth) : (_weth, address(_wrapper));
            if (
                Currency.unwrap(_key.currency0) != c0 || Currency.unwrap(_key.currency1) != c1
                    || !LPFeeLibrary.isDynamicFee(_key.fee)
            ) revert PoolKeyMismatch();
            WethWstGbpHook hook = WethWstGbpHook(address(_key.hooks));
            if (
                address(hook.ethUsdFeed()) != address(_ethUsd) || address(hook.gbpUsdFeed()) != address(_gbpUsd)
                    || address(hook.wrapper()) != address(_wrapper) || hook.weth() != _weth
                    || hook.poolManager() != _poolManager
            ) revert PoolKeyMismatch();
        }
        poolManager = _poolManager;
        currency0 = _key.currency0;
        currency1 = _key.currency1;
        fee = _key.fee;
        tickSpacing = _key.tickSpacing;
        hooks = _key.hooks;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        poolId = _key.toId();
        sqrtLowerX96 = TickMath.getSqrtPriceAtTick(_tickLower);
        sqrtUpperX96 = TickMath.getSqrtPriceAtTick(_tickUpper);
        ethUsdFeed = _ethUsd;
        gbpUsdFeed = _gbpUsd;
        wrapper = _wrapper;
        wstGbpIsCurrency0 = address(_wrapper) < _weth;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
    }

    function positionKey() public view returns (bytes32) {
        return Position.calculatePositionKey(address(this), tickLower, tickUpper, POSITION_SALT);
    }

    // ---------------------------------------------------------------- views

    /// @notice Claimable (un-poked) fees of the POL position — pure view via extsload, wrap-safe
    ///         unchecked math matching `Position.update`.
    function pendingFees() public view returns (uint256 fee0, uint256 fee1) {
        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
        (uint128 liq, uint256 last0, uint256 last1) = poolManager.getPositionInfo(poolId, positionKey());
        unchecked {
            fee0 = FullMath.mulDiv(fg0 - last0, liq, FixedPoint128.Q128);
            fee1 = FullMath.mulDiv(fg1 - last1, liq, FixedPoint128.Q128);
        }
    }

    /// @notice Everything the next `compound()` can put to work: pending fees + held dust/seed.
    ///         The keeper's trigger quantity.
    function compoundable() external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = pendingFees();
        amount0 += IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        amount1 += IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
    }

    // ---------------------------------------------------------------- keeper path

    /// @notice Compound accrued fees (+ held dust) into the position. See the contract NatSpec for
    ///         the single-unlock flow. Reverts `PriceOutOfBounds` if the rebalance would execute
    ///         off oracle fair (sandwich defense), `NothingToCompound` when there is nothing to add.
    function compound() external onlyKeeper returns (uint128 liquidityAdded) {
        bytes memory res = poolManager.unlock(abi.encode(uint8(1), uint256(0), uint256(0), uint256(0), address(0)));
        liquidityAdded = abi.decode(res, (uint128));
    }

    // ---------------------------------------------------------------- owner path

    /// @notice Remove `liquidity` (type(uint128).max = all) plus its fees to `to`, with slippage floors.
    function withdrawLiquidity(uint128 liquidity, uint256 amount0Min, uint256 amount1Min, address to)
        external
        onlyOwner
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory res = poolManager.unlock(
            abi.encode(uint8(2), uint256(liquidity), amount0Min, amount1Min, to == address(0) ? msg.sender : to)
        );
        (amount0, amount1) = abi.decode(res, (uint256, uint256));
    }

    /// @notice Recover any ERC-20 sitting on the contract (dust, mistaken transfers). Cannot touch
    ///         in-pool principal — that requires `withdrawLiquidity`.
    function sweep(address token, address to) external onlyOwner {
        uint256 amount = IERC20Minimal(token).balanceOf(address(this));
        if (!_transfer(token, to, amount)) revert TransferFailed();
        emit Swept(token, to, amount);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setToleranceBps(uint16 bps) external onlyOwner {
        if (bps > MAX_TOLERANCE_BPS) revert ToleranceTooHigh();
        toleranceBps = bps;
        emit ToleranceSet(bps);
    }

    function setStaleness(uint32 ethWindow, uint32 gbpWindow) external onlyOwner {
        ethUsdStalenessSec = ethWindow;
        gbpUsdStalenessSec = gbpWindow;
        emit StalenessSet(ethWindow, gbpWindow);
    }

    // ---------------------------------------------------------------- locker

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, uint256 a, uint256 b, uint256 c, address to) =
            abi.decode(raw, (uint8, uint256, uint256, uint256, address));
        if (action == 1) return abi.encode(_compound());
        return _withdraw(uint128(a), b, c, to);
    }

    function _compound() internal returns (uint128 liquidityAdded) {
        PoolKey memory key = poolKey();

        // 1. Poke: credit accrued fees as transient deltas. An empty position cannot be poked
        //    (Position.update reverts) — that is the bootstrap path: skip straight to the add.
        if (poolManager.getPositionLiquidity(poolId, positionKey()) > 0) {
            poolManager.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, 0, POSITION_SALT), "");
        }

        // 2. Gather: deltas (fees just poked) + own balances (dust / seed). This is the ENTIRE
        //    input set — principal stays in the pool, so the rebalance is structurally capped.
        (uint256 avail0, uint256 avail1) = _availables();

        // 3. Oracle-bounded rebalance toward the range ratio.
        (uint256 fairWad, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(ethUsdFeed, gbpUsdFeed, address(wrapper), ethUsdStalenessSec, gbpUsdStalenessSec);
        if (reason != OracleLib.FallbackReason.NONE) {
            emit RebalanceSkipped(1);
        } else if (poolManager.getLiquidity(poolId) == 0) {
            // No counterparty liquidity to rebalance against (bootstrap of a fresh pool, or all
            // third-party LP gone): a swap would deliver nothing. Add what balances and carry
            // the surplus as dust.
            emit RebalanceSkipped(3);
        } else {
            _rebalance(key, avail0, avail1, fairWad);
            (avail0, avail1) = _availables();
        }

        // 4. Add the max liquidity the availables fund at the (post-rebalance) price.
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, avail0, avail1);
        // Rounding guard: never promise amounts the availables cannot cover.
        while (liquidityAdded > 0 && !_fits(sqrtP, liquidityAdded, avail0, avail1)) {
            liquidityAdded--;
        }
        if (liquidityAdded == 0) revert NothingToCompound();
        poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidityAdded)), POSITION_SALT), ""
        );

        // 5. Settle both currencies; what flows back is retained dust.
        _settle(currency0);
        _settle(currency1);
        uint256 dust0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 dust1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        emit Compounded(avail0 - dust0, avail1 - dust1, liquidityAdded, dust0, dust1);
        return liquidityAdded;
    }

    function _withdraw(uint128 liquidity, uint256 amount0Min, uint256 amount1Min, address to)
        internal
        returns (bytes memory)
    {
        uint128 posLiq = poolManager.getPositionLiquidity(poolId, positionKey());
        if (liquidity > posLiq) liquidity = posLiq; // type(uint128).max = withdraw all
        if (liquidity > 0) {
            poolManager.modifyLiquidity(
                poolKey(), ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(liquidity)), POSITION_SALT), ""
            );
        }
        uint256 amount0 = _takeAll(currency0, to);
        uint256 amount1 = _takeAll(currency1, to);
        if (amount0 < amount0Min || amount1 < amount1Min) revert WithdrawSlippage();
        emit LiquidityWithdrawn(liquidity, amount0, amount1, to);
        return abi.encode(amount0, amount1);
    }

    // ---------------------------------------------------------------- rebalance internals

    /// @dev Swap the wrong-side surplus so the availables match the range's token ratio at the
    ///      current price, bounded on execution price vs oracle fair. Split into sizing + execution
    ///      halves so the legacy (coverage) pipeline doesn't run out of stack.
    function _rebalance(PoolKey memory key, uint256 avail0, uint256 avail1, uint256 fairWad) internal {
        (bool zeroForOne, uint256 amountIn) = _rebalanceSize(avail0, avail1);
        if (amountIn == 0) return;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        uint256 amtIn = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        uint256 amtOut = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        _checkExecPrice(zeroForOne, amtIn, amtOut, fairWad);
        emit RebalanceSwap(zeroForOne, amtIn, amtOut);
    }

    /// @dev Size the surplus swap: split so the post-swap availables keep the range ratio r0 : r1.
    ///      Returns amountIn 0 (emitting RebalanceSkipped) for dust-sized swaps.
    function _rebalanceSize(uint256 avail0, uint256 avail1) internal returns (bool zeroForOne, uint256 amountIn) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtClamped = sqrtP < sqrtLowerX96 ? sqrtLowerX96 : (sqrtP > sqrtUpperX96 ? sqrtUpperX96 : sqrtP);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLowerX96, sqrtUpperX96, avail0, avail1);
        // Required amounts for l at the current price; the binding side has ~zero surplus.
        uint256 r0 = SqrtPriceMath.getAmount0Delta(sqrtClamped, sqrtUpperX96, l, true);
        uint256 r1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtClamped, l, true);
        uint256 v0r = _val0(r0, sqrtP); // r0 valued in currency1 terms

        {
            uint256 e0 = avail0 > r0 ? avail0 - r0 : 0;
            uint256 e1 = avail1 > r1 ? avail1 - r1 : 0;
            if (_val0(e0, sqrtP) > e1) {
                zeroForOne = true;
                amountIn = v0r + r1 == 0 ? e0 : FullMath.mulDiv(e0, r1, v0r + r1);
            } else {
                amountIn = v0r + r1 == 0 ? e1 : FullMath.mulDiv(e1, v0r, v0r + r1);
            }
        }

        uint256 total = _val0(avail0, sqrtP) + avail1;
        uint256 amountInVal1 = zeroForOne ? _val0(amountIn, sqrtP) : amountIn;
        if (amountIn == 0 || total == 0 || amountInVal1 * 10_000 < total * REBALANCE_EPSILON_BPS) {
            if (amountIn > 0) emit RebalanceSkipped(2);
            amountIn = 0;
        }
    }

    /// @dev Bound the EXECUTION price (what we actually paid/received — the only thing a sandwich
    ///      can hurt) against fair ± tolerance, in wstGBP-per-WETH WAD terms.
    function _checkExecPrice(bool zeroForOne, uint256 amtIn, uint256 amtOut, uint256 fairWad) internal view {
        if (amtIn == 0 || amtOut == 0) revert PriceOutOfBounds();
        bool wsgIn = zeroForOne == wstGbpIsCurrency0;
        (uint256 wsg, uint256 weth) = wsgIn ? (amtIn, amtOut) : (amtOut, amtIn);
        uint256 execWad = FullMath.mulDiv(wsg, 1e18, weth); // wstGBP paid/received per WETH
        if (wsgIn) {
            // selling wstGBP: adverse = paying MORE wstGBP per WETH than fair allows
            if (execWad > FullMath.mulDiv(fairWad, 10_000 + toleranceBps, 10_000)) revert PriceOutOfBounds();
        } else {
            // selling WETH: adverse = receiving FEWER wstGBP per WETH than fair allows
            if (execWad < FullMath.mulDiv(fairWad, 10_000 - toleranceBps, 10_000)) revert PriceOutOfBounds();
        }
    }

    // ---------------------------------------------------------------- accounting helpers

    /// @dev What the compound can still spend per currency: transient delta (SIGNED — a rebalance
    ///      swap may have left a debt that the held balance must repay) plus the ERC-20 balance.
    function _availables() internal view returns (uint256 avail0, uint256 avail1) {
        int256 net0 = poolManager.currencyDelta(address(this), currency0)
            + int256(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this)));
        int256 net1 = poolManager.currencyDelta(address(this), currency1)
            + int256(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this)));
        avail0 = net0 > 0 ? uint256(net0) : 0;
        avail1 = net1 > 0 ? uint256(net1) : 0;
    }

    function _fits(uint160 sqrtP, uint128 l, uint256 avail0, uint256 avail1) internal view returns (bool) {
        uint160 sqrtClamped = sqrtP < sqrtLowerX96 ? sqrtLowerX96 : (sqrtP > sqrtUpperX96 ? sqrtUpperX96 : sqrtP);
        return SqrtPriceMath.getAmount0Delta(sqrtClamped, sqrtUpperX96, l, true) <= avail0
            && SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtClamped, l, true) <= avail1;
    }

    /// @dev Value `amount0` in currency1 terms at the current sqrt price.
    function _val0(uint256 amount0, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
    }

    /// @dev Net a currency's transient delta: pay debts from own balance, take credits back to self.
    function _settle(Currency c) internal {
        int256 d = poolManager.currencyDelta(address(this), c);
        if (d < 0) {
            poolManager.sync(c);
            if (!_transfer(Currency.unwrap(c), address(poolManager), uint256(-d))) revert TransferFailed();
            poolManager.settle();
        } else if (d > 0) {
            poolManager.take(c, address(this), uint256(d));
        }
    }

    function _takeAll(Currency c, address to) internal returns (uint256 amount) {
        int256 d = poolManager.currencyDelta(address(this), c);
        if (d > 0) {
            amount = uint256(d);
            poolManager.take(c, to, amount);
        }
    }

    function _transfer(address token, address to, uint256 amount) internal returns (bool ok) {
        if (amount == 0) return true;
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }
}
