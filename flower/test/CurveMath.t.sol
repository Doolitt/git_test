// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActivationManager, IFLOWER} from "../src/ActivationManager.sol";
import {FLOWER} from "../src/FLOWER.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("Mock", "MOCK") {}
}

contract CurveMathTest is Test {
    ActivationManager internal manager;

    function setUp() public {
        FLOWER flower = new FLOWER(address(this));
        MockNFT nft = new MockNFT();
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
    }

    function testBelowFloorHasZeroWeight() public view {
        assertEq(manager.computeWeight(49_999_999 ether, 0, 365), 0);
    }

    function testFloorGetsOnlyBaseWeight() public view {
        assertEq(manager.computeWeight(50_000_000 ether, 0, 365), 0.25e18);
    }

    function testDevelopmentCurveIsIncreasing() public view {
        uint256 w100 = manager.computeWeight(100_000_000 ether, 0, 365);
        uint256 w350 = manager.computeWeight(350_000_000 ether, 0, 365);
        uint256 w1b = manager.computeWeight(1_000_000_000 ether, 0, 365);

        assertGt(w350, w100);
        assertGt(w1b, w350);
    }

    function testLongerCommitmentHasHigherLockBoost() public view {
        uint256 w90 = manager.computeWeight(500_000_000 ether, 0, 90);
        uint256 w365 = manager.computeWeight(500_000_000 ether, 0, 365);
        uint256 w730 = manager.computeWeight(500_000_000 ether, 0, 730);

        assertGt(w365, w90);
        assertGt(w730, w365);
    }

    function testBurnDevelopmentIsMonotonic() public view {
        uint256 w0 = manager.computeWeight(500_000_000 ether, 0, 365);
        uint256 w50 = manager.computeWeight(500_000_000 ether, 50_000_000 ether, 365);
        uint256 w500 = manager.computeWeight(500_000_000 ether, 500_000_000 ether, 365);

        assertGt(w50, w0);
        assertGt(w500, w50);
    }
}
