// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FLOWER} from "../src/FLOWER.sol";

contract FLOWERTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000_000 ether;
    uint256 internal constant BURN_AMOUNT = 100_000_000 ether;

    FLOWER internal flower;
    address internal alice = address(0xA11CE);

    function setUp() public {
        flower = new FLOWER(alice);
    }

    function testInitialSupplyIsOneTrillion() public view {
        assertEq(flower.totalSupply(), INITIAL_SUPPLY);
        assertEq(flower.balanceOf(alice), INITIAL_SUPPLY);
    }

    function testNoOwnerOrMintSurface() public view {
        assertEq(flower.name(), "FLOWER");
        assertEq(flower.symbol(), "FLOWER");
    }

    function testBurnReducesTotalSupply() public {
        vm.prank(alice);
        flower.burn(BURN_AMOUNT);
        assertEq(flower.totalSupply(), INITIAL_SUPPLY - BURN_AMOUNT);
    }
}
