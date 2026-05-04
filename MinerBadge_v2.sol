// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBaseMiner {
    function miners(address player) external view returns (uint256 totalMined, uint256 clicks, uint8 tool);
    function isOnLeaderboard(address player) external view returns (bool);
    function wasSeeded(address player) external view returns (bool); // M-3
}

/**
 * @title MinerBadge
 * @notice ERC-721 NFT awarded to BaseMiner players based on bBALL milestones.
 *
 * Tiers (based on totalMined at time of claim):
 *   GOD       — totalMined >= 95,000 AND clicks >= 10,000. Distinct from Legendary:
 *               the clicks gate rewards sustained engagement over raw score alone.
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
 *
 * Audit fixes applied:
 *   H-01  Mint caps removed from all tiers — any player reaching the threshold
 *         may claim regardless of how many others have already done so.
 *   H-02  claimRare() no longer requires !isOnLeaderboard. Leaderboard members
 *         can claim all tiers independently.
 *   H-03  Constructor rejects address(0) for the game argument.
 *   L-02  safeTransferFrom now calls _checkOnERC721Received so badges sent to
 *         non-receiver contracts revert rather than being permanently locked.
 *   L-03  tokenURI uses single-quoted SVG attributes (valid XML) and
 *         charset=utf-8 in the data URI, fixing malformed output.
 *   L-08  _checkOnERC721Received passes address(this) as the operator argument,
 *         matching the EIP-721 specification. Previously msg.sender was passed,
 *         which is the caller of safeTransferFrom, not the NFT contract itself.
 *   M-07  Hex colour strings in the on-chain SVG data URI are percent-encoded
 *         ('%23' instead of '#') so URI parsers do not truncate at the hash
 *         character per RFC 3986.
 *   L-02  SVG embedded in tokenURI is now base64-encoded before being set as the
 *         image field value. This prevents any SVG character (quotes, angle brackets)
 *         from breaking the enclosing JSON and removes dependence on attribute
 *         quoting style for correctness.
 *   I-02  owner field removed — it was set but never read and falsely implied
 *         admin control over the NFT contract. Re-add with two-step transfer if
 *         admin functions (e.g. royalty config) are needed in a future version.
 *   H-2   nonReentrant guard added to all claim functions. Although the
 *         current game address is a view-only interface, a future owner-replaced
 *         game contract could re-enter _claimTier before state is fully written.
 *         The guard costs ~200 gas and eliminates the risk class entirely.
 *
 * v2 changes:
 *   T-01  LEGENDARY_THRESHOLD raised from 95,000 to 80,000 to create a genuine
 *         progression gap between Legendary and God.
 *   T-02  GOD_THRESHOLD kept at 95,000. GOD_MIN_CLICKS = 10,000 added as a
 *         second gate on claimGod(). An honest Excavator player reaches 95,000
 *         bBALL in ~10,556 clicks so the gate never blocks legitimate grinders.
 *         It does exclude accounts whose totalMined was inflated by migration,
 *         an exploit, or a replacement minter without corresponding click activity.
 *         eligibility() updated to reflect both conditions for the God tier.
 */
contract MinerBadge {

    // ── Reentrancy guard (H-2) ────────────────────────────────────────────────

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
    // GOD tier: higher bBALL threshold than Legendary plus a minimum click count.
    // The clicks gate rewards sustained engagement — an honest Excavator player
    // reaches 95,000 bBALL in ~10,556 clicks, comfortably clearing GOD_MIN_CLICKS.
    // Migrated or exploited accounts with inflated totalMined but low clicks are
    // excluded without affecting any legitimate grinder.
    uint256 public constant GOD_THRESHOLD       =  95_000;
    uint256 public constant GOD_MIN_CLICKS      =  10_000;

    // ── State ─────────────────────────────────────────────────────────────────

    IBaseMiner public immutable game;

    // P-01: owner with two-step transfer. Controls pause/unpause independently
    //       of bBALL and BaseMiner so badge claiming can be halted without
    //       affecting token transfers.
    address public owner;
    address public pendingOwner;
    bool    public paused;

    mapping(address => mapping(Tier => bool))    public hasClaimedTier;
    mapping(address => mapping(Tier => uint256)) public tokenOfOwnerByTier;
    mapping(uint256 => Tier)                     public tierOf;

    // L-2: named *Minted (not *Count) to accurately reflect these are
    //      cumulative mint totals, not current holder counts. Badges are
    //      transferable so holder counts would require Transfer-event tracking.
    uint256 public legendaryMinted;
    uint256 public mythicalMinted;
    uint256 public rareMinted;
    uint256 public commonMinted;
    uint256 public godMinted;

    event BadgeClaimed(address indexed player, uint256 tokenId, Tier tier);
    // P-01
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner()     { require(msg.sender == owner, "not owner"); _; }
    modifier whenNotPaused() { require(!paused, "MinerBadge: paused");    _; }

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param game_   Address of the deployed BaseMiner contract.
    /// @param owner_  Initial owner (should be a multisig). Controls pause/unpause.
    constructor(address game_, address owner_) {
        require(game_  != address(0), "zero game address");   // H-03
        require(owner_ != address(0), "zero owner address");
        game    = IBaseMiner(game_);
        owner   = owner_;
        _status = _NOT_ENTERED;                               // H-2
    }

    // ── Ownership (two-step, mirrors bBALL pattern) ───────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        // I-4: supersedes any prior pending transfer; old nominee's
        //      acceptOwnership() will revert. New event signals the change.
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        address previous = owner;
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    // ── Pause (P-01) ─────────────────────────────────────────────────────────

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
    function claimCommon() external nonReentrant whenNotPaused {   // H-2
        _claimTier(Tier.Common);
    }

    /// @notice Claim your Rare badge. Requires 9,800+ bBALL mined.
    function claimRare() external nonReentrant whenNotPaused {     // H-2
        _claimTier(Tier.Rare);
    }

    /// @notice Claim your Mythical badge. Requires 50,000+ bBALL mined.
    function claimMythical() external nonReentrant whenNotPaused { // H-2
        _claimTier(Tier.Mythical);
    }

    /// @notice Claim your Legendary badge. Requires 80,000+ bBALL mined.
    function claimLegendary() external nonReentrant whenNotPaused { // H-2
        _claimTier(Tier.Legendary);
    }

    /// @notice Claim your God badge. Requires 95,000+ bBALL mined AND 10,000+ total clicks.
    ///         The clicks gate distinguishes sustained grinders from migrated/exploited accounts.
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
            // God: bBALL threshold + engagement gate.
            // clicks is already fetched above — no extra external call needed.
            require(totalMined >= GOD_THRESHOLD,  "Mine at least 95,000 bBALL to claim God");
            require(clicks >= GOD_MIN_CLICKS,     "God requires at least 10,000 total clicks");
            // M-3: seeded accounts may have inflated totalMined and clicks without
            //      corresponding organic gameplay. Exclude them from God tier.
            require(!game.wasSeeded(msg.sender),  "God badge not available to seeded accounts");
        }

        uint256 tokenId = _nextTokenId++;
        _ownerOf[tokenId]      = msg.sender;
        _balanceOf[msg.sender] += 1;
        hasClaimedTier[msg.sender][tier]      = true;
        tokenOfOwnerByTier[msg.sender][tier]  = tokenId;
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

    /// @notice Check eligibility for all tiers for any address.
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
        (totalMined, uint256 clicks, ) = game.miners(player);
        commonEligible    = totalMined >= COMMON_THRESHOLD;
        rareEligible      = totalMined >= RARE_THRESHOLD;
        mythicalEligible  = totalMined >= MYTHICAL_THRESHOLD;
        legendaryEligible = totalMined >= LEGENDARY_THRESHOLD;
        // M-3: seeded accounts are excluded from God tier regardless of stats.
        godEligible       = totalMined >= GOD_THRESHOLD && clicks >= GOD_MIN_CLICKS && !game.wasSeeded(player);
        commonClaimed     = hasClaimedTier[player][Tier.Common];
        rareClaimed       = hasClaimedTier[player][Tier.Rare];
        mythicalClaimed   = hasClaimedTier[player][Tier.Mythical];
        legendaryClaimed  = hasClaimedTier[player][Tier.Legendary];
        godClaimed        = hasClaimedTier[player][Tier.God];
    }

    // ── tokenURI (fully on-chain SVG) ─────────────────────────────────────────

    /**
     * @notice Returns a fully on-chain metadata + SVG token URI.
     * L-03: SVG attributes now use single quotes (valid XML/SVG); data URI uses
     *       charset=utf-8; JSON wrapper uses charset=utf-8 media type.
     * M-07: Hex colour strings are percent-encoded ('%23' instead of '#') so
     *       that RFC-3986-compliant URI parsers do not treat '#' as a fragment
     *       separator and truncate the URI prematurely.
     * L-02: The SVG is base64-encoded before being embedded in the JSON image
     *       field. This makes the output robust to any SVG content — angle
     *       brackets, double quotes, special characters — without relying on
     *       careful attribute-quoting or percent-encoding inside the SVG body.
     */
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_ownerOf[tokenId] != address(0), "Token does not exist");
        Tier t = tierOf[tokenId];
        string memory tierName  = t == Tier.God ? "God" : t == Tier.Legendary ? "Legendary" : t == Tier.Mythical ? "Mythical" : t == Tier.Rare ? "Rare" : "Common";
        string memory tierEmoji = t == Tier.God ? unicode"\u2604" : t == Tier.Legendary ? unicode"\u2B50" : t == Tier.Mythical ? unicode"\u1F300" : t == Tier.Rare ? unicode"💎" : unicode"\u26CF";

        // I-2: use string.concat() instead of abi.encodePacked() on multiple
        //      strings to avoid hash-collision ambiguity flagged by static analysers.
        //      Solidity >=0.8.12 supports string.concat natively.
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

        // L-02 / blocker fix: base64-encode the whole JSON envelope so that
        // curly braces, colons, and double-quotes in the JSON body cannot
        // break the data URI or confuse marketplace parsers.
        bytes memory jsonBytes = bytes(string.concat( // I-2
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

    /// @dev Returns a percent-encoded hex colour for use inside a data URI (M-07).
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

    function approve(address to, uint256 tokenId) external {
        address o = _ownerOf[tokenId];
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "Not authorized");
        _approvals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_ownerOf[tokenId] != address(0), "Token does not exist");
        return _approvals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
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
        emit Transfer(from, to, tokenId);
    }

    // L-02: safeTransferFrom invokes ERC-721 receiver hook on contract targets
    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    /// @dev Calls onERC721Received on `to` if it is a contract.
    ///      Reverts if the hook is absent or returns an unexpected selector.
    ///      L-08: operator is address(this) per EIP-721 — the NFT contract itself
    ///      initiates the call, not the EOA/contract that triggered safeTransferFrom.
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal {
        if (to.code.length == 0) return; // EOA — no hook needed
        // L-08: pass address(this) as operator, not msg.sender
        try IERC721Receiver(to).onERC721Received(address(this), from, tokenId, data) returns (bytes4 retval) {
            require(retval == IERC721Receiver.onERC721Received.selector, "ERC721: transfer to non ERC721Receiver");
        } catch {
            revert("ERC721: transfer to non ERC721Receiver");
        }
    }

    // ── ERC-2981 Royalty (I-3) ────────────────────────────────────────────────

    /// @dev Royalty recipient and basis points (e.g. 500 = 5%).
    ///      Set by the owner. Defaults to zero (no royalty) until configured.
    address public royaltyRecipient;
    uint96  public royaltyBps;

    event RoyaltyUpdated(address indexed recipient, uint96 bps);

    /// @notice Set royalty recipient and fee for secondary sales (ERC-2981).
    /// @param recipient  Address that receives royalty payments.
    /// @param bps        Fee in basis points (100 = 1%; max 1000 = 10%).
    function setRoyalty(address recipient, uint96 bps) external onlyOwner {
        require(recipient != address(0), "zero recipient");
        require(bps <= 1000, "royalty too high"); // cap at 10%
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
            interfaceId == 0x2a55205a || // ERC-2981 royalty (I-3)
            interfaceId == 0x01ffc9a7;   // ERC-165
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Base64-encodes raw bytes for use in data URIs (L-02).
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
