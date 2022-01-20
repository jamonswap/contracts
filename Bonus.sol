// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IERC20MintBurn.sol";
import "./interfaces/IJamonRouter.sol";
import "./interfaces/IJamonPair.sol";
import "./interfaces/IJamonVesting.sol";

contract Bonus is ReentrancyGuard, Pausable, Ownable {
    //---------- Libraries ----------//
    using SafeMath for uint256;
    using SafeERC20 for IJamonPair;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    //---------- Contracts ----------//
    IERC20MintBurn private Jamon_V2;
    IJamonRouter private Router;
    IJamonVesting private Vesting;
    IJamonPair private JamonUSDCV2LP;

    //---------- Variables ----------//
    EnumerableSet.Bytes32Set private BonusMap;
    EnumerableSet.AddressSet private StableCoins;
    EnumerableSet.AddressSet private PriceFeeds;
    address private Governor;
    address private JamonShareVault;

    //---------- Storage -----------//
    struct BonusInput {
        uint256 amount;
        uint256 reward;
    }

    struct Proposal {
        address lpAddress;
        address feedToken;
        uint256 startBlock;
        uint256 endBlock;
        uint256 collected;
        uint256 hardcap;
        uint256 rate;
        mapping(address => BonusInput) holders;
    }

    struct Feed {
        address proxy;
        uint256 decimals;
    }

    mapping(bytes32 => Proposal) internal BONUS;
    mapping(address => Feed) internal FEEDS;

    //---------- Events -----------//
    event Contributed(
        bytes32 indexed id,
        address indexed wallet,
        address lp,
        uint256 amount,
        uint256 reward
    );

    //---------- Constructor ----------//
    constructor(
        address jamonV2_,
        address jamonUSDClp_,
        address vesting_,
        address governor_,
        address jamonShareVault_
    ) {
        Jamon_V2 = IERC20MintBurn(jamonV2_);
        Router = IJamonRouter(0xdBe30E8742fBc44499EB31A19814429CECeFFaA0);
        JamonUSDCV2LP = IJamonPair(jamonUSDClp_);
        Vesting = IJamonVesting(vesting_);
        Governor = governor_;
        JamonShareVault = jamonShareVault_;
        /**
         * Network: Mumbai
         ------------------------------
         * Aggregator: MATIC/USD
         * Address: 0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada
         */
        FEEDS[Router.WETH()].proxy = 0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada;
        FEEDS[Router.WETH()].decimals = 8;
        PriceFeeds.add(Router.WETH());
    }

    //----------- Internal Functions -----------//
    function _getTokenPrice(address token_) public view returns (uint256) {
        if (StableCoins.contains(token_)) {
            return 1 ether;
        }
        if (PriceFeeds.contains(token_)) {
            (, int256 price, , , ) = AggregatorV3Interface(FEEDS[token_].proxy)
                .latestRoundData();
            uint256 decimals = FEEDS[token_].decimals;
            decimals = uint256(18).sub(decimals);
            return uint256(price).mul(10**decimals);
        }
        if (token_ == address(Jamon_V2)) {
            return _getJamon2USD(1 ether);
        }
        return 0;
    }

    function _getUSD2Jamon(uint256 usdAmount_) internal view returns (uint256) {
        (uint256 Res0, uint256 Res1, ) = JamonUSDCV2LP.getReserves();

        uint256 res0 = Res0 * (1e12); // USDC 6 decimals, 6 + 12
        return ((usdAmount_ * Res1) / res0); // return amount of token0 needed to buy token1
    }

    function _getJamon2USD(uint256 jamonAmount_)
        internal
        view
        returns (uint256)
    {
        (uint256 Res0, uint256 Res1, ) = JamonUSDCV2LP.getReserves();

        uint256 res0 = Res0 * (1e12); // USDC 6 decimals, 6 + 12
        return ((jamonAmount_ * res0) / Res1); // return amount of token0 needed to buy token1
    }

    function _doTransfers(address lp_, address from_, uint256 amount_) internal virtual {
        uint256 toVault = amount_.mul(20).div(10000);        
        uint256 amount = amount_;
        if(toVault > 0) {
            IJamonPair(lp_).safeTransferFrom(from_, JamonShareVault, toVault);
            amount = amount.sub(toVault);
        }
        IJamonPair(lp_).safeTransferFrom(from_, Governor, amount);
    }

    //----------- External Functions -----------//
    function remaining4Sale(bytes32 bonusId_) public view returns (uint256) {
        Proposal storage p = BONUS[bonusId_];
        uint256 available = p.hardcap.sub(p.collected);
        if (available > 0) {
            uint256 tokensBase = (available.div(2).mul(1e18)).div(_getTokenPrice(p.feedToken));
            uint256 totalTokenBase = IERC20(p.feedToken).balanceOf(
                address(p.lpAddress)
            );
            uint256 totalSupply = IJamonPair(p.lpAddress).totalSupply();
            uint256 percentage = tokensBase.mul(1e18).div(totalTokenBase);
            return percentage.mul(totalSupply).div(1e18);
        }
        return 0;
    }

    function isValidBase(address token_) public view returns (bool) {
        return (StableCoins.contains(token_) ||
            PriceFeeds.contains(token_) ||
            token_ == address(Jamon_V2));
    }

    function totalBonus() external view returns (uint256) {
        return BonusMap.length();
    }

    function bonusAt(uint256 index_) external view returns (bytes32) {
        return BonusMap.at(index_);
    }

    function isBonusOpen(bytes32 bonus_) public view returns (bool) {
        Proposal storage p = BONUS[bonus_];
        if (p.startBlock < block.number && p.endBlock > block.number) {
            return p.collected < p.hardcap;
        }
        return false;
    }

    function contribute(bytes32 bonusId_, uint256 amount_)
        external
        whenNotPaused
        nonReentrant
    {
        require(BonusMap.contains(bonusId_), "Invalid ID");
        require(amount_ > 0, "Invalid amount");
        require(isBonusOpen(bonusId_), "Not open");
        uint256 allowed = remaining4Sale(bonusId_);
        uint256 amount = amount_ > allowed ? allowed : amount_;
        Proposal storage p = BONUS[bonusId_];
        address LP = p.lpAddress;
        address feedToken = p.feedToken;
        uint256 totalSupply = IERC20(LP).totalSupply();
        uint256 totalFeedToken = IERC20(feedToken).balanceOf(LP);
        uint256 percentage = amount.mul(10e18).div(totalSupply);
        uint256 contributed = totalFeedToken.mul(percentage).div(10e18);
        uint256 amountUSD = contributed.mul(2).div(_getTokenPrice(feedToken));
        uint256 JamonReward = _getUSD2Jamon(amountUSD).mul(p.rate).div(100);
        _doTransfers(LP, _msgSender(), amount);
        p.collected += amountUSD;
        Vesting.createVestingSchedule(_msgSender(), JamonReward);
        emit Contributed(bonusId_, _msgSender(), LP, amount, JamonReward);
    }

    function addBonus(
        address lpAddress_,
        address feedToken_,
        uint256 startBlock_,
        uint256 endBlock_,
        uint256 hardcap_,
        uint256 rate_
    ) external onlyOwner {
        require(lpAddress_ != address(0));
        require(isValidBase(feedToken_));
        require(startBlock_ > block.number && endBlock_ > startBlock_);
        require(rate_ >= 120 && rate_ <= 180);
        IJamonPair pair = IJamonPair(lpAddress_);
        require(pair.token0() == feedToken_ || pair.token1() == feedToken_);
        bytes32 bonusId = keccak256(
            abi.encodePacked(lpAddress_, startBlock_, endBlock_, hardcap_)
        );
        Proposal storage p = BONUS[bonusId];
        p.lpAddress = lpAddress_;
        p.feedToken = feedToken_;
        p.startBlock = startBlock_;
        p.endBlock = endBlock_;
        p.hardcap = hardcap_;
    }

    function addFeed(
        address token_,
        address proxy_,
        uint256 decimals_
    ) external onlyOwner {
        require(token_ != address(0) && proxy_ != address(0) && decimals_ > 0);
        require(!isValidBase(token_));
        FEEDS[token_].proxy = proxy_;
        FEEDS[token_].decimals = decimals_;
        PriceFeeds.add(token_);
    }

    function addStableCoin(address token_) external onlyOwner {
        require(token_ != address(0));
        StableCoins.add(token_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
