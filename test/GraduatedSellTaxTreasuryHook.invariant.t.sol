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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GraduatedSellTaxTreasuryHook} from "../src/GraduatedSellTaxTreasuryHook.sol";
import {TestERC20} from "../src/mocks/TestERC20.sol";

/// @dev Randomly sells, buys, and harvests through the real pool -- checking cross-consistency
/// between what the `Harvested` event claims happened and what actually landed on-chain, across
/// far more sell-size/ordering/timing combinations than the example-based unit tests cover.
contract GraduatedSellTaxTreasuryHookHandler is Test {
    bytes32 constant HARVESTED_TOPIC = keccak256("Harvested(uint256,uint256,uint256,uint256)");

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolKey key;
    GraduatedSellTaxTreasuryHook hook;
    address TOKEN;
    bool tokenIsCurrency0;
    address treasury;
    address dev;

    /// @dev Ghost sums of what `Harvested` events have claimed, to cross-check against real
    /// balances in the invariants below.
    uint256 public ghost_totalBurned;
    uint256 public ghost_totalToTreasury;
    uint256 public ghost_totalToDev;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolKey memory _key,
        GraduatedSellTaxTreasuryHook _hook,
        address _token,
        bool _tokenIsCurrency0,
        address _treasury,
        address _dev
    ) {
        manager = _manager;
        swapRouter = _swapRouter;
        key = _key;
        hook = _hook;
        TOKEN = _token;
        tokenIsCurrency0 = _tokenIsCurrency0;
        treasury = _treasury;
        dev = _dev;
    }

    function sell(uint256 amountSeed) external {
        uint256 reserve = IERC20(TOKEN).balanceOf(address(manager));
        if (reserve < 10) return;
        uint256 amountIn = bound(amountSeed, 1, reserve / 10); // never try to drain the pool dry
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !tokenIsCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: !tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    function buy(uint256 amountSeed) external {
        uint256 amountIn = bound(amountSeed, 1, 1_000e18);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: tokenIsCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    function harvest() external {
        vm.recordLogs();
        try hook.harvest(0) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == address(hook) && logs[i].topics[0] == HARVESTED_TOPIC) {
                    (, uint256 burned, uint256 toTreasury, uint256 toDev) =
                        abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                    ghost_totalBurned += burned;
                    ghost_totalToTreasury += toTreasury;
                    ghost_totalToDev += toDev;
                }
            }
        } catch {}
    }
}

contract GraduatedSellTaxTreasuryHookInvariantTest is Test, Deployers {
    GraduatedSellTaxTreasuryHook hook;
    GraduatedSellTaxTreasuryHookHandler handler;
    address TOKEN;
    address otherToken;
    address treasury = makeAddr("treasury");
    address dev = makeAddr("dev");
    uint256 supplyBefore;

    function setUp() public {
        deployFreshManagerAndRouters();

        Currency otherCurrency = deployMintAndApproveCurrency();
        otherToken = Currency.unwrap(otherCurrency);
        TestERC20 magik = new TestERC20("Test Magik", "tMAGIK", 2 ** 128, address(this));
        magik.approve(address(swapRouter), type(uint256).max);
        magik.approve(address(modifyLiquidityRouter), type(uint256).max);
        TOKEN = address(magik);

        (currency0, currency1) = SortTokens.sort(MockERC20(TOKEN), MockERC20(Currency.unwrap(otherCurrency)));

        uint256[] memory thresholds = new uint256[](4);
        thresholds[0] = 0;
        thresholds[1] = 100;
        thresholds[2] = 300;
        thresholds[3] = 500;

        uint24[] memory fees = new uint24[](4);
        fees[0] = 0;
        fees[1] = 10_000;
        fees[2] = 30_000;
        fees[3] = 50_000;

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        hook = GraduatedSellTaxTreasuryHook(address(flags));
        // priceSupportBps > 0 here so the standing-bid mint/remove path is actually exercised
        // by the bounded fuzzing below, not just the burn/treasury/dev path.
        deployCodeTo(
            "GraduatedSellTaxTreasuryHook.sol:GraduatedSellTaxTreasuryHook",
            abi.encode(
                address(manager), TOKEN, address(this), treasury, dev, thresholds, fees, uint256(3000), int24(200), int24(60)
            ),
            address(hook)
        );

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        handler = new GraduatedSellTaxTreasuryHookHandler(
            manager, swapRouter, key, hook, TOKEN, Currency.unwrap(currency0) == TOKEN, treasury, dev
        );

        // Give the handler its own funded, approved actor to swap as.
        magik.mint(address(handler), 10_000_000e18);
        vm.prank(address(handler));
        magik.approve(address(swapRouter), type(uint256).max);

        // Captured after all setup minting -- the invariant below only tracks supply changes
        // caused by the handler's own harvest() calls, not this setup mint.
        supplyBefore = IERC20(TOKEN).totalSupply();

        targetContract(address(handler));
    }

    /// @dev What `Harvested` claims went to `treasury`/`dev` must match what actually landed
    /// there -- treasury/dev never receive TOKEN from anything else in this closed system, so
    /// any mismatch means the event is lying about where value went.
    function invariant_harvestedAmountsMatchRealBalances() public view {
        assertEq(IERC20(TOKEN).balanceOf(treasury), handler.ghost_totalToTreasury());
        assertEq(IERC20(TOKEN).balanceOf(dev), handler.ghost_totalToDev());
    }

    /// @dev Every `Harvested.burned` must have actually reduced supply by that amount.
    function invariant_burnedAmountsMatchSupplyReduction() public view {
        assertEq(supplyBefore - IERC20(TOKEN).totalSupply(), handler.ghost_totalBurned());
    }

    /// @dev The hook is a pass-through -- it should never be left holding a real TOKEN balance
    /// between top-level calls (only transient ERC-6909 claims until the next harvest).
    function invariant_hookNeverRetainsRealTokenBalance() public view {
        assertEq(IERC20(TOKEN).balanceOf(address(hook)), 0);
    }

    /// @dev Same as above for the "other" currency -- price-support ETH either sits as an
    /// ERC-6909 claim (unspent dust) or is locked in the standing-bid position; it should never
    /// end up as a real balance sitting directly on the hook contract between calls, which would
    /// indicate a mint/remove accounting bug in `_placeBid`/`_removeBid`.
    function invariant_hookNeverRetainsRealOtherBalance() public view {
        assertEq(IERC20(otherToken).balanceOf(address(hook)), 0);
    }
}
