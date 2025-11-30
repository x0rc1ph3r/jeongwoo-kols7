// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title KOLSBadgeMarketplace
 * @notice KOLS Participation Badge Marketplace (Configurable NFT / USDT)
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender)
        external
        view
        returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount)
        external
        returns (bool);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator)
        external
        view
        returns (bool);
}

abstract contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed prev, address indexed next);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract KOLSBadgeMarketplace is Ownable, ReentrancyGuard {

    IERC721 public badgeNft;
    IERC20 public usdt;

    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }

    struct Bundle {
        address seller;
        uint256 price;
        uint256[] tokenIds;
        bool active;
    }

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Bundle)  public bundles;

    uint16  public feeBps = 200;
    address public feeRecipient;
    uint256 public nextBundleId = 1;

    event FeeBpsUpdated(uint16 prev, uint16 next);
    event FeeRecipientUpdated(address prev, address next);
    event NftAddressUpdated(address prev, address next);
    event UsdtAddressUpdated(address prev, address next);

    event Listed(address indexed seller, uint256 indexed tokenId, uint256 price);
    event Purchased(address indexed buyer, uint256 indexed tokenId, uint256 price);
    event Cancelled(uint256 indexed tokenId);

    event BundleListed(uint256 indexed id, address indexed seller, uint256[] tokenIds, uint256 price);
    event BundlePurchased(uint256 indexed id, address indexed buyer, uint256 price);
    event BundleCancelled(uint256 indexed id);

    constructor() {
        feeRecipient = msg.sender;
    }

    // ----------------- ADMIN CONFIG -----------------

    function setNftAddress(address nft) external onlyOwner {
        require(nft != address(0), "zero");
        emit NftAddressUpdated(address(badgeNft), nft);
        badgeNft = IERC721(nft);
    }

    function setUsdtAddress(address token) external onlyOwner {
        require(token != address(0), "zero");
        emit UsdtAddressUpdated(address(usdt), token);
        usdt = IERC20(token);
    }

    function setFeeBps(uint16 newFee) external onlyOwner {
        require(newFee <= 2000, "fee too high");
        emit FeeBpsUpdated(feeBps, newFee);
        feeBps = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "zero");
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    // ----------------- INTERNAL FEE -----------------

   function _processFee(
    address payer,
    uint256 price,
    bool,
    uint256
) internal returns (uint256 sellerAmount) {

    uint256 feeAmount = (price * feeBps) / 10000;
    sellerAmount = price - feeAmount;

    if (feeAmount > 0) {
        require(usdt.transferFrom(payer, feeRecipient, feeAmount), "fee tx fail");
    }
}
    // ----------------- SINGLE LIST -----------------

    function listBadge(uint256 tokenId, uint256 price) external nonReentrant {
        require(price > 0, "zero price");
        require(badgeNft.ownerOf(tokenId) == msg.sender, "not owner");

        require(
            badgeNft.getApproved(tokenId) == address(this) ||
            badgeNft.isApprovedForAll(msg.sender, address(this)),
            "not approved"
        );

        badgeNft.transferFrom(msg.sender, address(this), tokenId);

        listings[tokenId] = Listing(msg.sender, price, true);

        emit Listed(msg.sender, tokenId, price);
    }

    function cancelListing(uint256 tokenId) external nonReentrant {
        Listing memory lst = listings[tokenId];
        require(lst.active, "not active");
        require(msg.sender == lst.seller || msg.sender == owner, "not allowed");

        badgeNft.transferFrom(address(this), lst.seller, tokenId);
        delete listings[tokenId];

        emit Cancelled(tokenId);
    }

    function buyBadge(uint256 tokenId) external nonReentrant {
        Listing memory lst = listings[tokenId];
        require(lst.active, "not active");

        address seller = lst.seller;
        address buyer  = msg.sender;
        uint256 price  = lst.price;

        require(buyer != seller, "self buy");
        require(usdt.allowance(buyer, address(this)) >= price, "allowance");
        require(usdt.balanceOf(buyer) >= price, "balance");

        uint256 sellerAmount = _processFee(buyer, price, false, tokenId);

        require(usdt.transferFrom(buyer, seller, sellerAmount), "seller tx");
        badgeNft.transferFrom(address(this), buyer, tokenId);

        delete listings[tokenId];

        emit Purchased(buyer, tokenId, price);
    }

    // ----------------- BUNDLE LIST -----------------

    function listBundle(uint256[] calldata tokenIds, uint256 price)
        external
        nonReentrant
    {
        require(price > 0, "zero price");
        require(tokenIds.length > 1, "need >=2");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(badgeNft.ownerOf(tokenIds[i]) == msg.sender, "not owner");
            require(
                badgeNft.getApproved(tokenIds[i]) == address(this) ||
                badgeNft.isApprovedForAll(msg.sender, address(this)),
                "not approved"
            );

            badgeNft.transferFrom(msg.sender, address(this), tokenIds[i]);
        }

        uint256 id = nextBundleId++;
        bundles[id] = Bundle(msg.sender, price, tokenIds, true);

        emit BundleListed(id, msg.sender, tokenIds, price);
    }

    function cancelBundle(uint256 id) external nonReentrant {
        Bundle memory b = bundles[id];
        require(b.active, "not active");
        require(msg.sender == b.seller || msg.sender == owner, "not allowed");

        for (uint256 i = 0; i < b.tokenIds.length; i++) {
            badgeNft.transferFrom(address(this), b.seller, b.tokenIds[i]);
        }

        delete bundles[id];
        emit BundleCancelled(id);
    }

    function buyBundle(uint256 id) external nonReentrant {
        Bundle memory b = bundles[id];
        require(b.active, "not active");

        address seller = b.seller;
        address buyer  = msg.sender;
        uint256 price  = b.price;

        require(buyer != seller, "self buy");
        require(usdt.allowance(buyer, address(this)) >= price, "allowance");
        require(usdt.balanceOf(buyer) >= price, "balance");

        uint256 sellerAmount = _processFee(buyer, price, true, id);

        require(usdt.transferFrom(buyer, seller, sellerAmount), "seller tx");

        for (uint256 i = 0; i < b.tokenIds.length; i++) {
            badgeNft.transferFrom(address(this), buyer, b.tokenIds[i]);
        }

        delete bundles[id];

        emit BundlePurchased(id, buyer, price);
    }
}