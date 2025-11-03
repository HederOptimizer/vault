//SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ERC4626} from "@solmate/contracts/tokens/ERC4626.sol";
import {ERC20} from "@solmate/contracts/tokens/ERC20.sol";

contract HBARVault is ERC4626 {
    
    ERC20 public immutable override asset;

    constructor(ERC20 _asset, string memory _name, string memory _symbol) ERC4626(_asset, _name, _symbol) {

    }

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

}