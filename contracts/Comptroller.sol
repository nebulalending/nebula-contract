pragma solidity ^0.5.16;

import "./SToken.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/SAVM.sol";

/**
 * @title Comptroller Contract
 * @author comptroller
 */
contract Comptroller is ComptrollerV7Storage, ComptrollerInterface, ComptrollerErrorReporter, Exponential {
    /// @notice Emitted when an admin supports a market
    event MarketListed(SToken sToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(SToken sToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(SToken sToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(SToken sToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(SToken sToken, string action, bool pauseState);

    /// @notice Emitted when protocol pause state is changed by admin
    event ActionProtocolPaused(bool state);

    /// @notice Emitted when market status is changed
    event ComptrollerMarket(SToken sToken, bool boolValue);

    /// @notice Emitted when rate is changed
    event NewRate(uint oldRate, uint newRate);

    /// @notice Emitted when a new speed is calculated for a market
    event SpeedUpdated(SToken indexed sToken, uint newSpeed);

    /// @notice Emitted when is distributed to a supplier
    event DistributedSupplier(SToken indexed sToken, address indexed supplier, uint delta, uint supplyIndex);

    /// @notice Emitted when is distributed to a borrower
    event DistributedBorrower(SToken indexed sToken, address indexed borrower, uint delta, uint borrowIndex);

    /// @notice Emitted when new speed is set
    event ContributorSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when is granted
    event Granted(address recipient, uint amount);

     /// @notice Emitted when a new borrow-side speed is calculated for a market
    event BorrowSpeedUpdated(SToken indexed sToken, uint newSpeed);

    /// @notice Emitted when a new supply-side speed is calculated for a market
    event SupplySpeedUpdated(SToken indexed sToken, uint newSpeed);

    /// @notice Emitted when reserve guardian is changed
    event NewReserveGuardian(address oldReserveGuardian, address newReserveGuardian, address oldReserveAddress, address newReserveAddress);

    /// @notice Emitted when market cap for a sToken is changed
    event NewMarketCap(SToken indexed sToken, uint newSupplyCap, uint newBorrowCap);

    /// @notice Emitted when market cap guardian is changed
    event NewMarketCapGuardian(address oldMarketCapGuardian, address newMarketCapGuardian);

    /// @notice The initial index for a market
    uint224 public constant initialIndex = 1e36;

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyProtocolAllowed {
        require(!protocolPaused, "protocol is paused");
        _;
    }

    modifier validPauseState(bool state) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can");
        _;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (SToken[] memory) {
        SToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param sToken The sToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, SToken sToken) external view returns (bool) {
        return markets[address(sToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param sTokens The list of addresses of the sToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory sTokens) public returns (uint[] memory) {
        uint len = sTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            SToken sToken = SToken(sTokens[i]);

            results[i] = uint(addToMarketInternal(sToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param sToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(SToken sToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(sToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(sToken);

        emit MarketEntered(sToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param sTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address sTokenAddress) external returns (uint) {
        SToken sToken = SToken(sTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the sToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = sToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(sTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(sToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set sToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete sToken from the account’s list of assets */
        // load into memory for faster iteration
        SToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == sToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        SToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(sToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param sToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address sToken, address minter, uint mintAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[sToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint supplyCap = supplyCaps[sToken];
        // Supply cap of 0 corresponds to unlimited supplying
        if (supplyCap != 0) {
            uint totalCash = SToken(sToken).getCash();
            uint totalBorrows = SToken(sToken).totalBorrows();
            uint totalReserves = SToken(sToken).totalReserves();
            // totalSupplies = totalCash + totalBorrows - totalReserves
            (MathError mathErr, uint totalSupplies) = addThenSubUInt(totalCash, totalBorrows, totalReserves);
            require(mathErr == MathError.NO_ERROR, "totalSupplies failed");

            uint nextTotalSupplies = add_(totalSupplies, mintAmount);
            require(nextTotalSupplies < supplyCap, "market supply cap reached");
        }

        // Keep the flywheel moving
        updateSupplyIndex(sToken);
        distributeSupplier(sToken, minter);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param sToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address sToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        sToken;
        minter;
        actualMintAmount;
        mintTokens;
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param sToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of sTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address sToken, address redeemer, uint redeemTokens) external onlyProtocolAllowed returns (uint) {
        uint allowed = redeemAllowedInternal(sToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateSupplyIndex(sToken);
        distributeSupplier(sToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address sToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[sToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[sToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, SToken(sToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param sToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address sToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        // Shh - currently unused
        sToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param sToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address sToken, address borrower, uint borrowAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[sToken], "borrow is paused");

        if (!markets[sToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[sToken].accountMembership[borrower]) {
            // only sTokens may call borrowAllowed if borrower not in market
            require(msg.sender == sToken, "sender must be sToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(SToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[sToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(SToken(sToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        uint borrowCap = borrowCaps[sToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = SToken(sToken).totalBorrows();
            (MathError mathErr, uint nextTotalBorrows) = addUInt(totalBorrows, borrowAmount);
            require(mathErr == MathError.NO_ERROR, "total borrows overflow");
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, SToken(sToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: SToken(sToken).borrowIndex()});
        updateBorrowIndex(sToken, borrowIndex);
        distributeBorrower(sToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param sToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address sToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        sToken;
        borrower;
        borrowAmount;
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param sToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address sToken,
        address payer,
        address borrower,
        uint repayAmount) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[sToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: SToken(sToken).borrowIndex()});
        updateBorrowIndex(sToken, borrowIndex);
        distributeBorrower(sToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param sToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address sToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) external {
        // Shh - currently unused
        sToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param sTokenBorrowed Asset which was borrowed by the borrower
     * @param sTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address sTokenBorrowed,
        address sTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[sTokenBorrowed].isListed || !markets[sTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = SToken(sTokenBorrowed).borrowBalanceStored(borrower);
        (MathError mathErr, uint maxClose) = mulScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        if (mathErr != MathError.NO_ERROR) {
            return uint(Error.MATH_ERROR);
        }
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param sTokenBorrowed Asset which was borrowed by the borrower
     * @param sTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address sTokenBorrowed,
        address sTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) external {
        // Shh - currently unused
        sTokenBorrowed;
        sTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param sTokenCollateral Asset which was used as collateral and will be seized
     * @param sTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address sTokenCollateral,
        address sTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms

        // Shh - currently unused
        seizeTokens;

        if (!markets[sTokenCollateral].isListed || !markets[sTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (SToken(sTokenCollateral).comptroller() != SToken(sTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateSupplyIndex(sTokenCollateral);
        distributeSupplier(sTokenCollateral, borrower);
        distributeSupplier(sTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param sTokenCollateral Asset which was used as collateral and will be seized
     * @param sTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address sTokenCollateral,
        address sTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external {
        // Shh - currently unused
        sTokenCollateral;
        sTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param sToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of sTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address sToken, address src, address dst, uint transferTokens) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(sToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateSupplyIndex(sToken);
        distributeSupplier(sToken, src);
        distributeSupplier(sToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param sToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of sTokens to transfer
     */
    function transferVerify(address sToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        sToken;
        src;
        dst;
        transferTokens;
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `sTokenBalance` is the number of sTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint sTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, SToken(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, SToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param sTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address sTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, SToken(sTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param sTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral sToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        SToken sTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;
        MathError mErr;

        // For each asset the account is in
        SToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            SToken asset = assets[i];

            // Read the balances and exchange rate from the sToken
            (oErr, vars.sTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumCollateral += tokensToDenom * sTokenBalance
            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.sTokenBalance, vars.sumCollateral);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // Calculate effects of interacting with sTokenModify
            if (asset == sTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in sToken.liquidateBorrowFresh)
     * @param sTokenBorrowed The address of the borrowed sToken
     * @param sTokenCollateral The address of the collateral sToken
     * @param actualRepayAmount The amount of sTokenBorrowed underlying to convert into sTokenCollateral tokens
     * @return (errorCode, number of sTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address sTokenBorrowed, address sTokenCollateral, uint actualRepayAmount) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(SToken(sTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(SToken(sTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = SToken(sTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, ratio) = divExp(numerator, denominator);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, seizeTokens) = mulScalarTruncate(ratio, actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param sToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(SToken sToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(sToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(sToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(sToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param sToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(SToken sToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(sToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        sToken.isSToken(); // Sanity check to make sure its really a SToken

        markets[address(sToken)] = Market({isListed: true, isValue: false, collateralFactorMantissa: 0});

        _addMarketInternal(address(sToken));
        _initializeMarket(address(sToken));

        emit MarketListed(sToken);

        return uint(Error.NO_ERROR);
    }

    function _initializeMarket(address sToken) internal {
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        MarketState storage supplyState = supplyState[sToken];
        MarketState storage borrowState = borrowState[sToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = initialIndex;
        }

         if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = initialIndex;
        }

        supplyState.block = borrowState.block = blockNumber;
    }

    function _addMarketInternal(address sToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != SToken(sToken), "market already added");
        }
        allMarkets.push(SToken(sToken));
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Set whole protocol pause/unpause state
     */
    function _setProtocolPaused(bool state) public validPauseState(state) returns(bool) {
        protocolPaused = state;
        emit ActionProtocolPaused(state);
        return state;
    }

    function _setBorrowPaused(SToken sToken, bool state) public returns (bool) {
        require(markets[address(sToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(sToken)] = state;
        emit ActionPaused(sToken, "Borrow", state);
        return state;
    }

    function _setReserveInfo(address payable newReserveGuardian, address payable newReserveAddress) external returns (uint) {
        // Check caller is admin or reserveGuardian
        if (!(msg.sender == admin || msg.sender == reserveGuardian)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_RESERVE_GUARDIAN_OWNER_CHECK);
        }

        address payable oldReserveGuardian = reserveGuardian;
        address payable oldReserveAddress = reserveAddress;

        reserveGuardian = newReserveGuardian;
        reserveAddress = newReserveAddress;

        // Emit NewReserveGuardian(OldReserveGuardian, NewReserveGuardian, OldReserveAddress, NewReserveAddress)
        emit NewReserveGuardian(oldReserveGuardian, newReserveGuardian, oldReserveAddress, newReserveAddress);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Admin function to change the Market Cap Guardian
     * @param newMarketCapGuardian The address of the new Market Cap Guardian
     */
    function _setMarketCapGuardian(address newMarketCapGuardian) external {
        require(msg.sender == admin, "only admin can set market cap guardian");

        // Save current value for inclusion in log
        address oldMarketCapGuardian = marketCapGuardian;

        // Store marketCapGuardian with value newMarketCapGuardian
        marketCapGuardian = newMarketCapGuardian;

        // Emit NewMarketCapGuardian(OldMarketCapGuardian, NewMarketCapGuardian)
        emit NewMarketCapGuardian(oldMarketCapGuardian, newMarketCapGuardian);
    }

    /**
      * @notice Set the given market caps for the given sToken markets.
      * @dev Admin or marketCapGuardian function to set the market caps.
      * @param sTokens The addresses of the markets (tokens) to change the market caps for
      * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited supplying.
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketCaps(SToken[] calldata sTokens, uint[] calldata newSupplyCaps, uint[] calldata newBorrowCaps) external {
        require(msg.sender == admin || msg.sender == marketCapGuardian, "only admin or market cap guardian can set supply caps");

        uint numMarkets = sTokens.length;
        uint numSupplyCaps = newSupplyCaps.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numSupplyCaps && numMarkets == numBorrowCaps, "invalid input");

        for (uint i = 0; i < numMarkets; i++) {
            supplyCaps[address(sTokens[i])] = newSupplyCaps[i];
            borrowCaps[address(sTokens[i])] = newBorrowCaps[i];
            emit NewMarketCap(sTokens[i], newSupplyCaps[i], newBorrowCaps[i]);
        }
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** Distribution ***/

    /**
     * @notice Set speed for a single market
     * @param sToken The market whose speed to update
     * @param supplySpeeds New supply-side speed for market
     * @param borrowSpeeds New borrow-side speed for market
     */
    function _setSpeeds(SToken[] memory sToken, uint[] memory supplySpeeds, uint[] memory borrowSpeeds) public {
        require(adminOrInitializing(), "only admin can set speed");

        uint numTokens = sToken.length;
        require(numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length, "Comptroller::_setCompSpeeds invalid input");

        for (uint i = 0; i < numTokens; ++i) {
            setSpeedInternal(sToken[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    function setSpeedInternal(SToken sToken, uint supplySpeed, uint borrowSpeed) internal {
        Market storage market = markets[address(sToken)];
        require(market.isListed, "market is not listed");

        if (supplySpeeds[address(sToken)] != supplySpeed) {
            updateSupplyIndex(address(sToken));
            supplySpeeds[address(sToken)] = supplySpeed;
            emit SupplySpeedUpdated(sToken, supplySpeed);
        }

        if (borrowSpeeds[address(sToken)] != borrowSpeed) {
            Exp memory borrowIndex = Exp({mantissa: sToken.borrowIndex()});
            updateBorrowIndex(address(sToken), borrowIndex);

            // Update speed and emit event
            borrowSpeeds[address(sToken)] = borrowSpeed;
            emit BorrowSpeedUpdated(sToken, borrowSpeed);
        }
    }

    /**
     * @notice Accrue to the market by updating the supply index
     * @param sToken The market whose supply index to update
     */
    function updateSupplyIndex(address sToken) internal {
        MarketState storage supplyState = supplyState[sToken];
        uint supplySpeed = supplySpeeds[sToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = SToken(sToken).totalSupply();
            uint accrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(accrued, supplyTokens) : Double({mantissa: 0});
            supplyState.index = safe224(add_(Double({mantissa: supplyState.index}), ratio).mantissa, "new index exceeds 224 bits");
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue to the market by updating the borrow index
     * @param sToken The market whose borrow index to update
     */
    function updateBorrowIndex(address sToken, Exp memory marketBorrowIndex) internal {
        MarketState storage borrowState = borrowState[sToken];
        uint borrowSpeed = borrowSpeeds[sToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(SToken(sToken).totalBorrows(), marketBorrowIndex);
            uint accrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(accrued, borrowAmount) : Double({mantissa: 0});
            borrowState.index = safe224(add_(Double({mantissa: borrowState.index}), ratio).mantissa, "new index exceeds 224 bits");
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate accrued by a supplier and possibly transfer it to them
     * @param sToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute to
     */
    function distributeSupplier(address sToken, address supplier) internal {
        MarketState storage supplyState = supplyState[sToken];

        uint supplyIndex = supplyState.index;
        uint innerSupplierIndex = supplierIndex[sToken][supplier];

        supplierIndex[sToken][supplier] = supplyIndex;

        if (innerSupplierIndex == 0 && supplyIndex >= initialIndex) {
            innerSupplierIndex = initialIndex;
        }

        Double memory deltaIndex = Double({mantissa: sub_(supplyIndex, innerSupplierIndex)});
        uint supplierTokens = SToken(sToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(accrued[supplier], supplierDelta);
        accrued[supplier] = supplierAccrued;
        emit DistributedSupplier(SToken(sToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param sToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute to
     */
    function distributeBorrower(address sToken, address borrower, Exp memory marketBorrowIndex) internal {
        MarketState storage borrowState = borrowState[sToken];

        uint borrowIndex = borrowState.index;
        uint innerBorrowerIndex = borrowerIndex[sToken][borrower];

        borrowerIndex[sToken][borrower] = borrowIndex;

        if (innerBorrowerIndex == 0 && borrowIndex >= initialIndex) {
            innerBorrowerIndex = initialIndex;
        }

        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, innerBorrowerIndex)});
        uint borrowerAmount = div_(SToken(sToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // Calculate accrued: sTokenAmount * accruedPerBorrowedUnit
        uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
        uint borrowerAccrued = add_(accrued[borrower], borrowerDelta);
        accrued[borrower] = borrowerAccrued;
        emit DistributedBorrower(SToken(sToken), borrower, borrowerDelta, borrowIndex);
    }

    /*** Distribution Admin ***/

    /**
     * @notice Update additional accrued for a contributor
     * @param contributor The address to calculate contributor rewards
     */
    function updateContributorRewards(address contributor) public {
        uint speed = contributorSpeeds[contributor];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);

        if (deltaBlocks > 0 && speed > 0) {
            uint newAccrued = mul_(deltaBlocks, speed);
            uint contributorAccrued = add_(accrued[contributor], newAccrued);

            accrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice Set speed for a single contributor
     * @param contributor The contributor whose speed to set
     * @param speed New speed for contributor
     */
    function _setContributorSpeed(address contributor, uint speed) public {
        require(adminOrInitializing(), "Only Admin can set speed");

        // Update contributor reward before update speed
        updateContributorRewards(contributor);

        if (speed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        }

        // Update last block
        lastContributorBlock[contributor] = getBlockNumber();
        // Update speed
        contributorSpeeds[contributor] = speed;

        emit ContributorSpeedUpdated(contributor, speed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (SToken[] memory) {
        return allMarkets;
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

}
