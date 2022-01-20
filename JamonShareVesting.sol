// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IERC20MintBurn.sol";
import "./interfaces/IJamonShareVesting.sol";
import "./interfaces/IJamonVesting.sol";

contract JamonShareVesting is IJamonShareVesting, ReentrancyGuard, Pausable, Ownable {
    //---------- Libraries ----------//
    using SafeMath for uint256;
    using SafeERC20 for IERC20MintBurn;

    //---------- Contracts ----------//
    IERC20MintBurn internal JamonShare;
    IJamonVesting internal JamonVesting;

    //---------- Variables ----------//
    address private Presale;
    uint256 constant month = 2629743; // 1 Month Timestamp 2629743

    //---------- Storage -----------//

    mapping(address => uint256) internal SHARE_VESTING;

    //---------- Events -----------//
    event Vested(
        address indexed wallet,
        uint256 amount
    );
    event Released(
        address indexed wallet,
        uint256 amount
    );

    //---------- Constructor ----------//
    constructor(address jamonShare_) {
        JamonShare = IERC20MintBurn(jamonShare_);
    }

    function initialize(address presale_, address jamonVesting_) external onlyOwner {
        require(Presale == address(0x0), "Already initialized");
        Presale = presale_;
        JamonVesting = IJamonVesting(jamonVesting_);
    }
    //---------- Modifiers ----------//
    modifier onlyPresale {
        require(_msgSender() == Presale);
        _;
    } 

    //----------- External Functions -----------//
    function shareInfo(address wallet_) external view returns(uint256) {
        return SHARE_VESTING[wallet_];
    }

    function createVesting(address wallet_, uint256 jsNow_, uint256 jsEnd_) external override whenNotPaused onlyPresale {        
        JamonShare.mint(wallet_, jsNow_);
        SHARE_VESTING[wallet_] += jsEnd_;
        emit Vested(wallet_, jsEnd_);
    }

    function claimShare() external nonReentrant {  
        require(JamonVesting.depositsCount() == 12, "Shares lockeds");
        uint256 amount = SHARE_VESTING[_msgSender()];
        require(amount > 0, "Zero amount");
        delete SHARE_VESTING[_msgSender()];
        JamonShare.mint(_msgSender(), amount);
        emit Released(_msgSender(), amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }


}
