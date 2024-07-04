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
    IERC20 auraPool;

    function setUp() public virtual override {
        super.setUp();
        bal = IERC20(tokenAddrs["BAL"]);
        auraPool = IERC20(0xBDD6984C3179B099E9D383ee2F44F3A57764BF7d);

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
        auction.setHookFlags(true, true, false, true);

        strategy.setAuction(address(auction));
        vm.stopPrank();
    }

    function test_auction(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 lpBeforeAuction = auraPool.balanceOf(address(strategy));

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

        uint256 lpAfterAuction = auraPool.balanceOf(address(strategy));
        assertGt(lpAfterAuction, lpBeforeAuction);

        skip(strategy.profitMaxUnlockTime());

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

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
}


