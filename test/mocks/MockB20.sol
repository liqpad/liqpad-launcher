// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {B20Constants} from "base-std/lib/B20Constants.sol";

contract MockB20 {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    uint256 public supplyCap = type(uint128).max;
    string public contractURI;
    bool public initialized;
    address public bootstrapFactory;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    mapping(bytes32 role => mapping(address account => bool held)) private _roles;

    function initialize(string calldata name_, string calldata symbol_, address initialAdmin, uint8 decimals_)
        external
    {
        require(!initialized);
        initialized = true;
        bootstrapFactory = msg.sender;
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        if (initialAdmin != address(0)) _roles[DEFAULT_ADMIN_ROLE][initialAdmin] = true;
    }

    function updateContractURI(string calldata uri) external {
        _requireBootstrapOrAdmin();
        contractURI = uri;
    }

    function updateSupplyCap(uint256 cap) external {
        _requireBootstrapOrAdmin();
        require(cap >= totalSupply && cap <= type(uint128).max);
        supplyCap = cap;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == bootstrapFactory);
        require(totalSupply + amount <= supplyCap);
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(uint256 amount) external {
        require(_roles[B20Constants.BURN_ROLE][msg.sender]);
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function BURN_ROLE() external pure returns (bytes32) {
        return B20Constants.BURN_ROLE;
    }

    function grantRole(bytes32 role, address account) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender]);
        _roles[role][account] = true;
    }

    function renounceLastAdmin() external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender]);
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = false;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function _requireBootstrapOrAdmin() private view {
        require(msg.sender == bootstrapFactory || _roles[DEFAULT_ADMIN_ROLE][msg.sender]);
    }
}
