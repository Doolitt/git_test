// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FLOWER} from "../src/FLOWER.sol";

contract FLOWERTest is Test {
    FLOWER internal flower;
    address internal alice = address(0xA11CE);

    function setUp() public {
        flower = new FLOWER(alice);
    }

    function testInitialSupplyIsOneTrillion() public view {
        assertEq(flower.totalSupply(), 1_000_000_000_000 ether);
        assertEq(flower.balanceOf(alice), 1_000_000_000_000 ether);
    }

    function testNoOwnerOrMintSurface() public view {
        assertEq(flower.name(), "FLOWER");
        assertEq(flower.symbol(), "FLOWER");
    }

    function testBurnReducesTotalSupply() public {
        vm.prank(alice);
        flower.burn(100_000_000 ether);
        assertEq(flower.totalSupply(), 999_900_000_000 ether);
    }
}
