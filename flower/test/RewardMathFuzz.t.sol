// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IWeightProvider} from "../src/interfaces/IWeightProvider.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RewardTestNFT is ERC721 {
    uint256 internal nextId = 1;
    constructor() ERC721("Reward Test NFT", "RTN") {}
    function mint(address to) external returns (uint256 tokenId) {
        tokenId = nextId++;
        _mint(to, tokenId);
    }
}

contract RewardWeightProvider is IWeightProvider {
    mapping(uint256 => uint256) internal weights;
    uint256 public override totalWeight;

    function setWeight(uint256 tokenId, uint256 newWeight) external {
        uint256 oldWeight = weights[tokenId];
        if (newWeight >= oldWeight) totalWeight += newWeight - oldWeight;
        else totalWeight -= oldWeight - newWeight;
        weights[tokenId] = newWeight;
    }

    function weightOf(uint256 tokenId) external view override returns (uint256) {
        return weights[tokenId];
    }
}

contract FeeRewardToken is ERC20 {
    constructor() ERC20("Fee Reward", "FEE") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value / 100;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, address(0xdead), fee);
    }
}

/// @notice Fuzzes reward distribution over realistic 10-100 NFT batches and skewed weights.
contract RewardMathFuzzTest is Test {
    uint256 internal constant MIN_WEIGHT = 0.25e18;
    uint256 internal constant WEIGHT_SPAN = 6e18;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    MockERC20 internal reward;
    RewardTestNFT internal nft;
    RewardWeightProvider internal provider;
    RewardDistributor internal distributor;

    function setUp() public {
        reward = new MockERC20("USDG", "USDG");
        nft = new RewardTestNFT();
        provider = new RewardWeightProvider();
        distributor = new RewardDistributor(IERC20(address(reward)), nft, provider, address(this));

        for (uint256 i = 0; i < 100; ++i) {
            nft.mint(i % 2 == 0 ? alice : bob);
        }
        reward.mint(address(this), 10_000_000 ether);
        reward.approve(address(distributor), type(uint256).max);
    }

    function testFuzzTenToHundredPositionsRemainSolvent(uint8 rawCount, uint128 rawReward, uint256 seed) public {
        uint256 count = bound(uint256(rawCount), 10, 100);
        uint256 rewardAmount = bound(uint256(rawReward), 1 ether, 1_000_000 ether);

        uint256[] memory aliceIds = new uint256[]((count + 1) / 2);
        uint256[] memory bobIds = new uint256[](count / 2);
        uint256 ai;
        uint256 bi;

        for (uint256 i = 1; i <= count; ++i) {
            uint256 pseudo = uint256(keccak256(abi.encode(seed, i)));
            uint256 positionWeight = MIN_WEIGHT + (pseudo % WEIGHT_SPAN);
            provider.setWeight(i, positionWeight);
            distributor.onWeightChange(i, i % 2 == 1 ? alice : bob, 0, positionWeight);

            if (i % 2 == 1) aliceIds[ai++] = i;
            else bobIds[bi++] = i;
        }

        distributor.fund(rewardAmount);

        uint256 aggregatePending;
        for (uint256 i = 1; i <= count; ++i) aggregatePending += distributor.pending(i);
        assertLe(aggregatePending, rewardAmount);

        vm.prank(alice);
        distributor.claim(aliceIds);
        vm.prank(bob);
        distributor.claim(bobIds);

        uint256 paid = reward.balanceOf(alice) + reward.balanceOf(bob);
        assertEq(paid, distributor.totalClaimed());
        assertLe(paid, rewardAmount);
        assertEq(reward.balanceOf(address(distributor)), rewardAmount - paid);
        assertEq(distributor.accountedLiability(), rewardAmount - paid);

        // Two stages of integer division can only leave tiny base-unit dust here.
        assertLe(distributor.accountedLiability(), 1_000);
    }

    function testDuplicateTokenIdsCannotDoubleClaim() public {
        provider.setWeight(1, 1e18);
        distributor.onWeightChange(1, alice, 0, 1e18);
        distributor.fund(100 ether);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;

        vm.prank(alice);
        distributor.claim(ids);
        assertEq(reward.balanceOf(alice), 100 ether);
        assertEq(distributor.totalClaimed(), 100 ether);
    }

    function testFeeOnTransferRewardTokenIsRejected() public {
        FeeRewardToken feeToken = new FeeRewardToken();
        RewardWeightProvider feeProvider = new RewardWeightProvider();
        RewardDistributor feeDistributor =
            new RewardDistributor(IERC20(address(feeToken)), nft, feeProvider, address(this));

        feeProvider.setWeight(1, 1e18);
        feeDistributor.onWeightChange(1, alice, 0, 1e18);
        feeToken.mint(address(this), 100 ether);
        feeToken.approve(address(feeDistributor), type(uint256).max);

        vm.expectRevert(RewardDistributor.UnsupportedRewardToken.selector);
        feeDistributor.fund(100 ether);
    }
}
