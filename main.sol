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
