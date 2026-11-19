// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ICrestFactory} from "./ICrestFactory.sol";
import {ICrestEscrowModule, ICrestVault} from "./ICrestVault.sol";

interface IERC3009Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title CrestVault
/// @notice An owner's vault and its tree of grants. `ICrestVault` describes every function, event and error.
contract CrestVault is ICrestVault {
    /// @notice The root grant's ID. The owner controls it.
    uint256 public constant ROOT = 1;
    /// keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant ERC1271_NO = 0xffffffff;

    address public owner;
    address public pendingOwner;
    address public token;
    address public factory;
    address public parent;
    uint256 public parentGrant;

    mapping(uint256 id => Grant) internal _grants;
    mapping(address controller => uint256 id) public grantOf;
    mapping(address child => uint256 id) public grantOfChild;
    mapping(uint256 id => mapping(bytes32 counterparty => bool)) public allowed;
    mapping(bytes32 commitment => Open) internal _opens;
    mapping(address module => address payee) internal _payees;

    /// @dev The implementation is never a vault: it can never be initialized.
    constructor() {
        owner = address(1);
    }

    // Setup

    /// @inheritdoc ICrestVault
    function initialize(address owner_, address token_, address parent_, uint256 parentGrant_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0) || token_ == address(0)) revert NotAuthorized();
        (owner, token, factory, parent, parentGrant) = (owner_, token_, msg.sender, parent_, parentGrant_);
        Grant storage g = _grants[ROOT];
        g.controller = owner_;
        g.caps = Caps({
            perSpend: type(uint128).max,
            perPeriod: type(uint128).max,
            lifetime: type(uint128).max,
            maxOpen: type(uint32).max,
            period: 1 days,
            expiresAt: 0,
            restricted: false,
            mayDelegate: true
        });
        grantOf[owner_] = ROOT;
        emit Initialized(owner_, token_, parent_, parentGrant_);
        emit Granted(ROOT, 0, owner_, g.caps);
    }

    // The owner

    /// @inheritdoc ICrestVault
    function proposeOwner(address proposed) external {
        if (msg.sender != owner) revert NotAuthorized();
        pendingOwner = proposed;
        emit OwnerProposed(owner, proposed);
    }

    /// @inheritdoc ICrestVault
    function acceptOwner() external {
        address proposed = pendingOwner;
        if (proposed == address(0) || msg.sender != proposed) revert NotAuthorized();
        if (grantOf[proposed] != 0) revert GrantExists();
        address previous = owner;
        delete grantOf[previous];
        (owner, pendingOwner) = (proposed, address(0));
        _grants[ROOT].controller = proposed;
        grantOf[proposed] = ROOT;
        emit OwnerChanged(previous, proposed);
    }

    /// @inheritdoc ICrestVault
    function setModule(address module, address payee) external {
        if (parent != address(0)) revert NotTopVault();
        if (msg.sender != owner) revert NotAuthorized();
        _payees[module] = payee;
        emit ModuleSet(module, payee);
    }

    /// @inheritdoc ICrestVault
    function withdraw(address to, uint256 amount) external {
        if (parent != address(0)) revert NotTopVault();
        if (msg.sender != owner) revert NotAuthorized();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Withdrawn(to, amount);
    }

    // The tree

    /// @inheritdoc ICrestVault
    function grant(uint256 parentId, address controller, Caps calldata caps, bytes32 salt)
        external
        returns (uint256 id)
    {
        Grant storage p = _grants[parentId];
        if (p.controller == address(0)) revert NoGrant();
        _requireDelegator(parentId, p);
        if (p.closed) revert GrantClosed(parentId);
        if (controller == address(0)) revert NotAuthorized();
        _requireValid(caps);
        id = uint256(keccak256(abi.encode(parentId, controller, salt)));
        if (id <= ROOT || _grants[id].controller != address(0) || grantOf[controller] != 0) revert GrantExists();
        Grant storage g = _grants[id];
        (g.parent, g.controller, g.caps) = (parentId, controller, caps);
        grantOf[controller] = id;
        emit Granted(id, parentId, controller, caps);
    }

    /// @inheritdoc ICrestVault
    function setCaps(uint256 id, Caps calldata caps) external {
        _requireExists(id);
        if (!_above(msg.sender, id)) revert NotAuthorized();
        _requireValid(caps);
        _grants[id].caps = caps;
        emit CapsSet(id, caps, msg.sender);
    }

    /// @inheritdoc ICrestVault
    function setPaused(uint256 id, bool paused) external {
        Grant storage g = _grants[id];
        _requireExists(id);
        bool own = paused && msg.sender == g.controller;
        if (!own && !_above(msg.sender, id)) revert NotAuthorized();
        g.paused = paused;
        emit PausedSet(id, paused, msg.sender);
    }

    /// @inheritdoc ICrestVault
    function close(uint256 id) external {
        Grant storage g = _grants[id];
        _requireExists(id);
        if (msg.sender != g.controller && !_above(msg.sender, id)) revert NotAuthorized();
        g.closed = true;
        emit Closed(id, msg.sender);
    }

    /// @inheritdoc ICrestVault
    function allow(uint256 id, bytes32 counterparty, bool ok) external {
        _requireExists(id);
        if (!_above(msg.sender, id)) revert NotAuthorized();
        allowed[id][counterparty] = ok;
        emit Allowed(id, counterparty, ok, msg.sender);
    }

    // Child vaults

    /// @inheritdoc ICrestVault
    function createChild(uint256 grantId, bytes32 salt) external returns (address child) {
        Grant storage g = _grants[grantId];
        if (g.controller == address(0)) revert NoGrant();
        _requireDelegator(grantId, g);
        _requireUsable(grantId);
        child = ICrestFactory(factory).createChild(g.controller, grantId, salt);
        grantOfChild[child] = grantId;
        emit ChildCreated(child, grantId, g.controller);
    }

    /// @inheritdoc ICrestVault
    function fundChild(address child, uint256 amount) external {
        uint256 id = grantOfChild[child];
        if (id == 0) revert UnknownChild();
        if (!authorityOver(msg.sender, id)) revert NotAuthorized();
        uint128 a = _amount(amount);
        for (uint256 g = id; g != 0; g = _grants[g].parent) {
            _chargeOne(g, a, bytes32(0), false);
        }
        SafeTransferLib.safeTransfer(token, child, amount);
        emit ChildFunded(child, id, amount, msg.sender);
    }

    /// @inheritdoc ICrestVault
    function takeBackFromChild(address child, uint256 amount) external {
        uint256 id = grantOfChild[child];
        if (id == 0) revert UnknownChild();
        if (!authorityOver(msg.sender, id)) revert NotAuthorized();
        ICrestVault(child).returnToParent(amount);
    }

    /// @inheritdoc ICrestVault
    function returnToParent(uint256 amount) external {
        address p = parent;
        if (p == address(0)) revert NotChildVault();
        if (msg.sender != p && !authorityOver(msg.sender, ROOT)) revert NotAuthorized();
        SafeTransferLib.safeTransfer(token, p, amount);
        emit ReturnedToParent(p, amount, msg.sender);
    }

    // Payments

    /// @inheritdoc ICrestVault
    function charge(
        address controller,
        uint256 amount,
        bytes32 counterparty,
        bytes32 commitment,
        uint256 validBefore,
        bytes32 nonce
    ) external {
        address payee = payeeOf(msg.sender);
        if (payee == address(0)) revert ModuleNotEnabled();
        uint256 leaf = grantOf[controller];
        if (leaf == 0) revert NoGrant();
        if (_opens[commitment].module != address(0)) revert CommitmentOpen();
        uint128 a = _amount(amount);
        for (uint256 g = leaf; g != 0; g = _grants[g].parent) {
            _chargeOne(g, a, counterparty, true);
        }
        if (parent != address(0)) ICrestVault(parent).checkPath(parentGrant, amount, counterparty);
        _opens[commitment] = Open({grant: leaf, amount: a, module: msg.sender});
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC3009Domain(token).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        RECEIVE_WITH_AUTHORIZATION_TYPEHASH, address(this), payee, amount, uint256(0), validBefore, nonce
                    )
                )
            )
        );
        assembly {
            tstore(digest, 1)
        }
        emit Charged(leaf, commitment, msg.sender, amount, counterparty);
    }

    /// @inheritdoc ICrestVault
    function release(bytes32 commitment) external {
        Open memory o = _opens[commitment];
        if (o.module == address(0) || o.module != msg.sender) revert NotOpen();
        delete _opens[commitment];
        for (uint256 g = o.grant; g != 0; g = _grants[g].parent) {
            _grants[g].open -= 1;
        }
        emit Released(o.grant, commitment, o.amount);
    }

    /// @inheritdoc ICrestVault
    function reclaim(address module, AuthCaptureEscrow.PaymentInfo calldata paymentInfo) external {
        if (payeeOf(module) == address(0)) revert ModuleNotEnabled();
        if (paymentInfo.payer != address(this)) revert NotThePayer();
        address escrow = ICrestEscrowModule(module).escrow();
        AuthCaptureEscrow(escrow).reclaim(paymentInfo);
        emit Reclaimed(module, escrow);
    }

    /// @inheritdoc ICrestVault
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        uint256 approved;
        assembly {
            approved := tload(hash)
        }
        return approved == 1 && msg.sender == token ? ERC1271_MAGIC : ERC1271_NO;
    }

    // Views

    /// @inheritdoc ICrestVault
    function authorityOver(address who, uint256 id) public view returns (bool) {
        return who != address(0) && (_grants[id].controller == who || _above(who, id));
    }

    /// @inheritdoc ICrestVault
    function checkPath(uint256 id, uint256 amount, bytes32 counterparty) external view {
        for (uint256 g = id; g != 0; g = _grants[g].parent) {
            Grant storage x = _grants[g];
            Caps memory c = x.caps;
            _requireState(g, x, c);
            if (amount > c.perSpend) revert OverPerSpend(g);
            if (c.restricted && !allowed[g][counterparty]) revert CounterpartyNotAllowed(g);
        }
        if (parent != address(0)) ICrestVault(parent).checkPath(parentGrant, amount, counterparty);
    }

    /// @inheritdoc ICrestVault
    function checkState(uint256 id) external view {
        _requireUsable(id);
    }

    /// @inheritdoc ICrestVault
    function payeeOf(address module) public view returns (address) {
        return parent == address(0) ? _payees[module] : ICrestVault(parent).payeeOf(module);
    }

    /// @inheritdoc ICrestVault
    function getGrant(uint256 id) external view returns (Grant memory) {
        return _grants[id];
    }

    /// @inheritdoc ICrestVault
    function getOpen(bytes32 commitment) external view returns (Open memory) {
        return _opens[commitment];
    }

    // Internals

    /// @dev Whether `who` controls a grant strictly above `id` here, or has authority over this vault's parent grant
    ///      in the parent vault. A top vault's owner is above everything in it, the root included.
    function _above(address who, uint256 id) internal view returns (bool) {
        if (who == address(0)) return false;
        if (parent == address(0) && who == owner) return true;
        for (uint256 g = _grants[id].parent; g != 0; g = _grants[g].parent) {
            if (_grants[g].controller == who) return true;
        }
        return parent != address(0) && ICrestVault(parent).authorityOver(who, parentGrant);
    }

    /// @dev The caller may act for grant `id` as a delegator: its own controller when the grant may delegate, or
    ///      anyone with authority above it.
    function _requireDelegator(uint256 id, Grant storage g) internal view {
        if (msg.sender == g.controller && g.caps.mayDelegate) return;
        if (_above(msg.sender, id)) return;
        if (msg.sender == g.controller) revert MayNotDelegate();
        revert NotAuthorized();
    }

    /// @dev One grant on a payment's or a funding's path: its state and expiry, then, for a payment, the per-payment
    ///      limit, the allow list and the open count; for both, the period and total limits. Then it counts.
    function _chargeOne(uint256 id, uint128 amount, bytes32 counterparty, bool payment) internal {
        Grant storage x = _grants[id];
        Caps memory c = x.caps;
        _requireState(id, x, c);
        if (payment) {
            if (amount > c.perSpend) revert OverPerSpend(id);
            if (c.restricted && !allowed[id][counterparty]) revert CounterpartyNotAllowed(id);
            if (uint256(x.open) + 1 > c.maxOpen) revert TooManyOpen(id);
            x.open += 1;
        }
        uint40 index = uint40(block.timestamp / c.period);
        uint256 inPeriod = index == x.periodIndex ? x.inPeriod : 0;
        if (inPeriod + amount > c.perPeriod) revert OverPerPeriod(id);
        if (uint256(x.spent) + amount > c.lifetime) revert OverLifetime(id);
        (x.inPeriod, x.periodIndex) = (uint128(inPeriod + amount), index);
        x.spent += amount;
    }

    function _requireState(uint256 id, Grant storage x, Caps memory c) internal view {
        if (x.closed) revert GrantClosed(id);
        if (x.paused) revert Paused(id);
        if (c.expiresAt != 0 && block.timestamp >= c.expiresAt) revert Expired(id);
    }

    /// @dev The grant's path is open: no grant on it, here or in any ancestor vault, is closed, paused or expired.
    function _requireUsable(uint256 id) internal view {
        for (uint256 g = id; g != 0; g = _grants[g].parent) {
            Grant storage x = _grants[g];
            _requireState(g, x, x.caps);
        }
        if (parent != address(0)) ICrestVault(parent).checkState(parentGrant);
    }

    function _requireExists(uint256 id) internal view {
        if (_grants[id].controller == address(0)) revert NoGrant();
    }

    function _requireValid(Caps calldata caps) internal pure {
        if (caps.period == 0) revert InvalidCaps();
    }

    function _amount(uint256 amount) internal pure returns (uint128) {
        if (amount > type(uint128).max) revert AmountTooLarge();
        return uint128(amount);
    }
}
