// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IWeightProvider} from "./interfaces/IWeightProvider.sol";

/// @title RewardDistributor
/// @notice Cumulative reward-per-weight distributor for one ERC-20 reward asset.
/// @dev Deploy one instance per reward asset if the protocol pays multiple assets.
///      The base deployment can use USDG and fund it from the 45% NFT reward waterfall.
contract RewardDistributor is IRewardDistributor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;

    IERC20 public immutable rewardToken;
    IERC721 public immutable nft;
    IWeightProvider public immutable weightProvider;
    address public immutable activationManager;

    uint256 public accRewardPerWeight;
    uint256 public totalFunded;
    uint256 public totalClaimed;

    mapping(uint256 tokenId => uint256 accPaid) public tokenAccPaid;
    mapping(address beneficiary => uint256 amount) public claimable;

    error NotActivationManager();
    error NoActiveWeight();
    error InvalidAmount();
    error NotNFTOwner();

    event RewardsFunded(address indexed funder, uint256 amount, uint256 totalWeight, uint256 newAccumulator);
    event TokenCheckpointed(uint256 indexed tokenId, address indexed beneficiary, uint256 weight, uint256 accrued);
    event Claimed(address indexed beneficiary, uint256 amount);

    constructor(
        IERC20 rewardToken_,
        IERC721 nft_,
        IWeightProvider weightProvider_,
        address activationManager_
    ) {
        rewardToken = rewardToken_;
        nft = nft_;
        weightProvider = weightProvider_;
        activationManager = activationManager_;
    }

    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 networkWeight = weightProvider.totalWeight();
        if (networkWeight == 0) revert NoActiveWeight();

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        accRewardPerWeight += (amount * WAD) / networkWeight;
        totalFunded += amount;

        emit RewardsFunded(msg.sender, amount, networkWeight, accRewardPerWeight);
    }

    function onWeightChange(
        uint256 tokenId,
        address beneficiary,
        uint256 oldWeight,
        uint256
    ) external override {
        if (msg.sender != activationManager) revert NotActivationManager();
        _settle(tokenId, beneficiary, oldWeight);
        tokenAccPaid[tokenId] = accRewardPerWeight;
    }

    function claim(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (nft.ownerOf(tokenId) != msg.sender) revert NotNFTOwner();

            uint256 currentWeight = weightProvider.weightOf(tokenId);
            _settle(tokenId, msg.sender, currentWeight);
            tokenAccPaid[tokenId] = accRewardPerWeight;
        }

        _pay(msg.sender);
    }

    function claimCredits() external nonReentrant {
        _pay(msg.sender);
    }

    function pending(uint256 tokenId) external view returns (uint256) {
        uint256 currentWeight = weightProvider.weightOf(tokenId);
        uint256 delta = accRewardPerWeight - tokenAccPaid[tokenId];
        return (currentWeight * delta) / WAD;
    }

    function _settle(uint256 tokenId, address beneficiary, uint256 weight) internal {
        uint256 delta = accRewardPerWeight - tokenAccPaid[tokenId];
        uint256 accrued = (weight * delta) / WAD;
        if (accrued != 0) {
            claimable[beneficiary] += accrued;
        }
        emit TokenCheckpointed(tokenId, beneficiary, weight, accrued);
    }

    function _pay(address beneficiary) internal {
        uint256 amount = claimable[beneficiary];
        if (amount == 0) return;

        claimable[beneficiary] = 0;
        totalClaimed += amount;
        rewardToken.safeTransfer(beneficiary, amount);

        emit Claimed(beneficiary, amount);
    }
}
