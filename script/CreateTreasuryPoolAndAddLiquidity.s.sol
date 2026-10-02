// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {TestERC20} from "../src/mocks/TestERC20.sol";
import {BaseSepoliaAddresses} from "./BaseSepoliaAddresses.sol";

/// @notice Initializes the ETH/tMAGIK pool behind the treasury hook (static 0.3% LP fee --
/// BaseHookFee taxes independently of it) and seeds it with full-range liquidity.
///
/// Usage: set TMAGIK_ADDRESS, TREASURY_HOOK_ADDRESS in .env, then:
///   forge script script/CreateTreasuryPoolAndAddLiquidity.s.sol --rpc-endpoint base_sepolia --broadcast -vvvv
contract CreateTreasuryPoolAndAddLiquidityScript is Script {
    uint256 constant ETH_AMOUNT = 0.02 ether;
    uint256 constant TOKEN_AMOUNT = 20_000e18;
    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant STARTING_SQRT_PRICE_X96 = 79228162514264337593543950336; // 1:1

    function run() external {
        address token = vm.envAddress("TREASURY_TOKEN_ADDRESS");
        address hook = vm.envAddress("TREASURY_HOOK_ADDRESS");

        IPoolManager manager = IPoolManager(BaseSepoliaAddresses.POOL_MANAGER);
        PoolModifyLiquidityTest modifyLiquidityRouter =
            PoolModifyLiquidityTest(BaseSepoliaAddresses.POOL_MODIFY_LIQUIDITY_TEST);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            STARTING_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ETH_AMOUNT,
            TOKEN_AMOUNT
        );

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        TestERC20(token).approve(address(modifyLiquidityRouter), type(uint256).max);
        manager.initialize(key, STARTING_SQRT_PRICE_X96);
        modifyLiquidityRouter.modifyLiquidity{value: ETH_AMOUNT}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );

        vm.stopBroadcast();

        console2.log("Treasury pool initialized. tMAGIK held by PoolManager:", TestERC20(token).balanceOf(address(manager)));
    }
}
