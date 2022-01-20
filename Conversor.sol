// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IERC20MintBurn.sol";
import "./interfaces/IJamonSharePresale.sol";
import "./interfaces/IConversor.sol";
import "./interfaces/IJamonRouter.sol";
import "./interfaces/IJamonPair.sol";

contract Conversor is IConversor, Ownable, ReentrancyGuard, Pausable {
    //---------- Libraries ----------//
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IJamonPair;

    //---------- Contracts ----------//
    IJamonRouter internal Router;
    IJamonSharePresale internal Presale;

    //---------- Variables ----------//
    uint256 private immutable _endTime;
    bool public Completed_LP;

    //---------- Storage -----------//
    struct TokensContracts {
        IERC20 USDC;
        IERC20 JAMON_V1;
        IERC20MintBurn JAMON_V2;
        IJamonPair MATIC_LP_V1;
        IJamonPair USDC_LP_V1;
        IJamonPair MATIC_LP_V2;
        IJamonPair USDC_LP_V2;
    }

    struct Tokens {
        uint256 TotalOldMaticLP;
        uint256 TotalNewMaticLP;
        uint256 TotalOldUsdcLP;
        uint256 TotalNewUsdcLP;
    }

    struct Wallet {
        uint256 MaticLpBalance;
        uint256 USDCLpBalance;
    }

    mapping(address => Wallet) public Wallets;
    TokensContracts internal Contracts;
    Tokens public Balances;

    //---------- Events -----------//
    event Deposit(
        address indexed token,
        address indexed wallet,
        uint256 amount
    );
    event Updated(address indexed wallet, uint256 amount);
    event ClaimedLP(address indexed wallet, uint256[2] amounts);

    //---------- Constructor ----------//
    constructor(address oldToken_, address newToken_, address usdc_) {
        Router = IJamonRouter(0xdBe30E8742fBc44499EB31A19814429CECeFFaA0);
        _endTime = block.timestamp.add(259200); // 3 days update lps period
        Contracts.JAMON_V1 = IERC20(oldToken_);
        Contracts.JAMON_V2 = IERC20MintBurn(newToken_);
        Contracts.USDC = IERC20(usdc_);
    }

    function initialize(
        address maticlpV1,
        address usdclpV1,
        address maticlpV2,
        address usdclpV2,
        address presale
    ) external onlyOwner {
        require(
            address(Contracts.MATIC_LP_V1) == address(0x0),
            "Already initialized"
        );
        Contracts.MATIC_LP_V1 = IJamonPair(maticlpV1);
        Contracts.USDC_LP_V1 = IJamonPair(usdclpV1);
        Contracts.MATIC_LP_V2 = IJamonPair(maticlpV2);
        Contracts.USDC_LP_V2 = IJamonPair(usdclpV2);
        Presale = IJamonSharePresale(presale);
    }

    //---------- Modifiers ----------//
    modifier onlyTokens(address token_) {
        require(
            token_ == address(Contracts.MATIC_LP_V1) ||
                token_ == address(Contracts.USDC_LP_V1)
        );
        _;
    }

    //----------- Internal Functions -----------//
    function _getTokensAmount(
        uint256 balance_,
        uint256 oldTotal_,
        uint256 newTotal_
    ) internal pure returns (uint256) {
        uint256 oldPercent = balance_.mul(10e18).div(oldTotal_);
        uint256 newBalance = oldPercent.mul(newTotal_).div(10e18);
        return newBalance;
    }

    //----------- External Functions -----------//
    function endTime() external view override returns (uint256) {
        return _endTime;
    }

    function updateLP(address token_, uint256 amount_)
        external
        whenNotPaused
        nonReentrant
        onlyTokens(token_)
    {
        require(amount_ > 0, "Invalid amount");
        require(block.timestamp < _endTime, "Initial period ended");
        IERC20(token_).safeTransferFrom(_msgSender(), address(this), amount_);
        Wallet storage w = Wallets[_msgSender()];
        if (token_ == address(Contracts.MATIC_LP_V1)) {
            w.MaticLpBalance += amount_;
            Balances.TotalOldMaticLP += amount_;
        }
        if (token_ == address(Contracts.USDC_LP_V1)) {
            w.USDCLpBalance += amount_;
            Balances.TotalOldUsdcLP += amount_;
        }
        emit Deposit(token_, _msgSender(), amount_);
    }

    function update(uint256 amount_) external whenNotPaused nonReentrant {
        require(amount_ > 0, "Invalid amount");
        (uint256 round, ) = Presale.status();
        require(round == 4, "Presale not ended");
        Contracts.JAMON_V1.safeTransferFrom(
            _msgSender(),
            0x000000000000000000000000000000000000dEaD,
            amount_
        );
        Contracts.JAMON_V2.mint(_msgSender(), amount_);
        emit Updated(_msgSender(), amount_);
    }

    function claimLP() external whenNotPaused nonReentrant {
        require(Completed_LP, "Not completed");
        Wallet storage w = Wallets[_msgSender()];
        require(w.MaticLpBalance > 0 || w.USDCLpBalance > 0, "Zero balance");
        uint256 MaticLpBalance = w.MaticLpBalance;
        uint256 USDCLpBalance = w.USDCLpBalance;
        uint256[2] memory amounts;
        if (MaticLpBalance > 0) {
            w.MaticLpBalance = 0;
            uint256 amountLP = _getTokensAmount(
                MaticLpBalance,
                Balances.TotalOldMaticLP,
                Balances.TotalNewMaticLP
            );
            Contracts.MATIC_LP_V2.transfer(_msgSender(), amountLP);
            amounts[0] = amountLP;
        }
        if (USDCLpBalance > 0) {
            w.USDCLpBalance = 0;
            uint256 amountLP = _getTokensAmount(
                USDCLpBalance,
                Balances.TotalOldUsdcLP,
                Balances.TotalNewUsdcLP
            );
            Contracts.USDC_LP_V2.transfer(_msgSender(), amountLP);
            amounts[1] = amountLP;
        }
        delete Wallets[_msgSender()];
        emit ClaimedLP(_msgSender(), amounts);
    }

    function completeLP() external onlyOwner {
        require(!Completed_LP && block.timestamp > _endTime);
        uint256 oldMaticLpBalance = Contracts.MATIC_LP_V1.balanceOf(
            address(this)
        );
        uint256 oldUsdcLpBalance = Contracts.USDC_LP_V1.balanceOf(
            address(this)
        );
        if (oldMaticLpBalance > 0) {
            (uint256 TokenA, uint256 TokenB) = Router.removeLiquidity(
                Router.WETH(),
                address(Contracts.JAMON_V1),
                oldMaticLpBalance,
                0,
                0,
                address(this),
                block.timestamp.add(60)
            );
            IERC20(Router.WETH()).approve(address(Router), TokenA);
            Contracts.JAMON_V2.mint(address(this), TokenB);
            Contracts.JAMON_V2.approve(address(Router), TokenB);
            (, , uint256 liquidity) = Router.addLiquidity(
                Router.WETH(),
                address(Contracts.JAMON_V2),
                TokenA,
                TokenB,
                0,
                0,
                address(this),
                block.timestamp.add(60)
            );
            Balances.TotalNewMaticLP = liquidity;
        }
        if (oldUsdcLpBalance > 0) {
            (uint256 TokenA, uint256 TokenB) = Router.removeLiquidity(
                address(Contracts.USDC),
                address(Contracts.JAMON_V1),
                oldMaticLpBalance,
                0,
                0,
                address(this),
                block.timestamp.add(60)
            );
            Contracts.USDC.approve(address(Router), TokenA);
            Contracts.JAMON_V2.mint(address(this), TokenB);
            Contracts.JAMON_V2.approve(address(Router), TokenB);
            (, , uint256 liquidity) = Router.addLiquidity(
                address(Contracts.USDC),
                address(Contracts.JAMON_V2),
                TokenA,
                TokenB,
                0,
                0,
                address(this),
                block.timestamp.add(60)
            );
            Balances.TotalNewUsdcLP = liquidity;
        }
        Completed_LP = true;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
