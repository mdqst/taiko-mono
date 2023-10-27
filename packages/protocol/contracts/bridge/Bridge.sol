// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/
pragma solidity ^0.8.20;

import { EssentialContract } from "../common/EssentialContract.sol";
import { Proxied } from "../common/Proxied.sol";
import { ISignalService } from "../signal/ISignalService.sol";
import { LibAddress } from "../libs/LibAddress.sol";

import { EtherVault } from "./EtherVault.sol";
import { IBridge, IRecallableSender } from "./IBridge.sol";

/// @title Bridge
/// @notice See the documentation for {IBridge}.
/// @dev The code hash for the same address on L1 and L2 may be different.
contract Bridge is EssentialContract, IBridge {
    using LibAddress for address;
    using LibAddress for address payable;

    enum Status {
        NEW,
        RETRIABLE,
        DONE,
        FAILED
    }

    bytes32 internal constant MESSAGE_HASH_PLACEHOLDER = bytes32(uint256(1));
    uint256 internal constant CHAINID_PLACEHOLDER = type(uint256).max;
    address internal constant SRC_CHAIN_SENDER_PLACEHOLDER =
        address(uint160(uint256(1)));

    uint128 public nextMessageId; // slot 1
    mapping(bytes32 msgHash => bool recalled) public isMessageRecalled;
    mapping(bytes32 msgHash => Status) public messageStatus; // slot 3
    Context private _ctx; // // slot 4,5,6pnpm
    uint256[44] private __gap;

    event SignalSent(address indexed sender, bytes32 msgHash);
    event MessageSent(bytes32 indexed msgHash, Message message);
    event MessageRecalled(bytes32 indexed msgHash);
    event DestChainEnabled(uint256 indexed chainId, bool enabled);
    event MessageStatusChanged(bytes32 indexed msgHash, Status status);

    error B_INVALID_CHAINID();
    error B_INVALID_CONTEXT();
    error B_INVALID_GAS_LIMIT();
    error B_INVALID_SIGNAL();
    error B_INVALID_USER();
    error B_INVALID_VALUE();
    error B_NON_RETRIABLE();
    error B_NOT_FAILED();
    error B_NOT_RECEIVED();
    error B_PERMISSION_DENIED();
    error B_RECALLED_ALREADY();
    error B_STATUS_MISMATCH();

    modifier sameChain(uint256 chainId) {
        if (chainId != block.chainid) revert B_INVALID_CHAINID();
        _;
    }

    /// @dev Vaults will transfer Ether to this Bridge before these Ether are
    /// sent to users.
    receive() external payable { }

    /// @notice Initializes the contract.
    /// @param _addressManager The address of the {AddressManager} contract.
    function init(address _addressManager) external initializer {
        EssentialContract._init(_addressManager);
    }

    /// @notice Sends a message to the destination chain and takes custody
    /// of Ether required in this contract. All extra Ether will be refunded.
    /// @inheritdoc IBridge
    function sendMessage(Message calldata message)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 msgHash, Message memory _message)
    {
        // Ensure the message user is not null.
        if (message.user == address(0)) revert B_INVALID_USER();

        // Check if the destination chain is enabled.
        (bool destChainEnabled,) = isDestChainEnabled(message.destChainId);

        // Verify destination chain and to address.
        if (!destChainEnabled) revert B_INVALID_CHAINID();
        if (message.destChainId == block.chainid) {
            revert B_INVALID_CHAINID();
        }

        // Ensure the sent value matches the expected amount.
        uint256 expectedAmount = message.value + message.fee;
        if (expectedAmount != msg.value) revert B_INVALID_VALUE();

        resolve("ether_vault", false).sendEther(expectedAmount);

        _message = message;
        // Configure message details and send signal to indicate message
        // sending.
        _message.id = nextMessageId++;
        _message.from = msg.sender;
        _message.srcChainId = block.chainid;

        msgHash = keccak256(abi.encode(_message));

        ISignalService(resolve("signal_service", false)).sendSignal(msgHash);
        emit MessageSent(msgHash, _message);
    }

    /// @notice Recalls a failed message on its source chain, releasing
    /// associated assets.
    /// @dev This function checks if the message failed on the source chain and
    /// releases associated Ether or tokens.
    /// @param message The message whose associated Ether should be released.
    /// @param proof The merkle inclusion proof.
    function recallMessage(
        Message calldata message,
        bytes calldata proof
    )
        external
        nonReentrant
        whenNotPaused
        sameChain(message.srcChainId)
    {
        bytes32 msgHash = keccak256(abi.encode(message));
        if (isMessageRecalled[msgHash]) revert B_RECALLED_ALREADY();

        bool received = _proveSignalReceived(
            _signalForFailedMessage(msgHash), message.destChainId, proof
        );
        if (!received) revert B_NOT_FAILED();

        isMessageRecalled[msgHash] = true;

        // Release necessary Ether from EtherVault.
        EtherVault(resolve("ether_vault", false)).releaseEther(
            address(this), message.value
        );

        // Execute the recall logic based on the contract's support for the
        // IRecallableSender interface
        bool support =
            message.from.supportsInterface(type(IRecallableSender).interfaceId);
        if (support) {
            IRecallableSender(message.from).onMessageRecalled{
                value: message.value
            }(message, msgHash);
        } else {
            message.user.sendEther(message.value);
        }

        emit MessageRecalled(msgHash);
    }

    /// @notice Processes a bridge message on the destination chain. This
    /// function is callable by any address, including the `message.user`.
    /// @dev The process begins by hashing the message and checking the message
    /// status in the bridge  If the status is "NEW", custody of Ether is
    /// taken from the EtherVault, and the message is invoked. The status is
    /// updated accordingly, and processing fees are refunded as needed.
    /// @param message The message to be processed.
    /// @param proof The merkle inclusion proof.
    function processMessage(
        Message calldata message,
        bytes calldata proof
    )
        external
        nonReentrant
        whenNotPaused
        sameChain(message.destChainId)
    {
        // If the gas limit is set to zero, only the user can process the
        // message.
        if (message.gasLimit == 0 && msg.sender != message.user) {
            revert B_PERMISSION_DENIED();
        }

        bytes32 msgHash = keccak256(abi.encode(message));
        if (messageStatus[msgHash] != Status.NEW) revert B_STATUS_MISMATCH();

        bool received = _proveSignalReceived(msgHash, message.srcChainId, proof);
        if (!received) revert B_NOT_RECEIVED();

        address payable ethVault = resolve("ether_vault", false);
        EtherVault(ethVault).releaseEther(
            address(this), message.value + message.fee
        );

        Status status;
        uint256 refundAmount;

        // Process message differently based on the target address
        if (
            message.to == address(0) || message.to == address(this)
                || message.to == ethVault || message.to == resolve("taiko", true)
        ) {
            // Handle special addresses that don't require actual invocation but
            // mark message as DONE
            status = Status.DONE;
            refundAmount = message.value;
        } else {
            // Use the specified message gas limit if called by the user, else
            // use remaining gas
            uint256 gasLimit =
                msg.sender == message.user ? gasleft() : message.gasLimit;

            if (_invokeMessageCall(message, msgHash, gasLimit)) {
                status = Status.DONE;
            } else {
                status = Status.RETRIABLE;
                ethVault.sendEther(message.value);
            }
        }

        // Update the message status
        _updateMessageStatus(msgHash, status);

        // Determine the refund recipient
        address refundTo =
            message.refundTo == address(0) ? message.user : message.refundTo;

        // Refund the processing fee
        if (msg.sender == refundTo) {
            refundTo.sendEther(message.fee + refundAmount);
        } else {
            // If sender is another address, reward it and refund the rest
            msg.sender.sendEther(message.fee);
            refundTo.sendEther(refundAmount);
        }
    }

    /// @notice Retries to invoke the messageCall after releasing associated
    /// Ether and tokens.
    /// @dev This function can be called by any address, including the
    /// `message.user`.
    /// It attempts to invoke the messageCall and updates the message status
    /// accordingly.
    /// @param message The message to retry.
    /// @param isLastAttempt Specifies if this is the last attempt to retry the
    /// message.
    function retryMessage(
        Message calldata message,
        bool isLastAttempt
    )
        external
        nonReentrant
        whenNotPaused
        sameChain(message.destChainId)
    {
        // If the gasLimit is set to 0 or isLastAttempt is true, the caller must
        // be the message.user.
        if (message.gasLimit == 0 || isLastAttempt) {
            if (msg.sender != message.user) revert B_PERMISSION_DENIED();
        }

        bytes32 msgHash = keccak256(abi.encode(message));
        if (messageStatus[msgHash] != Status.RETRIABLE) {
            revert B_NON_RETRIABLE();
        }

        address payable ethVault = resolve("ether_vault", false);
        EtherVault(ethVault).releaseEther(address(this), message.value);

        // Attempt to invoke the messageCall.
        if (_invokeMessageCall(message, msgHash, gasleft())) {
            // Update the message status to "DONE" on successful invocation.
            _updateMessageStatus(msgHash, Status.DONE);
        } else {
            // Update the message status to "FAILED"
            _updateMessageStatus(msgHash, Status.FAILED);
            // Release Ether back to EtherVault (if on Taiko it is OK)
            // otherwise funds stay at Bridge anyways.
            ethVault.sendEther(message.value);
        }
    }

    /// @notice Checks if the message was sent.
    /// @param message The message.
    /// @return True if the message was sent.
    function isMessageSent(Message calldata message)
        public
        view
        returns (bool)
    {
        if (message.srcChainId != block.chainid) return false;
        return ISignalService(resolve("signal_service", false)).isSignalSent({
            app: address(this),
            signal: keccak256(abi.encode(message))
        });
    }

    /// @notice Checks if a msgHash has failed on its destination chain.
    /// @param message The message.
    /// @param proof The merkle inclusion proof.
    /// @return Returns true if the message has failed, false otherwise.
    function proveMessageFailed(
        Message calldata message,
        bytes calldata proof
    )
        public
        view
        returns (bool)
    {
        if (message.srcChainId != block.chainid) return false;
        return _proveSignalReceived(
            _signalForFailedMessage(keccak256(abi.encode(message))),
            message.destChainId,
            proof
        );
    }

    /// @notice Checks if a msgHash has failed on its destination chain.
    /// @param message The message.
    /// @param proof The merkle inclusion proof.
    /// @return Returns true if the message has failed, false otherwise.
    function proveMessageReceived(
        Message calldata message,
        bytes calldata proof
    )
        public
        view
        returns (bool)
    {
        if (message.destChainId != block.chainid) return false;
        return _proveSignalReceived(
            keccak256(abi.encode(message)), message.srcChainId, proof
        );
    }

    /// @notice Checks if the destination chain is enabled.
    /// @param chainId The destination chain ID.
    /// @return enabled True if the destination chain is enabled.
    /// @return destBridge The bridge of the destination chain.
    function isDestChainEnabled(uint256 chainId)
        public
        view
        returns (bool enabled, address destBridge)
    {
        destBridge = resolve(chainId, "bridge", true);
        enabled = destBridge != address(0);
    }

    /// @notice Gets the current context.
    /// @inheritdoc IBridge
    function context() public view returns (Context memory) {
        if (_ctx.msgHash == 0 || _ctx.msgHash == MESSAGE_HASH_PLACEHOLDER) {
            revert B_INVALID_CONTEXT();
        }
        return _ctx;
    }

    /// @notice Invokes a call message on the Bridge.
    /// @param message The call message to be invoked.
    /// @param msgHash The hash of the message.
    /// @param gasLimit The gas limit for the message call.
    /// @return success A boolean value indicating whether the message call was
    /// successful.
    /// @dev This function updates the context in the state before and after the
    /// message call.
    function _invokeMessageCall(
        Message calldata message,
        bytes32 msgHash,
        uint256 gasLimit
    )
        private
        returns (bool success)
    {
        if (gasLimit == 0) revert B_INVALID_GAS_LIMIT();

        // Update the context for the message call
        // Should we simply provide the message itself rather than
        // a context object?
        _ctx = Context({
            msgHash: msgHash,
            from: message.from,
            srcChainId: message.srcChainId
        });

        // Perform the message call and capture the success value
        (success,) =
            message.to.call{ value: message.value, gas: gasLimit }(message.data);

        // Reset the context after the message call
        _ctx = Context({
            msgHash: MESSAGE_HASH_PLACEHOLDER,
            from: SRC_CHAIN_SENDER_PLACEHOLDER,
            srcChainId: CHAINID_PLACEHOLDER
        });
    }

    /// @notice Updates the status of a bridge message.
    /// @dev If the new status is different from the current status in the
    /// mapping, the status is updated and an event is emitted.
    /// @param msgHash The hash of the message.
    /// @param status The new status of the message.
    function _updateMessageStatus(bytes32 msgHash, Status status) private {
        if (messageStatus[msgHash] == status) return;

        messageStatus[msgHash] = status;
        emit MessageStatusChanged(msgHash, status);

        if (status != Status.FAILED) return;

        ISignalService(resolve("signal_service", false)).sendSignal(
            _signalForFailedMessage(msgHash)
        );
    }

    /// @notice Checks if the signal was received.
    /// @param signal The signal.
    /// @param srcChainId The ID of the source chain.
    /// @param proof The merkle inclusion proof.
    /// @return True if the message was received.
    function _proveSignalReceived(
        bytes32 signal,
        uint256 srcChainId,
        bytes calldata proof
    )
        private
        view
        returns (bool)
    {
        return ISignalService(resolve("signal_service", false))
            .proveSignalReceived({
            srcChainId: srcChainId,
            app: resolve(srcChainId, "bridge", false),
            signal: signal,
            proof: proof
        });
    }

    function _signalForFailedMessage(bytes32 msgHash)
        private
        pure
        returns (bytes32)
    {
        return msgHash ^ bytes32(uint256(Status.FAILED));
    }
}

/// @title ProxiedBridge
/// @notice Proxied version of the parent contract.
contract ProxiedBridge is Proxied, Bridge { }
