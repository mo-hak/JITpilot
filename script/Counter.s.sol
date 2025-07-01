// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {JITpilot} from "../src/JITpilot.sol";

contract JITpilotScript is Script {
    JITpilot public JITpilot;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        JITpilot = new JITpilot();

        vm.stopBroadcast();
    }
}
