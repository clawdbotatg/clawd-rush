//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeployCLAWDRush } from "./DeployCLAWDRush.s.sol";

contract DeployScript is ScaffoldETHDeploy {
  function run() external {
    DeployCLAWDRush deployCLAWDRush = new DeployCLAWDRush();
    deployCLAWDRush.run();
  }
}