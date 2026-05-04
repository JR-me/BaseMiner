// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Baseball Token (bBALL)
 * @notice ERC-20 token mintable only by the BaseMiner game contract.
 *
 * Audit fixes applied:
 *   L-01  Zero-address guards added to mint() and _transfer().
 *   L-05  OwnerSet event emitted in constructor so deployer is auditable on-chain.
 *   L-07  Two-step ownership transfer: transferOwnership() nominates, acceptOwnership()
 *         confirms. Prevents accidental permanent lockout.
 *   M-05  updateMinter() added as an emergency owner-only path to replace a
 *         compromised or buggy minter. The original one-shot setMinter() is kept
 *         for initial deployment wiring.
 *   I-01  Deployer SHOULD be a multisig (e.g. Gnosis Safe): owner controls both
 *         minter assignment and ownership transfer.
 *   M-03  MAX_SUPPLY cap (100,940,000) is now enforced inside mint() so that any
 *         future minter — including one installed via updateMinter() — cannot
 *         mint beyond the intended hard cap regardless of its own internal logic.
 *   P-01  Emergency pause added. Owner can call pause() to halt mint() and all
 *         token transfers instantly. unpause() resumes normal operation.
 *         Scope is intentionally broad: pausing the token is the last-resort
 *         lever when the minter contract itself cannot be halted in time.
 *   H-1   approve() is now also pause-gated. Without this a malicious actor
 *         could pre-stage allowances during a pause and drain them the moment
 *         the contract is unpaused. The fix makes the pause surface consistent:
 *         mint, transfer, transferFrom, and approve all revert while paused.
 */
contract bBALL {
    string public constant name     = "Baseball";
    string public constant symbol   = "bBALL";
    uint8  public constant decimals = 0;

    // M-03: token-level hard cap — independent of BaseMiner's own accounting.
    // Must match BaseMiner.MAX_BBALL_GLOBAL. Any minter (current or future)
    // that attempts to exceed this limit is rejected here, not only at the
    // game layer, so a replacement minter cannot accidentally over-mint.
    uint256 public constant MAX_SUPPLY = 100_940_000;

    address public owner;
    address public pendingOwner;   // L-07
    address public minter;

    // P-01: emergency pause flag. When true, mint() and all token transfers revert.
    bool public paused;

    // Migration: owner can seed balances until lockMigration() is called.
    bool public migrationLocked;
    // M-1: auto-expiry block for the migration window. seedBalance() reverts
    //      after this block even if lockMigration() was never called.
    //      Set to deploy block + 50,000 (~27 hours on Base at 2s blocks).
    uint256 public immutable migrationDeadline;
    // L-5: track the amount already seeded per address so that re-seeding
    //      applies a delta to totalSupply rather than double-counting.
    mapping(address => uint256) public seededBalance;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner_, address indexed spender, uint256 value);
    event MinterSet(address indexed minter_);
    event MinterUpdated(address indexed oldMinter, address indexed newMinter); // M-05
    event OwnerSet(address indexed owner_);                                    // L-05
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner); // L-07
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);     // L-07
    event Paused(address indexed by);    // P-01
    event Unpaused(address indexed by);  // P-01
    event MigrationLocked();             // Migration

    modifier onlyOwner()    { require(msg.sender == owner,  "not owner");  _; }
    modifier onlyMinter()   { require(msg.sender == minter, "not minter"); _; }
    modifier whenNotPaused() { require(!paused, "bBALL: paused"); _; }         // P-01

    constructor() {
        owner = msg.sender;
        emit OwnerSet(msg.sender);  // L-05
        migrationDeadline = block.number + 50_000; // M-1: ~27 hrs on Base
    }

    // ── Ownership (L-07) ─────────────────────────────────────────────────────

    /// @notice Step 1 — nominate a new owner. No effect until acceptOwnership().
    ///         If a pending transfer is already in progress, it is silently
    ///         superseded; the old nominee's acceptOwnership() call will revert.
    ///         A new OwnershipTransferStarted event is emitted so off-chain monitors
    ///         can detect the replacement. // I-4
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

    // ── Minter management ────────────────────────────────────────────────────

    /// @notice Initial one-shot wiring: set the minter when none is assigned yet.
    function setMinter(address minter_) external onlyOwner {
        require(minter == address(0), "minter already set; use updateMinter");
        require(minter_ != address(0), "zero address");
        minter = minter_;
        emit MinterSet(minter_);
    }

    /// @notice Emergency replacement of a compromised or buggy minter (M-05).
    ///         Caller is responsible for decommissioning the old BaseMiner first.
    function updateMinter(address newMinter) external onlyOwner {
        require(newMinter != address(0), "zero address");
        address old = minter;
        minter = newMinter;
        emit MinterUpdated(old, newMinter);
    }

    // ── Pause (P-01) ─────────────────────────────────────────────────────────

    /// @notice Halt all minting and token transfers immediately.
    ///         Use in an emergency when a bug is detected in the minter or game.
    /// @dev    Note: existing allowances are NOT revoked by pausing. They remain
    ///         active and can be exercised immediately upon unpause(). If allowance
    ///         revocation is needed during an incident, affected users must set their
    ///         allowances to 0 manually, or a future upgrade can add revokeAllowance(). // L-1
    function pause() external onlyOwner {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume normal operation after a pause.
    function unpause() external onlyOwner {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ── Migration ─────────────────────────────────────────────────────────────

    /// @notice Seed a player's bBALL balance during contract migration.
    ///         Owner-only. Only callable before lockMigration() is called.
    ///         Re-seeding the same address adjusts totalSupply by the delta so
    ///         the global counter stays correct and no balance is double-counted. // L-5
    ///         Emits a standard Transfer(address(0), to, amount) so explorers
    ///         and indexers treat migrated balances identically to minted ones.
    function seedBalance(address to, uint256 amount) external onlyOwner {
        require(!migrationLocked,                      "Migration locked");
        require(block.number <= migrationDeadline,     "Migration window expired"); // M-1
        require(to != address(0),                      "zero address");

        // L-5: adjust totalSupply by delta, not by full amount, so re-seeding
        //      the same address does not double-count the previous seed.
        uint256 previousSeed = seededBalance[to];
        if (amount >= previousSeed) {
            uint256 delta = amount - previousSeed;
            require(totalSupply + delta <= MAX_SUPPLY, "bBALL cap exceeded");
            totalSupply   += delta;
        } else {
            uint256 delta = previousSeed - amount;
            totalSupply   -= delta;
        }
        balanceOf[to]     = balanceOf[to] - previousSeed + amount;
        seededBalance[to] = amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Permanently close the migration window.
    ///         Once called, seedBalance() can never be called again.
    ///         Also callable after migrationDeadline has passed to tidy state. // M-1
    function lockMigration() external onlyOwner {
        require(!migrationLocked, "Already locked");
        migrationLocked = true;
        emit MigrationLocked();
    }

    // ── Mint ─────────────────────────────────────────────────────────────────

    /// @notice Mint bBALL — only callable by the authorised minter contract.
    /// @dev    M-03: enforces MAX_SUPPLY independently of the minter's own cap
    ///         logic, so a replacement minter cannot accidentally over-mint.
    ///         P-01: reverts when paused so a buggy minter cannot mint while
    ///         an incident is being investigated.
    function mint(address to, uint256 amount) external onlyMinter whenNotPaused {
        require(to != address(0), "mint to zero address");                 // L-01
        require(totalSupply + amount <= MAX_SUPPLY, "bBALL cap exceeded"); // M-03
        totalSupply        += amount;
        balanceOf[to]      += amount;
        emit Transfer(address(0), to, amount);
    }

    // ── Standard ERC-20 ──────────────────────────────────────────────────────

    function transfer(address to, uint256 amount) external whenNotPaused returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    // H-1: whenNotPaused added so that allowances cannot be pre-staged while an
    //      emergency pause is in effect. transferFrom is already pause-gated;
    //      leaving approve() open would let an attacker queue approvals for
    //      immediate execution the moment the contract is unpaused.
    function approve(address spender, uint256 amount) external whenNotPaused returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external whenNotPaused returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance exceeded");
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "transfer from zero address"); // L-3
        require(to != address(0), "transfer to zero address");  // L-01
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
