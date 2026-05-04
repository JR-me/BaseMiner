// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBaseMiner {
    function miners(address player) external view returns (uint256 totalMined, uint256 clicks, uint8 tool);
    function isOnLeaderboard(address player) external view returns (bool);
    function wasSeeded(address player) external view returns (bool);
}

/**
 * @title MinerBadge
 * @notice ERC-721 NFT awarded to BaseMiner players based on bBALL milestones.
 *
 * Tiers (based on totalMined at time of claim):
 *   GOD       — totalMined >= 95,000 AND clicks >= 10,000. The clicks gate
 *               rewards sustained engagement over raw score alone.
 *   LEGENDARY — totalMined >= 80,000. Open to all qualifying players, no cap.
 *   MYTHICAL  — totalMined >= 50,000. Open to all qualifying players, no cap.
 *   RARE      — totalMined >= 9,800.  Open to all qualifying players, no cap.
 *   COMMON    — totalMined >= 400.    Open to all qualifying players, no cap.
 *
 * Rules:
 *   - Players can claim each tier badge independently as they reach it.
 *   - One badge NFT per tier per wallet (max 5 badges total).
 *   - Claiming a lower tier does NOT prevent claiming a higher tier later.
 *   - No bBALL burn required — reaching the milestone is sufficient.
 *   - No mint caps on any tier — all qualifying players may claim.
 *   - Transferable (standard ERC-721).
 *   - Owner controls pause/unpause for badge claiming independently of bBALL.
 *   - Ownership follows a two-step transfer pattern.
 */
contract MinerBadge {

    // ── Reentrancy guard ─────────────────────────────────────────────────────

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    string public constant name   = "BaseMiner Badge";
    string public constant symbol = "CBADGE";

    uint256 private _nextTokenId = 1;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner_, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner_, address indexed operator, bool approved);

    // ── Tiers ─────────────────────────────────────────────────────────────────

    enum Tier { Common, Rare, Mythical, Legendary, God }

    uint256 public constant COMMON_THRESHOLD    =     400;
    uint256 public constant RARE_THRESHOLD      =   9_800;
    uint256 public constant MYTHICAL_THRESHOLD  =  50_000;
    uint256 public constant LEGENDARY_THRESHOLD =  80_000;

    /// @notice God tier requires both a bBALL threshold and a minimum click count.
    ///         The clicks gate distinguishes sustained grinders from accounts whose
    ///         totalMined was inflated by migration without corresponding gameplay.
    ///         An honest Excavator player reaches 95,000 bBALL in ~10,556 clicks,
    ///         comfortably clearing GOD_MIN_CLICKS.
    uint256 public constant GOD_THRESHOLD  = 95_000;
    uint256 public constant GOD_MIN_CLICKS = 10_000;

    // ── State ─────────────────────────────────────────────────────────────────

    IBaseMiner public immutable game;

    address public owner;
    address public pendingOwner;
    bool    public paused;

    mapping(address => mapping(Tier => bool))    public hasClaimedTier;
    mapping(address => mapping(Tier => uint256)) public tokenOfOwnerByTier;
    mapping(uint256 => Tier)                     public tierOf;

    /// @dev Cumulative mint totals per tier. Not current holder counts — badges
    ///      are transferable so holder counts would require Transfer-event tracking.
    uint256 public legendaryMinted;
    uint256 public mythicalMinted;
    uint256 public rareMinted;
    uint256 public commonMinted;
    uint256 public godMinted;

    event BadgeClaimed(address indexed player, uint256 tokenId, Tier tier);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner()     { require(msg.sender == owner, "not owner");       _; }
    modifier whenNotPaused() { require(!paused, "MinerBadge: paused");          _; }

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param game_   Address of the deployed BaseMiner contract.
    /// @param owner_  Initial owner (should be a multisig). Controls pause/unpause.
    constructor(address game_, address owner_) {
        require(game_  != address(0), "zero game address");
        require(owner_ != address(0), "zero owner address");
        game    = IBaseMiner(game_);
        owner   = owner_;
        _status = _NOT_ENTERED;
    }

    // ── Ownership ────────────────────────────────────────────────────────────

    /// @notice Step 1 — nominate a new owner. No effect until acceptOwnership().
    ///         If a pending transfer is already in progress it is silently
    ///         superseded; the old nominee's acceptOwnership() call will revert.
    ///         A new OwnershipTransferStarted event is emitted so off-chain
    ///         monitors can detect the replacement.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2 — called by the nominated address to complete the transfer.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        address previous = owner;
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    // ── Pause ────────────────────────────────────────────────────────────────

    /// @notice Halt all badge claiming immediately. Transfers are unaffected.
    function pause() external onlyOwner {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume badge claiming after a pause.
    function unpause() external onlyOwner {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ── Claim ─────────────────────────────────────────────────────────────────

    /// @notice Claim your Common badge. Requires 400+ bBALL mined.
    function claimCommon() external nonReentrant whenNotPaused {
        _claimTier(Tier.Common);
    }

    /// @notice Claim your Rare badge. Requires 9,800+ bBALL mined.
    function claimRare() external nonReentrant whenNotPaused {
        _claimTier(Tier.Rare);
    }

    /// @notice Claim your Mythical badge. Requires 50,000+ bBALL mined.
    function claimMythical() external nonReentrant whenNotPaused {
        _claimTier(Tier.Mythical);
    }

    /// @notice Claim your Legendary badge. Requires 80,000+ bBALL mined.
    function claimLegendary() external nonReentrant whenNotPaused {
        _claimTier(Tier.Legendary);
    }

    /// @notice Claim your God badge. Requires 95,000+ bBALL mined AND 10,000+ total clicks.
    ///         Seeded accounts are not eligible for the God tier.
    function claimGod() external nonReentrant whenNotPaused {
        _claimTier(Tier.God);
    }

    function _claimTier(Tier tier) internal {
        require(!hasClaimedTier[msg.sender][tier], "Already claimed this tier");

        (uint256 totalMined, uint256 clicks, ) = game.miners(msg.sender);

        if (tier == Tier.Common) {
            require(totalMined >= COMMON_THRESHOLD,    "Mine at least 400 bBALL to claim Common");
        } else if (tier == Tier.Rare) {
            require(totalMined >= RARE_THRESHOLD,      "Mine at least 9,800 bBALL to claim Rare");
        } else if (tier == Tier.Mythical) {
            require(totalMined >= MYTHICAL_THRESHOLD,  "Mine at least 50,000 bBALL to claim Mythical");
        } else if (tier == Tier.Legendary) {
            require(totalMined >= LEGENDARY_THRESHOLD, "Mine at least 80,000 bBALL to claim Legendary");
        } else {
            require(totalMined >= GOD_THRESHOLD,  "Mine at least 95,000 bBALL to claim God");
            require(clicks >= GOD_MIN_CLICKS,     "God requires at least 10,000 total clicks");
            require(!game.wasSeeded(msg.sender),  "God badge not available to seeded accounts");
        }

        uint256 tokenId = _nextTokenId++;
        _ownerOf[tokenId]      = msg.sender;
        _balanceOf[msg.sender] += 1;
        hasClaimedTier[msg.sender][tier]     = true;
        tokenOfOwnerByTier[msg.sender][tier] = tokenId;
        tierOf[tokenId] = tier;

        if (tier == Tier.God)            godMinted++;
        else if (tier == Tier.Legendary) legendaryMinted++;
        else if (tier == Tier.Mythical)  mythicalMinted++;
        else if (tier == Tier.Rare)      rareMinted++;
        else                             commonMinted++;

        emit Transfer(address(0), msg.sender, tokenId);
        emit BadgeClaimed(msg.sender, tokenId, tier);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// @notice Check eligibility and claim status for all tiers for any address.
    function eligibility(address player) external view
        returns (
            bool commonEligible,
            bool rareEligible,
            bool mythicalEligible,
            bool legendaryEligible,
            bool godEligible,
            bool commonClaimed,
            bool rareClaimed,
            bool mythicalClaimed,
            bool legendaryClaimed,
            bool godClaimed,
            uint256 totalMined
        )
    {
        uint256 clicks;
        uint256 _totalMined;
        (_totalMined, clicks, ) = game.miners(player);
        totalMined = _totalMined;
        commonEligible    = totalMined >= COMMON_THRESHOLD;
        rareEligible      = totalMined >= RARE_THRESHOLD;
        mythicalEligible  = totalMined >= MYTHICAL_THRESHOLD;
        legendaryEligible = totalMined >= LEGENDARY_THRESHOLD;
        godEligible       = totalMined >= GOD_THRESHOLD && clicks >= GOD_MIN_CLICKS && !game.wasSeeded(player);
        commonClaimed     = hasClaimedTier[player][Tier.Common];
        rareClaimed       = hasClaimedTier[player][Tier.Rare];
        mythicalClaimed   = hasClaimedTier[player][Tier.Mythical];
        legendaryClaimed  = hasClaimedTier[player][Tier.Legendary];
        godClaimed        = hasClaimedTier[player][Tier.God];
    }

    // ── tokenURI (fully on-chain SVG) ─────────────────────────────────────────

    /// @notice Returns a fully on-chain metadata + SVG token URI.
    ///         The SVG is base64-encoded before embedding in the JSON image field,
    ///         making the output robust to any SVG content without relying on
    ///         careful attribute-quoting or percent-encoding inside the SVG body.
    ///         Hex colour strings are percent-encoded ('%23' instead of '#') so
    ///         RFC-3986-compliant URI parsers do not treat '#' as a fragment
    ///         separator and truncate the URI prematurely.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_ownerOf[tokenId] != address(0), "Token does not exist");
        Tier t = tierOf[tokenId];
        string memory tierName  = t == Tier.God ? "God" : t == Tier.Legendary ? "Legendary" : t == Tier.Mythical ? "Mythical" : t == Tier.Rare ? "Rare" : "Common";
        string memory tierEmoji = t == Tier.God ? unicode"\u2604" : t == Tier.Legendary ? unicode"\u2B50" : t == Tier.Mythical ? unicode"\u1F300" : t == Tier.Rare ? unicode"💎" : unicode"\u26CF";

        bytes memory svgBytes = bytes(string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 200 200'>",
            "<rect width='200' height='200' fill='", _bgColorEncoded(t), "'/>",
            "<text x='100' y='90' font-size='60' text-anchor='middle' dominant-baseline='middle'>", tierEmoji, "</text>",
            "<text x='100' y='150' font-size='14' fill='%23ffffff' text-anchor='middle' font-family='monospace'>", tierName, "</text>",
            "</svg>"
        ));

        string memory imageUri = string(abi.encodePacked(
            "data:image/svg+xml;base64,",
            _base64Encode(svgBytes)
        ));

        bytes memory jsonBytes = bytes(string.concat(
            '{"name":"BaseMiner Badge #', _toString(tokenId),
            '","description":"Awarded to BaseMiner players for reaching bBALL milestones.",',
            '"attributes":[{"trait_type":"Tier","value":"', tierName,
            '"},{"trait_type":"Token ID","value":"', _toString(tokenId), '"}],',
            '"image":"', imageUri, '"}'
        ));
        return string(abi.encodePacked(
            "data:application/json;base64,",
            _base64Encode(jsonBytes)
        ));
    }

    /// @dev Returns a percent-encoded hex colour for use inside a data URI.
    ///      '#' is replaced with '%23' so RFC-3986 parsers do not treat it as a
    ///      fragment separator and truncate the URI at the first hash character.
    function _bgColorEncoded(Tier t) internal pure returns (string memory) {
        if (t == Tier.God)       return "%23FFD700"; // gold
        if (t == Tier.Legendary) return "%234a1a6b"; // deep purple
        if (t == Tier.Mythical)  return "%23800020"; // crimson
        if (t == Tier.Rare)      return "%230a3a5c"; // deep blue
        return "%231a4a2a";                           // dark green (Common)
    }

    // ── ERC-721 standard ──────────────────────────────────────────────────────

    function balanceOf(address owner_) external view returns (uint256) {
        require(owner_ != address(0), "Zero address");
        return _balanceOf[owner_];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        require(o != address(0), "Token does not exist");
        return o;
    }

    function approve(address to, uint256 tokenId) external whenNotPaused {
        address o = _ownerOf[tokenId];
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "Not authorized");
        _approvals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_ownerOf[tokenId] != address(0), "Token does not exist");
        return _approvals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external whenNotPaused {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_ownerOf[tokenId] == from,                                "Wrong owner");
        require(to != address(0),                                          "Zero address");
        require(
            msg.sender == from ||
            _approvals[tokenId] == msg.sender ||
            _operatorApprovals[from][msg.sender],                          "Not authorized"
        );
        _ownerOf[tokenId]  = to;
        _balanceOf[from]  -= 1;
        _balanceOf[to]    += 1;
        delete _approvals[tokenId];
        // Keep tokenOfOwnerByTier in sync with ownership.
        // hasClaimedTier is intentionally NOT updated — the original claimer keeps
        // their claim flag so they cannot double-claim after transferring a badge away.
        Tier t = tierOf[tokenId];
        if (tokenOfOwnerByTier[from][t] == tokenId) {
            delete tokenOfOwnerByTier[from][t];
        }
        tokenOfOwnerByTier[to][t] = tokenId;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    /// @dev Calls onERC721Received on `to` if it is a contract.
    ///      Reverts if the hook is absent or returns an unexpected selector.
    ///      Passes address(this) as operator per EIP-721 — the NFT contract itself
    ///      initiates the call, not the EOA/contract that triggered safeTransferFrom.
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal {
        if (to.code.length == 0) return; // EOA — no hook needed
        try IERC721Receiver(to).onERC721Received(address(this), from, tokenId, data) returns (bytes4 retval) {
            require(retval == IERC721Receiver.onERC721Received.selector, "ERC721: transfer to non ERC721Receiver");
        } catch {
            revert("ERC721: transfer to non ERC721Receiver");
        }
    }

    // ── ERC-2981 Royalty ─────────────────────────────────────────────────────

    /// @dev Royalty recipient and basis points (e.g. 500 = 5%).
    ///      Defaults to zero (no royalty) until configured by the owner.
    address public royaltyRecipient;
    uint96  public royaltyBps;

    event RoyaltyUpdated(address indexed recipient, uint96 bps);

    /// @notice Set royalty recipient and fee for secondary sales (ERC-2981).
    /// @param recipient  Address that receives royalty payments.
    /// @param bps        Fee in basis points (100 = 1%; max 1000 = 10%).
    function setRoyalty(address recipient, uint96 bps) external onlyOwner {
        require(recipient != address(0), "zero recipient");
        require(bps <= 1000, "royalty too high");
        royaltyRecipient = recipient;
        royaltyBps       = bps;
        emit RoyaltyUpdated(recipient, bps);
    }

    /// @notice ERC-2981 royalty query. Returns (recipient, royaltyAmount).
    function royaltyInfo(uint256 /*tokenId*/, uint256 salePrice)
        external view returns (address, uint256)
    {
        return (royaltyRecipient, (salePrice * royaltyBps) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x80ac58cd || // ERC-721
            interfaceId == 0x5b5e139f || // ERC-721Metadata
            interfaceId == 0x2a55205a || // ERC-2981 royalty
            interfaceId == 0x01ffc9a7;   // ERC-165
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Base64-encodes raw bytes for use in data URIs.
    ///      Implements RFC 4648 §4 standard alphabet with '=' padding.
    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        string memory TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        bytes memory tableBytes = bytes(TABLE);
        uint256 i = 0;
        uint256 j = 0;
        for (; i + 3 <= data.length; i += 3) {
            uint256 a = uint8(data[i]);
            uint256 b = uint8(data[i + 1]);
            uint256 c = uint8(data[i + 2]);
            result[j++] = tableBytes[(a >> 2) & 0x3F];
            result[j++] = tableBytes[((a & 3) << 4) | (b >> 4)];
            result[j++] = tableBytes[((b & 0xF) << 2) | (c >> 6)];
            result[j++] = tableBytes[c & 0x3F];
        }
        if (data.length - i == 2) {
            uint256 a = uint8(data[i]);
            uint256 b = uint8(data[i + 1]);
            result[j++] = tableBytes[(a >> 2) & 0x3F];
            result[j++] = tableBytes[((a & 3) << 4) | (b >> 4)];
            result[j++] = tableBytes[(b & 0xF) << 2];
            result[j++] = "=";
        } else if (data.length - i == 1) {
            uint256 a = uint8(data[i]);
            result[j++] = tableBytes[(a >> 2) & 0x3F];
            result[j++] = tableBytes[(a & 3) << 4];
            result[j++] = "=";
            result[j++] = "=";
        }
        return string(result);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

// ── Minimal ERC-721 receiver interface ───────────────────────────────────────

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}
