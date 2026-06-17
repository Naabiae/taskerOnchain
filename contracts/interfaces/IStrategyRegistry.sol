// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategyRegistry {
    function isStrategyActive(address adapter) external view returns (bool);
}
