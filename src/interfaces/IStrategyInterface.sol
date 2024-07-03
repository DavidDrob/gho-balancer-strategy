// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IAuctionSwapper} from "@periphery/swappers/interfaces/IAuctionSwapper.sol";

interface IStrategyInterface is IStrategy, IAuctionSwapper {
    function MIN_BAL_TO_AUCTION() external view returns (uint256);

    function setAuction(address _auction) external;
}
