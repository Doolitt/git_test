// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title FLOWER
/// @notice Fixed-supply token for the FLOWER protocol.
/// @dev No owner, no mint authority, no transfer tax, no pause, no blacklist.
///      ERC20Burnable is included because NFT development permanently burns FLOWER.
contract FLOWER is ERC20, ERC20Burnable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000_000 ether;

    error ZeroInitialRecipient();

    constructor(address initialRecipient) ERC20("FLOWER", "FLOWER") {
        if (initialRecipient == address(0)) revert ZeroInitialRecipient();
        _mint(initialRecipient, INITIAL_SUPPLY);
    }
}
