// SPDX-FileCopyrightText: 2021 ShardLabs
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IValidatorShare.sol";
import "./interfaces/INodeOperatorRegistry.sol";
import "./interfaces/IStMATIC.sol";

/// @title NodeOperatorRegistry
/// @author 2021 ShardLabs.
/// @notice NodeOperatorRegistry is the main contract that manage operators.
contract NodeOperatorRegistry is
    INodeOperatorRegistry,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    /// @notice stakeManager interface.
    IStakeManager public stakeManager;

    /// @notice stMatic interface.
    IStMATIC public stMATIC;

    /// @notice all the roles.
    bytes32 public constant DAO_ROLE = keccak256("LIDO_DAO");
    bytes32 public constant PAUSE_ROLE = keccak256("LIDO_PAUSE_OPERATOR");
    bytes32 public constant ADD_NODE_OPERATOR_ROLE = keccak256("ADD_NODE_OPERATOR_ROLE");
    bytes32 public constant REMOVE_NODE_OPERATOR_ROLE = keccak256("REMOVE_NODE_OPERATOR_ROLE");


    /// @notice The min amount to recognize the system as balanced.
    uint256 public DISTANCE_THRESHOLD;

    /// @notice The maximum percentage withdraw per system rebalance.
    uint256 public MAX_WITHDRAW_PERCENTAGE_PER_REBALANCE;

    /// @notice Allows to increse the number of validators to request withdraw from
    /// when the system is balanced.
    uint8 public MIN_REQUEST_WITHDRAW_RANGE;

    /// @notice the default commission rate for operators.
    uint8 public DEFAULT_COMMISSION_RATE;

    /// @notice all the validators ids.
    uint256[] public validatorIds;

    /// @notice Mapping of all owners with node operator id. Mapping is used to be able to
    /// extend the struct.
    mapping(uint256 => address) public validatorIdToRewardAddress;

    /// @notice Mapping of validator reward address to validator Id. Mapping is used to be able to
    /// extend the struct.
    mapping(address => uint256) public validatorRewardAddressToId;

    /// @notice Check if the msg.sender has permission.
    /// @param _role role needed to call function.
    modifier userHasRole(bytes32 _role) {
        require(hasRole(_role, msg.sender), "Unauthorized");
        _;
    }

    /// @notice Initialize the NodeOperatorRegistry contract.
    function initialize(
        IStakeManager _stakeManager,
        IStMATIC _stMATIC,
        address _dao
    ) external initializer {
        __Pausable_init();
        __AccessControl_init();

        stakeManager = _stakeManager;
        stMATIC = _stMATIC;

        DISTANCE_THRESHOLD = 100;
        MAX_WITHDRAW_PERCENTAGE_PER_REBALANCE = 20;
        DEFAULT_COMMISSION_RATE = 5;
        MIN_REQUEST_WITHDRAW_RANGE = 15;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(PAUSE_ROLE, msg.sender);
        _setupRole(DAO_ROLE, _dao);
        _setupRole(PAUSE_ROLE, _dao);
        _setupRole(ADD_NODE_OPERATOR_ROLE, _dao);
        _setupRole(REMOVE_NODE_OPERATOR_ROLE, _dao);
    }

    /// @notice Add a new node operator to the system.
    /// ONLY DAO can execute this function.
    /// @param _validatorId the validator id on stakeManager.
    /// @param _rewardAddress the reward address.
    function addNodeOperator(uint256 _validatorId, address _rewardAddress)
        external
        override
        userHasRole(ADD_NODE_OPERATOR_ROLE)
    {
        require(_validatorId != 0, "ValidatorId=0");
        require(
            validatorIdToRewardAddress[_validatorId] == address(0),
            "Validator exists"
        );
        require(
            validatorRewardAddressToId[_rewardAddress] == 0,
            "Reward Address already used"
        );
        require(_rewardAddress != address(0), "Invalid reward address");

        IStakeManager.Validator memory validator = stakeManager.validators(
            _validatorId
        );

        require(
            validator.status == IStakeManager.Status.Active &&
                validator.deactivationEpoch == 0,
            "Validator isn't ACTIVE"
        );

        require(
            validator.contractAddress != address(0),
            "Validator has no ValidatorShare"
        );

        require(
            IValidatorShare(validator.contractAddress).delegation(),
            "Delegation is disabled"
        );

        validatorIdToRewardAddress[_validatorId] = _rewardAddress;
        validatorRewardAddressToId[_rewardAddress] = _validatorId;
        validatorIds.push(_validatorId);

        emit AddNodeOperator(_validatorId, _rewardAddress);
    }

    /// @notice Exit the node operator registry
    /// ONLY the owner of the node operator can call this function
    function exitNodeOperatorRegistry() external override {
        uint256 validatorId = validatorRewardAddressToId[msg.sender];
        address rewardAddress = validatorIdToRewardAddress[validatorId];
        require(rewardAddress == msg.sender, "Unauthorized");

        IStakeManager.Validator memory validator = stakeManager.validators(
            validatorId
        );
        _removeOperator(validatorId, validator.contractAddress, rewardAddress);
        emit ExitNodeOperator(validatorId, rewardAddress);
    }

    /// @notice Remove a node operator from the system and withdraw total delegated tokens to it.
    /// ONLY DAO can execute this function.
    /// withdraw delegated tokens from it.
    /// @param _validatorId the validator id on stakeManager.
    function removeNodeOperator(uint256 _validatorId)
        external
        override
        userHasRole(REMOVE_NODE_OPERATOR_ROLE)
    {
        address rewardAddress = validatorIdToRewardAddress[_validatorId];
        require(rewardAddress != address(0), "Validator doesn't exist");

        IStakeManager.Validator memory validator = stakeManager.validators(
            _validatorId
        );

        _removeOperator(_validatorId, validator.contractAddress, rewardAddress);

        emit RemoveNodeOperator(_validatorId, rewardAddress);
    }

    /// @notice Remove a node operator from the system if it fails to meet certain conditions.
    /// If the Node Operator is either Unstaked or Ejected.
    /// @param _validatorId the validator id on stakeManager.
    function removeInvalidNodeOperator(uint256 _validatorId)
        external
        override
        whenNotPaused
    {
        address rewardAddress = validatorIdToRewardAddress[_validatorId];
        require(rewardAddress != address(0), "Validator doesn't exist");

        (
            NodeOperatorRegistryStatus operatorStatus,
            IStakeManager.Validator memory validator
        ) = _getOperatorStatusAndValidator(_validatorId);

        require(
            operatorStatus == NodeOperatorRegistryStatus.UNSTAKED ||
                operatorStatus == NodeOperatorRegistryStatus.EJECTED,
            "Cannot remove valid operator."
        );

        _removeOperator(_validatorId, validator.contractAddress, rewardAddress);

        emit RemoveInvalidNodeOperator(_validatorId, rewardAddress);
    }

    function _removeOperator(
        uint256 _validatorId,
        address _contractAddress,
        address _rewardAddress
    ) private {
        uint256 length = validatorIds.length;
        for (uint256 idx = 0; idx < length - 1; idx++) {
            if (_validatorId == validatorIds[idx]) {
                validatorIds[idx] = validatorIds[validatorIds.length - 1];
                break;
            }
        }
        validatorIds.pop();
        stMATIC.withdrawTotalDelegated(_contractAddress);
        delete validatorIdToRewardAddress[_validatorId];
        delete validatorRewardAddressToId[_rewardAddress];
    }

    ///@notice Set default commission rate.
    /// ONLY DAO can call this function.
    ///@param _newCommissionRate new commission rate.
    function setCommissionRate(uint8 _newCommissionRate)
        external
        override
        userHasRole(DAO_ROLE)
    {
        require(
            _newCommissionRate != 0 && _newCommissionRate <= 100,
            "Invalid commission rate"
        );

        uint256 oldCommissionRate = DEFAULT_COMMISSION_RATE;
        DEFAULT_COMMISSION_RATE = _newCommissionRate;
        emit SetCommissionRate(oldCommissionRate, _newCommissionRate);
    }

    /// @notice Set StMatic address.
    /// ONLY DAO can call this function
    /// @param _newStMatic new stMatic address.
    function setStMaticAddress(address _newStMatic)
        external
        override
        userHasRole(DAO_ROLE)
    {
        require(_newStMatic != address(0), "Invalid stMatic address");

        address oldStMATIC = address(stMATIC);
        stMATIC = IStMATIC(_newStMatic);

        emit SetStMaticAddress(oldStMATIC, _newStMatic);
    }

    /// @notice Update the reward address of a Node Operator.
    /// ONLY Operator owner can call this function
    /// @param _newRewardAddress the new reward address.
    function setRewardAddress(address _newRewardAddress) external override {
        uint256 validatorId = validatorRewardAddressToId[msg.sender];
        address oldRewardAddress = validatorIdToRewardAddress[validatorId];
        require(oldRewardAddress == msg.sender, "Unauthorized");
        require(_newRewardAddress != address(0), "Invalid reward address");

        validatorIdToRewardAddress[validatorId] = _newRewardAddress;

        emit SetRewardAddress(validatorId, oldRewardAddress, _newRewardAddress);
    }

    /// @notice set DISTANCE_THRESHOLD
    /// ONLY DAO can call this function
    /// @param _newDistanceThreshold the min rebalance threshold to include
    /// a validator in the delegation process.
    function setDistanceThreshold(uint256 _newDistanceThreshold)
        external
        override
        userHasRole(DAO_ROLE)
    {
        require(_newDistanceThreshold >= 100, "Invalid distance threshold");
        uint256 _oldDistanceThreshold = DISTANCE_THRESHOLD;
        DISTANCE_THRESHOLD = _newDistanceThreshold;

        emit SetDistanceThreshold(_oldDistanceThreshold, _newDistanceThreshold);
    }

    /// @notice set MIN_REQUEST_WITHDRAW_RANGE
    /// ONLY DAO can call this function
    /// @param _newMinRequestWithdrawRange the min request withdraw range.
    function setMinRequestWithdrawRange(uint8 _newMinRequestWithdrawRange)
        external
        override
        userHasRole(DAO_ROLE)
    {
        require(
            _newMinRequestWithdrawRange <= 100,
            "Invalid minRequestWithdrawRange"
        );
        uint8 _oldMinRequestWithdrawRange = MIN_REQUEST_WITHDRAW_RANGE;
        MIN_REQUEST_WITHDRAW_RANGE = _newMinRequestWithdrawRange;

        emit SetMinRequestWithdrawRange(
            _oldMinRequestWithdrawRange,
            _newMinRequestWithdrawRange
        );
    }

    /// @notice set MAX_WITHDRAW_PERCENTAGE_PER_REBALANCE
    /// ONLY DAO can call this function
    /// @param _newMaxWithdrawPercentagePerRebalance the max withdraw percentage to
    /// withdraw from a validator per rebalance.
    function setMaxWithdrawPercentagePerRebalance(
        uint256 _newMaxWithdrawPercentagePerRebalance
    ) external override userHasRole(DAO_ROLE) {
        require(
            _newMaxWithdrawPercentagePerRebalance <= 100,
            "Invalid maxWithdrawPercentagePerRebalance"
        );
        uint256 _oldMaxWithdrawPercentagePerRebalance = MAX_WITHDRAW_PERCENTAGE_PER_REBALANCE;
        MAX_WITHDRAW_PERCENTAGE_PER_REBALANCE = _newMaxWithdrawPercentagePerRebalance;

        emit SetMaxWithdrawPercentagePerRebalance(
            _oldMaxWithdrawPercentagePerRebalance,
            _newMaxWithdrawPercentagePerRebalance
        );
    }

    /// @notice Allows to pause the contract.
    function togglePause() external override userHasRole(PAUSE_ROLE) {
        paused() ? _unpause() : _pause();
    }

    /// @notice List all the ACTIVE operators on the stakeManager.
    /// @return activeNodeOperators a list of ACTIVE node operator.
    /// @return totalActiveNodeOperators total active node operators.
    function listDelegatedNodeOperators()
        external
        view
        override
        returns (NodeOperatorRegistry[] memory, uint256)
    {
        uint256 totalActiveNodeOperators = 0;
        uint256[] memory memValidatorIds = validatorIds;
        uint256 length = memValidatorIds.length;
        IStakeManager.Validator memory validator;
        NodeOperatorRegistryStatus operatorStatus;
        NodeOperatorRegistry[]
            memory activeNodeOperators = new NodeOperatorRegistry[](length);

        for (uint256 i = 0; i < length; i++) {
            (operatorStatus, validator) = _getOperatorStatusAndValidator(
                memValidatorIds[i]
            );
            if (operatorStatus == NodeOperatorRegistryStatus.ACTIVE) {
                if (!IValidatorShare(validator.contractAddress).delegation())
                    continue;

                activeNodeOperators[
                    totalActiveNodeOperators
                ] = NodeOperatorRegistry(
                    validator.contractAddress,
                    validatorIdToRewardAddress[memValidatorIds[i]]
                );
                totalActiveNodeOperators++;
            }
        }
        return (activeNodeOperators, totalActiveNodeOperators);
    }

    /// @notice List all the operators on the stakeManager that can be withdrawn from this
    /// includes ACTIVE, JAILED, ejected, and UNSTAKED operators.
    /// @return nodeOperators a list of ACTIVE, JAILED, EJECTED or UNSTAKED node operator.
    /// @return totalNodeOperators total number of node operators.
    function listWithdrawNodeOperators()
        external
        view
        override
        returns (NodeOperatorRegistry[] memory, uint256)
    {
        uint256 totalNodeOperators = 0;
        uint256[] memory memValidatorIds = validatorIds;
        uint256 length = memValidatorIds.length;
        IStakeManager.Validator memory validator;
        NodeOperatorRegistryStatus operatorStatus;
        NodeOperatorRegistry[]
            memory withdrawNodeOperators = new NodeOperatorRegistry[](length);

        for (uint256 i = 0; i < length; i++) {
            (operatorStatus, validator) = _getOperatorStatusAndValidator(
                memValidatorIds[i]
            );
            if (operatorStatus == NodeOperatorRegistryStatus.INACTIVE) continue;

            validator = stakeManager.validators(memValidatorIds[i]);
            withdrawNodeOperators[totalNodeOperators] = NodeOperatorRegistry(
                validator.contractAddress,
                validatorIdToRewardAddress[memValidatorIds[i]]
            );
            totalNodeOperators++;
        }

        return (withdrawNodeOperators, totalNodeOperators);
    }

    /// @notice Returns operators delegation infos.
    /// @return nodeOperators all active node operators.
    /// @return activeOperatorCount count onlt active validators.
    /// @return stakePerOperator amount staked in each validator.
    /// @return totalStaked the total amount staked in all validators.
    /// @return distanceThreshold the distance between the min and max amount staked in a validator.
    function _getValidatorsDelegationInfos()
        private
        view
        returns (
            NodeOperatorRegistry[] memory nodeOperators,
            uint256 activeOperatorCount,
            uint256[] memory stakePerOperator,
            uint256 totalStaked,
            uint256 distanceThreshold
        )
    {
        uint256 length = validatorIds.length;
        nodeOperators = new NodeOperatorRegistry[](length);
        stakePerOperator = new uint256[](length);

        uint256 validatorId;
        IStakeManager.Validator memory validator;
        NodeOperatorRegistryStatus status;

        uint256 maxAmount;
        uint256 minAmount;

        for (uint256 i = 0; i < length; i++) {
            validatorId = validatorIds[i];
            (status, validator) = _getOperatorStatusAndValidator(validatorId);
            if (status == NodeOperatorRegistryStatus.INACTIVE) continue;

            require(
                !(status == NodeOperatorRegistryStatus.EJECTED),
                "Could not calculate the stake data, an operator was EJECTED"
            );

            require(
                !(status == NodeOperatorRegistryStatus.UNSTAKED),
                "Could not calculate the stake data, an operator was UNSTAKED"
            );

            // Get the total staked tokens by the StMatic contract in a validatorShare.
            (uint256 amount, ) = IValidatorShare(validator.contractAddress)
                .getTotalStake(address(stMATIC));

            totalStaked += amount;

            if (maxAmount < amount) {
                maxAmount = amount;
            }

            if (minAmount > amount || minAmount == 0) {
                minAmount = amount;
            }

            bool delegation = IValidatorShare(validator.contractAddress)
                .delegation();

            if (status == NodeOperatorRegistryStatus.ACTIVE && delegation) {
                stakePerOperator[activeOperatorCount] = amount;

                nodeOperators[activeOperatorCount] = NodeOperatorRegistry(
                    validator.contractAddress,
                    validatorIdToRewardAddress[validatorIds[i]]
                );

                activeOperatorCount++;
            }
        }

        require(activeOperatorCount > 0, "There are no active validator");

        // The max amount is multiplied by 100 to have a precise value.
        minAmount = minAmount == 0 ? 1 : minAmount;
        distanceThreshold = ((maxAmount * 100) / minAmount);
    }

    /// @notice  Calculate how total buffered should be delegated between the active validators,
    /// depending on if the system is balanced or not. If validators are in EJECTED or UNSTAKED
    /// status the function will revert.
    /// @param _totalBuffered The total amount buffered in stMatic.
    /// @return nodeOperators all active node operators.
    /// @return totalActiveNodeOperator total active node operators.
    /// @return operatorRatios a list of operator's ratio. It will be calculated if the system is not balanced.
    /// @return totalRatio the total ratio. If ZERO that means the system is balanced.
    ///  It will be calculated if the system is not balanced.
    function getValidatorsDelegationAmount(uint256 _totalBuffered)
        external
        view
        override
        returns (
            NodeOperatorRegistry[] memory nodeOperators,
            uint256 totalActiveNodeOperator,
            uint256[] memory operatorRatios,
            uint256 totalRatio
        )
    {
        require(validatorIds.length > 0, "Not enough operators to delegate");
        uint256[] memory stakePerOperator;
        uint256 totalStaked;
        uint256 distanceThreshold;
        (
            nodeOperators,
            totalActiveNodeOperator,
            stakePerOperator,
            totalStaked,
            distanceThreshold
        ) = _getValidatorsDelegationInfos();

        // If the system is balanced
        if (distanceThreshold <= DISTANCE_THRESHOLD) {
            return (
                nodeOperators,
                totalActiveNodeOperator,
                operatorRatios,
                totalRatio
            );
        }

        // If the system is not balanced calculate ratios
        operatorRatios = new uint256[](totalActiveNodeOperator);
        uint256 rebalanceTarget = (totalStaked + _totalBuffered) /
            totalActiveNodeOperator;

        uint256 operatorRatioToDelegate;

        for (uint256 idx = 0; idx < totalActiveNodeOperator; idx++) {
            operatorRatioToDelegate = stakePerOperator[idx] >= rebalanceTarget
                ? 0
                : rebalanceTarget - stakePerOperator[idx];

            if (operatorRatioToDelegate != 0 && stakePerOperator[idx] != 0) {
                operatorRatioToDelegate = (rebalanceTarget * 100) /
                    stakePerOperator[idx] >=
                    DISTANCE_THRESHOLD
                    ? operatorRatioToDelegate
                    : 0;
            }

            operatorRatios[idx] = operatorRatioToDelegate;
            totalRatio += operatorRatioToDelegate;
        }
    }

    /// @notice  Calculate how the system could be rebalanced depending on the current
    /// buffered tokens. If validators are in EJECTED or UNSTAKED status the function will revert.
    /// If the system is balanced the function will revert.
    /// @notice Calculate the operator ratios to rebalance the system.
    /// @param _totalBuffered The total amount buffered in stMatic.
    /// @return nodeOperators all active node operators.
    /// @return totalActiveNodeOperator total active node operators.
    /// @return operatorRatios is a list of operator's ratio.
    /// @return totalRatio the total ratio. If ZERO that means the system is balanced.
    /// @return totalToWithdraw the total amount to withdraw.
    function getValidatorsRebalanceAmount(uint256 _totalBuffered)
        external
        view
        override
        returns (
            NodeOperatorRegistry[] memory nodeOperators,
            uint256 totalActiveNodeOperator,
            uint256[] memory operatorRatios,
            uint256 totalRatio,
            uint256 totalToWithdraw
        )
    {
        require(validatorIds.length > 1, "Not enough operator to rebalance");
        uint256[] memory stakePerOperator;
        uint256 totalStaked;
        uint256 distanceThreshold;
        (
            nodeOperators,
            totalActiveNodeOperator,
            stakePerOperator,
            totalStaked,
            distanceThreshold
        ) = _getValidatorsDelegationInfos();

        require(
            distanceThreshold >= DISTANCE_THRESHOLD && totalStaked > 0,
            "The system is balanced"
        );

        operatorRatios = new uint256[](totalActiveNodeOperator);
        uint256 rebalanceTarget = totalStaked / totalActiveNodeOperator;
        uint256 operatorRatioToRebalance;

        for (uint256 idx = 0; idx < totalActiveNodeOperator; idx++) {
            operatorRatioToRebalance = stakePerOperator[idx] > rebalanceTarget
                ? stakePerOperator[idx] - rebalanceTarget
                : 0;

            operatorRatioToRebalance = (stakePerOperator[idx] * 100) /
                rebalanceTarget >=
                DISTANCE_THRESHOLD
                ? operatorRatioToRebalance
                : 0;

            operatorRatios[idx] = operatorRatioToRebalance;
            totalRatio += operatorRatioToRebalance;
        }
        totalToWithdraw = totalRatio > _totalBuffered
            ? totalRatio - _totalBuffered
            : 0;

        require(totalToWithdraw > 0, "Zero total to withdraw");
        totalToWithdraw =
            (totalToWithdraw * MAX_WITHDRAW_PERCENTAGE_PER_REBALANCE) /
            100;
    }

    /// @notice Returns operators info.
    /// @return activeNodeOperators all active node operators.
    /// @return stakePerOperator amount staked in each validator.
    /// @return totalDelegated the total amount delegated to all validators.
    /// @return minAmount the distance between the min and max amount staked in a validator.
    /// @return maxAmount the distance between the min and max amount staked in a validator.
    function _getValidatorsRequestWithdraw()
        private
        view
        returns (
            NodeOperatorRegistry[] memory activeNodeOperators,
            uint256[] memory stakePerOperator,
            uint256 totalDelegated,
            uint256 minAmount,
            uint256 maxAmount
        )
    {
        uint256 length = validatorIds.length;
        activeNodeOperators = new NodeOperatorRegistry[](length);
        stakePerOperator = new uint256[](length);

        uint256 validatorId;
        IStakeManager.Validator memory validator;
        NodeOperatorRegistryStatus status;

        for (uint256 i = 0; i < length; i++) {
            validatorId = validatorIds[i];
            (status, validator) = _getOperatorStatusAndValidator(validatorId);
            if (status == NodeOperatorRegistryStatus.INACTIVE) continue;

            // Get the total staked tokens by the StMatic contract in a validatorShare.
            (uint256 amount, ) = IValidatorShare(validator.contractAddress)
                .getTotalStake(address(stMATIC));

            stakePerOperator[i] = amount;
            totalDelegated += amount;

            if (maxAmount < amount) {
                maxAmount = amount;
            }

            if ((minAmount > amount && amount != 0) || minAmount == 0) {
                minAmount = amount;
            }

            activeNodeOperators[i] = NodeOperatorRegistry(
                validator.contractAddress,
                validatorIdToRewardAddress[validatorIds[i]]
            );
        }
        minAmount = minAmount == 0 ? 1 : minAmount;
    }

    /// @notice Calculate the validators to request withdrawal from depending if the system is balalnced or not.
    /// @param _withdrawAmount The amount to withdraw.
    /// @return nodeOperators all node operators.
    /// @return totalDelegated total amount delegated.
    /// @return bigNodeOperatorLength number of ids bigNodeOperatorIds.
    /// @return bigNodeOperatorIds stores the ids of node operators that amount delegated to it is greater than the average delegation.
    /// @return smallNodeOperatorLength number of ids smallNodeOperatorIds.
    /// @return smallNodeOperatorIds stores the ids of node operators that amount delegated to it is less than the average delegation.
    /// @return operatorAmountCanBeRequested amount that can be requested from a spécific validator when the system is not balanced.
    /// @return totalValidatorToWithdrawFrom the number of validator to withdraw from when the system is balanced.
    function getValidatorsRequestWithdraw(uint256 _withdrawAmount)
        external
        view
        override
        returns (
            NodeOperatorRegistry[] memory nodeOperators,
            uint256 totalDelegated,
            uint256 bigNodeOperatorLength,
            uint256[] memory bigNodeOperatorIds,
            uint256 smallNodeOperatorLength,
            uint256[] memory smallNodeOperatorIds,
            uint256[] memory operatorAmountCanBeRequested,
            uint256 totalValidatorToWithdrawFrom
        )
    {
        if (validatorIds.length == 0) {
            return (
                nodeOperators,
                totalDelegated,
                bigNodeOperatorLength,
                bigNodeOperatorIds,
                smallNodeOperatorLength,
                smallNodeOperatorIds,
                operatorAmountCanBeRequested,
                totalValidatorToWithdrawFrom
            );
        }
        uint256[] memory stakePerOperator;
        uint256 minAmount;
        uint256 maxAmount;

        (
            nodeOperators,
            stakePerOperator,
            totalDelegated,
            minAmount,
            maxAmount
        ) = _getValidatorsRequestWithdraw();

        if (totalDelegated == 0) {
            return (
                nodeOperators,
                totalDelegated,
                bigNodeOperatorLength,
                bigNodeOperatorIds,
                smallNodeOperatorLength,
                smallNodeOperatorIds,
                operatorAmountCanBeRequested,
                totalValidatorToWithdrawFrom
            );
        }

        uint256 length = nodeOperators.length;
        uint256 withdrawAmountPercentage = (_withdrawAmount * 100) /
            totalDelegated;

        totalValidatorToWithdrawFrom =
            ((withdrawAmountPercentage + MIN_REQUEST_WITHDRAW_RANGE) /
                (100 / length)) +
            1;

        totalValidatorToWithdrawFrom = totalValidatorToWithdrawFrom > length
            ? length
            : totalValidatorToWithdrawFrom;

        if (
            (maxAmount * 100) / minAmount <= DISTANCE_THRESHOLD &&
            minAmount * totalValidatorToWithdrawFrom >= _withdrawAmount
        ) {
            return (
                nodeOperators,
                totalDelegated,
                bigNodeOperatorLength,
                bigNodeOperatorIds,
                smallNodeOperatorLength,
                smallNodeOperatorIds,
                operatorAmountCanBeRequested,
                totalValidatorToWithdrawFrom
            );
        }
        totalValidatorToWithdrawFrom = 0;
        operatorAmountCanBeRequested = new uint256[](length);
        withdrawAmountPercentage = withdrawAmountPercentage == 0
            ? 1
            : withdrawAmountPercentage;
        uint256 rebalanceTarget = totalDelegated > _withdrawAmount
            ? (totalDelegated - _withdrawAmount) / length
            : 0;

        rebalanceTarget = rebalanceTarget > minAmount
            ? minAmount
            : rebalanceTarget;

        uint256 averageTarget = totalDelegated / length;
        bigNodeOperatorIds = new uint256[](length);
        smallNodeOperatorIds = new uint256[](length);

        for (uint256 idx = 0; idx < length; idx++) {
            if (stakePerOperator[idx] > averageTarget) {
                bigNodeOperatorIds[bigNodeOperatorLength] = idx;
                bigNodeOperatorLength++;
            } else {
                smallNodeOperatorIds[smallNodeOperatorLength] = idx;
                smallNodeOperatorLength++;
            }

            uint256 operatorRatioToRebalance = stakePerOperator[idx] != 0 &&
                stakePerOperator[idx] - rebalanceTarget > 0
                ? stakePerOperator[idx] - rebalanceTarget
                : 0;
            operatorAmountCanBeRequested[idx] = operatorRatioToRebalance;
        }
    }

    /// @notice Returns a node operator.
    /// @param _validatorId the validator id on stakeManager.
    /// @return nodeOperator Returns a node operator.
    function getNodeOperator(uint256 _validatorId)
        external
        view
        override
        returns (FullNodeOperatorRegistry memory nodeOperator)
    {
        (
            NodeOperatorRegistryStatus operatorStatus,
            IStakeManager.Validator memory validator
        ) = _getOperatorStatusAndValidator(_validatorId);
        nodeOperator.validatorShare = validator.contractAddress;
        nodeOperator.validatorId = _validatorId;
        nodeOperator.rewardAddress = validatorIdToRewardAddress[_validatorId];
        nodeOperator.status = operatorStatus;
        nodeOperator.commissionRate = validator.commissionRate;
    }

    /// @notice Returns a node operator.
    /// @param _rewardAddress the reward address.
    /// @return nodeOperator Returns a node operator.
    function getNodeOperator(address _rewardAddress)
        external
        view
        override
        returns (FullNodeOperatorRegistry memory nodeOperator)
    {
        uint256 validatorId = validatorRewardAddressToId[_rewardAddress];
        (
            NodeOperatorRegistryStatus operatorStatus,
            IStakeManager.Validator memory validator
        ) = _getOperatorStatusAndValidator(validatorId);

        nodeOperator.status = operatorStatus;
        nodeOperator.rewardAddress = _rewardAddress;
        nodeOperator.validatorId = validatorId;
        nodeOperator.validatorShare = validator.contractAddress;
        nodeOperator.commissionRate = validator.commissionRate;
    }

    /// @notice Returns a node operator status.
    /// @param  _validatorId is the id of the node operator.
    /// @return operatorStatus Returns a node operator status.
    function getNodeOperatorStatus(uint256 _validatorId)
        external
        view
        override
        returns (NodeOperatorRegistryStatus operatorStatus)
    {
        (operatorStatus, ) = _getOperatorStatusAndValidator(_validatorId);
    }

    /// @notice Returns a node operator status.
    /// @param  _validatorId is the id of the node operator.
    /// @return operatorStatus is the operator status.
    /// @return validator is the validator info.
    function _getOperatorStatusAndValidator(uint256 _validatorId)
        private
        view
        returns (
            NodeOperatorRegistryStatus operatorStatus,
            IStakeManager.Validator memory validator
        )
    {
        address rewardAddress = validatorIdToRewardAddress[_validatorId];
        require(rewardAddress != address(0), "Operator not found");
        validator = stakeManager.validators(_validatorId);

        if (
            validator.status == IStakeManager.Status.Active &&
            validator.deactivationEpoch == 0
        ) {
            operatorStatus = NodeOperatorRegistryStatus.ACTIVE;
        } else if (
            validator.status == IStakeManager.Status.Locked &&
            validator.deactivationEpoch == 0
        ) {
            operatorStatus = NodeOperatorRegistryStatus.JAILED;
        } else if (
            (validator.status == IStakeManager.Status.Active ||
                validator.status == IStakeManager.Status.Locked) &&
            validator.deactivationEpoch != 0
        ) {
            operatorStatus = NodeOperatorRegistryStatus.EJECTED;
        } else if ((validator.status == IStakeManager.Status.Unstaked)) {
            operatorStatus = NodeOperatorRegistryStatus.UNSTAKED;
        } else {
            operatorStatus = NodeOperatorRegistryStatus.INACTIVE;
        }

        return (operatorStatus, validator);
    }

    /// @notice Return a list of all validator ids in the system.
    function getValidatorIds()
        external
        view
        override
        returns (uint256[] memory)
    {
        return validatorIds;
    }

    /// @notice List all the node operator statuses in the system.
    /// @return inactiveNodeOperator the number of inactive operators.
    /// @return activeNodeOperator the number of active operators.
    /// @return jailedNodeOperator the number of jailed operators.
    /// @return ejectedNodeOperator the number of ejected operators.
    /// @return unstakedNodeOperator the number of unstaked operators.
    function getStats()
        external
        view
        override
        returns (
            uint256 inactiveNodeOperator,
            uint256 activeNodeOperator,
            uint256 jailedNodeOperator,
            uint256 ejectedNodeOperator,
            uint256 unstakedNodeOperator
        )
    {
        uint256[] memory memValidatorIds = validatorIds;
        uint256 length = memValidatorIds.length;
        for (uint256 idx = 0; idx < length; idx++) {
            (
                NodeOperatorRegistryStatus operatorStatus,

            ) = _getOperatorStatusAndValidator(memValidatorIds[idx]);
            if (operatorStatus == NodeOperatorRegistryStatus.ACTIVE) {
                activeNodeOperator++;
            } else if (operatorStatus == NodeOperatorRegistryStatus.JAILED) {
                jailedNodeOperator++;
            } else if (operatorStatus == NodeOperatorRegistryStatus.EJECTED) {
                ejectedNodeOperator++;
            } else if (operatorStatus == NodeOperatorRegistryStatus.UNSTAKED) {
                unstakedNodeOperator++;
            } else {
                inactiveNodeOperator++;
            }
        }
    }
}
