// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FLOWER} from "../src/FLOWER.sol";
import {FlowerNFT} from "../src/FlowerNFT.sol";
import {ActivationManager} from "../src/ActivationManager.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IFLOWER} from "../src/interfaces/IFLOWER.sol";
import {IActivationTransferHook} from "../src/interfaces/IActivationTransferHook.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";
import {IWeightProvider} from "../src/interfaces/IWeightProvider.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract EconomicEpochTest is Test {
    uint256 internal constant MINT_PRICE = 250 ether;
    uint256 internal constant FLOOR = 50_000_000 ether;
    uint256 internal constant LOCK = 400_000_000 ether;
    uint16 internal constant DAYS_90 = 90;
    uint16 internal constant DAYS_365 = 365;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasury = address(0x7777);

    FLOWER internal flower;
    MockERC20 internal usdg;
    FlowerNFT internal nft;
    ActivationManager internal manager;
    RewardDistributor internal distributor;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG");
        flower = new FLOWER(alice);
        nft = new FlowerNFT(address(this), IERC20(address(usdg)), treasury, MINT_PRICE, "ipfs://flower/");
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
        distributor =
            new RewardDistributor(IERC20(address(usdg)), nft, IWeightProvider(address(manager)), address(manager));

        nft.setActivationHook(IActivationTransferHook(address(manager)));
        manager.setRewardDistributor(IRewardDistributor(address(distributor)));
        manager.enableActivation();

        nft.reserveMint(alice, 2);
        nft.reserveMint(bob, 1);

        vm.prank(alice);
        assertTrue(flower.transfer(bob, 20_000_000_000 ether));

        vm.prank(alice);
        assertTrue(flower.approve(address(manager), type(uint256).max));
        vm.prank(bob);
        assertTrue(flower.approve(address(manager), type(uint256).max));

        usdg.mint(address(this), 100_000 ether);
        assertTrue(usdg.approve(address(distributor), type(uint256).max));
    }

    function testLaunchEpochIsFixedAtOneXAndUpdatesDisabled() public view {
        assertEq(manager.currentEpochId(), 0);
        (uint64 activatedAt, uint64 scaleWad) = manager.economicEpochs(0);
        assertGt(activatedAt, 0);
        assertEq(uint256(scaleWad), 1e18);
        assertFalse(manager.economicScaleUpdatesEnabled());
        assertEq(manager.currentActivationFloor(), FLOOR);
    }

    function testEnablementRequiresThirtyDayNotice() public {
        manager.scheduleEconomicScaleEnablement();

        vm.expectRevert(ActivationManager.EconomicScaleEnablementNotReady.selector);
        manager.enableEconomicScaleUpdates();

        vm.warp(block.timestamp + 30 days);
        manager.enableEconomicScaleUpdates();
        assertTrue(manager.economicScaleUpdatesEnabled());
    }

    function testScaleProposalEnforcesBoundsStepAndTimelock() public {
        _enableScaleUpdates();

        vm.expectRevert(ActivationManager.InvalidEconomicScale.selector);
        manager.proposeEconomicScale(0.04e18);

        vm.expectRevert(ActivationManager.EconomicScaleStepTooLarge.selector);
        manager.proposeEconomicScale(0.70e18);

        manager.proposeEconomicScale(0.75e18);
        vm.expectRevert(ActivationManager.EconomicScaleProposalNotReady.selector);
        manager.executeEconomicScale();

        vm.warp(block.timestamp + 7 days);
        manager.executeEconomicScale();

        assertEq(manager.currentEpochId(), 1);
        (, uint64 scaleWad) = manager.economicEpochs(1);
        assertEq(uint256(scaleWad), 0.75e18);
        assertEq(manager.currentActivationFloor(), 37_500_000 ether);
    }

    function testExistingPositionUnaffectedByNewEpoch() public {
        _activate(alice, 1, LOCK, DAYS_365);
        (,,,, uint256 oldWeight) = manager.positions(1);
        uint256 oldTotal = manager.totalWeight();

        _activateEpoch(0.75e18);

        (,,,, uint256 weightAfter) = manager.positions(1);
        assertEq(manager.positionEpoch(1), 0);
        assertEq(weightAfter, oldWeight);
        assertEq(manager.totalWeight(), oldTotal);
        assertEq(weightAfter, manager.computeWeightAtEpoch(0, LOCK, 0, DAYS_365));
        assertGt(manager.computeWeightAtEpoch(1, LOCK, 0, DAYS_365), weightAfter);
    }

    function testTopUpAndExtensionPreserveOriginalEpoch() public {
        _activate(alice, 1, LOCK, DAYS_90);
        _activateEpoch(0.75e18);

        vm.prank(alice);
        manager.increaseLock(1, 100_000_000 ether);
        assertEq(manager.positionEpoch(1), 0);
        (,,, uint16 durationAfterTopUp, uint256 weightAfterTopUp) = manager.positions(1);
        assertEq(weightAfterTopUp, manager.computeWeightAtEpoch(0, 500_000_000 ether, 0, durationAfterTopUp));

        vm.prank(alice);
        manager.extendDuration(1, DAYS_365);
        assertEq(manager.positionEpoch(1), 0);
        (,,,, uint256 weightAfterExtension) = manager.positions(1);
        assertEq(weightAfterExtension, manager.computeWeightAtEpoch(0, 500_000_000 ether, 0, DAYS_365));
    }

    function testBurnPreservesOriginalEpochAndUsesGatedCurve() public {
        _activate(alice, 1, LOCK, DAYS_365);
        _activateEpoch(0.75e18);

        uint256 burnAmount = 20_000_000 ether;
        vm.prank(alice);
        manager.burnForDevelopment(1, burnAmount);

        assertEq(manager.positionEpoch(1), 0);
        (,,,, uint256 weightAfterBurn) = manager.positions(1);
        assertEq(weightAfterBurn, manager.computeWeightAtEpoch(0, LOCK, burnAmount, DAYS_365));
        assertGt(weightAfterBurn, manager.computeWeightAtEpoch(0, LOCK, 0, DAYS_365));
    }

    function testBuyerReactivationUsesCurrentEpochWhileSellerLockStaysDetached() public {
        _activate(alice, 1, LOCK, DAYS_365);
        _activateEpoch(0.75e18);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(manager.positionEpoch(1), 0);

        (address beneficiary, uint128 detachedAmount, uint64 unlockAt, bool claimed) = manager.detachedLocks(1);
        assertEq(beneficiary, alice);
        assertEq(uint256(detachedAmount), LOCK);
        assertGt(unlockAt, block.timestamp);
        assertFalse(claimed);

        vm.prank(bob);
        manager.activate(1, LOCK, DAYS_365);
        assertEq(manager.positionEpoch(1), 1);
        (,,,, uint256 buyerWeight) = manager.positions(1);
        assertEq(buyerWeight, manager.computeWeightAtEpoch(1, LOCK, 0, DAYS_365));
    }

    function testEpochChangeCannotAlterAccruedRewards() public {
        _activate(alice, 1, LOCK, DAYS_365);
        distributor.fund(1_000 ether);
        uint256 pendingBefore = distributor.pending(1);

        _activateEpoch(0.75e18);

        uint256 pendingAfter = distributor.pending(1);
        assertEq(pendingAfter, pendingBefore);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        distributor.claim(ids);
        assertApproxEqAbs(usdg.balanceOf(alice), 1_000 ether, 2);
    }

    function testPermanentFreezeCancelsProposalAndCannotBeReversed() public {
        _enableScaleUpdates();
        manager.proposeEconomicScale(0.75e18);
        manager.permanentlyDisableEconomicScaleUpdates();

        assertTrue(manager.economicScaleUpdatesPermanentlyDisabled());
        (,, bool exists) = manager.pendingEconomicScale();
        assertFalse(exists);

        vm.expectRevert(ActivationManager.EconomicScaleUpdatesFrozen.selector);
        manager.scheduleEconomicScaleEnablement();

        vm.expectRevert(ActivationManager.EconomicScaleUpdatesFrozen.selector);
        manager.permanentlyDisableEconomicScaleUpdates();
    }

    function testBoundaryScaleWeightQuotesRemainFinite() public {
        uint256 minWeight = _weightAtTemporaryEpoch(0.75e18, 50_000_000 ether, 5_000_000 ether);
        assertGt(minWeight, 0);

        vm.warp(block.timestamp + 30 days);
        manager.proposeEconomicScale(0.9375e18);
        vm.warp(block.timestamp + 7 days);
        manager.executeEconomicScale();
        uint256 weight = manager.computeWeightAtEpoch(2, 1_000_000_000 ether, 100_000_000 ether, DAYS_365);
        assertGt(weight, 0);
        assertLt(weight, 100e18);
    }

    function _enableScaleUpdates() internal {
        manager.scheduleEconomicScaleEnablement();
        vm.warp(block.timestamp + 30 days);
        manager.enableEconomicScaleUpdates();
    }

    function _activateEpoch(uint256 scaleWad) internal {
        _enableScaleUpdates();
        manager.proposeEconomicScale(scaleWad);
        vm.warp(block.timestamp + 7 days);
        manager.executeEconomicScale();
    }

    function _activate(address owner, uint256 tokenId, uint256 lockAmount, uint16 durationDays) internal {
        vm.prank(owner);
        manager.activate(tokenId, lockAmount, durationDays);
    }

    function _weightAtTemporaryEpoch(uint256 scaleWad, uint256 lockAmount, uint256 burnAmount)
        internal
        returns (uint256)
    {
        _activateEpoch(scaleWad);
        return manager.computeWeightAtEpoch(1, lockAmount, burnAmount, DAYS_365);
    }
}
