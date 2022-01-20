// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract JamonShareVault is ReentrancyGuard, Pausable, Ownable {
    //---------- Libraries ----------//
    using SafeMath for uint256;
    using Counters for Counters.Counter;
    using EnumerableSet for EnumerableSet.AddressSet;

    //---------- Contracts ----------//
    IERC20 private JAMON_SHARE;

    //---------- Variables ----------//
    Counters.Counter public totalHolders;
    EnumerableSet.AddressSet internal validTokens;
    address private JamonV2;
    uint256 constant month = 2629743; // 1 Month Timestamp 2629743
    uint256 public totalStaked;
    uint256 public lastUpdated;

    //---------- Storage -----------//
    struct Wallet {
        uint256 stakedBal;
        uint256 startTime;
        mapping(address => uint256) tokenPoints;
        mapping(address => uint256) pendingTokenbal;
        bool inStake;
    }

    mapping(address => Wallet) private stakeHolders;
    mapping(address => uint256) private TokenPoints;
    mapping(address => uint256) private UnclaimedToken;
    mapping(address => uint256) private ProcessedToken;

    //---------- Events -----------//
    event Deposit(address indexed payee, uint256 amount, uint256 totalStaked);
    event Withdrawn(address indexed payee, uint256 amount);
    event Staked(address indexed wallet, uint256 amount);
    event UnStaked(address indexed wallet, uint256 amount);

    //---------- Constructor ----------//
    constructor(address jamonShare_, address jamonV2_) {
        JAMON_SHARE = IERC20(jamonShare_);
        JamonV2 = jamonV2_;
        validTokens.add(jamonShare_);
        validTokens.add(jamonV2_);
    }

    //---------- Deposits -----------//
    function depositTokens(
        address token_,
        address from_,
        uint256 amount_
    ) external nonReentrant {
        require(amount_ > 0, "Tokens too low");
        require(validTokens.contains(token_), "Invalid token");
        require(IERC20(token_).transferFrom(from_, address(this), amount_));
        _disburseToken(token_, amount_);
    }

    //----------- Internal Functions -----------//
    function _disburseToken(address token_, uint256 amount_) internal {
        if (totalStaked > 1000000 && amount_ >= 1000000) {
            TokenPoints[token_] = TokenPoints[token_].add(
                (amount_.mul(10e18)).div(totalStaked)
            );
            UnclaimedToken[token_] = UnclaimedToken[token_].add(amount_);
            emit Deposit(_msgSender(), amount_, totalStaked);
        }
    }

    function _recalculateBalances() internal virtual {
        uint256 tokensCount = validTokens.length();
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = validTokens.at(i);
            uint256 balance = token == address(JAMON_SHARE)
                ? IERC20(token).balanceOf(address(this)).sub(totalStaked)
                : IERC20(token).balanceOf(address(this));
            uint256 processed = UnclaimedToken[token].add(
                ProcessedToken[token]
            );
            if (balance > processed) {
                uint256 pending = balance.sub(processed);
                if (pending > 1000000) {
                    _disburseToken(token, pending);
                }
            }
        }
    }

    function _recalculateTokenBalance(address token_) internal virtual {
        uint256 balance = IERC20(token_).balanceOf(address(this));
        uint256 processed = UnclaimedToken[token_].add(ProcessedToken[token_]);
        if (balance > processed) {
            uint256 pending = balance.sub(processed);
            if (pending > 1000000) {
                _disburseToken(token_, pending);
            }
        }
    }

    function _processWalletTokens(address wallet_) internal virtual {
        uint256 tokensCount = validTokens.length();
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = validTokens.at(i);
            _processRewardsToken(token, wallet_);
        }
    }

    function _processRewardsToken(address token_, address wallet_)
        internal
        virtual
    {
        uint256 rewards = getRewardsToken(token_, wallet_);
        if (rewards > 0) {
            UnclaimedToken[token_] = UnclaimedToken[token_].sub(rewards);
            ProcessedToken[token_] = ProcessedToken[token_].add(rewards);
            stakeHolders[wallet_].tokenPoints[token_] = TokenPoints[token_];
            stakeHolders[wallet_].pendingTokenbal[token_] = stakeHolders[
                wallet_
            ].pendingTokenbal[token_].add(rewards);
        }
    }

    function _harvestToken(address token_, address wallet_) internal virtual {
        _processRewardsToken(token_, wallet_);
        uint256 amount = stakeHolders[wallet_].pendingTokenbal[token_];
        if (amount > 0) {
            stakeHolders[wallet_].pendingTokenbal[token_] = 0;
            ProcessedToken[token_] = ProcessedToken[token_].sub(amount);
            IERC20(token_).transfer(wallet_, amount);
            emit Withdrawn(wallet_, amount);
        }
    }

    function _harvestAll(address wallet_) internal virtual {
        _processWalletTokens(wallet_);
        uint256 tokensCount = validTokens.length();
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = validTokens.at(i);
            uint256 amount = stakeHolders[wallet_].pendingTokenbal[token];
            if (amount > 0) {
                stakeHolders[wallet_].pendingTokenbal[token] = 0;
                ProcessedToken[token] = ProcessedToken[token].sub(amount);
                IERC20(token).transfer(wallet_, amount);
                emit Withdrawn(wallet_, amount);
            }
        }
    }

    function _initWalletPoints(address wallet_) internal virtual {
        uint256 tokensCount = validTokens.length();
        Wallet storage w = stakeHolders[wallet_];
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = validTokens.at(i);
            w.tokenPoints[token] = TokenPoints[token];
        }
    }

    function _initStake(address wallet_, uint256 amount_)
        internal
        virtual
        returns (bool)
    {
        _recalculateBalances();
        _initWalletPoints(wallet_);
        bool success = JAMON_SHARE.transferFrom(
            wallet_,
            address(this),
            amount_
        );
        stakeHolders[wallet_].startTime = block.timestamp;
        stakeHolders[wallet_].inStake = true;
        stakeHolders[wallet_].stakedBal = amount_;
        totalStaked = totalStaked.add(amount_);
        totalHolders.increment();
        return success;
    }

    function _addStake(address wallet_, uint256 amount_)
        internal
        virtual
        returns (bool)
    {
        _recalculateBalances();
        _processWalletTokens(wallet_);
        bool success = JAMON_SHARE.transferFrom(
            wallet_,
            address(this),
            amount_
        );
        stakeHolders[wallet_].stakedBal = stakeHolders[wallet_].stakedBal.add(
            amount_
        );
        totalStaked = totalStaked.add(amount_);

        return success;
    }

    function _unStakeBal(address wallet_) internal virtual returns (uint256) {
        uint256 accumulated = block.timestamp.sub(
            stakeHolders[wallet_].startTime
        );
        uint256 balance = stakeHolders[wallet_].stakedBal;
        uint256 minPercent = 88;
        if (accumulated >= month.mul(12)) {
            return balance;
        }
        balance = balance.mul(10e18);
        if (accumulated < month) {
            balance = (balance.mul(minPercent)).div(100);
            return balance.div(10e18);
        }
        for (uint256 m = 1; m < 12; m++) {
            if (accumulated >= month.mul(m) && accumulated < month.mul(m + 1)) {
                minPercent = minPercent.add(m);
                balance = (balance.mul(minPercent)).div(100);
                return balance.div(10e18);
            }
        }
        return 0;
    }

    //----------- External Functions -----------//
    function isInStake(address wallet_) external view returns (bool) {
        return stakeHolders[wallet_].inStake;
    }

    function getRewardsToken(address token_, address wallet_)
        public
        view
        returns (uint256)
    {
        uint256 newTokenPoints = TokenPoints[token_].sub(
            stakeHolders[wallet_].tokenPoints[token_]
        );
        return
            (stakeHolders[wallet_].stakedBal.mul(newTokenPoints)).div(
                10e18
            );
    }

    function getPendingBal(address token_, address wallet_)
        external
        view
        returns (uint256)
    {
        uint256 newTokenPoints = TokenPoints[token_].sub(
            stakeHolders[wallet_].tokenPoints[token_]
        );
        uint256 pending = stakeHolders[wallet_].pendingTokenbal[token_];
        return
            (stakeHolders[wallet_].stakedBal.mul(newTokenPoints)).div(
                10e18
            ).add(pending);
    }

    function getWalletInfo(address wallet_)
        public
        view
        returns (uint256 stakedBal, uint256 startTime)
    {
        Wallet storage w = stakeHolders[wallet_];
        return (w.stakedBal, w.startTime);
    }

    function pendingBalances() public view returns (bool) {
        uint256 tokensCount = validTokens.length();
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = validTokens.at(i);
            uint256 balance = token == address(JAMON_SHARE)
                ? IERC20(token).balanceOf(address(this)).sub(totalStaked)
                : IERC20(token).balanceOf(address(this));
            uint256 processed = UnclaimedToken[token].add(
                ProcessedToken[token]
            );
            if (balance > processed) {
                uint256 pending = balance.sub(processed);
                if (pending > 1000000) {
                    return true;
                }
            }
        }
        return false;
    }

    function stake(uint256 amount_) external whenNotPaused nonReentrant {
        require(amount_ > 1000000);
        require(
            JAMON_SHARE.allowance(_msgSender(), address(this)) >= amount_,
            "Amount not allowed"
        );

        if (stakeHolders[_msgSender()].inStake) {
            require(_addStake(_msgSender(), amount_));
        } else {
            require(_initStake(_msgSender(), amount_));
        }
        emit Staked(_msgSender(), amount_);
    }

    function harvestToken(address token_) external whenNotPaused nonReentrant {
        require(stakeHolders[_msgSender()].inStake, "Not in stake");
        require(validTokens.contains(token_), "Invalid token");
        _harvestToken(token_, _msgSender());
    }

    function harvestAll() external whenNotPaused nonReentrant {
        require(stakeHolders[_msgSender()].inStake, "Not in stake");
        _harvestAll(_msgSender());
    }

    function unStake() external whenNotPaused nonReentrant {
        require(stakeHolders[_msgSender()].inStake, "Not in stake");
        _harvestAll(_msgSender());
        uint256 stakedBal = stakeHolders[_msgSender()].stakedBal;
        uint256 balance = _unStakeBal(_msgSender());
        uint256 balanceDiff = stakedBal.sub(balance);
        if (balance > 0) {
            require(JAMON_SHARE.transfer(_msgSender(), balance));
        }
        totalStaked = totalStaked.sub(stakedBal);
        delete stakeHolders[_msgSender()];
        totalHolders.decrement();
        if (balanceDiff > 0) {
            _disburseToken(address(JAMON_SHARE), balanceDiff);
        }
        emit UnStaked(_msgSender(), balance);
    }

    function safeUnStake() external whenPaused nonReentrant {
        require(stakeHolders[_msgSender()].inStake, "Not in stake");
        uint256 stakedBal = stakeHolders[_msgSender()].stakedBal;
        delete stakeHolders[_msgSender()];
        require(JAMON_SHARE.transfer(_msgSender(), stakedBal));
        totalStaked = totalStaked.sub(stakedBal);
        totalHolders.decrement();
    }

    function updateBalances() external whenNotPaused nonReentrant {
        if (lastUpdated.add(1 days) < block.timestamp) {
            _recalculateBalances();
            lastUpdated = block.timestamp;
        }
    }

    function updateTokenBalance(address token_) external onlyOwner {
        require(validTokens.contains(token_), "Invalid token");
        _recalculateTokenBalance(token_);
    }

    function setTokenList(address token_, bool add_) external onlyOwner {
        require(token_ != address(0) && token_ != address(JAMON_SHARE) && token_ != JamonV2);
        if(add_) {
            validTokens.add(token_);
        } else {
            validTokens.remove(token_);
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
