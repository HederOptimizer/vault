// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {ERC20} from "@solmate/contracts/tokens/ERC20.sol";
import {FixedPointMathLib} from "@solmate/contracts/utils/FixedPointMathLib.sol";

/*//////////////////////////////////////////////////////////////
//
// 1. PROVIDED ABSTRACT CONTRACT
//
//////////////////////////////////////////////////////////////*/

/// @notice Minimal ERC4626 tokenized Vault implementation for Native ETH.
/// @author Solmate (modified for native ETH)
abstract contract ERC4626Native is ERC20 {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol, 18) { // Decimals hardcoded to 18 for ETH
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public payable virtual returns (uint256 shares) {
        // Check that the sent ETH matches the 'assets' parameter
        require(msg.value == assets, "ASSETS_MISMATCH");

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // No asset.safeTransferFrom needed, ETH is already in the contract
        
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function mint(uint256 shares, address receiver) public payable virtual returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Check that the sent ETH matches the calculated 'assets'
        require(msg.value == assets, "ASSETS_MISMATCH");

        // No asset.safeTransferFrom needed, ETH is already in the contract

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        // Transfer native ETH
        (bool success, ) = receiver.call{value: assets}("");
        require(success, "ETH_TRANSFER_FAILED");
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        // Transfer native ETH
        (bool success, ) = receiver.call{value: assets}("");
        require(success, "ETH_TRANSFER_FAILED");
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This is the ONLY function you need to implement.
     * For a simple vault that just holds ETH, return address(this).balance.
     * For a complex vault that invests ETH elsewhere, return:
     * address(this).balance + totalAssetsInvested
     */
    function totalAssets() public view virtual returns (uint256);

    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivUp(supply, totalAssets());
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT/WITHDRAWAL LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        // FIX APPLIED: Changed balanceOf[owner] to balanceOf(owner)
        // Note: This was in your original code, but `balanceOf` is a function.
        return convertToAssets(balanceOf[owner]);
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        // FIX APPLIED: Changed balanceOf[owner] to balanceOf(owner)
        // Note: This was in your original code, but `balanceOf` is a function.
        return balanceOf[owner];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 assets, uint256 shares) internal virtual {}

    function afterDeposit(uint256 assets, uint256 shares) internal virtual {}

    /*//////////////////////////////////////////////////////////////
                                ETH RECEIVE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This allows the contract to receive ETH via direct sends.
     * The received ETH will be reflected in totalAssets() (if implemented
     * as address(this).balance), effectively distributing its value to
     * all current vault share holders.
     */
    receive() external virtual payable {}
}