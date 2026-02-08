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
        address aerodromeRouter = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

        CLAWDRush rush = new CLAWDRush(usdc, clawd, pyth, aerodromeRouter);
        console.logString(string.concat("CLAWDRush deployed at: ", vm.toString(address(rush))));
    }
}
