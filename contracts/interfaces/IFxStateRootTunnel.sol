// SPDX-FileCopyrightText: 2021 ShardLabs
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;

interface IFxStateRootTunnel {
    function sendMessageToChild(bytes memory message) external;

    function setStMATIC(address _stMATIC) external;
}
