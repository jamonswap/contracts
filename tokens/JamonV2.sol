// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "../interfaces/IERC20MintBurn.sol";

contract JamonV2 is ERC20, ERC20Burnable, AccessControl, ERC20Permit, IERC20MintBurn {    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    address internal vault;
    uint public fee;    

    constructor() ERC20("JamonV2", "JAMOON") ERC20Permit("JamonV2") {
        _mint(msg.sender, 2000000 * 10 ** decimals());
        vault = msg.sender;
        fee = 10; // 0.1% tx fee
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) public override onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function setVault(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(msg.sender == vault);
        vault = to;
    }

    // The following functions are overrides required by Solidity.    
    function transfer(address recipient, uint256 amount) public virtual override(ERC20, IERC20) returns (bool) {
        if(amount >= 10000) {
            uint256 toVault = amount*fee/10000;
            _transfer(_msgSender(), vault, toVault);
            amount = amount - toVault;
        }
        _transfer(_msgSender(), recipient, amount);
        return true;
    }    

     function burn(uint256 amount) public virtual override(ERC20Burnable, IERC20MintBurn) {
        _burn(_msgSender(), amount);
    }

     function burnFrom(address account, uint256 amount) public virtual override(ERC20Burnable, IERC20MintBurn) {
        uint256 currentAllowance = allowance(account, _msgSender());
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        unchecked {
            _approve(account, _msgSender(), currentAllowance - amount);
        }
        _burn(account, amount);
    }
}