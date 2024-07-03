// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Auction, AuctionFactory} from "@periphery/Auctions/AuctionFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract AuctionTest is Setup {
    Auction public auction;
    bytes32 public auctionId;

    IERC20 bal;

    function setUp() public virtual override {
        super.setUp();
        bal = IERC20(tokenAddrs["BAL"]);

        // setup dutch auction
        // BAL -> GHO
        vm.startPrank(management);
        AuctionFactory auctionFactory = AuctionFactory(
            strategy.auctionFactory()
        );
        auction = Auction(
            // TODO: include governance
            auctionFactory.createNewAuction(strategy.asset(), address(strategy))
        );
        auctionId = auction.enable(address(bal), address(strategy));
        auction.setHookFlags(true, true, false, false);

        strategy.setAuction(address(auction));
        vm.stopPrank();
    }

    function test_auction(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 assetBeforeAuction = asset.balanceOf(address(strategy));

        // airdrop on strategy
        uint256 toAirdrop = strategy.MIN_BAL_TO_AUCTION();
        deal(address(bal), address(strategy), toAirdrop - 1e18);
        assertTrue(bal.balanceOf(address(strategy)) == 11e18);

        // below minimum should revert
        vm.expectRevert();
        auction.kick(auctionId);

        deal(address(bal), address(strategy), toAirdrop);
        auction.kick(auctionId);

        // wait until the auction is 75% complete
        skip((auction.auctionLength() * 75) / 100);
        address buyer = address(62735);
        uint256 amountNeeded = auction.getAmountNeeded(auctionId, toAirdrop);

        deal(address(strategy.asset()), buyer, amountNeeded);

        vm.prank(buyer);
        asset.approve(address(auction), amountNeeded);

        // take the auction
        vm.prank(buyer);
        auction.take(auctionId);

        uint256 assetAfterAuction = asset.balanceOf(address(strategy));
        assertGt(assetAfterAuction, assetBeforeAuction);

        skip(strategy.profitMaxUnlockTime());
    }
}


