// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GraduatedSellTaxTreasuryHook} from "../src/GraduatedSellTaxTreasuryHook.sol";
import {BaseSepoliaAddresses} from "./BaseSepoliaAddresses.sol";

/// @notice Deploys the treasury-collecting sell-tax hook against the existing tMAGIK token,
/// with `treasury` pointed at the sMAGIK vault (set VAULT_ADDRESS in .env after DeployVault.s.sol).
///
/// Usage: set TMAGIK_ADDRESS, VAULT_ADDRESS in .env, then:
///   forge script script/DeployTreasuryHook.s.sol --rpc-endpoint base_sepolia --broadcast -vvvv
contract DeployTreasuryHookScript is Script {
    function run() external returns (GraduatedSellTaxTreasuryHook hook) {
        address token = vm.envAddress("TREASURY_TOKEN_ADDRESS");
        address vault = vm.envAddress("VAULT_ADDRESS");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        uint256[] memory thresholds = new uint256[](4);
        thresholds[0] = 0;
        thresholds[1] = 100;
        thresholds[2] = 300;
        thresholds[3] = 500;

        uint24[] memory feePpm = new uint24[](4);
        feePpm[0] = 0;
        feePpm[1] = 10_000;
        feePpm[2] = 30_000;
        feePpm[3] = 50_000;

        // Standing-bid price support is opt-in: 0 leaves it fully disabled (see
        // README.md). Owner can tune via setPriceSupportBps/setBidRange
        // post-deploy; these are just safe placeholder values for the disabled case.
        uint256 priceSupportBps = vm.envOr("PRICE_SUPPORT_BPS", uint256(0));
        int24 bidTicksBelowSpot = int24(vm.envOr("BID_TICKS_BELOW_SPOT", int256(200)));
        int24 bidWidthTicks = int24(vm.envOr("BID_WIDTH_TICKS", int256(60)));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(
            IPoolManager(BaseSepoliaAddresses.POOL_MANAGER),
            token,
            deployer,
            vault,
            deployer,
            thresholds,
            feePpm,
            priceSupportBps,
            bidTicksBelowSpot,
            bidWidthTicks
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            BaseSepoliaAddresses.CREATE2_FACTORY,
            flags,
            type(GraduatedSellTaxTreasuryHook).creationCode,
            constructorArgs
        );

        hook = new GraduatedSellTaxTreasuryHook{salt: salt}(
            IPoolManager(BaseSepoliaAddresses.POOL_MANAGER),
            token,
            deployer,
            vault,
            deployer,
            thresholds,
            feePpm,
            priceSupportBps,
            bidTicksBelowSpot,
            bidWidthTicks
        );
        require(address(hook) == hookAddress, "DeployTreasuryHookScript: hook address mismatch");

        vm.stopBroadcast();

        console2.log("GraduatedSellTaxTreasuryHook:", address(hook));
    }
}
