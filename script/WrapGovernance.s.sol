// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Constants} from "../src/constants/Constants.sol";
import {LibStaking} from "../src/libraries/LibStaking.sol";
import {LibSafe} from "../src/libraries/LibSafe.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IwZRX} from "../src/interfaces/IwZRX.sol";
import {IStakingProxy} from "../src/interfaces/IStakingProxy.sol";
import {WrapGovernanceMode, Delegation, WrapState, Call} from "../src/types/Types.sol";

/**
 * @title WrapGovernance
 * @notice Wraps ZRX into the wZRX governance token and delegates voting power.
 */
contract WrapGovernance is Script {
    uint8 internal constant UNDELEGATED = 0;

    // Storage array lets the script build the operation in a flat, readable way
    // without running into stack-depth limits.
    Call[] internal _calls;

    /// @notice Wrap ZRX according to the selected mode.
    /// @param mode Operation mode (unstake, full, liquid, exclude-pools).
    /// @param staker Staker address; pass address(0) to use the default staker.
    /// @param delegatee wZRX delegatee; pass address(0) to use the default delegatee.
    /// @param excludePoolsCsv Comma-separated pool ids to exclude from wrapping.
    ///                        Empty string uses defaultTargetPools().
    function run(
        WrapGovernanceMode mode,
        address staker,
        address delegatee,
        string memory excludePoolsCsv
    ) external {
        if (staker == address(0)) staker = Constants.DEFAULT_STAKER;
        if (delegatee == address(0)) delegatee = Constants.DEFAULT_DELEGATEE;
        require(staker != address(0), "Invalid staker");
        require(delegatee != address(0), "Invalid delegatee");
        bytes32[] memory excludePoolIds = LibStaking.parsePools(excludePoolsCsv);

        if (mode == WrapGovernanceMode.Unstake) {
            _unstake(staker);
        } else if (mode == WrapGovernanceMode.Liquid) {
            _wrapLiquid(staker, delegatee);
        } else if (mode == WrapGovernanceMode.Full) {
            _wrapFull(staker, delegatee);
        } else {
            _wrapExcludePools(staker, delegatee, excludePoolIds);
        }

        console2.log("WrapGovernance done");
    }

    function _unstake(address staker) private {
        IStakingProxy staking = IStakingProxy(Constants.STAKING_PROXY);
        uint256 unstakeAmount =
            staking.getOwnerStakeByStatus(staker, UNDELEGATED).currentEpochBalance;
        require(unstakeAmount > 0, "no undelegated stake");

        uint256 zrxBefore = IERC20(Constants.ZRX_TOKEN).balanceOf(staker);

        delete _calls;
        _calls.push(
            Call({
                target: Constants.STAKING_PROXY,
                value: 0,
                data: abi.encodeWithSelector(IStakingProxy.unstake.selector, unstakeAmount)
            })
        );
        bool executed = LibSafe.executeCalls(staker, _calls);

        if (executed) {
            require(
                IERC20(Constants.ZRX_TOKEN).balanceOf(staker) - zrxBefore == unstakeAmount,
                "WrapGovernance: unstake did not increase ZRX balance"
            );
        }
    }

    function _readWrapState(address staker) private view returns (WrapState memory state) {
        IwZRX wzrx = IwZRX(Constants.WZRX_TOKEN);
        state.wzrxBefore = wzrx.balanceOf(staker);
        state.delegateeBefore = wzrx.delegates(staker);
    }

    function _wrapLiquid(address staker, address delegatee) private {
        WrapState memory state = _readWrapState(staker);
        uint256 wrapAmount = IERC20(Constants.ZRX_TOKEN).balanceOf(staker);
        require(wrapAmount > 0, "no liquid ZRX");

        delete _calls;
        _pushWrapDelegateCalls(staker, delegatee, wrapAmount);

        bool executed = LibSafe.executeCalls(staker, _calls);
        if (executed) {
            _verifyWrap(staker, delegatee, wrapAmount, state.wzrxBefore);
        }
    }

    function _wrapFull(address staker, address delegatee) private {
        (Delegation[] memory delegations, uint256 totalDelegated) =
            LibStaking.getActiveDelegations(Constants.STAKING_PROXY, staker);
        require(delegations.length > 0, "no delegated stake");
        require(totalDelegated > 0, "no delegated stake");

        WrapState memory state = _readWrapState(staker);

        _ensureEpochEnded();

        delete _calls;
        _calls.push(
            Call({
                target: Constants.STAKING_PROXY,
                value: 0,
                data: abi.encodeWithSelector(
                    IStakingProxy.batchExecute.selector, _buildUndelegateCalls(delegations)
                )
            })
        );
        _calls.push(
            Call({
                target: Constants.STAKING_PROXY,
                value: 0,
                data: abi.encodeWithSelector(IStakingProxy.endEpoch.selector)
            })
        );
        _calls.push(
            Call({
                target: Constants.STAKING_PROXY,
                value: 0,
                data: abi.encodeWithSelector(IStakingProxy.unstake.selector, totalDelegated)
            })
        );
        _pushWrapDelegateCalls(staker, delegatee, totalDelegated);

        bool executed = LibSafe.executeCalls(staker, _calls);
        if (executed) {
            _verifyWrap(staker, delegatee, totalDelegated, state.wzrxBefore);
            _verifyActiveDelegation(staker, 0, "WrapGovernance: full wrap left active delegations");
        }
    }

    function _wrapExcludePools(address staker, address delegatee, bytes32[] memory excludePoolIds)
        private
    {
        (Delegation[] memory delegations, uint256 totalDelegated) =
            LibStaking.getActiveDelegations(Constants.STAKING_PROXY, staker);
        require(totalDelegated > 0, "no delegated stake");

        uint256 excludedTotal = 0;
        for (uint256 i = 0; i < delegations.length; i++) {
            if (_isExcluded(delegations[i].poolId, excludePoolIds)) {
                excludedTotal += delegations[i].amount;
            }
        }
        uint256 wrapAmount = totalDelegated - excludedTotal;
        require(wrapAmount > 0, "no stake to wrap");

        WrapState memory state = _readWrapState(staker);

        _ensureEpochEnded();

        delete _calls;
        _calls.push(
            Call({
                target: Constants.STAKING_PROXY,
                value: 0,
                data: abi.encodeWithSelector(
                    IStakingProxy.batchExecute.selector,
                    _buildExcludeUndelegateCalls(delegations, excludePoolIds, wrapAmount)
                )
            })
        );
        _calls.push(
            Call({
                target: Constants.STAKING_PROXY,
                value: 0,
                data: abi.encodeWithSelector(IStakingProxy.endEpoch.selector)
            })
        );
        _calls.push(
            Call({
                target: Constants.STAKING_PROXY,
                value: 0,
                data: abi.encodeWithSelector(IStakingProxy.unstake.selector, wrapAmount)
            })
        );
        _pushWrapDelegateCalls(staker, delegatee, wrapAmount);

        bool executed = LibSafe.executeCalls(staker, _calls);
        if (executed) {
            _verifyWrap(staker, delegatee, wrapAmount, state.wzrxBefore);
            _verifyActiveDelegation(
                staker,
                totalDelegated - wrapAmount,
                "WrapGovernance: exclude-pools delegation mismatch"
            );
        }
    }

    /// @notice Append the approve/depositFor/delegate/reset-approval sequence to `_calls`.
    function _pushWrapDelegateCalls(address staker, address delegatee, uint256 amount) private {
        _calls.push(
            Call({
                target: Constants.ZRX_TOKEN,
                value: 0,
                data: abi.encodeWithSelector(IERC20.approve.selector, Constants.WZRX_TOKEN, amount)
            })
        );
        _calls.push(
            Call({
                target: Constants.WZRX_TOKEN,
                value: 0,
                data: abi.encodeWithSelector(IwZRX.depositFor.selector, staker, amount)
            })
        );
        _calls.push(
            Call({
                target: Constants.WZRX_TOKEN,
                value: 0,
                data: abi.encodeWithSelector(IwZRX.delegate.selector, delegatee)
            })
        );
        _calls.push(
            Call({
                target: Constants.ZRX_TOKEN,
                value: 0,
                data: abi.encodeWithSelector(IERC20.approve.selector, Constants.WZRX_TOKEN, 0)
            })
        );
    }

    function _ensureEpochEnded() private {
        IStakingProxy stake = IStakingProxy(Constants.STAKING_PROXY);
        uint256 epochEndTime = stake.currentEpochStartTimeInSeconds() + stake.epochDurationInSeconds();
        if (vm.isContext(VmSafe.ForgeContext.ScriptGroup)) {
            // forge-lint: disable-next-item(block-timestamp)
            // Production scripts must gate endEpoch() on the real chain timestamp.
            require(block.timestamp > epochEndTime, "WrapGovernance: epoch not ended");
        } else {
            vm.warp(epochEndTime + 1);
        }
    }

    function _verifyWrap(
        address staker,
        address expectedDelegatee,
        uint256 expectedIncrease,
        uint256 wzrxBefore
    ) private view {
        IwZRX wzrx = IwZRX(Constants.WZRX_TOKEN);
        uint256 wzrxAfter = wzrx.balanceOf(staker);
        require(
            wzrxAfter - wzrxBefore == expectedIncrease,
            "WrapGovernance: wZRX balance increase mismatch"
        );
        require(wzrx.delegates(staker) == expectedDelegatee, "WrapGovernance: delegatee mismatch");
        // ZRX approval should always be reset to 0.
        require(
            IERC20(Constants.ZRX_TOKEN).allowance(staker, Constants.WZRX_TOKEN) == 0,
            "WrapGovernance: ZRX allowance not reset"
        );
    }

    function _verifyActiveDelegation(address staker, uint256 expectedTotal, string memory message)
        private
        view
    {
        (, uint256 activeTotal) = LibStaking.getActiveDelegations(Constants.STAKING_PROXY, staker);
        require(activeTotal == expectedTotal, message);
    }

    function _buildUndelegateCalls(Delegation[] memory delegations)
        private
        pure
        returns (bytes[] memory calls)
    {
        calls = new bytes[](delegations.length);
        for (uint256 i = 0; i < delegations.length; i++) {
            calls[i] = LibStaking.encodeUndelegate(delegations[i].poolId, delegations[i].amount);
        }
    }

    function _buildExcludeUndelegateCalls(
        Delegation[] memory delegations,
        bytes32[] memory excludePoolIds,
        uint256 amount
    ) private pure returns (bytes[] memory calls) {
        uint256 sourceCount = 0;
        uint256 sourceTotal = 0;
        for (uint256 i = 0; i < delegations.length; i++) {
            if (!_isExcluded(delegations[i].poolId, excludePoolIds)) {
                sourceCount++;
                sourceTotal += delegations[i].amount;
            }
        }
        require(sourceCount > 0, "no source pools");
        require(amount <= sourceTotal, "amount exceeds source stake");

        Delegation[] memory sources = new Delegation[](sourceCount);
        uint256 idx = 0;
        uint256[] memory weights = new uint256[](sourceCount);
        for (uint256 i = 0; i < delegations.length; i++) {
            if (!_isExcluded(delegations[i].poolId, excludePoolIds)) {
                sources[idx] = delegations[i];
                weights[idx] = delegations[i].amount;
                idx++;
            }
        }

        uint256[] memory undelegateAmounts = LibStaking.splitByWeights(amount, weights);
        calls = new bytes[](sourceCount);
        for (uint256 i = 0; i < sourceCount; i++) {
            calls[i] = LibStaking.encodeUndelegate(sources[i].poolId, undelegateAmounts[i]);
        }
    }

    function _isExcluded(bytes32 poolId, bytes32[] memory excludePoolIds)
        private
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < excludePoolIds.length; i++) {
            if (poolId == excludePoolIds[i]) return true;
        }
        return false;
    }
}
