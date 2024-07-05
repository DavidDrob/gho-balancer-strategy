// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Auction, AuctionFactory} from "@periphery/Auctions/AuctionFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract AuctionTest is Setup {
    IERC20 bal;
    IERC20 auraPool;

    function setUp() public virtual override {
        super.setUp();

        bal = IERC20(tokenAddrs["BAL"]);
        auraPool = IERC20(0xBDD6984C3179B099E9D383ee2F44F3A57764BF7d);
    }

    function test_auction(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 lpBeforeAuction = auraPool.balanceOf(address(strategy));

        uint256 toAirdrop = strategy.MIN_BAL_TO_AUCTION();
        deal(address(bal), address(strategy), toAirdrop);

        // Start an auction
        skip(strategy.profitMaxUnlockTime());
        deal(address(bal), address(strategy), toAirdrop);
        vm.prank(keeper);
        strategy.report();

        Auction auction = Auction(strategy.auction());
        bytes32 auctionId = strategy.auctionId();

        auction.kick(auctionId);

        // wait until the auction is 75% complete
        skip((auction.auctionLength() * 75) / 100);
        address buyer = address(62735);
        uint256 amountNeeded = auction.getAmountNeeded(auctionId, toAirdrop);

        // TODO: find out why using `amountNeeded` doesn't work
        deal(address(strategy.asset()), buyer, type(uint256).max);

        vm.prank(buyer);
        asset.approve(address(auction), type(uint256).max);

        // take the auction
        vm.prank(buyer);
        auction.take(auctionId);

        uint256 lpAfterAuction = auraPool.balanceOf(address(strategy));
        assertGt(lpAfterAuction, lpBeforeAuction);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_minAmountToEnableAuction() public {
        mintAndDepositIntoStrategy(strategy, user, 100e18);

        uint256 toAirdrop = strategy.MIN_BAL_TO_AUCTION();
        deal(address(bal), address(strategy), toAirdrop - 1e18);

        skip(strategy.profitMaxUnlockTime());

        vm.prank(keeper);
        strategy.report();

        assertEq(strategy.auctionId(), "");
    }
}


