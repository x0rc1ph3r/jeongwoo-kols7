/**
 *Submitted for verification at testnet.bscscan.com on 2025-11-23
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    KOLS Staking Contract V3.1 (Insurance Pool + CAP Included)

    ✅ 주요 변경점 (V3 → V3.1)
    - 보상 출금 시 2% 수수료:
        • 1.8% → 재분배(diff로 반영)
        • 0.2% → 보험 풀(insuranceReserve)에 적립
    - rewardBalance 부족 시 보험 풀에서 자동 보충 (마지막 출금자도 실패 없음)
    - 보험 풀 상한(INSURANCE_CAP) = 100 USDT
      → 보험 풀 잔액이 100 USDT를 초과하면 초과분은 rewardBalance로 이동하여
         전체 스테이커에게 재분배됨

    기존 규칙:
      1) 최소 스테이킹: 유저별 총 1000 KOLS 이상
      2) 스테이킹은 즉시 활성화 (7일 대기 없음)
      3) 언스테이킹은 전액만 가능, 7일 대기 후 출금
      4) 언스테이킹 대기 중에는 스테이킹 불가
      5) 보상 토큰은 USDT, rewardPerShare(1e12 정밀도) 방식
      6) 언스테이킹 요청 이후에도, 그 이전까지 쌓인 보상은 언제든 출금 가능
      7) 관리자(Owner) 없음, 파라미터 변경 불가
      8) 통계 제공:
         - 현재 참여자 수
         - 오늘/어제/이번 주/지난 주/이번 달/지난 달 보상
         - 누적 보상
*/

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount)
        external
        returns (bool);
    function allowance(address owner, address spender)
        external
        view
        returns (uint256);
    function approve(address spender, uint256 amount)
        external
        returns (bool);
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

library SafeERC20 {
    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        require(token.transfer(to, value), "TRANSFER_FAILED");
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        require(token.transferFrom(from, to, value), "TRANSFER_FROM_FAILED");
    }

    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        require(token.approve(spender, value), "APPROVE_FAILED");
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANT");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract KolsStakingV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===========================
    // 기본 설정
    // ===========================
    IERC20 public immutable KOLS;
    IERC20 public immutable USDT;

    uint256 public constant MIN_STAKE     = 1000 * 1e18;
    uint256 public constant UNSTAKE_LOCK  = 7 days;

    // 보상 수수료: 2% (전체 보상의 2%)
    uint256 public constant FEE_RATE      = 200;    // 2.00%
    uint256 public constant FEE_DENOM     = 10000;  // 10000분율 기준

    // 보험 풀 적립 비율: 전체 보상의 0.2%
    // → 수수료 2% 중 10%가 보험, 90%가 재분배
    uint256 public constant INS_RATE      = 20;     // 0.20%

    // 보험 풀 상한: 100 USDT
    uint256 public constant INSURANCE_CAP = 100 * 1e18;

    // rewardPerShare 정밀도
    uint256 public constant REWARD_PRECISION = 1e12;

    // ===========================
    // 유저 구조체
    // ===========================
    struct UserInfo {
        uint256 amount;             // 활성 스테이킹 KOLS
        uint256 rewardDebt;         // accRewardPerShare 기준 부채
        uint256 pendingReward;      // 누적 보상(gross)
        uint256 unstakeAmount;      // 언스테이킹 대기 KOLS
        uint256 unstakeUnlockTime;  // 언스테이킹 출금 가능 시점
    }

    mapping(address => UserInfo) public users;

    // ===========================
    // 풀 상태 변수
    // ===========================
    uint256 public totalActiveStaked;
    uint256 public totalUnstakingPending;
    uint256 public totalStakerCount;
    mapping(address => bool) public isStaker;

    uint256 public accRewardPerShare;
    uint256 public rewardBalance;      // 보험 풀 제외, 분배 가능한 USDT 잔액
    uint256 public insuranceReserve;   // 보험 풀 USDT 잔액

    // 누적 분배/수수료/인출 통계
    uint256 public totalRewardsDistributed; // diff 기반 누적 분배
    uint256 public totalUserClaimedNet;     // 유저 실제 인출(net)
    uint256 public totalFeeToPool;          // 재분배 수수료 누적 (1.8%)
    uint256 public totalFeeToInsurance;     // 보험 풀 적립 수수료 누적 (0.2%)

    // ===========================
    // 일/주/월 통계
    // ===========================
    uint256 public todayReward;
    uint256 public yesterdayReward;

    uint256 public thisWeekReward;
    uint256 public lastWeekReward;

    uint256 public thisMonthReward;
    uint256 public lastMonthReward;

    uint256 public lastRewardDay;
    uint256 public lastRewardWeek;
    uint256 public lastRewardMonth;

    // ===========================
    // 이벤트
    // ===========================
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 unlockTime);
    event UnstakeWithdrawn(address indexed user, uint256 amount);

    event RewardClaimed(
        address indexed user,
        uint256 gross,
        uint256 net,
        uint256 feePool,
        uint256 feeInsurance
    );

    event RewardAdded(uint256 amount);
    event InsuranceUsed(uint256 amount);

    // ===========================
    // 생성자
    // ===========================
    constructor() {
        KOLS = IERC20(0x1fb87C271dDdDd7D06E8384566717482D88a2456);
        USDT = IERC20(0xe19B4cBc6ee843c4d77dd55e3DfCced3FdA87be9);

        uint256 d = block.timestamp / 1 days;
        lastRewardDay   = d;
        lastRewardWeek  = d / 7;
        lastRewardMonth = d / 30;
    }

    // ===========================
    // 내부 유틸 — 날짜별 통계 업데이트
    // ===========================
    function _updateDateStats() internal {
        uint256 currentDay = block.timestamp / 1 days;

        // 일 단위 (오늘/어제)
        if (currentDay > lastRewardDay) {
            yesterdayReward = todayReward;
            todayReward = 0;
            lastRewardDay = currentDay;
        }

        // 주 단위 (일~토 근사: 7일 블록)
        uint256 currentWeek = currentDay / 7;
        if (currentWeek > lastRewardWeek) {
            lastWeekReward = thisWeekReward;
            thisWeekReward = 0;
            lastRewardWeek = currentWeek;
        }

        // 월 단위 (30일 근사)
        uint256 currentMonth = currentDay / 30;
        if (currentMonth > lastRewardMonth) {
            lastMonthReward = thisMonthReward;
            thisMonthReward = 0;
            lastRewardMonth = currentMonth;
        }
    }

    // ===========================
    // 외부 수익 + 재분배(diff) 반영
    // 보험 풀(insuranceReserve)은 제외
    // ===========================
    function _updatePool() internal {
        _updateDateStats();

        uint256 balance = USDT.balanceOf(address(this));

        // 보험 풀 제외 "실제 분배 가능 잔액"
        uint256 effectiveBalance;
        if (balance > insuranceReserve) {
            effectiveBalance = balance - insuranceReserve;
        } else {
            effectiveBalance = 0;
        }

        if (effectiveBalance > rewardBalance && totalActiveStaked > 0) {
            uint256 diff = effectiveBalance - rewardBalance;

            accRewardPerShare =
                accRewardPerShare +
                (diff * REWARD_PRECISION) / totalActiveStaked;

            totalRewardsDistributed += diff;

            todayReward     += diff;
            thisWeekReward  += diff;
            thisMonthReward += diff;

            emit RewardAdded(diff);
        }

        rewardBalance = effectiveBalance;
    }

    // ===========================
    // 내부 유저 보상 업데이트
    // ===========================
    function _updateUserReward(address _user) internal {
        UserInfo storage u = users[_user];

        if (u.amount > 0) {
            uint256 accumulated =
                (u.amount * accRewardPerShare) / REWARD_PRECISION;
            uint256 reward = accumulated - u.rewardDebt;

            if (reward > 0) {
                u.pendingReward += reward;
            }
        }

        u.rewardDebt =
            (u.amount * accRewardPerShare) / REWARD_PRECISION;
    }

    // ===========================
    // 스테이킹
    // ===========================
    function stake(uint256 _amount) external nonReentrant {
        require(_amount > 0, "STAKE_ZERO");
        UserInfo storage u = users[msg.sender];

        require(u.unstakeAmount == 0, "UNSTAKING_IN_PROGRESS");

        _updatePool();
        _updateUserReward(msg.sender);

        require(
            u.amount + _amount >= MIN_STAKE,
            "MIN_STAKE_1000_KOLS"
        );

        KOLS.safeTransferFrom(msg.sender, address(this), _amount);

        if (!isStaker[msg.sender]) {
            isStaker[msg.sender] = true;
            totalStakerCount += 1;
        }

        u.amount += _amount;
        totalActiveStaked += _amount;

        u.rewardDebt =
            (u.amount * accRewardPerShare) / REWARD_PRECISION;

        emit Staked(msg.sender, _amount);
    }

    // ===========================
    // 언스테이킹 요청
    // ===========================
    function _requestUnstakeInternal(address _user) internal {
        UserInfo storage u = users[_user];
        require(u.unstakeAmount == 0, "ALREADY_UNSTAKING");
        require(u.amount > 0, "NO_ACTIVE_STAKE");

        _updatePool();
        _updateUserReward(_user);

        uint256 amt = u.amount;

        u.amount = 0;
        totalActiveStaked -= amt;
        u.rewardDebt = 0;

        u.unstakeAmount = amt;
        u.unstakeUnlockTime = block.timestamp + UNSTAKE_LOCK;
        totalUnstakingPending += amt;

        emit UnstakeRequested(_user, amt, u.unstakeUnlockTime);
    }

    function requestUnstake() external nonReentrant {
        _requestUnstakeInternal(msg.sender);
    }

    // ===========================
    // 언스테이킹 출금 (7일 이후)
    // ===========================
    function withdrawUnstaked() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        uint256 amt = u.unstakeAmount;

        require(amt > 0, "NO_UNSTAKING");
        require(block.timestamp >= u.unstakeUnlockTime, "UNSTAKE_LOCKED");

        u.unstakeAmount = 0;
        u.unstakeUnlockTime = 0;
        totalUnstakingPending -= amt;

        KOLS.safeTransfer(msg.sender, amt);

        if (isStaker[msg.sender]) {
            isStaker[msg.sender] = false;
            if (totalStakerCount > 0) {
                totalStakerCount -= 1;
            }
        }

        emit UnstakeWithdrawn(msg.sender, amt);
    }

    // ===========================
    // 🔥 보상 클레임 (보험 풀 자동 보충 + CAP)
    // ===========================
    function _claimRewardInternal(address _user) internal {
        _updatePool();
        UserInfo storage u = users[_user];
        _updateUserReward(_user);

        uint256 reward = u.pendingReward; // gross 기준
        require(reward > 0, "NO_REWARD");

        // 2% 수수료 전체
        uint256 feeTotal = (reward * FEE_RATE) / FEE_DENOM;

        // 전체 보상의 0.2%는 보험 풀 적립
        uint256 feeToInsurance = (reward * INS_RATE) / FEE_DENOM;

        // 재분배 수수료 = 2% - 0.2% = 1.8%
        uint256 feeToPool = feeTotal - feeToInsurance;

        // 유저 실수령액(net)
        uint256 net = reward - feeTotal;

        // 유저 pendingReward 초기화
        u.pendingReward = 0;

        // 지급 가능한 총액 = rewardBalance + insuranceReserve
        uint256 available = rewardBalance + insuranceReserve;
        require(available >= reward, "INSUFFICIENT_FUNDS");

        // rewardBalance 먼저 사용, 부족분은 보험풀에서 자동 보충
        if (rewardBalance >= reward) {
            rewardBalance -= reward;
        } else {
            uint256 shortage = reward - rewardBalance;
            rewardBalance = 0;

            require(insuranceReserve >= shortage, "INSURANCE_SHORTAGE");
            insuranceReserve -= shortage;

            emit InsuranceUsed(shortage);
        }

        // 수수료 처리
        // 보험 풀 적립
        insuranceReserve += feeToInsurance;
        totalFeeToInsurance += feeToInsurance;

        // 보험 풀 상한 적용 (최대 100 USDT)
        if (insuranceReserve > INSURANCE_CAP) {
            uint256 excess = insuranceReserve - INSURANCE_CAP;
            insuranceReserve = INSURANCE_CAP;

            // 초과분은 rewardBalance에 추가되어 전체 스테이커에게 분배됨
            rewardBalance += excess;
        }

        // 재분배 수수료는 rewardBalance에 더해져 다음 diff 분배에 반영됨
        rewardBalance += feeToPool;
        totalFeeToPool += feeToPool;

        // 유저에게 net 지급
        USDT.safeTransfer(_user, net);
        totalUserClaimedNet += net;

        emit RewardClaimed(
            _user,
            reward,
            net,
            feeToPool,
            feeToInsurance
        );
        // V2에서 문제되던 claim 후 _updatePool() 재호출은 제거.
    }

    function claimReward() public nonReentrant {
        _claimRewardInternal(msg.sender);
    }

    function claimRewardAndUnstake() external nonReentrant {
        _claimRewardInternal(msg.sender);
        _requestUnstakeInternal(msg.sender);
    }

    // ===========================
    // VIEW 함수 (UI 용)
    // ===========================
    function userActiveStaked(address _user)
        external
        view
        returns (uint256)
    {
        return users[_user].amount;
    }

    function userUnstaking(address _user)
        external
        view
        returns (uint256 amount, uint256 unlockTime)
    {
        UserInfo storage u = users[_user];
        amount = u.unstakeAmount;
        unlockTime = u.unstakeUnlockTime;
    }

    function isUnstaking(address _user)
        external
        view
        returns (bool)
    {
        return users[_user].unstakeAmount > 0;
    }

    // gross 기준 예상 보상
    function pendingReward(address _user)
        public
        view
        returns (uint256)
    {
        UserInfo storage u = users[_user];

        uint256 _accRewardPerShare = accRewardPerShare;
        uint256 _totalActiveStaked = totalActiveStaked;

        uint256 balance = USDT.balanceOf(address(this));

        uint256 effectiveBalance = 0;
        if (balance > insuranceReserve) {
            effectiveBalance = balance - insuranceReserve;
        }

        if (effectiveBalance > rewardBalance && _totalActiveStaked > 0) {
            uint256 diff = effectiveBalance - rewardBalance;
            _accRewardPerShare =
                _accRewardPerShare +
                (diff * REWARD_PRECISION) / _totalActiveStaked;
        }

        uint256 accumulated =
            (u.amount * _accRewardPerShare) / REWARD_PRECISION;
        uint256 reward = accumulated - u.rewardDebt;

        return u.pendingReward + reward;
    }

    // net 기준 예상 보상 (2% 수수료 차감 후)
    function pendingRewardAfterFee(address _user)
        external
        view
        returns (uint256)
    {
        uint256 gross = pendingReward(_user);
        if (gross == 0) return 0;

        uint256 feeTotal = (gross * FEE_RATE) / FEE_DENOM;
        return gross - feeTotal;
    }

    // 규칙/기본 정보
    function minStakeAmount() external pure returns (uint256) {
        return MIN_STAKE;
    }

    function unstakeLockPeriod() external pure returns (uint256) {
        return UNSTAKE_LOCK;
    }

    function feeRate() external pure returns (uint256, uint256) {
        return (FEE_RATE, FEE_DENOM);
    }

    function insuranceRate() external pure returns (uint256, uint256) {
        return (INS_RATE, FEE_DENOM);
    }

    function insuranceCap() external pure returns (uint256) {
        return INSURANCE_CAP;
    }

    function kolsToken() external view returns (address) {
        return address(KOLS);
    }

    function usdtToken() external view returns (address) {
        return address(USDT);
    }

    // 실제 잔고 조회
    function contractUsdtBalance() external view returns (uint256) {
        return USDT.balanceOf(address(this));
    }

    function contractKolsBalance() external view returns (uint256) {
        return KOLS.balanceOf(address(this));
    }

    // 보험 풀 잔액
    function insurancePoolBalance() external view returns (uint256) {
        return insuranceReserve;
    }

    // 누적 인출/수수료/분배 통계
    function totalUserClaimed() external view returns (uint256) {
        return totalUserClaimedNet;
    }

    function totalFeeStats()
        external
        view
        returns (
            uint256 feeToPool_,
            uint256 feeToInsurance_,
            uint256 feeTotal_
        )
    {
        feeToPool_      = totalFeeToPool;
        feeToInsurance_ = totalFeeToInsurance;
        feeTotal_       = totalFeeToPool + totalFeeToInsurance;
    }

    function totalDistributed() external view returns (uint256) {
        return totalRewardsDistributed;
    }
}