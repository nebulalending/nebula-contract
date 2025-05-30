pragma solidity ^0.5.16;

import "./SErc20Delegate.sol";

interface SavmLike {
  function delegate(address delegatee) external;
}

/**
 * @title LikeDelegate Contract
 * @notice STokens which can 'delegate votes' of their underlying ERC-20
 */
contract SSavmLikeDelegate is SErc20Delegate {
  /**
   * @notice Construct an empty delegate
   */
  constructor() public SErc20Delegate() {}

  /**
   * @notice Admin call to delegate the votes of the SAVM-like underlying
   * @param savmLikeDelegatee The address to delegate votes to
   */
  function _delegateSavmLikeTo(address savmLikeDelegatee) external {
    require(msg.sender == admin, "only the admin may set the savm-like delegate");
    SavmLike(underlying).delegate(savmLikeDelegatee);
  }
}
