// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {Auction, AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "@balancer/interfaces/contracts/vault/IVault.sol";
import {IAsset} from "@balancer/interfaces/contracts/vault/IAsset.sol";
import {IBalancerQueries} from "@balancer/interfaces/contracts/standalone-utils/IBalancerQueries.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/aave/IGhoToken.sol";
import "./interfaces/aura/IRewardPool4626.sol";
import "./interfaces/balancer/IWeightedPool2Tokens.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

error BalancerStrategy__InvalidToken();
error BalancerStrategy__TooLittleBAL();
error BalancerStrategy__NoAuraRewards();

contract Strategy is BaseStrategy, AuctionSwapper {
    using SafeERC20 for ERC20;

    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    address public constant AURA = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant BAL_LP = 0x8353157092ED8Be69a9DF8F95af097bbF33Cb2aF;

    IVault public constant BALANCER_VAULT = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IBalancerQueries public constant BALANCER_QUERY = IBalancerQueries(0xE39B5e3B6D74016b2F6A9673D7d7493B6DF549d5);
    IRewardPool4626 public constant AURA_POOL = IRewardPool4626(0xBDD6984C3179B099E9D383ee2F44F3A57764BF7d);
    IWeightedPool2Tokens public constant BAL_USDC_POOl = IWeightedPool2Tokens(0x9c08C7a7a89cfD671c79eacdc6F07c1996277eD5);

    bytes32 public constant POOL_ID = bytes32(0x8353157092ed8be69a9df8f95af097bbf33cb2af0000000000000000000005d9);

    uint256 public constant SLIPPAGE = 9_900; // slippage in BPS
    uint256 public constant MAX_BPS = 10_000;

    uint256 public constant MIN_BAL_TO_AUCTION = 12e18; // 12 BAL

    IVault.FundManagement private FUNDS = IVault.FundManagement(
        address(this),
        false,
        payable(address(this)),
        false
    );

    constructor(
        address _asset,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        IGhoToken(GHO).approve(address(BALANCER_VAULT), type(uint256).max);
        IERC20(BAL).approve(address(BALANCER_VAULT), type(uint256).max);
        IERC20(WETH).approve(address(BALANCER_VAULT), type(uint256).max);
        ERC20(USDT).safeIncreaseAllowance(address(BALANCER_VAULT), type(uint256).max);
        IERC20(BAL_LP).approve(address(AURA_POOL), type(uint256).max);
    }

    // TODO: do this in the constructor
    function setAuction(address _auction) external onlyManagement {
        if (_auction != address(0)) {
            require(Auction(_auction).want() == address(asset));
        }
        auction = _auction;
    }

    function _auctionKicked(address _token)
        internal
        virtual
        override
        returns (uint256 _kicked)
    {
        if (_token != BAL) revert BalancerStrategy__InvalidToken();

        // send BAL to auction contract
        _kicked = super._auctionKicked(_token);

        if (_kicked < MIN_BAL_TO_AUCTION) revert BalancerStrategy__TooLittleBAL();
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // Deposit GHO into Balancer Pool
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
            POOL_ID,
            IVault.SwapKind.GIVEN_IN,
            IAsset(GHO),
            IAsset(BAL_LP),
            _amount,
            ""
        );

        // pool consists of stablecoins, so LP price is almost 1:1 to assets
        uint256 limit = Math.mulDiv(_amount, SLIPPAGE, MAX_BPS);

        uint256 _out = BALANCER_VAULT.swap(
            singleSwap,
            FUNDS,
            limit,
            block.timestamp
        );

        // Stake LP
        AURA_POOL.deposit(_out, address(this));
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Calculate LP amount to withdraw
        IVault.SingleSwap memory querySwap = IVault.SingleSwap(
            POOL_ID,
            IVault.SwapKind.GIVEN_OUT,
            IAsset(BAL_LP),
            IAsset(GHO),
            _amount,
            ""
        );

        uint256 _desired_lp_amount = BALANCER_QUERY.querySwap(
            querySwap,
            FUNDS
        );

        uint256 _staked_tokens = AURA_POOL.balanceOf(address(this));

        uint256 _lp_amount = Math.min(_desired_lp_amount, _staked_tokens);

        // Withdraw LP from Aura Pool
        uint256 bptAmount = AURA_POOL.redeem(
            _lp_amount,
            address(this),
            address(this)
        );

        // Swap LP for GHO
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
            POOL_ID,
            IVault.SwapKind.GIVEN_IN,
            IAsset(BAL_LP),
            IAsset(GHO),
            bptAmount,
            ""
        );

        BALANCER_VAULT.swap(
            singleSwap,
            FUNDS,
            0, // vault already checks for slippage
            block.timestamp
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
            bool _claimedSucessfully = AURA_POOL.getReward();
            if (!_claimedSucessfully) revert BalancerStrategy__NoAuraRewards();

            uint256 _auraBalance = AURA_POOL.maxWithdraw(address(this));
            uint256 _lpAmountTotal =
                AURA_POOL.previewWithdraw(_auraBalance) +
                IERC20(BAL_LP).balanceOf(address(this));

            // LP in GHO
            IVault.SingleSwap memory querySwap = IVault.SingleSwap(
                POOL_ID,
                IVault.SwapKind.GIVEN_OUT,
                IAsset(BAL_LP),
                IAsset(GHO),
                _lpAmountTotal,
                ""
            );

            uint256 ghoAmountExpected = BALANCER_QUERY.querySwap(
                querySwap,
                FUNDS
            );

            // assuming USDC and GHO are 1:1
            uint256 balRate = BAL_USDC_POOl.getLatest(uint8(0));
            uint256 balAmount = IERC20(BAL).balanceOf(address(this));
            uint256 balInGho = Math.mulDiv(balRate, balAmount, 1e18);

            // TODO: add AURA rewards
            _totalAssets +=
                ghoAmountExpected +
                IGhoToken(GHO).balanceOf(address(this)) + 
                balInGho;
    }

    function _swapBalForWeth(uint256 _amount) internal returns (uint256) {
            bytes32 balWethPoolId =
                bytes32(
                    0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014
                );
            IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
                balWethPoolId,
                IVault.SwapKind.GIVEN_IN,
                IAsset(BAL),
                IAsset(WETH),
                _amount,
                ""
            );

            return BALANCER_VAULT.swap(
                singleSwap,
                FUNDS,
                0,
                block.timestamp
            );
    }

    function _swapWethForUSDT(uint256 _amount) internal returns (uint256) {
            bytes32 wethUsdtPoolId =
                bytes32(
                    0x3e5fa9518ea95c3e533eb377c001702a9aacaa32000200000000000000000052 
            );
            IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
                wethUsdtPoolId,
                IVault.SwapKind.GIVEN_IN,
                IAsset(WETH),
                IAsset(USDT),
                _amount,
                ""
            );

            return BALANCER_VAULT.swap(
                singleSwap,
                FUNDS,
                0,
                block.timestamp
            );
   }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // NOTE: Withdraw limitations such as liquidity constraints should be accounted for HERE
        //  rather than _freeFunds in order to not count them as losses on withdraws.

        // TODO: If desired implement withdraw limit logic and any needed state variables.

        // EX:
        // if(yieldSource.notShutdown()) {
        //    return asset.balanceOf(address(this)) + asset.balanceOf(yieldSource);
        // }
        return type(uint256).max;
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement deposit limit logic and any needed state variables .
        
        EX:    
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            return totalAssets >= depositLimit ? 0 : depositLimit - totalAssets;
    }
    */

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    function _tend(uint256 _totalIdle) internal override {}
    */

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function _tendTrigger() internal view override returns (bool) {}
    */

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    */
}
