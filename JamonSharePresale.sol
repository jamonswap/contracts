// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IJamonSharePresale.sol";
import "./interfaces/IJamonShareVesting.sol";
import "./interfaces/IConversor.sol";
import "./interfaces/IJamonPair.sol";
import "./interfaces/IERC20MintBurn.sol";

contract JamonSharePresale is
    IJamonSharePresale,
    ReentrancyGuard,
    Pausable,
    Ownable
{
    //---------- Libraries ----------//
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    //---------- Contracts ----------//
    AggregatorV3Interface private maticFeed;
    IJamonShareVesting private RewardVesting;
    IConversor private Conversor;

    //---------- Variables ----------//
    EnumerableSet.AddressSet private Whitelist;
    uint256 public constant max4list = 1700 ether; // 1700 USD per user in whitelist
    address private Governor;
    bool public listActive;
    bool public listLimit;
    uint256 private roundHardcap;

    //---------- Storage -----------//
    struct TokensContracts {
        IERC20 WMATIC;
        IERC20 USDC;
        IERC20MintBurn JAMON_V2;
        IJamonPair MATIC_LP;
        IJamonPair USDC_LP;
    }

    struct Round {
        uint256 endTime;
        uint256 collected;
    }

    TokensContracts internal CONTRACTS;
    Round[3] internal ROUNDS;
    mapping(address => uint256) public Max4Wallet;

    //---------- Events -----------//
    event Contributed(
        address indexed lp,
        address indexed wallet,
        uint256 rewardJV2,
        uint256 rewardJS
    );

    //---------- Constructor ----------//
    constructor(address jamon_) {
        /**
         * Network: Mumbai
         ------------------------------
         * Aggregator: MATIC/USD
         * Address: 0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada
         * Decimals: 8
         */
        maticFeed = AggregatorV3Interface(
            0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada
        );
        CONTRACTS.JAMON_V2 = IERC20MintBurn(jamon_);
        roundHardcap = 350000 ether;
    }

    function initialize(
        address wmatic_,
        address usdc_,
        address maticlpV2_,
        address usdclpV2_,
        address rewardVesting_,
        address governor_
    ) external onlyOwner {
        require(
            address(CONTRACTS.WMATIC) == address(0x0),
            "Already initialized"
        );
        CONTRACTS.WMATIC = IERC20(wmatic_);
        CONTRACTS.USDC = IERC20(usdc_);
        CONTRACTS.MATIC_LP = IJamonPair(maticlpV2_);
        CONTRACTS.USDC_LP = IJamonPair(usdclpV2_);
        RewardVesting = IJamonShareVesting(rewardVesting_);
        Governor = governor_;
        uint256 startAt = Conversor.endTime();
        ROUNDS[0].endTime = startAt.add(10 days);
        ROUNDS[1].endTime = startAt.add(20 days);
        ROUNDS[2].endTime = startAt.add(30 days);
    }

    //---------- Modifiers ----------//
    modifier onlyConversor() {
        require(_msgSender() == address(Conversor));
        _;
    }

    //----------- Internal Functions -----------//
    function _getUSD2Jamon(uint256 usdAmount_) internal view returns (uint256) {
        IJamonPair pair = IJamonPair(CONTRACTS.USDC_LP);
        (uint256 Res0, uint256 Res1, ) = pair.getReserves();

        uint256 res0 = Res0 * (1e12); // USDC 6 decimals, 6 + 12
        return ((usdAmount_ * Res1) / res0); // return amount of token0 needed to buy token1
    }

    function _getJamon2USD(uint256 jamonAmount_)
        internal
        view
        returns (uint256)
    {
        IJamonPair pair = IJamonPair(CONTRACTS.USDC_LP);
        (uint256 Res0, uint256 Res1, ) = pair.getReserves();

        uint256 res0 = Res0 * (1e12); // USDC 6 decimals, 6 + 12
        return ((jamonAmount_ * res0) / Res1); // return amount of token0 needed to buy token1
    }

    function _getMaticPrice() public view returns (uint256) {
        (, int256 price, , , ) = maticFeed.latestRoundData();
        return uint256(price * 1e10); // Return price with 18 decimals, 8 + 10.
    }

    //----------- External Functions -----------//
    function endsAt() external view returns(uint256) {
        return ROUNDS[2].endTime;
    }

    function status()
        public
        view
        override
        returns (uint256 round, uint256 rate)
    {
        if (
            ROUNDS[0].collected >= roundHardcap ||
            ROUNDS[0].endTime < block.timestamp
        ) {
            if (
                ROUNDS[1].collected >= roundHardcap ||
                ROUNDS[1].endTime < block.timestamp
            ) {
                if (
                    ROUNDS[2].collected >= roundHardcap ||
                    ROUNDS[2].endTime < block.timestamp
                ) {
                    return (4, 0);
                }
                return (3, 160);
            }
            return (2, 180);
        }
        if (Conversor.endTime() < block.timestamp) {
            return (1, 200);
        }
        return (0, 0);
    }

    function remaining4Sale(address lp_, uint256 round_)
        public
        view
        returns (uint256)
    {
        uint256 remaining;
        uint256 available;
        if (round_ == 1) {
            available = roundHardcap.sub(ROUNDS[0].collected);
        }
        if (round_ == 2) {
            available = roundHardcap.sub(ROUNDS[1].collected);
        }
        if (round_ == 3) {
            available = roundHardcap.sub(ROUNDS[2].collected);
        }
        if (lp_ == address(CONTRACTS.MATIC_LP)) {
            if (available > 0) {
                uint256 matics = (available.div(2).mul(1e18)).div(
                    _getMaticPrice()
                );
                uint256 totalMatic = CONTRACTS.WMATIC.balanceOf(
                    address(CONTRACTS.MATIC_LP)
                );
                uint256 totalSupply = CONTRACTS.MATIC_LP.totalSupply();
                uint256 percentage = matics.mul(10e18).div(
                    totalMatic
                );
                remaining = percentage.mul(totalSupply).div(10e18);
            }
        }
        if (lp_ == address(CONTRACTS.USDC_LP)) {
            if (available > 0) {
                uint256 usdc = available.div(2);
                uint256 totalUSDC = CONTRACTS.USDC.balanceOf(
                    address(CONTRACTS.USDC_LP)
                );
                uint256 totalSupply = CONTRACTS.USDC_LP.totalSupply();
                uint256 percentage = usdc.mul(10e18).div(
                    totalUSDC.mul(1e12)
                );
                remaining = percentage.mul(totalSupply).div(10e18);
            }
        }
        return remaining;
    }

    function getRewardMaticLP(uint256 amount)
        public
        view
        returns (uint256 usd_in, uint256 jamon_out)
    {
        uint256 totalSupply = CONTRACTS.MATIC_LP.totalSupply();
        uint256 totalMatic = CONTRACTS.WMATIC.balanceOf(
            address(CONTRACTS.MATIC_LP)
        );
        uint256 totalUSD = (totalMatic.mul(2).mul(_getMaticPrice())).div(1e18);
        uint256 percentage = amount.mul(10e18).div(totalSupply);
        uint256 contributed = percentage.mul(totalUSD).div(10e18);
        uint256 amountJamon = _getUSD2Jamon(contributed);
        return (contributed, amountJamon);
    }

    function getRewardUSDCLP(uint256 amount)
        public
        view
        returns (uint256 usd_in, uint256 jamon_out)
    {
        uint256 totalSupply = CONTRACTS.USDC_LP.totalSupply();
        uint256 totalUSDC = CONTRACTS
            .USDC
            .balanceOf(address(CONTRACTS.USDC_LP))
            .mul(1e12);
        uint256 totalUSD = totalUSDC.mul(2);
        uint256 percentage = amount.mul(10e18).div(totalSupply);
        uint256 contributed = percentage.mul(totalUSD).div(10e18);
        uint256 amountJamon = _getUSD2Jamon(contributed);
        return (contributed, amountJamon);
    }

    function contributeMaticLP(uint256 amount_)
        external
        whenNotPaused
        nonReentrant
        returns (
            uint256 jamonReward,
            uint256 jsnow,
            uint256 jsend
        )
    {
        require(amount_ > 0, "Invalid amount");
        (uint256 round, uint256 rate) = status();
        require(round > 0 && round < 4, "Not on sale");
        if (round == 1 && listActive) {
            require(Whitelist.contains(_msgSender()), "Wallet not allowed");
        }
        require(
            CONTRACTS.MATIC_LP.allowance(_msgSender(), address(this)) >=
                amount_,
            "LP not allowed"
        );
        uint256 allowed = remaining4Sale(address(CONTRACTS.MATIC_LP), round);
        uint256 limitAmount = listLimit && amount_ > max4list
            ? max4list
            : amount_;
        uint256 amount = limitAmount > allowed ? allowed : limitAmount;
        (uint256 contributed, uint256 reward) = getRewardMaticLP(amount);
        reward = reward.mul(rate).div(100);
        require(reward >= 600, "Reward too low");
        require(
            CONTRACTS.MATIC_LP.transferFrom(_msgSender(), Governor, amount)
        );
        uint256 rewardMonth = reward.div(12);
        uint256 JSnow = rewardMonth.div(50);
        uint256 JSend = contributed.sub(JSnow);
        ROUNDS[round.sub(1)].collected += contributed;
        RewardVesting.createVesting(_msgSender(), JSnow, JSend);
        emit Contributed(
            address(CONTRACTS.MATIC_LP),
            _msgSender(),
            reward,
            contributed
        );
        return (reward, JSnow, JSend);
    }

    function contributeUSDCLP(uint256 amount_)
        external
        whenNotPaused
        nonReentrant
        returns (
            uint256 jamonReward,
            uint256 jsnow,
            uint256 jsend
        )
    {
        require(amount_ > 0, "Invalid amount");
        (uint256 round, uint256 rate) = status();
        require(round > 0 && round < 4, "Not on sale");
        if (round == 1 && listActive) {
            require(Whitelist.contains(_msgSender()), "Wallet not allowed");
        }
        require(
            CONTRACTS.USDC_LP.allowance(_msgSender(), address(this)) >= amount_,
            "LP not allowed"
        );
        uint256 allowed = remaining4Sale(address(CONTRACTS.USDC_LP), round);
        uint256 limitAmount = listLimit && amount_ > max4list
            ? max4list
            : amount_;
        uint256 amount = limitAmount > allowed ? allowed : limitAmount;
        (uint256 contributed, uint256 reward) = getRewardUSDCLP(amount);
        reward = reward.mul(rate).div(100);
        require(reward >= 600, "Reward too low");
        require(CONTRACTS.USDC_LP.transferFrom(_msgSender(), Governor, amount));
        uint256 rewardMonth = reward.div(12);
        uint256 JSnow = rewardMonth.div(50);
        uint256 JSend = contributed.sub(JSnow);
        ROUNDS[round.sub(1)].collected += contributed;
        RewardVesting.createVesting(_msgSender(), JSnow, JSend);
        emit Contributed(
            address(CONTRACTS.USDC_LP),
            _msgSender(),
            reward,
            contributed
        );
        return (reward, JSnow, JSend);
    }

    function contributeJamon(uint256 amount_)
        external
        whenNotPaused
        nonReentrant
        returns (
            uint256 jamonReward,
            uint256 jsnow,
            uint256 jsend
        )
    {
        require(amount_ > 0, "Invalid amount");
        (uint256 round, ) = status();
        require(round == 4, "LP Rounds not ended");
        require(Max4Wallet[_msgSender()] >= amount_, "Amount not allowed");
        require(
            CONTRACTS.JAMON_V2.allowance(_msgSender(), address(this)) >=
                amount_,
            "Jamon not allowed"
        );
        uint256 contributed = _getJamon2USD(amount_).mul(150).div(100);
        uint256 reward = amount_.mul(110).div(100);
        require(reward >= 600 && contributed > 0, "Reward too low");
        uint256 rewardMonth = reward.div(12);
        uint256 JSnow = rewardMonth.div(50);
        uint256 JSend = contributed.sub(JSnow);
        CONTRACTS.JAMON_V2.burnFrom(_msgSender(), amount_);
        RewardVesting.createVesting(_msgSender(), JSnow, JSend);
        emit Contributed(
            address(CONTRACTS.JAMON_V2),
            _msgSender(),
            reward,
            contributed
        );
        return (reward, JSnow, JSend);
    }

    function whitelistCount() external view returns (uint256) {
        return Whitelist.length();
    }

    function setWhitelist(bool set_) external onlyOwner {
        listActive = set_;
    }

    function editWhitelist(address[] memory _users, bool _add)
        external
        onlyOwner
    {
        if (_add) {
            for (uint256 i = 0; i < _users.length; i++) {
                Whitelist.add(_users[i]);
            }
        } else {
            for (uint256 i = 0; i < _users.length; i++) {
                Whitelist.remove(_users[i]);
            }
        }
    }

    function editWhitelist(
        address[] memory _users,
        uint256[] memory _amounts,
        bool _add
    ) external onlyOwner {
        if (_add) {
            for (uint256 i = 0; i < _users.length; i++) {
                Max4Wallet[_users[i]] = _amounts[i];
            }
        } else {
            for (uint256 i = 0; i < _users.length; i++) {
                delete Max4Wallet[_users[i]];
            }
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
