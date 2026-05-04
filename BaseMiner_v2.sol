// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IbBALL {
    function mint(address to, uint256 amount) external;
}

/**
 * @title BaseMiner
 * @notice On-chain idle clicker game on Base mainnet.
 *
 * Audit fixes applied:
 *   M-03  _checkUpgrade() no longer emits Upgraded; upgrade() emits it once
 *         after confirming a transition occurred. mine() calls _checkUpgrade
 *         and then emits Upgraded itself if the tool changed — one event per
 *         transition, no duplicates.
 *   M-04  LeaderboardEvicted event emitted when a player is displaced from
 *         the last leaderboard slot.
 *   H-03  Constructor rejects address(0) for the token argument so an accidental
 *         zero-address deployment is caught at deploy time rather than silently
 *         bricking the contract.
 *   H-04  Simple reentrancy guard (nonReentrant modifier) added to mine() so
 *         that any future wrapper or token hook cannot re-enter the leaderboard
 *         update while state is mid-write.
 *   L-06  mine() reverts with "Nothing left to mine" when effectiveYield would
 *         be zero, saving the caller wasted gas and keeping event logs clean.
 *   M-06  MAX_LB is treated as an invariant: documented here and enforced by
 *         the fixed-size leaderboard array management. Any increase to MAX_LB
 *         should be accompanied by gas profiling of _updateLeaderboard.
 *   C-01  _checkUpgrade() and the Upgraded event are now emitted AFTER
 *         m.totalMined is updated, so upgrade thresholds are evaluated against
 *         the post-yield balance. Previously the upgrade check fired before
 *         totalMined was incremented, causing the Upgraded event to reference
 *         stale state and confusing indexers.
 *   H-01  Strict CEI order restored in mine(): all state writes (totalMined,
 *         totalMinted, clicks, leaderboard) complete before the external
 *         token.mint() call, eliminating a cross-contract state-observation
 *         window even though nonReentrant already prevents re-entry into mine().
 *   L-03  onLeaderboard mapping added alongside the leaderboard array so that
 *         isOnLeaderboard() is O(1) rather than O(n). The array scan inside
 *         _updateLeaderboard is retained (necessary for position lookup) but
 *         all external callers (MinerBadge) now use the mapping.
 *   M-01  Tie-breaking behaviour documented: players with equal totalMined to
 *         the current last-place holder do not displace them (strict less-than
 *         comparison). This is a deliberate first-mover advantage rule.
 *   I-01  owner field removed — it was set but never read and implied admin
 *         powers that do not exist. If admin functions are added in a future
 *         version they should use the two-step pattern from bBALL.
 *   P-01  Emergency pause added. A dedicated owner (set in constructor, two-step
 *         transfer) can call pause() to halt mine() and upgrade() instantly.
 *         unpause() resumes play. Owner is stored separately from bBALL's owner
 *         so each contract can be paused independently during an incident.
 */
contract BaseMiner {

    // ── Types ────────────────────────────────────────────────────────────────

    enum Tool { Pickaxe, Drill, Excavator }

    struct Miner {
        uint256 totalMined;
        uint256 clicks;
        Tool    tool;
    }

    // ── Reentrancy guard (H-04) ──────────────────────────────────────────────

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ── State ────────────────────────────────────────────────────────────────

    IbBALL  public immutable token;

    // P-01: owner with two-step transfer (mirrors bBALL pattern).
    //       Stored here so BaseMiner can be paused independently of bBALL.
    address public owner;
    address public pendingOwner;
    bool    public paused;

    // Migration: owner can seed player state until lockMigration() is called.
    bool    public migrationLocked;
    // M-1: auto-expiry block for the migration window. seedPlayer() and
    //      seedPlayerBatch() revert after this block even if lockMigration()
    //      was never called. Set to deploy block + 50,000 (~27 hrs on Base).
    uint256 public immutable migrationDeadline;

    mapping(address => Miner) public miners;

    address[] public leaderboard;
    // L-03: O(1) membership test used by isOnLeaderboard() and MinerBadge.
    //       Kept in sync with the leaderboard array by _updateLeaderboard().
    mapping(address => bool) public onLeaderboard;

    /// @dev M-06: MAX_LB is a gas-invariant. Increasing it raises _updateLeaderboard
    ///      worst-case from O(MAX_LB) to O(MAX_LB²) per mine() call. Raised to 25
    ///      to support the GOD badge tier which requires a top-25 leaderboard position.
    ///      At 25 entries the worst-case sort is 25 swaps per mine() call — acceptable.
    uint256   public constant MAX_LB = 25;

    uint256 public constant MAX_BBALL_GLOBAL  = 100_940_000;
    uint256 public constant MAX_BBALL_PER_USER =    98_000;

    uint256 public totalMinted;

    uint256 public constant DRILL_THRESHOLD     = 100;
    uint256 public constant EXCAVATOR_THRESHOLD = 400;

    uint256 public constant PICKAXE_YIELD   = 1;
    uint256 public constant DRILL_YIELD     = 3;
    uint256 public constant EXCAVATOR_YIELD = 9;

    // ── Events ───────────────────────────────────────────────────────────────

    event Mined(address indexed player, uint256 bBALLEarned, uint256 totalMined, Tool tool);
    event Upgraded(address indexed player, Tool newTool);
    event LeaderboardUpdated(address indexed player, uint256 totalMined);
    event LeaderboardEvicted(address indexed player);  // M-04
    // P-01
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    // Migration
    event PlayerSeeded(address indexed player, uint256 totalMined, Tool tool);
    event MigrationLocked();

    modifier onlyOwner()     { require(msg.sender == owner, "not owner"); _; }
    modifier whenNotPaused() { require(!paused, "BaseMiner: paused");     _; }

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @param token_  Address of the deployed bBALL token contract.
    /// @param owner_  Initial owner (should be a multisig). Controls pause/unpause
    ///                and ownership transfer for this contract independently of bBALL.
    constructor(address token_, address owner_) {
        require(token_ != address(0), "zero token address");  // H-03
        require(owner_ != address(0), "zero owner address");
        token   = IbBALL(token_);
        owner   = owner_;
        _status = _NOT_ENTERED;                               // H-04
        migrationDeadline = block.number + 50_000;           // M-1: ~27 hrs on Base
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

    /// @notice Halt mine() and upgrade() immediately. Call when a bug is detected.
    function pause() external onlyOwner {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume gameplay after a pause.
    function unpause() external onlyOwner {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ── Migration ────────────────────────────────────────────────────────────

    // M-3: track addresses that were seeded so claimGod() can exclude them
    //      from the God badge unless they have also earned clicks organically.
    mapping(address => bool) public wasSeeded;

    /// @notice Seed a single player's state from the old contract snapshot.
    ///         Owner-only. Only callable before lockMigration() is called
    ///         and before migrationDeadline. // M-1
    ///         Writes totalMined, clicks, tool — then increments totalMinted
    ///         and slots the player into the leaderboard exactly as mine() would.
    ///         Re-seeding the same address overwrites the previous values;
    ///         totalMinted is adjusted by the delta so the global counter stays correct.
    function seedPlayer(
        address player,
        uint256 totalMined_,
        uint256 clicks_,
        Tool    tool_
    ) external onlyOwner {
        require(!migrationLocked,              "Migration locked");
        require(block.number <= migrationDeadline, "Migration window expired"); // M-1
        require(player != address(0),          "zero address");
        require(totalMined_ <= MAX_BBALL_PER_USER, "exceeds per-user cap");

        Miner storage m = miners[player];

        // Adjust global counter for re-seeds (idempotent if values are unchanged)
        if (totalMinted >= m.totalMined) {
            totalMinted = totalMinted - m.totalMined + totalMined_;
        } else {
            totalMinted += totalMined_;
        }
        require(totalMinted <= MAX_BBALL_GLOBAL, "exceeds global cap");

        m.totalMined = totalMined_;
        m.clicks     = clicks_;
        m.tool       = tool_;
        wasSeeded[player] = true; // M-3: flag for God badge eligibility check

        // M-4: if the re-seed lowered totalMined, remove and re-insert so the
        //      leaderboard sort invariant is not broken by a stale position.
        if (totalMined_ > 0) {
            if (onLeaderboard[player]) {
                _removeFromLeaderboard(player);
            }
            _updateLeaderboard(player, totalMined_);
        }
        emit PlayerSeeded(player, totalMined_, tool_);
    }

    /// @notice Batch version of seedPlayer — seeds up to 100 players per call
    ///         to stay within block gas limits. Arrays must be equal length.
    function seedPlayerBatch(
        address[] calldata players,
        uint256[] calldata totalMineds,
        uint256[] calldata clicksArr,
        uint8[]   calldata tools
    ) external onlyOwner {
        require(!migrationLocked, "Migration locked");
        require(block.number <= migrationDeadline, "Migration window expired"); // M-1
        uint256 len = players.length;
        require(len == totalMineds.length && len == clicksArr.length && len == tools.length,
            "Array length mismatch");
        require(len <= 100, "Max 100 per batch");
        for (uint256 i = 0; i < len; i++) {
            address player   = players[i];
            uint256 mined    = totalMineds[i];
            uint256 clicks_  = clicksArr[i];
            Tool    tool_    = Tool(tools[i]);
            require(player != address(0), "zero address in batch");
            require(mined <= MAX_BBALL_PER_USER, "exceeds per-user cap");
            Miner storage m  = miners[player];
            if (totalMinted >= m.totalMined) {
                totalMinted = totalMinted - m.totalMined + mined;
            } else {
                totalMinted += mined;
            }
            require(totalMinted <= MAX_BBALL_GLOBAL, "exceeds global cap");
            m.totalMined = mined;
            m.clicks     = clicks_;
            m.tool       = tool_;
            wasSeeded[player] = true; // M-3
            // M-4: remove and re-insert to maintain sort invariant on re-seed
            if (mined > 0) {
                if (onLeaderboard[player]) {
                    _removeFromLeaderboard(player);
                }
                _updateLeaderboard(player, mined);
            }
            emit PlayerSeeded(player, mined, tool_);
        }
    }

    /// @notice Permanently close the migration window.
    ///         Once called, seedPlayer() and seedPlayerBatch() revert forever.
    function lockMigration() external onlyOwner {
        require(!migrationLocked, "Already locked");
        migrationLocked = true;
        emit MigrationLocked();
    }

    // ── Core gameplay ────────────────────────────────────────────────────────

    /// @notice Mine bBALL. Each call = one mine = one transaction.
    function mine() external nonReentrant whenNotPaused {      // H-04, P-01
        Miner storage m = miners[msg.sender];

        require(totalMinted < MAX_BBALL_GLOBAL,    "Global bBALL supply exhausted");
        require(m.totalMined < MAX_BBALL_PER_USER, "User bBALL cap reached");

        uint256 yield_          = _yield(m.tool);
        uint256 globalRemaining = MAX_BBALL_GLOBAL   - totalMinted;
        uint256 userRemaining   = MAX_BBALL_PER_USER - m.totalMined;
        uint256 effectiveYield  = _min(yield_, _min(globalRemaining, userRemaining));

        // L-06: revert early rather than recording a zero-yield click
        require(effectiveYield > 0, "Nothing left to mine");

        // ── All state mutations before any external call (H-01 CEI) ──────────

        m.totalMined += effectiveYield;
        totalMinted  += effectiveYield;
        m.clicks     += 1;

        // C-01: upgrade check runs AFTER totalMined is updated so that threshold
        //       comparisons (>= DRILL_THRESHOLD, >= EXCAVATOR_THRESHOLD) are
        //       evaluated against the post-yield balance. Previously this fired
        //       before the increment, causing the Upgraded event to reflect stale
        //       state and confusing off-chain indexers.
        Tool toolBefore = m.tool;
        _checkUpgrade(m);
        if (m.tool != toolBefore) {
            emit Upgraded(msg.sender, m.tool);
        }

        _updateLeaderboard(msg.sender, m.totalMined);

        emit Mined(msg.sender, effectiveYield, m.totalMined, m.tool);

        // H-01: external call placed last — all state is finalised before we
        //       hand control to the token contract. nonReentrant prevents
        //       re-entry into mine(), and CEI order protects any view of this
        //       contract's state that token.mint's implementation might take.
        token.mint(msg.sender, effectiveYield);
    }

    /// @notice Manually trigger upgrade check.
    /// @dev    L-01: upgrade() intentionally does not call _updateLeaderboard
    ///         because it does not change totalMined — the leaderboard rank is
    ///         unaffected. The tool tier is not stored in leaderboard state.
    function upgrade() external whenNotPaused {
        Miner storage m = miners[msg.sender];
        // Distinguish "already at max tier" from "not enough bBALL yet" so the
        // UI and the caller get a meaningful message in both cases.
        require(m.tool != Tool.Excavator, "already at max tier");
        Tool before = m.tool;
        _checkUpgrade(m);
        require(m.tool != before, "not enough bBALL to upgrade yet");
        // M-03: emit here (not inside _checkUpgrade) so there is exactly one
        // Upgraded event per transition regardless of call path
        emit Upgraded(msg.sender, m.tool);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function getLeaderboard() external view returns (address[] memory addrs, uint256[] memory totals) {
        uint256 len = leaderboard.length;
        addrs  = new address[](len);
        totals = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            addrs[i]  = leaderboard[i];
            totals[i] = miners[leaderboard[i]].totalMined;
        }
    }

    function getStats(address player) external view
        returns (uint256 totalMined, uint256 clicks, Tool tool, uint256 yieldPerClick)
    {
        Miner storage m = miners[player];
        return (m.totalMined, m.clicks, m.tool, _yield(m.tool));
    }

    function bBALLToNextUpgrade(address player) external view returns (uint256) {
        Miner storage m = miners[player];
        if (m.tool == Tool.Pickaxe) return DRILL_THRESHOLD     > m.totalMined ? DRILL_THRESHOLD     - m.totalMined : 0;
        if (m.tool == Tool.Drill)   return EXCAVATOR_THRESHOLD > m.totalMined ? EXCAVATOR_THRESHOLD - m.totalMined : 0;
        return 0;
    }

    function globalSupplyRemaining() external view returns (uint256) {
        return MAX_BBALL_GLOBAL - totalMinted;
    }

    function isOnLeaderboard(address player) external view returns (bool) {
        // L-03: O(1) lookup via the onLeaderboard mapping instead of an O(n)
        //       array scan. This is the path called by MinerBadge on every
        //       claimGod() call.
        return onLeaderboard[player];
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _yield(Tool t) internal pure returns (uint256) {
        if (t == Tool.Pickaxe) return PICKAXE_YIELD;
        if (t == Tool.Drill)   return DRILL_YIELD;
        return EXCAVATOR_YIELD;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Mutates tool in storage. Does NOT emit — callers emit once.
    function _checkUpgrade(Miner storage m) internal {
        if (m.tool == Tool.Pickaxe && m.totalMined >= DRILL_THRESHOLD) {
            m.tool = Tool.Drill;
        } else if (m.tool == Tool.Drill && m.totalMined >= EXCAVATOR_THRESHOLD) {
            m.tool = Tool.Excavator;
        }
    }

    /// @dev Remove a player from the leaderboard array and mapping.
    ///      Used by seedPlayer when re-seeding with a lower value (M-4).
    function _removeFromLeaderboard(address player) internal {
        uint256 len = leaderboard.length;
        for (uint256 i = 0; i < len; i++) {
            if (leaderboard[i] == player) {
                leaderboard[i] = leaderboard[len - 1];
                leaderboard.pop();
                onLeaderboard[player] = false;
                return;
            }
        }
    }

    function _updateLeaderboard(address player, uint256 total) internal {
        int256 existingIdx = -1;
        for (uint256 i = 0; i < leaderboard.length; i++) {
            if (leaderboard[i] == player) { existingIdx = int256(i); break; }
        }

        if (existingIdx >= 0) {
            // Existing player: bubble up while strictly less-than (first-mover
            // advantage preserved among incumbents).
            uint256 idx = uint256(existingIdx);
            while (idx > 0 && miners[leaderboard[idx - 1]].totalMined < total) {
                (leaderboard[idx], leaderboard[idx - 1]) = (leaderboard[idx - 1], leaderboard[idx]);
                idx--;
            }
        } else {
            // Invariant: if the array scan found no existing entry, the O(1)
            // mapping must also show the player as absent. A mismatch here
            // means the two data structures drifted out of sync — fail loudly
            // rather than silently double-inserting the player.
            require(!onLeaderboard[player], "Leaderboard state inconsistent");
            if (leaderboard.length < MAX_LB) {
                leaderboard.push(player);
                onLeaderboard[player] = true;  // L-03: keep mapping in sync
            } else if (total > miners[leaderboard[leaderboard.length - 1]].totalMined) {
                // M-01: strict greater-than is intentional — a player tying the
                //       last-place holder does NOT displace them (first-mover
                //       advantage). Document this if game rules change.
                // M-04: emit eviction event before overwriting the slot
                address evicted = leaderboard[leaderboard.length - 1];
                emit LeaderboardEvicted(evicted);
                onLeaderboard[evicted] = false; // L-03: keep mapping in sync
                leaderboard[leaderboard.length - 1] = player;
                onLeaderboard[player] = true;   // L-03: keep mapping in sync
            } else {
                return;
            }
            // M-2: for new insertions, use <= so that a new entrant who ties an
            //      incumbent rises to their correct sorted position. First-mover
            //      advantage (strict < ) applies only to last-place displacement
            //      above, not to the in-array sort of new entries.
            uint256 idx = leaderboard.length - 1;
            while (idx > 0 && miners[leaderboard[idx - 1]].totalMined <= total) {
                (leaderboard[idx], leaderboard[idx - 1]) = (leaderboard[idx - 1], leaderboard[idx]);
                idx--;
            }
        }

        emit LeaderboardUpdated(player, total);
    }
}
