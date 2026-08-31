// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IActivationTransferHook} from "./interfaces/IActivationTransferHook.sol";
import {IFlowerNFTActivationStatus} from "./interfaces/IFlowerNFTActivationStatus.sol";

/// @title FlowerNFT
/// @notice 7,777-unit FLOWER NFT collection.
/// @dev Public mint is paid directly to the protocol treasury in the quote token.
///      There is intentionally no wallet ownership cap.
contract FlowerNFT is ERC721, Ownable2Step, ReentrancyGuard, IFlowerNFTActivationStatus {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SUPPLY = 7_777;
    uint256 public constant PUBLIC_SUPPLY = 5_555;
    uint256 public constant RESERVED_SUPPLY = 2_222;
    uint256 public constant MAX_MINT_PER_TX = 20;

    IERC20 public immutable QUOTE_TOKEN;
    address public immutable TREASURY;
    uint256 public immutable MINT_PRICE;

    uint256 public publicMinted;
    uint256 public reservedMinted;
    uint256 private _nextTokenId = 1;

    bool public saleActive;
    bool public reserveMintingFinalized;
    bool public metadataFrozen;
    string private _baseTokenUri;
    IActivationTransferHook public override activationHook;

    error SaleClosed();
    error InvalidQuantity();
    error InvalidMintPrice();
    error PublicSupplyExceeded();
    error ReservedSupplyExceeded();
    error ReserveIncomplete();
    error ReserveAlreadyFinalized();
    error ReserveNotFinalized();
    error UnsupportedQuoteToken();
    error MetadataIsFrozen();
    error ActivationHookAlreadySet();
    error ZeroAddress();

    event SaleActiveSet(bool active);
    event BaseURISet(string newBaseURI);
    event MetadataFrozen(string finalBaseURI);
    event ReserveMintingFinalized(uint256 finalReservedSupply);
    event ActivationHookSet(address indexed hook);
    event PublicMint(address indexed buyer, uint256 quantity, uint256 cost, uint256 firstTokenId);
    event ReserveMint(address indexed to, uint256 quantity, uint256 firstTokenId);

    constructor(address initialOwner, IERC20 quoteToken_, address treasury_, uint256 mintPrice_, string memory baseUri_)
        ERC721("FLOWER", "FLOWER-NFT")
        Ownable(initialOwner)
    {
        if (address(quoteToken_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (mintPrice_ == 0) revert InvalidMintPrice();

        QUOTE_TOKEN = quoteToken_;
        TREASURY = treasury_;
        MINT_PRICE = mintPrice_;
        _baseTokenUri = baseUri_;
    }

    function mint(uint256 quantity) external nonReentrant {
        if (!saleActive) revert SaleClosed();
        if (quantity == 0 || quantity > MAX_MINT_PER_TX) revert InvalidQuantity();
        if (publicMinted + quantity > PUBLIC_SUPPLY) revert PublicSupplyExceeded();

        uint256 cost = MINT_PRICE * quantity;
        uint256 firstTokenId = _nextTokenId;
        uint256 treasuryBalanceBefore = QUOTE_TOKEN.balanceOf(TREASURY);

        publicMinted += quantity;
        emit PublicMint(msg.sender, quantity, cost, firstTokenId);

        QUOTE_TOKEN.safeTransferFrom(msg.sender, TREASURY, cost);
        // Exact settlement is intentional: fee-on-transfer quote assets are unsupported.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (QUOTE_TOKEN.balanceOf(TREASURY) - treasuryBalanceBefore != cost) {
            revert UnsupportedQuoteToken();
        }

        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(msg.sender, _nextTokenId++);
        }
    }

    /// @notice Mints from the single 2,222-NFT non-public pool.
    /// @dev The deployment/treasury process decides how this pool is split between
    ///      team and protocol reserve. All 2,222 must be allocated before public sale.
    function reserveMint(address to, uint256 quantity) external nonReentrant onlyOwner {
        if (reserveMintingFinalized) revert ReserveAlreadyFinalized();
        if (to == address(0)) revert ZeroAddress();
        if (quantity == 0 || reservedMinted + quantity > RESERVED_SUPPLY) {
            revert ReservedSupplyExceeded();
        }

        uint256 firstTokenId = _nextTokenId;
        reservedMinted += quantity;
        emit ReserveMint(to, quantity, firstTokenId);

        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(to, _nextTokenId++);
        }
    }

    /// @notice Permanently closes the non-public mint allocation.
    /// @dev The full 2,222 reserve must already be allocated, preserving the declared
    ///      7,777 maximum collection size before public buyers enter.
    function finalizeReserveMinting() external onlyOwner {
        if (reserveMintingFinalized) revert ReserveAlreadyFinalized();
        if (reservedMinted != RESERVED_SUPPLY) revert ReserveIncomplete();
        reserveMintingFinalized = true;
        emit ReserveMintingFinalized(reservedMinted);
    }

    function setSaleActive(bool active) external onlyOwner {
        if (active && !reserveMintingFinalized) revert ReserveNotFinalized();
        saleActive = active;
        emit SaleActiveSet(active);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        _baseTokenUri = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    /// @notice Permanently freezes metadata URI mutation.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        metadataFrozen = true;
        emit MetadataFrozen(_baseTokenUri);
    }

    /// @notice One-time installation of the activation transfer hook.
    function setActivationHook(IActivationTransferHook hook) external onlyOwner {
        if (address(activationHook) != address(0)) revert ActivationHookAlreadySet();
        if (address(hook) == address(0)) revert ZeroAddress();
        activationHook = hook;
        emit ActivationHookSet(address(hook));
    }

    function totalMinted() external view returns (uint256) {
        return publicMinted + reservedMinted;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenUri;
    }

    /// @dev OpenZeppelin 5.x transfer hook. A true ownership change resets temporary
    ///      activation. A self-transfer does not detach an otherwise valid lock.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);

        if (from != address(0) && to != address(0) && from != to && address(activationHook) != address(0)) {
            activationHook.onNftTransfer(tokenId, from, to);
        }
    }
}
