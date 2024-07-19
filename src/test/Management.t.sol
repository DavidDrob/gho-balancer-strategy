// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup, IStrategyInterface} from "./utils/Setup.sol";
import "src/Strategy.sol";

contract ManagementTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_updateSlippage() public {
        vm.expectRevert("!management");
        strategy.updateSlippage(9_000);

        vm.startPrank(management);

        vm.expectRevert(BalancerStrategy__InvalidSlippage.selector);
        strategy.updateSlippage(10_001);

        strategy.updateSlippage(9_000);
        assertEq(strategy.slippage(), 9_000);

        strategy.updateSlippage(10_000);
        assertEq(strategy.slippage(), 10_000);
    }
}
