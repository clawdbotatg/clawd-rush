// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/CLAWDRush.sol";
import "./DeployHelpers.s.sol";

contract DeployCLAWDRush is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        // Base mainnet addresses
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address clawd = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;
        address pyth = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
        address uniV3Router = 0x2626664c2603336E57B271c5C0b26F421741e481; // Uniswap V3 SwapRouter on Base
        address weth = 0x4200000000000000000000000000000000000006;

        CLAWDRush rush = new CLAWDRush(usdc, clawd, pyth, uniV3Router, weth);
        console.logString(string.concat("CLAWDRush deployed at: ", vm.toString(address(rush))));
    }
}
