// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    uint256 public constant MAX_CLAIM_BATCH = 100;

    IERC20 public immutable REWARD_TOKEN;
    IERC721 public immutable NFT;
    IWeightProvider public immutable WEIGHT_PROVIDER;
    address public immutable ACTIVATION_MANAGER;

    uint256 public accRewardPerWeight;
    uint256 public totalFunded;
    uint256 public totalClaimed;

    mapping(uint256 tokenId => uint256 accPaid) public tokenAccPaid;
    mapping(address beneficiary => uint256 amount) public claimable;

    error NotActivationManager();
    error NoActiveWeight();
    error InvalidAmount();
    error NotNFTOwner();
    error ZeroAddress();
    error InvalidContract();
    error UnsupportedRewardToken();
    error ClaimBatchTooLarge();

    event RewardsFunded(address indexed funder, uint256 amount, uint256 totalWeight, uint256 newAccumulator);
    event TokenCheckpointed(uint256 indexed tokenId, address indexed beneficiary, uint256 weight, uint256 accrued);
    event Claimed(address indexed beneficiary, uint256 amount);

    constructor(
        IERC20 rewardToken_,
        IERC721 nft_,
        IWeightProvider weightProvider_,
        address activationManager_
    ) {
        if (
            address(rewardToken_) == address(0) || address(nft_) == address(0)
                || address(weightProvider_) == address(0) || activationManager_ == address(0)
        ) revert ZeroAddress();
        if (
            address(rewardToken_).code.length == 0 || address(nft_).code.length == 0
                || address(weightProvider_).code.length == 0 || activationManager_.code.length == 0
        ) revert InvalidContract();

        REWARD_TOKEN = rewardToken_;
        NFT = nft_;
        WEIGHT_PROVIDER = weightProvider_;
        ACTIVATION_MANAGER = activationManager_;
    }

    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 networkWeight = WEIGHT_PROVIDER.totalWeight();
        if (networkWeight == 0) revert NoActiveWeight();

        uint256 balanceBefore = REWARD_TOKEN.balanceOf(address(this));
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = REWARD_TOKEN.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert UnsupportedRewardToken();

        accRewardPerWeight += Math.mulDiv(amount, WAD, networkWeight);
        totalFunded += amount;

        emit RewardsFunded(msg.sender, amount, networkWeight, accRewardPerWeight);
    }

    function onWeightChange(
        uint256 tokenId,
        address beneficiary,
        uint256 oldWeight,
        uint256
    ) external override {
        if (msg.sender != ACTIVATION_MANAGER) revert NotActivationManager();
        _settle(tokenId, beneficiary, oldWeight);
        tokenAccPaid[tokenId] = accRewardPerWeight;
    }

    function claim(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length > MAX_CLAIM_BATCH) revert ClaimBatchTooLarge();

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (NFT.ownerOf(tokenId) != msg.sender) revert NotNFTOwner();

            uint256 currentWeight = WEIGHT_PROVIDER.weightOf(tokenId);
            _settle(tokenId, msg.sender, currentWeight);
            tokenAccPaid[tokenId] = accRewardPerWeight;
        }

        _pay(msg.sender);
    }

    function claimCredits() external nonReentrant {
        _pay(msg.sender);
    }

    function pending(uint256 tokenId) external view returns (uint256) {
        uint256 currentWeight = WEIGHT_PROVIDER.weightOf(tokenId);
        uint256 delta = accRewardPerWeight - tokenAccPaid[tokenId];
        return Math.mulDiv(currentWeight, delta, WAD);
    }

    /// @notice Amount of funded reward tokens not yet paid out.
    /// @dev Includes any harmless integer-division dust that remains in the distributor.
    function accountedLiability() external view returns (uint256) {
        return totalFunded - totalClaimed;
    }

    function _settle(uint256 tokenId, address beneficiary, uint256 weight) internal {
        uint256 delta = accRewardPerWeight - tokenAccPaid[tokenId];
        uint256 accrued = Math.mulDiv(weight, delta, WAD);
        if (accrued != 0) claimable[beneficiary] += accrued;
        emit TokenCheckpointed(tokenId, beneficiary, weight, accrued);
    }

    function _pay(address beneficiary) internal {
        uint256 amount = claimable[beneficiary];
        if (amount == 0) return;

        claimable[beneficiary] = 0;
        totalClaimed += amount;
        emit Claimed(beneficiary, amount);

        REWARD_TOKEN.safeTransfer(beneficiary, amount);
    }
}
