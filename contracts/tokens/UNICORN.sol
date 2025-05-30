// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract UNICORNToken is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("unique new ideas create our remarkable new", "UNICORN") {
        _mint(msg.sender, 100000000 * 10 ** 18);
    }
}