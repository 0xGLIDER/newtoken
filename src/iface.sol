// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

interface iface {

    function balanceOf(address account) view external returns (uint256);

    function burnFrom(address _from, uint _amount) external;

    function mintTo(address _to, uint _amount) external;

}