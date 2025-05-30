pragma solidity ^0.5.16;

import "./PriceOracle.sol";
import "./SErc20.sol";

contract TestNetPriceOracle is PriceOracle {
    /**
    * @notice Administrator for this contract
    */
    address public admin;
    mapping(address => uint) prices;
    event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);

    string public coreTokenName;

    constructor(string memory _coreTokenName) public {
        admin = msg.sender;
        coreTokenName = _coreTokenName;
    }

    function getUnderlyingPrice(SToken sToken) public view returns (uint) {
        if (compareStrings(sToken.symbol(), coreTokenName)) {
            return prices[address(sToken)];
        } else {
            return prices[address(SErc20(address(sToken)).underlying())];
        }
    }

    function setUnderlyingPrice(SToken sToken, uint underlyingPriceMantissa) public {
        require(msg.sender == admin, "only admin can set underlyingPrice");
        if(compareStrings(sToken.symbol(),coreTokenName)){
            prices[address(sToken)] = underlyingPriceMantissa;
        }
        else{
            address asset = address(SErc20(address(sToken)).underlying());
            emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
            prices[asset] = underlyingPriceMantissa;
        }
    }

    function feedPrice(SToken[] memory sTokens, uint[] memory underlyingPriceMantissas) public{
        require(msg.sender == admin, "only admin can set underlyingPrice");
        uint numTokens = sTokens.length;
        for (uint i = 0; i < numTokens; ++i) {
            setUnderlyingPrice(sTokens[i],underlyingPriceMantissas[i]);
        }
    }

    function setDirectPrice(address asset, uint price) public {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    // v1 price oracle interface for use as backing of proxy
    function assetPrices(address asset) external view returns (uint) {
        return prices[asset];
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
