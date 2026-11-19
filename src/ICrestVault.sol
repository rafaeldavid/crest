// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";

/// @title ICrestVault
/// @notice An owner's vault: it holds one token and a tree of grants, and pays only through modules the owner enabled,
///         each to the one payee the owner pinned for it.
///
///         The tree. The owner controls the root grant. Each grant names a parent, one controller key and its limits.
///         A payment charges the grant of the key that asks and every grant above it: each checks its state, its
///         expiry, its limits and its allow list, and adds to its own counters. One refusal reverts the whole payment
///         and nothing is counted. A child granted wider limits than its parent is still bound by the parent at payment
///         time, so limits are never compared when a grant is made.
///
///         Who may do what. A top vault's owner withdraws, enables modules and acts on any grant. A controller above a
///         grant, at any level, may pause, resume, close or set the limits of that grant and list its counterparties. A
///         grant's own controller may pause or close itself and, when its grant allows it, grant children and create
///         child vaults. It can never widen, resume or reopen its own grant.
///
///         Child vaults. A grant's controller may create a child vault through this vault, own it, and fill it from
///         this vault within the grant's period and total limits. Every payment from the child is also checked against
///         the parent grant's path, and the paths above it in every ancestor vault, for state, expiry, per-payment
///         limit and allow lists. A child pays only through modules enabled at the top vault, to the payees pinned
///         there, and sends money only back to its parent. Anyone with authority over the parent grant has authority
///         over the child.
///
///         Payments. An enabled module asks the vault to `charge` a key's grant. After the charge the vault approves
///         exactly one ERC-3009 `ReceiveWithAuthorization`: from the vault, to the module's pinned payee, for exactly
///         the charged amount, with the module's deadline and nonce, for the rest of the transaction. It answers
///         ERC-1271 to the token only, and only for that digest, so no key's own signature ever moves the vault's money.
///
///         Money already committed. A vault has no function that can move money a venue holds. Its only call into a
///         venue is a Commerce Payments escrow's payer-only `reclaim`, after that escrow's expiry, which returns money to
///         the vault.
/// @dev No upgrade, no delegatecall, no selfdestruct. Every vault is a minimal clone of one implementation, created and
///      initialized in one transaction by `CrestFactory`.
interface ICrestVault {
    /// @notice What a grant allows. The largest value of a type means no limit of that kind.
    /// @param perSpend The most one payment may be, in the token's base units.
    /// @param perPeriod The most the payments of one period may add up to.
    /// @param lifetime The most this grant may ever pay, child-vault funding included.
    /// @param maxOpen How many commitments may be open at once.
    /// @param period A period's length in seconds; a period is `floor(block.timestamp / period)`, so 86,400 is a UTC
    ///        day. Must not be 0.
    /// @param expiresAt No payment from this instant on (unix seconds); 0 for no expiry.
    /// @param restricted True: a payment must name a counterparty on this grant's own allow list.
    /// @param mayDelegate True: the grant's controller may grant children and create child vaults.
    struct Caps {
        uint128 perSpend;
        uint128 perPeriod;
        uint128 lifetime;
        uint32 maxOpen;
        uint32 period;
        uint40 expiresAt;
        bool restricted;
        bool mayDelegate;
    }

    /// @notice A grant and its counters. `paused` can be lifted from above; `closed` is permanent.
    struct Grant {
        uint256 parent;
        address controller;
        bool paused;
        bool closed;
        Caps caps;
        uint128 inPeriod;
        uint128 spent;
        uint40 periodIndex;
        uint32 open;
    }

    /// @notice A commitment a module opened: which grant paid, how much, and which module may release it.
    struct Open {
        uint256 grant;
        uint128 amount;
        address module;
    }

    // Events. Every state change emits one.

    event Initialized(address indexed owner, address indexed token, address indexed parent, uint256 parentGrant);
    event OwnerProposed(address indexed owner, address indexed proposed);
    event OwnerChanged(address indexed previous, address indexed owner);
    event ModuleSet(address indexed module, address indexed payee);
    event Withdrawn(address indexed to, uint256 amount);
    event Granted(uint256 indexed id, uint256 indexed parent, address indexed controller, Caps caps);
    event CapsSet(uint256 indexed id, Caps caps, address indexed by);
    event PausedSet(uint256 indexed id, bool paused, address indexed by);
    event Closed(uint256 indexed id, address indexed by);
    event Allowed(uint256 indexed id, bytes32 indexed counterparty, bool allowed, address indexed by);
    event Charged(
        uint256 indexed grant, bytes32 indexed commitment, address indexed module, uint256 amount, bytes32 counterparty
    );
    event Released(uint256 indexed grant, bytes32 indexed commitment, uint256 amount);
    event ChildCreated(address indexed child, uint256 indexed grant, address indexed owner);
    event ChildFunded(address indexed child, uint256 indexed grant, uint256 amount, address by);
    event ReturnedToParent(address indexed parent, uint256 amount, address indexed by);
    event Reclaimed(address indexed module, address indexed escrow);

    // Errors. A refusal by a limit names the grant that refused.

    error AlreadyInitialized();
    error NotAuthorized();
    error NotTopVault();
    error NotChildVault();
    error InvalidCaps();
    error NoGrant();
    error GrantExists();
    error MayNotDelegate();
    error UnknownChild();
    error ModuleNotEnabled();
    error CommitmentOpen();
    error NotOpen();
    error AmountTooLarge();
    error NotThePayer();
    error Paused(uint256 grant);
    error GrantClosed(uint256 grant);
    error Expired(uint256 grant);
    error OverPerSpend(uint256 grant);
    error OverPerPeriod(uint256 grant);
    error OverLifetime(uint256 grant);
    error TooManyOpen(uint256 grant);
    error CounterpartyNotAllowed(uint256 grant);

    // Setup

    /// @notice Sets the owner, the token and, for a child, its parent vault and parent grant. Once, by the factory
    ///         that created the clone, in the same transaction. The root grant goes to the owner with no limits.
    function initialize(address owner, address token, address parent, uint256 parentGrant) external;

    // The owner

    /// @notice The owner proposes a new owner; the proposed key takes over with `acceptOwner`.
    function proposeOwner(address proposed) external;

    /// @notice The proposed key becomes the owner and the controller of the root grant.
    function acceptOwner() external;

    /// @notice A top vault's owner enables `module` to have this vault pay `payee`, or disables it with payee 0.
    ///         Child vaults inherit the top vault's modules and cannot set their own.
    function setModule(address module, address payee) external;

    /// @notice A top vault's owner sends `amount` of the vault's balance to `to`. Money a venue holds is not the
    ///         vault's balance and cannot be reached.
    function withdraw(address to, uint256 amount) external;

    // The tree

    /// @notice Grants `controller` a child of `parentId` with `caps`. By `parentId`'s controller when its grant may
    ///         delegate, or by anyone with authority above `parentId`. The ID is `keccak256(parentId, controller, salt)`.
    /// @return id The new grant's ID.
    function grant(uint256 parentId, address controller, Caps calldata caps, bytes32 salt) external returns (uint256 id);

    /// @notice Sets the limits of grant `id`. By anyone with authority above it.
    function setCaps(uint256 id, Caps calldata caps) external;

    /// @notice Pauses or resumes grant `id`, and with it every payment through it. Its own controller may pause it;
    ///         only authority above may resume it.
    function setPaused(uint256 id, bool paused) external;

    /// @notice Closes grant `id` for good. By its own controller or by authority above it.
    function close(uint256 id) external;

    /// @notice Lists or unlists `counterparty` on grant `id`. By anyone with authority above it.
    function allow(uint256 id, bytes32 counterparty, bool allowed) external;

    // Child vaults

    /// @notice Creates a child vault owned by grant `grantId`'s controller, through the factory. By that controller
    ///         when its grant may delegate, or by authority above it.
    /// @return child The child vault's address.
    function createChild(uint256 grantId, bytes32 salt) external returns (address child);

    /// @notice Moves `amount` into `child`, charged to the path of the grant that created it for its state, expiry,
    ///         period and total limits. By that grant's controller or authority above it.
    function fundChild(address child, uint256 amount) external;

    /// @notice Has `child` send `amount` back to this vault. By the grant's controller or authority above it.
    function takeBackFromChild(address child, uint256 amount) external;

    /// @notice A child vault sends `amount` to its parent vault: by its owner, or by its parent vault.
    function returnToParent(uint256 amount) external;

    // Payments

    /// @notice An enabled module charges `controller`'s grant and every grant above it with `amount` for
    ///         `counterparty`, opens `commitment`, and has the vault approve one ERC-3009 authorization of exactly
    ///         `amount` to the module's pinned payee, valid before `validBefore`, with `nonce`.
    function charge(
        address controller,
        uint256 amount,
        bytes32 counterparty,
        bytes32 commitment,
        uint256 validBefore,
        bytes32 nonce
    ) external;

    /// @notice The module that opened `commitment` says it has ended: the open counts fall at every level. What was
    ///         spent stays counted.
    function release(bytes32 commitment) external;

    /// @notice Anyone has the vault call `reclaim` on the Commerce Payments escrow an enabled `module` names, for a
    ///         payment this vault paid. The escrow allows it only to the payer and only after its own expiry, and
    ///         returns the money to the vault.
    function reclaim(address module, AuthCaptureEscrow.PaymentInfo calldata paymentInfo) external;

    /// @notice ERC-1271: yes to the token only, for a digest `charge` approved in this transaction.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);

    // Views used across vaults

    /// @notice Whether `who` controls grant `id` or any grant above it, here or in any ancestor vault, or is a top
    ///         vault's owner.
    function authorityOver(address who, uint256 id) external view returns (bool);

    /// @notice Reverts as `charge` would for `amount` and `counterparty` on grant `id`'s path, here and in every
    ///         ancestor vault, for state, expiry, per-payment limit and allow lists. Counts nothing.
    function checkPath(uint256 id, uint256 amount, bytes32 counterparty) external view;

    /// @notice Reverts when any grant on `id`'s path, here or in an ancestor vault, is closed, paused or expired.
    function checkState(uint256 id) external view;

    /// @notice The payee pinned for `module` at the top vault; 0 when it is not enabled.
    function payeeOf(address module) external view returns (address);

    function owner() external view returns (address);
    function token() external view returns (address);
    function parent() external view returns (address);
    function parentGrant() external view returns (uint256);
    function grantOf(address controller) external view returns (uint256);
    function grantOfChild(address child) external view returns (uint256);
    function allowed(uint256 id, bytes32 counterparty) external view returns (bool);
    function getGrant(uint256 id) external view returns (Grant memory);
    function getOpen(bytes32 commitment) external view returns (Open memory);
}

/// @notice A module that pays through a Commerce Payments escrow names it, so the vault can call that escrow's
///         payer-only `reclaim` after the escrow's expiry.
interface ICrestEscrowModule {
    function escrow() external view returns (address);
}
