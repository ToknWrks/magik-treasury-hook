// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GraduatedSellTaxTreasuryHook} from "../src/GraduatedSellTaxTreasuryHook.sol";
import {TestERC20} from "../src/mocks/TestERC20.sol";

contract GraduatedSellTaxTreasuryHookTest is Test, Deployers {
    bytes32 constant SELL_TAXED_TOPIC = keccak256("SellTaxed(address,uint256,uint24)");
    bytes32 constant HARVESTED_TOPIC = keccak256("Harvested(uint256,uint256,uint256,uint256)");
    bytes32 constant BID_PLACED_TOPIC = keccak256("BidPlaced(int24,int24,uint128,uint256)");
    bytes32 constant BID_REMOVED_TOPIC = keccak256("BidRemoved(uint256,uint256)");

    GraduatedSellTaxTreasuryHook hook;
    address TOKEN;
    address treasury = makeAddr("treasury");
    address dev = makeAddr("dev");
    uint256 reserve;

    uint256[] thresholds;
    uint24[] fees;

    function setUp() public {
        deployFreshManagerAndRouters();

        // The other currency can be Deployers' generic solmate mock; TOKEN must be a real
        // `TestERC20` (not the solmate mock) so the hook's `burn()` call in `harvest()` has a
        // real ERC20Burnable-compatible function to call -- solmate's mock doesn't implement it.
        Currency otherCurrency = deployMintAndApproveCurrency();
        TestERC20 magik = new TestERC20("Test Magik", "tMAGIK", 2 ** 128, address(this));
        magik.approve(address(swapRouter), type(uint256).max);
        magik.approve(address(modifyLiquidityRouter), type(uint256).max);
        TOKEN = address(magik);

        (currency0, currency1) = SortTokens.sort(MockERC20(TOKEN), MockERC20(Currency.unwrap(otherCurrency)));

        thresholds = new uint256[](4);
        thresholds[0] = 0;
        thresholds[1] = 100;
        thresholds[2] = 300;
        thresholds[3] = 500;

        fees = new uint24[](4);
        fees[0] = 0;
        fees[1] = 10_000;
        fees[2] = 30_000;
        fees[3] = 50_000;

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        hook = GraduatedSellTaxTreasuryHook(address(flags));
        deployCodeTo(
            "GraduatedSellTaxTreasuryHook.sol:GraduatedSellTaxTreasuryHook",
            abi.encode(
                address(manager), TOKEN, address(this), treasury, dev, thresholds, fees, uint256(0), int24(200), int24(60)
            ),
            address(hook)
        );

        // LP fee here is independent of our hook fee (BaseHookFee taxes on top of whatever LP
        // fee the pool has) -- use the standard 0.3% static tier so `initPool` derives a valid
        // tick spacing; 0 would derive a tick spacing of 0 and revert.
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        reserve = _tokenBalanceInManager();
        assertGt(reserve, 0);
    }

    /// @dev `SortTokens.sort` orders by raw address value, which depends on deployer nonce —
    /// not guaranteed to put TOKEN in any particular slot. All swap helpers below derive the
    /// correct `zeroForOne` from this instead of assuming a fixed slot.
    function _tokenIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(currency0) == TOKEN;
    }

    function _tokenBalanceInManager() internal view returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(manager));
    }

    function _tokenClaimId() internal view returns (uint256) {
        return (_tokenIsCurrency0() ? currency0 : currency1).toId();
    }

    function _otherClaimId() internal view returns (uint256) {
        return (_tokenIsCurrency0() ? currency1 : currency0).toId();
    }

    function _sell(uint256 amountIn) internal returns (bool taxed, uint24 feePpm) {
        bool sellingCurrency0 = _tokenIsCurrency0();
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellingCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sellingCurrency0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ZERO_BYTES
        );
        return _lastSellTaxedFee();
    }

    /// @dev Exact-out sell: caller specifies exactly how much of the OTHER currency they want
    /// out; TOKEN paid in floats. This is the case `GraduatedSellTaxHook` (the LP-fee sibling)
    /// can't size correctly — this hook should, since `afterSwap` sees the real delta.
    function _sellExactOut(uint256 otherAmountOut) internal returns (bool taxed, uint24 feePpm) {
        bool sellingCurrency0 = _tokenIsCurrency0();
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellingCurrency0,
                amountSpecified: int256(otherAmountOut),
                sqrtPriceLimitX96: sellingCurrency0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ZERO_BYTES
        );
        return _lastSellTaxedFee();
    }

    function _buy(uint256 amountIn) internal returns (bool taxed, uint24 feePpm) {
        bool sellingCurrency0 = _tokenIsCurrency0();
        // Buying TOKEN means selling the OTHER currency, i.e. the opposite direction of _sell.
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !sellingCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: !sellingCurrency0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ZERO_BYTES
        );
        return _lastSellTaxedFee();
    }

    function _lastSellTaxedFee() internal view returns (bool taxed, uint24 feePpm) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == address(hook) && log.topics.length > 0 && log.topics[0] == SELL_TAXED_TOPIC) {
                (, feePpm) = abi.decode(log.data, (uint256, uint24));
                return (true, feePpm);
            }
        }
        return (false, 0);
    }

    function test_sellBelowFirstThreshold_isUntaxed() public {
        (bool taxed, uint24 feePpm) = _sell(reserve / 1000);
        assertTrue(taxed);
        assertEq(feePpm, 0);
    }

    function test_sellInSecondBracket_pays1Percent_andCollectsEthClaim() public {
        uint256 sellAmount = (reserve * 2) / 100;
        (bool taxed, uint24 feePpm) = _sell(sellAmount);
        assertTrue(taxed);
        assertEq(feePpm, 10_000);

        uint256 ethClaim = manager.balanceOf(address(hook), _otherClaimId());
        assertGt(ethClaim, 0, "hook should hold an ERC-6909 claim on the ETH it collected");
    }

    function test_sellAtTopBracket_pays5Percent() public {
        (bool taxed, uint24 feePpm) = _sell((reserve * 6) / 100);
        assertTrue(taxed);
        assertEq(feePpm, 50_000);
    }

    function test_buy_isNeverTaxed() public {
        (bool taxed,) = _buy((reserve * 6) / 100);
        assertFalse(taxed, "buys must never emit SellTaxed");
    }

    /// @dev The improvement over the LP-fee sibling hook: exact-out sells get bracketed on the
    /// real settled TOKEN amount, not defaulted to a worst-case guess.
    function test_exactOutSell_isSizedCorrectly_andCollectsTokenClaim() public {
        // Ask for a small amount of ETH out -- should cost roughly a proportionally small
        // amount of TOKEN, landing well under the first threshold.
        (bool taxed, uint24 feePpm) = _sellExactOut(reserve / 2000);
        assertTrue(taxed);
        assertEq(feePpm, 0, "small exact-out sell should be sized correctly and land in bracket 0");

        // The fee for an exact-out sell is taken from the TOKEN (input) side per BaseHookFee,
        // not ETH -- confirm the hook holds a TOKEN claim, not (only) an ETH one.
        uint256 tokenClaim = manager.balanceOf(address(hook), _tokenClaimId());
        assertEq(tokenClaim, 0, "fee is 0 in bracket 0, so no claim should have been taken");
    }

    function test_exactOutSell_bigEnoughToTax_collectsTokenClaimDirectly() public {
        // A much bigger ETH-out request requires proportionally more TOKEN in, big enough to
        // cross into a taxed bracket.
        (bool taxed, uint24 feePpm) = _sellExactOut((reserve * 5) / 100);
        assertTrue(taxed);
        assertGt(feePpm, 0, "a big enough exact-out sell must still be taxed, not free-ridden");

        uint256 tokenClaim = manager.balanceOf(address(hook), _tokenClaimId());
        assertGt(tokenClaim, 0, "exact-out sells are taxed directly in TOKEN, not ETH");
    }

    /// @dev Same-tx split-sell protection, ported from the LP-fee sibling hook.
    function test_splitSellsInSameTx_bracketOnCumulativeAmount() public {
        uint256 halfOfTwoPercent = (reserve * 2) / 100 / 2;

        (, uint24 firstFee) = _sell(halfOfTwoPercent);
        assertEq(firstFee, 0);

        (, uint24 secondFee) = _sell(halfOfTwoPercent);
        assertEq(secondFee, 10_000);
    }

    /// @dev Same-block reserve-inflation protection, ported from the LP-fee sibling hook.
    function test_sameBlockLiquidityInflation_doesNotLowerBracket() public {
        (, uint24 bootstrapFee) = _sell(1);
        assertEq(bootstrapFee, 0);

        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 inflatedReserve = _tokenBalanceInManager();
        assertGt(inflatedReserve, reserve * 3 / 2);

        (, uint24 feePpm) = _sell((reserve * 4) / 100);
        assertEq(feePpm, 30_000, "must bracket against the pre-inflation snapshot, not the live balance");
    }

    function test_harvest_convertsCollectedEthAndSplits50_40_10() public {
        // Sell enough to land in a taxed bracket and accumulate a real ETH claim.
        _sell((reserve * 6) / 100);
        uint256 ethClaim = manager.balanceOf(address(hook), _otherClaimId());
        assertGt(ethClaim, 0);

        uint256 supplyBefore = IERC20(TOKEN).totalSupply();

        vm.recordLogs();
        hook.harvest(0);

        uint256 total;
        uint256 burned;
        uint256 toTreasury;
        uint256 toDev;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == HARVESTED_TOPIC) {
                (total, burned, toTreasury, toDev) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "expected a Harvested event");
        assertGt(total, 0);

        assertEq(burned, total * 5000 / 10000);
        assertEq(toTreasury, total * 4000 / 10000);
        assertEq(toDev, total - burned - toTreasury);

        assertEq(IERC20(TOKEN).totalSupply(), supplyBefore - burned, "burn must actually reduce total supply");
        assertEq(IERC20(TOKEN).balanceOf(treasury), toTreasury);
        assertEq(IERC20(TOKEN).balanceOf(dev), toDev);

        // Nothing left held by the hook or owed to it as claims.
        assertEq(IERC20(TOKEN).balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), _otherClaimId()), 0);
    }

    function test_harvest_isNoOpWhenNothingCollected() public {
        vm.recordLogs();
        hook.harvest(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != HARVESTED_TOPIC, "should not emit Harvested when nothing accrued");
        }
    }

    function test_harvest_revertsWhenOutputBelowMinTokenOut() public {
        _sell((reserve * 6) / 100);
        uint256 ethClaim = manager.balanceOf(address(hook), _otherClaimId());
        assertGt(ethClaim, 0);

        // Ask for far more TOKEN than this claim could ever convert to — simulates a
        // sandwiched/manipulated price producing worse-than-expected output.
        vm.expectRevert();
        hook.harvest(type(uint256).max);
    }

    function test_setBrackets_onlyOwner_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        hook.setBrackets(thresholds, fees);
    }

    function test_setTreasury_onlyOwner_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        hook.setTreasury(address(0xCAFE));
    }

    function test_setTreasury_zeroAddress_reverts() public {
        vm.expectRevert(GraduatedSellTaxTreasuryHook.ZeroAddress.selector);
        hook.setTreasury(address(0));
    }

    function test_setPriceSupportBps_onlyOwner_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        hook.setPriceSupportBps(3000);
    }

    function test_setPriceSupportBps_exceedsTotal_reverts() public {
        vm.expectRevert(GraduatedSellTaxTreasuryHook.PriceSupportBpsTooLarge.selector);
        hook.setPriceSupportBps(10_001);
    }

    function test_setBidRange_onlyOwner_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        hook.setBidRange(200, 60);
    }

    function test_setBidRange_invalidWidth_reverts() public {
        vm.expectRevert(GraduatedSellTaxTreasuryHook.InvalidBidRange.selector);
        hook.setBidRange(200, 0);
    }

    function test_harvest_placesStandingBid_whenPriceSupportBpsSet() public {
        hook.setPriceSupportBps(3000);
        _sell((reserve * 6) / 100);

        uint256 ethClaimBefore = manager.balanceOf(address(hook), _otherClaimId());
        assertGt(ethClaimBefore, 0);

        vm.recordLogs();
        hook.harvest(0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBidPlaced;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == BID_PLACED_TOPIC) {
                foundBidPlaced = true;
            }
        }
        assertTrue(foundBidPlaced, "expected a BidPlaced event");

        (,, uint128 liquidity, bool placed) = hook.bidPosition();
        assertTrue(placed);
        assertGt(liquidity, 0);

        // The ETH claim should have shrunk -- some of it went into the bid instead of being
        // fully converted to TOKEN.
        uint256 ethClaimAfter = manager.balanceOf(address(hook), _otherClaimId());
        assertLt(ethClaimAfter, ethClaimBefore);
    }

    function test_harvest_replacesUnfilledBid_onNextHarvest() public {
        hook.setPriceSupportBps(3000);
        _sell((reserve * 6) / 100);
        hook.harvest(0);

        (,, uint128 firstLiquidity, bool placedFirst) = hook.bidPosition();
        assertTrue(placedFirst);
        assertGt(firstLiquidity, 0);

        // More tax collected, but nothing pushed price into the first bid's range -- the next
        // harvest should pull the still-unfilled position and mint a fresh, bigger one (recycled
        // ETH from the first bid plus this round's new cut).
        _sell((reserve * 6) / 100);

        vm.recordLogs();
        hook.harvest(0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundRemoved;
        bool foundPlaced;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == BID_REMOVED_TOPIC) foundRemoved = true;
            if (logs[i].topics[0] == BID_PLACED_TOPIC) foundPlaced = true;
        }
        assertTrue(foundRemoved, "expected the old bid to be pulled");
        assertTrue(foundPlaced, "expected a fresh bid to be minted");

        (,, uint128 secondLiquidity, bool placedSecond) = hook.bidPosition();
        assertTrue(placedSecond);
        assertGt(secondLiquidity, firstLiquidity, "second bid should be funded with recycled + new ETH");
    }

    /// @dev Drives price down through the bid's range between two harvests so it (at least
    /// partially) fills into TOKEN, then confirms that recovered TOKEN flows through the normal
    /// burn/treasury/dev split rather than being stranded.
    function test_harvest_bidFill_routesRecoveredTokenThroughSplit() public {
        hook.setBidRange(0, 60);
        hook.setPriceSupportBps(5000);

        _sell((reserve * 6) / 100);
        hook.harvest(0);
        (,, uint128 liquidityBefore, bool placedBefore) = hook.bidPosition();
        assertTrue(placedBefore);
        assertGt(liquidityBefore, 0);

        // A big enough sell to push price through the bid's narrow range right next to spot.
        _sell((reserve * 60) / 100);

        // Disable further price support so this harvest only pulls + distributes, isolating the
        // "filled bid's TOKEN flows into the split" behavior from any re-mint.
        hook.setPriceSupportBps(0);

        vm.recordLogs();
        hook.harvest(0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 tokenRecovered;
        uint256 total;
        bool foundRemoved;
        bool foundHarvested;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == BID_REMOVED_TOPIC) {
                (, tokenRecovered) = abi.decode(logs[i].data, (uint256, uint256));
                foundRemoved = true;
            } else if (logs[i].topics[0] == HARVESTED_TOPIC) {
                (total,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                foundHarvested = true;
            }
        }

        assertTrue(foundRemoved, "expected the filled bid to be pulled");
        assertGt(tokenRecovered, 0, "expected the bid to have at least partially filled into TOKEN");
        assertTrue(foundHarvested);
        assertGe(total, tokenRecovered, "recovered TOKEN must flow into the distributed total");

        (,,, bool placedAfter) = hook.bidPosition();
        assertFalse(placedAfter, "priceSupportBps=0 this round means no new bid should be minted");
    }

    function test_setSplit_onlyOwner_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        hook.setSplit(3000, 3000);
    }

    function test_setSplit_exceedsTotal_reverts() public {
        vm.expectRevert(GraduatedSellTaxTreasuryHook.SplitExceedsTotal.selector);
        hook.setSplit(6000, 5000);
    }

    function test_setSplit_changesHarvestDistribution() public {
        hook.setSplit(3000, 5000); // 30% burn / 50% treasury / 20% dev
        assertEq(hook.burnBps(), 3000);
        assertEq(hook.treasuryBps(), 5000);

        _sell((reserve * 6) / 100);

        vm.recordLogs();
        hook.harvest(0);

        uint256 total;
        uint256 burned;
        uint256 toTreasury;
        uint256 toDev;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == HARVESTED_TOPIC) {
                (total, burned, toTreasury, toDev) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        assertGt(total, 0);
        assertEq(burned, total * 3000 / 10000);
        assertEq(toTreasury, total * 5000 / 10000);
        assertEq(toDev, total - burned - toTreasury);
    }
}
