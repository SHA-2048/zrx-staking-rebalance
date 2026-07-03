// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Constants} from "../constants/Constants.sol";
import {Call} from "../types/Types.sol";
import {Vm, VmSafe} from "../../lib/forge-std/src/Vm.sol";

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function nonce() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
    function approvedHashes(address owner, bytes32 hash) external view returns (uint256);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
}

interface IMultiSendCallOnly {
    function multiSend(bytes memory transactions) external payable;
}

/**
 * @title LibSafe
 * @notice Helpers for executing operations through a Safe multisig. When the
 *         caller (`staker`) is a Safe, operations are wrapped in a Safe
 *         `execTransaction` using the approved-hash flow. This lets a script be
 *         broadcast with an owner wallet instead of trying to sign as the Safe.
 */
library LibSafe {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Best-effort check whether `account` is a Safe v1.3.0 multisig.
    function isSafe(address account) internal view returns (bool) {
        if (account.code.length == 0) return false;
        (bool thresholdSuccess, bytes memory thresholdData) =
            account.staticcall(abi.encodeWithSelector(ISafe.getThreshold.selector));
        if (!thresholdSuccess || thresholdData.length == 0) return false;
        uint256 threshold = abi.decode(thresholdData, (uint256));
        if (threshold == 0) return false;

        (bool ownersSuccess, bytes memory ownersData) =
            account.staticcall(abi.encodeWithSelector(ISafe.getOwners.selector));
        if (!ownersSuccess || ownersData.length == 0) return false;
        address[] memory owners = abi.decode(ownersData, (address[]));
        return owners.length > 0;
    }

    /// @notice Execute a list of calls either directly from `staker` (EOA path)
    ///         or through a Safe `execTransaction` (Safe path). In Safe mode the
    ///         env var `SAFE_MODE` controls the phase:
    ///           - "approve": broadcast `safe.approveHash(txHash)` from the signer
    ///           - "execute" (default): broadcast `safe.execTransaction(...)` once
    ///             enough owners have approved the hash.
    ///         The signer's wallet is taken from `msg.sender`, matching Foundry's
    ///         `--private-key` / `--ledger` / `--trezor` broadcast model.
    /// @return executed True if the operation was actually executed (direct path
    ///         or Safe execute mode). False for Safe approve mode.
    function executeCalls(address staker, Call[] storage calls) internal returns (bool executed) {
        if (isSafe(staker)) {
            return _executeCallsViaSafe(staker, calls);
        } else {
            _executeCallsDirectly(staker, calls);
            return true;
        }
    }

    function _executeCallsDirectly(address staker, Call[] storage calls) private {
        bool isScript = VM.isContext(VmSafe.ForgeContext.ScriptGroup);
        if (isScript) {
            _startBroadcastFrom(staker);
        } else {
            VM.startPrank(staker);
        }
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            require(success, "LibSafe: direct call failed");
        }
        if (isScript) {
            VM.stopBroadcast();
        } else {
            VM.stopPrank();
        }
    }

    function _executeCallsViaSafe(address safe, Call[] storage calls)
        private
        returns (bool executed)
    {
        bytes memory safeData = _encodeMultiSend(calls);
        bytes memory execData =
            abi.encodeWithSelector(IMultiSendCallOnly.multiSend.selector, safeData);

        bytes32 txHash = _getSafeTxHash(safe, execData);

        bool isScript = VM.isContext(VmSafe.ForgeContext.ScriptGroup);
        bool isScriptDryRun = VM.isContext(VmSafe.ForgeContext.ScriptDryRun);
        address[] memory owners = ISafe(safe).getOwners();
        uint256 threshold = ISafe(safe).getThreshold();

        if (!isScript || isScriptDryRun) {
            // Tests and dry-run simulations run the full Safe flow locally.
            // Broadcast/resume still require real on-chain owner approvals.
            _approveHashFromOwners(safe, owners, txHash);
        } else {
            // Production mode: the signer only broadcasts one phase at a time.
            string memory safeMode = _safeMode();
            if (_eq(safeMode, "approve")) {
                address signer = _broadcastSigner(msg.sender);
                require(_isOwner(safe, signer), "LibSafe: signer is not a Safe owner");
                _startBroadcastFrom(signer);
                ISafe(safe).approveHash(txHash);
                VM.stopBroadcast();
                return false;
            }
            require(_eq(safeMode, "execute"), "LibSafe: unknown SAFE_MODE");
        }

        bytes memory signatures = _buildApprovedHashSignatures(safe, owners, txHash);
        require(
            signatures.length / 65 >= threshold,
            "LibSafe: insufficient approvals; run with SAFE_MODE=approve first"
        );

        _execSafeTransaction(safe, execData, signatures, isScript ? address(0) : owners[0]);
        return true;
    }

    function _getSafeTxHash(address safe, bytes memory execData) private view returns (bytes32) {
        return ISafe(safe)
            .getTransactionHash(
                Constants.SAFE_MULTISEND_CALL_ONLY,
                0,
                execData,
                1, // DelegateCall
                0,
                0,
                0,
                address(0),
                address(0),
                ISafe(safe).nonce()
            );
    }

    function _approveHashFromOwners(address safe, address[] memory owners, bytes32 txHash) private {
        for (uint256 i = 0; i < owners.length; i++) {
            if (ISafe(safe).approvedHashes(owners[i], txHash) == 0) {
                VM.startPrank(owners[i]);
                ISafe(safe).approveHash(txHash);
                VM.stopPrank();
            }
        }
    }

    function _execSafeTransaction(
        address safe,
        bytes memory execData,
        bytes memory signatures,
        address caller
    ) private {
        if (caller == address(0)) {
            _startBroadcast();
        } else {
            VM.startPrank(caller);
        }
        (bool success, bytes memory result) = safe.call(
            abi.encodeWithSelector(
                ISafe.execTransaction.selector,
                Constants.SAFE_MULTISEND_CALL_ONLY,
                0,
                execData,
                1, // DelegateCall
                0,
                0,
                0,
                address(0),
                address(0),
                signatures
            )
        );
        require(success, "LibSafe: Safe execution failed");
        require(abi.decode(result, (bool)), "LibSafe: Safe transaction returned false");
        if (caller == address(0)) {
            VM.stopBroadcast();
        } else {
            VM.stopPrank();
        }
    }

    /// @notice Encode a list of calls into the MultiSendCallOnly transaction format.
    function _encodeMultiSend(Call[] storage calls)
        private
        view
        returns (bytes memory transactions)
    {
        for (uint256 i = 0; i < calls.length; i++) {
            transactions = abi.encodePacked(
                transactions,
                uint8(0), // operation: Call
                calls[i].target,
                calls[i].value,
                uint256(calls[i].data.length),
                calls[i].data
            );
        }
    }

    /// @notice Build the concatenated approved-hash signatures for every owner
    ///         that has already approved `txHash` on-chain. Signatures are sorted
    ///         by owner address ascending, as required by Safe signature verification.
    function _buildApprovedHashSignatures(address safe, address[] memory owners, bytes32 txHash)
        private
        view
        returns (bytes memory signatures)
    {
        address[] memory approved = new address[](owners.length);
        uint256 approvedCount = 0;
        for (uint256 i = 0; i < owners.length; i++) {
            if (ISafe(safe).approvedHashes(owners[i], txHash) > 0) {
                approved[approvedCount++] = owners[i];
            }
        }

        _sortAddressesAscending(approved, approvedCount);

        for (uint256 i = 0; i < approvedCount; i++) {
            signatures = abi.encodePacked(
                signatures, bytes32(uint256(uint160(approved[i]))), bytes32(0), uint8(1)
            );
        }
    }

    function _sortAddressesAscending(address[] memory addrs, uint256 count) private pure {
        for (uint256 i = 1; i < count; i++) {
            address key = addrs[i];
            uint256 j = i;
            while (j > 0 && uint160(addrs[j - 1]) > uint160(key)) {
                addrs[j] = addrs[j - 1];
                j--;
            }
            addrs[j] = key;
        }
    }

    function _isOwner(address safe, address account) private view returns (bool) {
        address[] memory owners = ISafe(safe).getOwners();
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == account) return true;
        }
        return false;
    }

    function _startBroadcastFrom(address expectedSigner) private {
        if (VM.envExists("PRIVATE_KEY")) {
            uint256 privateKey = VM.envUint("PRIVATE_KEY");
            require(VM.addr(privateKey) == expectedSigner, "LibSafe: PRIVATE_KEY signer mismatch");
            VM.startBroadcast(privateKey);
        } else {
            VM.startBroadcast(expectedSigner);
        }
    }

    function _startBroadcast() private {
        if (VM.envExists("PRIVATE_KEY")) {
            VM.startBroadcast(VM.envUint("PRIVATE_KEY"));
        } else {
            VM.startBroadcast(msg.sender);
        }
    }

    function _broadcastSigner(address fallbackSigner) private view returns (address) {
        if (VM.envExists("PRIVATE_KEY")) {
            return VM.addr(VM.envUint("PRIVATE_KEY"));
        }
        return fallbackSigner;
    }

    function _safeMode() private view returns (string memory) {
        return VM.envOr("SAFE_MODE", string("execute"));
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
