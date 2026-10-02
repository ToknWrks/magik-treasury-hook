// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Canonical Uniswap v4 deployment addresses on Base Sepolia (chain id 84532).
/// Cross-checked against https://docs.uniswap.org/contracts/v4/deployments and the
/// independently-maintained Nethereum address constants (github.com/Nethereum/Nethereum) —
/// verify against https://developers.uniswap.org/contracts/v4/deployments before using
/// these for anything beyond this experiment, in case they've since moved.
library BaseSepoliaAddresses {
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address constant STATE_VIEW = 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4;
    address constant QUOTER = 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa;
    address constant POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address constant POOL_MODIFY_LIQUIDITY_TEST = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;

    /// @dev Canonical deterministic CREATE2 deployer proxy (same address on every chain).
    address constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
}
