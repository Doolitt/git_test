// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActivationManager} from "../src/ActivationManager.sol";
import {IFLOWER} from "../src/interfaces/IFLOWER.sol";
import {FLOWER} from "../src/FLOWER.sol";
import {MockNFT} from "./mocks/MockNFT.sol";

contract CurveMathTest is Test {
    uint16 internal constant DAYS_365 = 365;
    uint256 internal constant LOCK_50M = 50_000_000 ether;
    uint256 internal constant LOCK_500M = 500_000_000 ether;

    ActivationManager internal manager;

    function setUp() public {
        FLOWER flower = new FLOWER(address(this));
        MockNFT nft = new MockNFT();
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
    }

    function testBelowFloorHasZeroWeight() public view {
        assertEq(manager.computeWeight(LOCK_50M - 1 ether, 0, DAYS_365), 0);
    }

    function testFloorGetsOnlyBaseWeight() public view {
        assertEq(manager.computeWeight(LOCK_50M, 0, DAYS_365), manager.BASE_WEIGHT());
    }

    function testDevelopmentCurveIsIncreasing() public view {
        uint256 w100 = manager.computeWeight(100_000_000 ether, 0, DAYS_365);
        uint256 w350 = manager.computeWeight(350_000_000 ether, 0, DAYS_365);
        uint256 w1b = manager.computeWeight(1_000_000_000 ether, 0, DAYS_365);

        assertGt(w350, w100);
        assertGt(w1b, w350);
    }

    function testLongerCommitmentHasHigherLockBoost() public view {
        uint256 w90 = manager.computeWeight(LOCK_500M, 0, 90);
        uint256 w365 = manager.computeWeight(LOCK_500M, 0, DAYS_365);
        uint256 w730 = manager.computeWeight(LOCK_500M, 0, 730);

        assertGt(w365, w90);
        assertGt(w730, w365);
    }

    function testBurnDevelopmentIsMonotonic() public view {
        uint256 w0 = manager.computeWeight(LOCK_500M, 0, DAYS_365);
        uint256 w50 = manager.computeWeight(LOCK_500M, LOCK_50M, DAYS_365);
        uint256 w500 = manager.computeWeight(LOCK_500M, LOCK_500M, DAYS_365);

        assertGt(w50, w0);
        assertGt(w500, w50);
    }
}
