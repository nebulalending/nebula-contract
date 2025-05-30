pragma solidity ^0.5.16;

import "./SToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of Unitroller
    */
    address public comptrollerImplementation;

    /**
    * @notice Pending brains of Unitroller
    */
    address public pendingComptrollerImplementation;
}

contract ComptrollerV1Storage is UnitrollerAdminStorage {

    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => SToken[]) public accountAssets;

}

contract ComptrollerV2Storage is ComptrollerV1Storage {
    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;

        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint collateralFactorMantissa;

        /// @notice Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;

        /// @notice Whether or not this market receives CoreToken
        bool isValue;
    }

    /**
     * @notice Official mapping of sTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;


    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;
}

contract ComptrollerV3Storage is ComptrollerV2Storage {
    struct MarketState {
        /// @notice The market's last updated borrowIndex or supplyIndex
        uint224 index;

        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice A list of all markets
    SToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes, per block
    uint public rate;

    /// @notice The portion of rate that each market currently receives
    mapping(address => uint) public speeds;

    /// @notice The market supply state for each market
    mapping(address => MarketState) public supplyState;

    /// @notice The market borrow state for each market
    mapping(address => MarketState) public borrowState;

    /// @notice The borrow index for each market for each supplier as of the last time they accrued
    mapping(address => mapping(address => uint)) public supplierIndex;

    /// @notice The borrow index for each market for each borrower as of the last time they accrued
    mapping(address => mapping(address => uint)) public borrowerIndex;

    /// @notice The accrued but not yet transferred to each user
    mapping(address => uint) public accrued;
}

contract ComptrollerV4Storage is ComptrollerV3Storage {
    /// @notice The portion of that each constributor receives per block
    mapping(address => uint) public contributorSpeeds;

    /// @notice Last block at which a contributor's rewards have been allocated
    mapping(address => uint) public lastContributorBlock;
}

contract ComptrollerV5Storage is ComptrollerV4Storage {
    /// @notice The rate at which is distributed to the corresponding borrow market (per block)
    mapping(address => uint) public borrowSpeeds;

    /// @notice The rate at which is distributed to the corresponding supply market (per block)
    mapping(address => uint) public supplySpeeds;
}

contract ComptrollerV6Storage is ComptrollerV5Storage {
    /// @notice Reserve Guardian address
    address payable public reserveGuardian;

    /// @notice Reserve address
    address payable public reserveAddress;

    /// @notice staking
    address public staking;
}

contract ComptrollerV7Storage is ComptrollerV6Storage {
    // @notice The marketCapGuardian can set marketCaps to any number for any market.
    address public marketCapGuardian;

    // @notice Supply caps enforced by mintAllowed for each sToken address. Defaults to zero which corresponds to unlimited supplying.
    mapping(address => uint) public supplyCaps;

    // @notice Borrow caps enforced by borrowAllowed for each cToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;

    /**
     * @notice The Pause Guardian can pause protocol.
     */
    bool public protocolPaused;
}
