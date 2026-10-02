// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHookFee} from "@openzeppelin/uniswap-hooks/fee/BaseHookFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
// LiquidityAmounts lives under v4-core's test/ tree, not src/ — same dependency this repo's own
// deploy scripts already rely on (script/CreatePoolAndAddLiquidity.s.sol), not a new precedent.
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

interface ITestToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
}

/// @notice Graduated sell-tax hook that actually collects the graduated tax as real
/// value (via OpenZeppelin's `BaseHookFee`) instead of leaving it as an LP fee. Collected value
/// sits in the hook as ERC-6909 claims until anyone calls `harvest()`, which (a) diverts
/// `priceSupportBps` of the ETH-denominated tax into a standing, one-sided ETH-only liquidity
/// position just below spot instead of buying back MAGIK with it, and (b) converts the rest into
/// MAGIK and splits it burn/treasury/dev (owner-tunable via `setSplit`, default 50/40/10).
///
/// WARNING: experimental, unaudited, testnet-only. Reserve-manipulation mitigation: see
/// `_snapshotReserve`; same-tx anti-split accumulator: see `_accumulateSellAmount`.
/// Exact-output sells ARE sized correctly here, because `afterSwap` sees the real settled
/// amounts regardless of how the swap was specified.
contract GraduatedSellTaxTreasuryHook is BaseHookFee, Ownable, IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    struct Bracket {
        uint256 minSellBps;
        uint24 feePpm;
    }

    address public immutable TOKEN;

    address public treasury;
    address public dev;

    uint256 private constant TOTAL_BPS = 10_000;

    /// @dev Dev's share is always the remainder (`TOTAL_BPS - burnBps - treasuryBps`), so it
    /// absorbs rounding dust rather than being tracked as its own explicit setting.
    uint256 public burnBps = 5000;
    uint256 public treasuryBps = 4000;

    /// @dev Fraction of ETH-denominated tax (exact-in sells only — see the README ("Price support")
    /// for why exact-out sells' TOKEN-denominated tax can't feed this) diverted into a standing
    /// bid instead of being bought back and split burn/treasury/dev. Independent of
    /// `burnBps`/`treasuryBps`, which apply to the final TOKEN total *after* this cut is taken.
    uint256 public priceSupportBps;

    /// @dev How far from the current tick (magnitude, always >= 0) and how wide (> 0) the
    /// standing bid's range is, in ticks. Re-aligned to the pool's `tickSpacing` at placement
    /// time regardless of these raw values, so they don't need to be exact multiples themselves.
    int24 public bidTicksBelowSpot;
    int24 public bidWidthTicks;

    int24 private _bidTickLower;
    int24 private _bidTickUpper;
    uint128 private _bidLiquidity;
    bool private _bidPlaced;

    bytes32 private constant BID_SALT = keccak256("GraduatedSellTaxTreasuryHook.standingBid");

    Bracket[] private _brackets;

    /// @dev The pool this hook is attached to, captured at `afterInitialize` so `harvest()`
    /// knows which pool to swap the collected non-MAGIK currency back into MAGIK through.
    PoolKey private _poolKey;
    bool private _poolKeySet;

    /// @dev Fee computed by `_afterSwap` for the swap currently in flight, read back by
    /// `_getHookFee` (which BaseHookFee requires to stay `view`, so it can't do this work itself).
    uint24 private _pendingFeePpm;

    uint256 private _reserveSnapshot;
    uint256 private _snapshotBlock;

    event BracketsUpdated(uint256[] minSellBps, uint24[] feePpm);
    event SellTaxed(address indexed trader, uint256 sellBps, uint24 feePpm);
    event Harvested(uint256 totalMagik, uint256 burned, uint256 toTreasury, uint256 toDev);
    event TreasuryUpdated(address treasury);
    event DevUpdated(address dev);
    event SplitUpdated(uint256 burnBps, uint256 treasuryBps, uint256 devBps);
    event PriceSupportBpsUpdated(uint256 priceSupportBps);
    event BidRangeUpdated(int24 ticksBelowSpot, int24 widthTicks);
    event BidPlaced(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 ethDeposited);
    event BidRemoved(uint256 ethRecovered, uint256 tokenRecovered);

    error EmptyBrackets();
    error BracketsNotAscending();
    error FeeTooLarge();
    error LengthMismatch();
    error PoolKeyAlreadySet();
    error ZeroAddress();
    error SplitExceedsTotal();
    error PriceSupportBpsTooLarge();
    error InvalidBidRange();
    error InsufficientHarvestOutput(uint256 amountOut, uint256 minTokenOut);

    constructor(
        IPoolManager _poolManager,
        address _token,
        address _initialOwner,
        address _treasury,
        address _dev,
        uint256[] memory minSellBps,
        uint24[] memory feePpm,
        uint256 _priceSupportBps,
        int24 _bidTicksBelowSpot,
        int24 _bidWidthTicks
    ) BaseHook(_poolManager) Ownable(_initialOwner) {
        if (_treasury == address(0) || _dev == address(0)) revert ZeroAddress();
        TOKEN = _token;
        treasury = _treasury;
        dev = _dev;
        _setBrackets(minSellBps, feePpm);
        _setPriceSupportBps(_priceSupportBps);
        _setBidRange(_bidTicksBelowSpot, _bidWidthTicks);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setDev(address _dev) external onlyOwner {
        if (_dev == address(0)) revert ZeroAddress();
        dev = _dev;
        emit DevUpdated(_dev);
    }

    function setBrackets(uint256[] memory minSellBps, uint24[] memory feePpm) external onlyOwner {
        _setBrackets(minSellBps, feePpm);
    }

    function setSplit(uint256 _burnBps, uint256 _treasuryBps) external onlyOwner {
        if (_burnBps + _treasuryBps > TOTAL_BPS) revert SplitExceedsTotal();
        burnBps = _burnBps;
        treasuryBps = _treasuryBps;
        emit SplitUpdated(_burnBps, _treasuryBps, TOTAL_BPS - _burnBps - _treasuryBps);
    }

    function setPriceSupportBps(uint256 _priceSupportBps) external onlyOwner {
        _setPriceSupportBps(_priceSupportBps);
    }

    function setBidRange(int24 _bidTicksBelowSpot, int24 _bidWidthTicks) external onlyOwner {
        _setBidRange(_bidTicksBelowSpot, _bidWidthTicks);
    }

    function _setPriceSupportBps(uint256 _priceSupportBps) internal {
        if (_priceSupportBps > TOTAL_BPS) revert PriceSupportBpsTooLarge();
        priceSupportBps = _priceSupportBps;
        emit PriceSupportBpsUpdated(_priceSupportBps);
    }

    function _setBidRange(int24 _bidTicksBelowSpot, int24 _bidWidthTicks) internal {
        if (_bidTicksBelowSpot < 0 || _bidWidthTicks <= 0) revert InvalidBidRange();
        bidTicksBelowSpot = _bidTicksBelowSpot;
        bidWidthTicks = _bidWidthTicks;
        emit BidRangeUpdated(_bidTicksBelowSpot, _bidWidthTicks);
    }

    function brackets() external view returns (Bracket[] memory) {
        return _brackets;
    }

    function bidPosition() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool placed) {
        return (_bidTickLower, _bidTickUpper, _bidLiquidity, _bidPlaced);
    }

    function _setBrackets(uint256[] memory minSellBps, uint24[] memory feePpm) internal {
        if (minSellBps.length == 0) revert EmptyBrackets();
        if (minSellBps.length != feePpm.length) revert LengthMismatch();

        delete _brackets;
        uint256 lastThreshold = 0;
        for (uint256 i = 0; i < minSellBps.length; i++) {
            if (i > 0 && minSellBps[i] <= lastThreshold) revert BracketsNotAscending();
            if (feePpm[i] > MAX_HOOK_FEE) revert FeeTooLarge();
            _brackets.push(Bracket({minSellBps: minSellBps[i], feePpm: feePpm[i]}));
            lastThreshold = minSellBps[i];
        }

        emit BracketsUpdated(minSellBps, feePpm);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();
        permissions.afterInitialize = true;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (_poolKeySet) revert PoolKeyAlreadySet();
        _poolKey = key;
        _poolKeySet = true;
        return this.afterInitialize.selector;
    }

    /// @dev Computes the graduated fee (writing the snapshot/accumulator state `_getHookFee`
    /// can't touch, since BaseHookFee requires it to stay `view`) and stashes it for
    /// `_getHookFee` to read, then delegates to `BaseHookFee._afterSwap` to actually take it.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        bool token0IsTarget = Currency.unwrap(key.currency0) == TOKEN;
        int128 tokenDelta = token0IsTarget ? delta.amount0() : delta.amount1();

        // Negative delta = TOKEN was paid IN by the swapper = a sell. Real settled amount,
        // known regardless of whether the swap was specified exact-in or exact-out.
        if (tokenDelta < 0) {
            uint256 amountIn = uint256(uint128(-tokenDelta));
            uint256 cumulative = _accumulateSellAmount(amountIn);
            uint256 reserve = _snapshotReserve();
            uint256 sellBps = reserve == 0 ? type(uint256).max : (cumulative * 10_000) / reserve;

            uint24 fee = _brackets[0].feePpm;
            for (uint256 i = 0; i < _brackets.length; i++) {
                if (sellBps >= _brackets[i].minSellBps) {
                    fee = _brackets[i].feePpm;
                } else {
                    break;
                }
            }

            _pendingFeePpm = fee;
            emit SellTaxed(tx.origin, sellBps, fee);
        } else {
            _pendingFeePpm = 0;
        }

        return super._afterSwap(sender, key, params, delta, hookData);
    }

    function _getHookFee(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return _pendingFeePpm;
    }

    /// @dev Sell size is bracketed against the PoolManager's TOKEN balance, lagged by one block:
    /// the first swap in a block uses the balance recorded at the previous block's first swap
    /// (live balance only on the very first swap ever), then records the current balance; later
    /// swaps in the same block reuse the recorded value. This blunts same-tx reserve inflation
    /// (adding TOKEN to the pool just before selling to shrink the apparent sell size).
    function _snapshotReserve() internal returns (uint256 reserve) {
        if (_snapshotBlock < block.number) {
            reserve = _snapshotBlock == 0 ? ITestToken(TOKEN).balanceOf(address(poolManager)) : _reserveSnapshot;
            _reserveSnapshot = ITestToken(TOKEN).balanceOf(address(poolManager));
            _snapshotBlock = block.number;
        } else {
            reserve = _reserveSnapshot;
        }
    }

    /// @dev Tracks cumulative TOKEN sold within one transaction, keyed by `tx.origin` via
    /// transient storage, so splitting a large sell into many small swaps in the same tx still
    /// lands in the bracket of the combined size.
    function _accumulateSellAmount(uint256 amountIn) internal returns (uint256 cumulative) {
        bytes32 slot = keccak256(abi.encode("GraduatedSellTaxTreasuryHook.cumulativeSell", tx.origin));
        assembly {
            cumulative := tload(slot)
        }
        cumulative += amountIn;
        assembly {
            tstore(slot, cumulative)
        }
    }

    /// @dev Anyone can trigger a harvest — the destinations (treasury/dev/burn) are fixed by
    /// the owner, not the caller, so there's nothing to gain by calling it maliciously; at
    /// worst it's a no-op if nothing has accrued yet.
    ///
    /// `minTokenOut` bounds the internal ETH->TOKEN conversion swap (see `unlockCallback`),
    /// which otherwise has no price limit — without it, anyone could sandwich the swap and
    /// skim value straight out of the accrued tax on its way to burn/treasury/dev. Callers
    /// should pass a real quote (minus their own slippage tolerance), not 0.
    function harvest(uint256 minTokenOut) external {
        poolManager.unlock(abi.encode(uint8(1), abi.encode(minTokenOut)));
    }

    /// @dev Required override from `BaseHookFee`. `harvest()` above is the normal path; this
    /// is an owner-only escape hatch to redeem arbitrary collected currencies straight to the
    /// owner (as real tokens, no auto-convert/split) if `harvest()` ever can't run for some
    /// currency it doesn't know about.
    function handleHookFees(Currency[] memory currencies) public override onlyOwner {
        poolManager.unlock(abi.encode(uint8(2), abi.encode(currencies)));
    }

    /// @dev Rounds a non-negative tick magnitude (an offset or width, not an absolute tick) UP
    /// to the nearest multiple of `spacing` — used so `bidTicksBelowSpot`/`bidWidthTicks` don't
    /// need to be exact multiples themselves, while guaranteeing the bounds computed from them
    /// in `_bidBoundsAt` stay spacing-aligned without ever rounding back towards the current tick.
    function _ceilToSpacing(int24 value, int24 spacing) internal pure returns (int24) {
        int24 floored = TickBitmap.compress(value, spacing) * spacing;
        return floored == value ? floored : floored + spacing;
    }

    /// @dev Computes a tickSpacing-aligned range on the side of the current tick that holds
    /// 100% `otherCurrency` (ETH) right now, per `LiquidityAmounts.getAmountsForLiquidity`'s own
    /// branching: a range entirely below the current price holds 100% token1, a range entirely
    /// above it holds 100% token0. Which raw tick direction counts as "below spot" for the ETH
    /// side therefore depends on whether ETH sorted as currency0 or currency1 for this pool —
    /// fixed once at deploy time, not something callers need to reason about.
    ///
    /// Critically, the boundary nearest the current tick must never be rounded *towards* it —
    /// flooring naively can land that boundary strictly inside the current tick, leaving the
    /// range straddling spot instead of sitting entirely to one side (which would make the mint
    /// require both currencies, not just ETH, and desync `_mintBid`'s single-sided settlement).
    function _bidBoundsAt(int24 currentTick, bool otherIsCurrency0) internal view returns (int24 tickLower, int24 tickUpper) {
        int24 spacing = _poolKey.tickSpacing;
        int24 flooredTick = TickBitmap.compress(currentTick, spacing) * spacing;
        int24 offset = _ceilToSpacing(bidTicksBelowSpot, spacing);
        int24 width = _ceilToSpacing(bidWidthTicks, spacing);
        if (width == 0) width = spacing;

        if (otherIsCurrency0) {
            // Range must sit entirely at/above the current tick.
            int24 ceilTick = flooredTick == currentTick ? flooredTick : flooredTick + spacing;
            tickLower = ceilTick + offset;
            tickUpper = tickLower + width;
        } else {
            // Range must sit entirely at/below the current tick.
            tickUpper = flooredTick - offset;
            tickLower = tickUpper - width;
        }

        int24 minTick = TickMath.minUsableTick(spacing);
        int24 maxTick = TickMath.maxUsableTick(spacing);
        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;
        if (tickUpper <= tickLower) tickUpper = tickLower + spacing;
    }

    /// @dev Pulls 100% of the standing bid's liquidity and credits whatever comes back (ETH if
    /// unfilled, TOKEN if filled, a mix if the price sat inside the range) as ERC-6909 claims —
    /// letting the caller's normal claim-balance reads (`otherClaims`/`tokenClaims`) pick up the
    /// proceeds without any separate accounting path.
    function _removeBid(Currency tokenCurrency, Currency otherCurrency, bool otherIsCurrency0) internal {
        // `callerDelta` already nets in `feesAccrued` (PoolManager.modifyLiquidity computes
        // `callerDelta = principalDelta + feesAccrued` before returning) -- feesAccrued is
        // returned separately only for informational purposes, not as a second delta to settle.
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: _bidTickLower,
                tickUpper: _bidTickUpper,
                liquidityDelta: -int256(uint256(_bidLiquidity)),
                salt: BID_SALT
            }),
            ""
        );
        int128 amount0 = callerDelta.amount0();
        int128 amount1 = callerDelta.amount1();
        uint256 otherAmount = uint256(uint128(otherIsCurrency0 ? amount0 : amount1));
        uint256 tokenAmount = uint256(uint128(otherIsCurrency0 ? amount1 : amount0));

        if (otherAmount > 0) otherCurrency.take(poolManager, address(this), otherAmount, true);
        if (tokenAmount > 0) tokenCurrency.take(poolManager, address(this), tokenAmount, true);

        _bidPlaced = false;
        emit BidRemoved(otherAmount, tokenAmount);
    }

    /// @dev Mints a fresh one-sided ETH-only position just below (in the sense of `_bidBoundsAt`)
    /// the current price, funded by burning `ethAmount` of the hook's already-held ERC-6909
    /// claim on `otherCurrency`. No-ops on liquidity rounding to 0 (dust) rather than reverting —
    /// the unspent claim just carries over to the next `harvest()` call.
    function _placeBid(Currency otherCurrency, bool otherIsCurrency0, uint256 ethAmount) internal {
        (, int24 currentTick,,) = poolManager.getSlot0(_poolKey.toId());
        (int24 tickLower, int24 tickUpper) = _bidBoundsAt(currentTick, otherIsCurrency0);

        uint128 liquidity = otherIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), ethAmount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), ethAmount
            );
        if (liquidity == 0) return;

        _mintBid(otherCurrency, otherIsCurrency0, tickLower, tickUpper, liquidity);
    }

    /// @dev Split out of `_placeBid` to keep that function's local-variable count under the
    /// EVM's stack-depth limit.
    function _mintBid(Currency otherCurrency, bool otherIsCurrency0, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
    {
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: BID_SALT}),
            ""
        );
        int128 otherDelta = otherIsCurrency0 ? callerDelta.amount0() : callerDelta.amount1();
        uint256 ethNeeded = otherDelta < 0 ? uint256(uint128(-otherDelta)) : 0;
        if (ethNeeded > 0) otherCurrency.settle(poolManager, address(this), ethNeeded, true);

        _bidTickLower = tickLower;
        _bidTickUpper = tickUpper;
        _bidLiquidity = liquidity;
        _bidPlaced = true;
        emit BidPlaced(tickLower, tickUpper, liquidity, ethNeeded);
    }

    /// @dev Swaps `ethToConvert` of `otherCurrency` into `tokenCurrency` through this pool,
    /// funding the input by burning the hook's own claim. Split out of `unlockCallback` to keep
    /// that function's local-variable count under the EVM's stack-depth limit.
    function _convertToToken(
        Currency tokenCurrency,
        Currency otherCurrency,
        bool otherIsCurrency0,
        uint256 ethToConvert,
        uint256 minTokenOut
    ) internal {
        BalanceDelta delta = poolManager.swap(
            _poolKey,
            SwapParams({
                zeroForOne: otherIsCurrency0,
                amountSpecified: -int256(ethToConvert),
                sqrtPriceLimitX96: otherIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        otherCurrency.settle(poolManager, address(this), ethToConvert, true);
        int128 tokenOut = otherIsCurrency0 ? delta.amount1() : delta.amount0();
        uint256 tokenOutAmount = uint256(uint128(tokenOut));
        if (tokenOutAmount < minTokenOut) revert InsufficientHarvestOutput(tokenOutAmount, minTokenOut);
        tokenCurrency.take(poolManager, address(this), tokenOutAmount, false);
    }

    /// @dev Burns/transfers the hook's current real TOKEN balance per `burnBps`/`treasuryBps`.
    /// Split out of `unlockCallback` for the same stack-depth reason as `_convertToToken`.
    function _distribute() internal {
        uint256 total = ITestToken(TOKEN).balanceOf(address(this));
        if (total == 0) return;

        uint256 burnAmount = (total * burnBps) / TOTAL_BPS;
        uint256 treasuryAmount = (total * treasuryBps) / TOTAL_BPS;
        uint256 devAmount = total - burnAmount - treasuryAmount; // absorbs rounding dust

        ITestToken(TOKEN).burn(burnAmount);
        if (treasuryAmount > 0) require(ITestToken(TOKEN).transfer(treasury, treasuryAmount), "treasury transfer failed");
        if (devAmount > 0) require(ITestToken(TOKEN).transfer(dev, devAmount), "dev transfer failed");

        emit Harvested(total, burnAmount, treasuryAmount, devAmount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (uint8 mode, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (mode == 2) {
            Currency[] memory currencies = abi.decode(payload, (Currency[]));
            for (uint256 i = 0; i < currencies.length; i++) {
                uint256 amount = poolManager.balanceOf(address(this), currencies[i].toId());
                if (amount > 0) {
                    currencies[i].settle(poolManager, address(this), amount, true);
                    currencies[i].take(poolManager, owner(), amount, false);
                }
            }
            return "";
        }

        uint256 minTokenOut = abi.decode(payload, (uint256));

        Currency currency0 = _poolKey.currency0;
        Currency currency1 = _poolKey.currency1;
        bool token0IsTarget = Currency.unwrap(currency0) == TOKEN;
        Currency tokenCurrency = token0IsTarget ? currency0 : currency1;
        Currency otherCurrency = token0IsTarget ? currency1 : currency0;
        bool otherIsCurrency0 = !token0IsTarget;

        // Pull any existing standing bid first — whatever it returns (ETH if unfilled, TOKEN if
        // filled, or a mix) joins the ordinary claim balances read just below, so filled-bid
        // TOKEN flows through the same burn/treasury/dev split as regular tax with no separate
        // accounting path.
        if (_bidPlaced) {
            _removeBid(tokenCurrency, otherCurrency, otherIsCurrency0);
        }

        // Convert the non-price-support fraction of collected `other`-currency claims (from
        // exact-in sells, plus anything just recovered from the bid above) into TOKEN by
        // swapping through the same pool, funding the swap's input by burning our own claim.
        // `minTokenOut` is enforced below — this swap otherwise has no price limit, so without
        // it anyone could sandwich the harvest and skim value out of the conversion.
        uint256 otherClaims = poolManager.balanceOf(address(this), otherCurrency.toId());
        uint256 priceSupportCut = (otherClaims * priceSupportBps) / TOTAL_BPS;
        uint256 ethToConvert = otherClaims - priceSupportCut;
        if (ethToConvert > 0) {
            _convertToToken(tokenCurrency, otherCurrency, otherIsCurrency0, ethToConvert, minTokenOut);
        }

        // Any TOKEN claims collected directly (from exact-out sells, plus anything recovered
        // from a filled bid above) just get redeemed -- burn the standing claim first (creating
        // the offsetting delta), then take the real tokens; a bare `take()` alone only debits a
        // delta, it never burns the ERC-6909 balance, so skipping the burn leaves the claim
        // untouched while also opening an unresolved debt (`CurrencyNotSettled`).
        uint256 tokenClaims = poolManager.balanceOf(address(this), tokenCurrency.toId());
        if (tokenClaims > 0) {
            tokenCurrency.settle(poolManager, address(this), tokenClaims, true);
            tokenCurrency.take(poolManager, address(this), tokenClaims, false);
        }

        // Re-place the standing bid with the carved-out ETH (dust that can't fund even 1 wei of
        // liquidity is simply left as a claim, picked up by `otherClaims` next harvest).
        if (priceSupportCut > 0) {
            _placeBid(otherCurrency, otherIsCurrency0, priceSupportCut);
        }

        _distribute();

        return "";
    }
}
