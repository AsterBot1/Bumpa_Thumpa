// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// RabbyGo — burrows, bunnies, and city-glow footprints.
/// A compact onchain core for an AI-social scavenger game: post sightings, commit/reveal captures, and claim signed quests.

interface IRabbyGoERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

contract RabbyGo {
    error RG_Unauthorized();
    error RG_BadInput();
    error RG_Expired();
    error RG_TooSoon(uint256 unlockAt);
    error RG_TooLate(uint256 deadline);
    error RG_Paused();
    error RG_Reentrancy();
    error RG_NotFound();
    error RG_Exists();
    error RG_TransferFailed();
    error RG_BadSignature();
    error RG_NotMintable();
    error RG_UnsafeRecipient();
    event RG_OwnerProposed(address indexed currentOwner, address indexed pendingOwner, uint256 acceptAfter);
    event RG_OwnerAccepted(address indexed previousOwner, address indexed newOwner);
    event RG_GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event RG_PauseSet(bool on);
    event RG_QuestOracleSet(address indexed previousOracle, address indexed newOracle);
    event RG_SightingPosted(bytes32 indexed sightingId, address indexed author, int32 latE6, int32 lonE6, uint16 biome, bytes32 messageHash);
    event RG_SightingReacted(bytes32 indexed sightingId, address indexed by, uint8 kind, uint32 newCount);
    event RG_CaptureCommitted(address indexed player, bytes32 indexed commit, uint40 committedAt, uint32 committedBlock);
    event RG_CaptureRevealed(address indexed player, bytes32 indexed commit, bytes32 indexed captureId, bool success, uint256 mintedTokenId);
    event RG_CaptureStakeRefunded(address indexed to, uint256 amountWei);
    event RG_FeeDial(uint16 protocolFeeBps, address indexed feeCollector);
    event RG_RabbitMinted(address indexed to, uint256 indexed tokenId, bytes32 indexed captureId, uint16 fur, uint16 aura, uint16 mood);
    event RG_ProfileSet(address indexed who, bytes32 indexed profileId, bytes32 handleHash, bytes32 bioHash);
    event RG_QuestClaimed(address indexed player, bytes32 indexed questId, uint32 points, uint256 payoutWei);
    event RG_Sweep(address indexed asset, address indexed to, uint256 amount);
    uint256 public constant OWNER_DELAY = 33 hours;
    uint256 public constant MAX_SIGHTING_BYTES = 192;
    uint256 public constant MAX_HANDLE_BYTES = 24;
    uint256 public constant MAX_BIO_BYTES = 200;
    uint256 public constant COMMIT_MIN_AGE = 2 minutes;
    uint256 public constant COMMIT_MAX_AGE = 2 hours;
    uint256 public constant COMMIT_BLOCK_WINDOW = 180; // ~36 minutes @ 12s; must be < 256 for blockhash availability
    uint256 public constant MAX_REACTIONS_PER_KIND = 4_000_000_000; // uint32 max-ish sentinel, avoids revert on overflow checks
    uint256 public constant RABBIT_CAP = 50_000;
    uint256 public constant QUEST_POINTS_CAP = 2_000_000_000;
    uint16 public constant FEE_BPS_CAP = 950; // 9.50%

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");
    bytes32 internal constant QUEST_TYPEHASH =
        keccak256("QuestClaim(address player,bytes32 questId,uint32 points,uint256 payoutWei,uint256 nonce,uint256 deadline)");

    bytes32 internal constant RG_SALT =
        0x7fa8d7e1a8a7a55f3a5d5a1c0af9a2d80b2bb818b62d79ac2cb6dbd2b0c2f617;

    bytes32 internal constant SEED_PEPPER =
        0x1f54b6de8f5d6a8c1c8f2e9a0dbb0c8ef4d7b3b3b5f9df0b7fd5c7df1e5b4a13;

    address public immutable genesisDeployer;
    uint256 public immutable genesisAt;
    bytes32 public immutable domainSeparator;
    address public owner;
    address public pendingOwner;
    uint256 public pendingOwnerUnlockAt;
    address public guardian;
    bool public paused;

    modifier onlyOwner() {
        if (msg.sender != owner) revert RG_Unauthorized();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && msg.sender != guardian) revert RG_Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert RG_Paused();
        _;
    }
    uint256 private _lock;
    modifier nonReentrant() {
        if (_lock == 1) revert RG_Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }
    uint16 public protocolFeeBps = 137;
    address public feeCollector;
    struct Sighting {
        address author;
        uint40 createdAt;
        int32 latE6;
        int32 lonE6;
        uint16 biome;
        bytes32 messageHash;
        bool exists;
    }

    uint256 public sightingCount;
    mapping(bytes32 => Sighting) private _sightings;

    // reactions: sightingId => (kind => count)
    mapping(bytes32 => mapping(uint8 => uint32)) public reactionCount;
    // per-player reaction rate limit per sightingId per kind
    mapping(bytes32 => mapping(uint8 => mapping(address => bool))) public reacted;
    // profiles
    struct Profile {
        bytes32 handleHash;
        bytes32 bioHash;
        uint40 updatedAt;
        bool exists;
    }
    mapping(address => Profile) private _profiles;

    // =============================================================
    struct CommitInfo {
        uint40 committedAt;
        uint32 committedBlock;
        uint96 stakeWei;
        bool exists;
    }
    mapping(address => mapping(bytes32 => CommitInfo)) public commits;
    mapping(bytes32 => bool) public captureUsed;

    uint256 public captureCount;
    uint256 public rabbitCount;
    address public questOracle;
    mapping(address => uint256) public questNonces;
    mapping(bytes32 => bool) public questClaimed;
    uint256 public totalQuestPayouts;
    uint256 public totalQuestPoints;
    string public name = "RabbyGo";
    string public symbol = "RGO";

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    struct RabbitCore {
        uint16 fur;
        uint16 aura;
        uint16 mood;
        uint40 bornAt;
        uint40 lastHopAt;
        uint32 hops;
    }

    mapping(uint256 => RabbitCore) public rabbitCore;
    mapping(uint256 => bytes32) public rabbitOriginCapture;
    mapping(bytes32 => uint256) public captureToToken;
    constructor() {
        genesisDeployer = msg.sender;
        genesisAt = block.timestamp;
        owner = msg.sender;
        feeCollector = msg.sender;
        questOracle = msg.sender;

        domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("RabbyGo")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                address(this),
                RG_SALT
            )
        );
    }
    receive() external payable {}
    function proposeOwner(address next) external onlyOwner {
        if (next == address(0) || next == owner) revert RG_BadInput();
        pendingOwner = next;
        pendingOwnerUnlockAt = block.timestamp + OWNER_DELAY;
        emit RG_OwnerProposed(owner, next, pendingOwnerUnlockAt);
    }

    function clearProposedOwner() external onlyOwner {
        pendingOwner = address(0);
        pendingOwnerUnlockAt = 0;
        emit RG_OwnerProposed(owner, address(0), 0);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert RG_Unauthorized();
        if (block.timestamp < pendingOwnerUnlockAt) revert RG_TooSoon(pendingOwnerUnlockAt);
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        pendingOwnerUnlockAt = 0;
        emit RG_OwnerAccepted(prev, owner);
    }

    function setGuardian(address next) external onlyOwner {
        if (next == owner) revert RG_BadInput();
        address prev = guardian;
        guardian = next;
        emit RG_GuardianSet(prev, next);
    }

    function setPaused(bool on) external onlyOwnerOrGuardian {
        paused = on;
        emit RG_PauseSet(on);
    }

    function setQuestOracle(address next) external onlyOwner {
        if (next == address(0)) revert RG_BadInput();
        address prev = questOracle;
        questOracle = next;
        emit RG_QuestOracleSet(prev, next);
    }
    function setFee(uint16 feeBps, address collector) external onlyOwner {
        if (feeBps > FEE_BPS_CAP) revert RG_BadInput();
        if (collector == address(0)) revert RG_BadInput();
        protocolFeeBps = feeBps;
        feeCollector = collector;
        emit RG_FeeDial(feeBps, collector);
    }
    function setProfile(bytes calldata handle, bytes calldata bio) external whenNotPaused returns (bytes32 profileId) {
        if (handle.length == 0 || handle.length > MAX_HANDLE_BYTES) revert RG_BadInput();
        if (bio.length > MAX_BIO_BYTES) revert RG_BadInput();
        bytes32 h = keccak256(handle);
        bytes32 b = keccak256(bio);

        Profile storage p = _profiles[msg.sender];
        p.handleHash = h;
        p.bioHash = b;
        p.updatedAt = uint40(block.timestamp);
        p.exists = true;

        profileId = keccak256(abi.encodePacked(SEED_PEPPER, msg.sender, h, b, p.updatedAt, block.chainid));
        emit RG_ProfileSet(msg.sender, profileId, h, b);
    }

    function getProfile(address who) external view returns (Profile memory) {
        Profile memory p = _profiles[who];
        if (!p.exists) revert RG_NotFound();
        return p;
    }
    function postSighting(int32 latE6, int32 lonE6, uint16 biome, bytes calldata message)
        external
        whenNotPaused
        returns (bytes32 sightingId)
    {
        if (message.length == 0 || message.length > MAX_SIGHTING_BYTES) revert RG_BadInput();
        if (!_validLatLon(latE6, lonE6)) revert RG_BadInput();

        uint256 t = block.timestamp;
        bytes32 messageHash = keccak256(message);
        unchecked {
            sightingCount += 1;
        }

        sightingId = keccak256(
            abi.encodePacked(
                SEED_PEPPER,
                "RG:SIGHT",
                msg.sender,
                latE6,
                lonE6,
                biome,
                messageHash,
                sightingCount,
                t
            )
        );
        if (_sightings[sightingId].exists) revert RG_Exists();
        _sightings[sightingId] = Sighting({
            author: msg.sender,
            createdAt: uint40(t),
            latE6: latE6,
            lonE6: lonE6,
            biome: biome,
            messageHash: messageHash,
            exists: true
        });

        emit RG_SightingPosted(sightingId, msg.sender, latE6, lonE6, biome, messageHash);
    }

    function getSighting(bytes32 sightingId) external view returns (Sighting memory) {
        Sighting memory s = _sightings[sightingId];
        if (!s.exists) revert RG_NotFound();
        return s;
    }

    function react(bytes32 sightingId, uint8 kind) external whenNotPaused {
        if (!_sightings[sightingId].exists) revert RG_NotFound();
        if (kind == 0) revert RG_BadInput();
        if (reacted[sightingId][kind][msg.sender]) revert RG_Exists();
        reacted[sightingId][kind][msg.sender] = true;

        uint32 next = reactionCount[sightingId][kind] + 1;
        if (next == 0 || next > MAX_REACTIONS_PER_KIND) revert RG_BadInput();
        reactionCount[sightingId][kind] = next;

        emit RG_SightingReacted(sightingId, msg.sender, kind, next);
    }
    /// commit = keccak256(abi.encodePacked("RG:CAPTURE", player, salt, latE6, lonE6, biome, intentHash))
    /// intentHash can be any bytes32 the client uses to bind UI intent (e.g. sightingId or AR scene hash).
    function commitCapture(bytes32 commit) external payable whenNotPaused {
        if (commit == bytes32(0)) revert RG_BadInput();
        CommitInfo storage ci = commits[msg.sender][commit];
        if (ci.exists) revert RG_Exists();

        uint256 stake = msg.value;
        if (stake > type(uint96).max) revert RG_BadInput();

        ci.committedAt = uint40(block.timestamp);
        ci.committedBlock = uint32(block.number);
        ci.stakeWei = uint96(stake);
        ci.exists = true;

        emit RG_CaptureCommitted(msg.sender, commit, ci.committedAt, ci.committedBlock);
    }

    struct Reveal {
        bytes32 salt;
        int32 latE6;
        int32 lonE6;
        uint16 biome;
        bytes32 intentHash;
    }

    function revealCapture(Reveal calldata r) external whenNotPaused nonReentrant returns (bytes32 captureId, bool success, uint256 tokenId) {
        if (!_validLatLon(r.latE6, r.lonE6)) revert RG_BadInput();
        if (r.salt == bytes32(0)) revert RG_BadInput();

        bytes32 commit = keccak256(abi.encodePacked("RG:CAPTURE", msg.sender, r.salt, r.latE6, r.lonE6, r.biome, r.intentHash));
        CommitInfo memory ci = commits[msg.sender][commit];
        if (!ci.exists) revert RG_NotFound();

        uint256 nowTs = block.timestamp;
        uint256 minAt = uint256(ci.committedAt) + COMMIT_MIN_AGE;
        if (nowTs < minAt) revert RG_TooSoon(minAt);
        uint256 maxAt = uint256(ci.committedAt) + COMMIT_MAX_AGE;
        if (nowTs > maxAt) revert RG_Expired();

        // Must be recent enough for blockhash usage but old enough to reduce same-block manipulation.
        uint256 ageBlocks = block.number - uint256(ci.committedBlock);
        if (ageBlocks == 0) revert RG_TooSoon(block.timestamp + 1);
        if (ageBlocks > COMMIT_BLOCK_WINDOW) revert RG_Expired();

        // Consume commit
        delete commits[msg.sender][commit];

        captureId = keccak256(
            abi.encodePacked(
                SEED_PEPPER,
                "RG:CAPID",
                msg.sender,
                commit,
                ci.committedAt,
                ci.committedBlock,
                block.chainid
            )
        );
        if (captureUsed[captureId]) revert RG_Exists();
        captureUsed[captureId] = true;
        unchecked {
            captureCount += 1;
        }

        // Random-ish outcome: commit binds player inputs; reveal uses blockhash to de-bias a bit.
        bytes32 bh = blockhash(uint256(ci.committedBlock) + 1);
        bytes32 rnd = keccak256(
            abi.encodePacked(
                SEED_PEPPER,
                bh,
                block.prevrandao,
                address(this),
                msg.sender,
                captureId,
                r.salt,
                r.intentHash
            )
        );

        // Success odds: dynamic curve based on biome and a small stake influence (capped).
        uint256 oddsBps = _oddsBps(r.biome, uint256(ci.stakeWei));
        uint256 roll = uint256(rnd) % 10_000;
        success = roll < oddsBps;

        if (success) {
            tokenId = _mintRabbit(msg.sender, captureId, rnd);
        } else {
            tokenId = 0;
        }

        // Stake refund minus protocol fee (if any); fee collector gets its cut.
        if (ci.stakeWei != 0) {
            (uint256 fee, uint256 refund) = _splitFee(uint256(ci.stakeWei));
            if (fee != 0) _pay(feeCollector, fee);
            if (refund != 0) {
                _pay(msg.sender, refund);
                emit RG_CaptureStakeRefunded(msg.sender, refund);
            }
        }

        emit RG_CaptureRevealed(msg.sender, commit, captureId, success, tokenId);
    }

    function previewOddsBps(uint16 biome, uint256 stakeWei) external pure returns (uint256) {
        return _oddsBps(biome, stakeWei);
