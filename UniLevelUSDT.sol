/**
 *Submitted for verification at testnet.bscscan.com on 2025-11-23
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * BSC 테스트넷용 유니레벨 7 USDT 분배 컨트랙트 (다운라인 수 카운트 + 조회 기능 확장)
 *
 * - 토큰: 테스트넷 USDT (18 decimals 가정)
 * - 예치: 항상 7 USDT
 * - 분배:
 *   - 상위 6단계(upline)까지 각 1 USDT씩 pendingReward에 누적
 *   - 상위 단계가 부족하면 남는 금액은 treasuryWallet(스테이킹 컨트랙트)로 전송
 * - 출금:
 *   - 유저가 7 USDT 예치 시점에 자신의 pendingReward 전체를 출금
 *   - 출금 수수료 2% → feeWallet(개인 지갑)으로 전송
 * - 구조:
 *   - 유니레벨 (각 유저는 referrer 1명, 하위는 무제한)
 *   - 동일 지갑은 한 번만 참여 가능 (referrer 변경 불가)
 * - 다운라인 카운트:
 *   - 새 유저가 가입할 때, 해당 유저의 상위 6단계까지 downlineCount++
 *   - getDownlineCount(user) 로 나 기준 하위 유저 총 수 조회 가능 (보상 트리 6단계 기준)
 * - 조회:
 *   - 본인 pendingReward
 *   - 본인 totalEarned / totalDeposited / totalWithdrawn
 *   - 나 기준 상위 6명(getUpline6)
 *   - 직추천 리스트 전체(getDirectReferrals)  ← 기존 유지
 *   - 직추천 상위 300명만 반환(getDirectReferralsLimited)  ← 신규
 *   - 직추천 총 인원수(getDirectReferralsCount) ← 신규
 *   - 특정 주소가 나의 하위인지, 몇 단계인지 확인(checkIsDownline) ← 신규
 *   - 나 기준 하위 유저 수(getDownlineCount)
 *   - 전체 참여 유저 수, 총 예치, treasury 전송 총액, 수수료 총액, 마지막 참여자
 *
 * 테스트넷 주소:
 *   - USDT 토큰 주소:              0xe19B4cBc6ee843c4d77dd55e3dfcced3fda87be9
 *   - 스테이킹 컨트랙트(treasury): 0x91e830c16f6f15e0cf12b501b3617576605ec98f
 *   - 수수료 지갑(feeWallet):      0xb2566b4806e264e85771f78BF41FAf022CB94f8a
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

/**
 * 간단한 Ownable 구현
 */
abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
}

/**
 * ReentrancyGuard (재진입 공격 방지)
 */
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract UniLevelUSDT is Ownable, ReentrancyGuard {
    // ---------------- 기본 상수 ----------------

    uint8 public constant TOKEN_DECIMALS = 18;
    uint256 public constant UNIT = 10 ** TOKEN_DECIMALS;

    // 예치 금액: 7 USDT
    uint256 public constant DEPOSIT_AMOUNT = 7 * UNIT;

    // 레벨당 보상: 1 USDT
    uint8   public constant MAX_LEVEL = 6;
    uint256 public constant LEVEL_REWARD = 1 * 1e18;

    // 출금 수수료 비율: 2%
    uint256 public constant FEE_PERCENT     = 2;      // 2%
    uint256 public constant FEE_DENOMINATOR = 100;    // 100 = 100%

    // 직추천 조회 최대 반환 개수 (오래된 순으로 300개까지)
    uint256 public constant MAX_DIRECT_REFERRALS_RETURN = 300;

    // ---------------- 토큰 및 지갑 주소 ----------------

    IERC20 public immutable usdtToken;

    // 상위 유저가 부족할 때 남는 금액이 전송되는 외부 지갑 (스테이킹 컨트랙트)
    address public treasuryWallet;

    // 출금 수수료(2%)가 전송되는 외부 지갑 (개인 지갑)
    address public feeWallet;

    // ---------------- 유저 정보 구조 ----------------

    struct UserInfo {
        address referrer;        // 추천인 (상위 1단계)
        uint256 totalDeposited;  // 누적 예치 금액
        uint256 totalEarned;     // 하위 유저 입금으로 발생한 총 수익 (출금 포함)
        uint256 totalWithdrawn;  // 지금까지 출금된 수익 총합
        uint256 pendingReward;   // 아직 출금되지 않은 인출 가능 수익
        uint256 downlineCount;   // 나 기준 하위 유저 수 (보상 트리 6단계 기준)
        bool    registered;      // 참여 여부 (한 번 참여 후 referrer 변경 불가)
    }

    // 유저별 정보
    mapping(address => UserInfo) public users;

    // 직추천 리스트 (유니레벨 트리 구성용, 순서: 오래된 순)
    mapping(address => address[]) private _directReferrals;

    // ---------------- 통계용 상태 변수 ----------------

    uint256 public totalUsers;           // 전체 참여 유저 수
    uint256 public totalDepositedUSDT;   // 컨트랙트에 누적 입금된 USDT 총량
    uint256 public totalSentToTreasury;  // treasuryWallet으로 전송된 USDT 총량
    uint256 public totalFeeAmount;       // feeWallet으로 전송된 수수료 총량

    // 마지막 참여자 주소 (추천 코드 자동 선택용)
    address public lastJoinedUser;

    // ---------------- 이벤트 ----------------

    event Registered(address indexed user, address indexed referrer);
    event Deposited(address indexed user, uint256 amount);
    event RewardAdded(
        address indexed fromUser,
        address indexed toUser,
        uint256 amount,
        uint8   level
    );
    event Withdrawn(
        address indexed user,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount
    );
    event TreasuryPaid(address indexed fromUser, uint256 amount);
    event FeePaid(address indexed fromUser, uint256 amount);
    event TreasuryWalletChanged(address indexed oldWallet, address indexed newWallet);
    event FeeWalletChanged(address indexed oldWallet, address indexed newWallet);

    // ---------------- 생성자 ----------------

    constructor() {
        usdtToken = IERC20(0xe19B4cBc6ee843c4d77dd55e3DfCced3FdA87be9); // 테스트 USDT
        treasuryWallet = 0x91E830c16F6f15E0cF12B501B3617576605eC98f;    // 스테이킹 컨트랙트
        feeWallet      = 0xb2566b4806e264e85771f78BF41FAf022CB94f8A;    // 본인 지갑
    }

    // ---------------- 관리자 함수 ----------------

    /**
     * 수익금이 전송될 외부 지갑(스테이킹 컨트랙트) 변경
     */
    function setTreasuryWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "treasury: zero address");
        emit TreasuryWalletChanged(treasuryWallet, _wallet);
        treasuryWallet = _wallet;
    }

    /**
     * 출금 수수료가 전송될 외부 지갑(개인 지갑) 변경
     */
    function setFeeWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "fee: zero address");
        emit FeeWalletChanged(feeWallet, _wallet);
        feeWallet = _wallet;
    }

    /**
     * 루트 유저를 (referrer 없이) 미리 생성하는 함수
     * - owner만 호출 가능
     * - 이 루트 유저는 다른 유저의 상위 referrer로 사용될 수 있음
     * - downlineCount 는 증가시키지 않음
     */
    function ownerRegisterRoot(address _user) external onlyOwner {
        require(_user != address(0), "root: zero address");
        require(!users[_user].registered, "root: already registered");

        UserInfo storage info = users[_user];
        info.registered = true;
        info.referrer   = address(0);

        totalUsers += 1;
        lastJoinedUser = _user;

        emit Registered(_user, address(0));
    }

    // ---------------- 내부 유저 등록 로직 ----------------

    /**
     * 신규 유저 등록 + 직추천 추가 + 상위 6단계 downlineCount 증가
     */
    function _registerUser(address _user, address _referrer) internal {
        require(_user != address(0), "reg: zero user");
        require(!users[_user].registered, "reg: already registered");
        require(_referrer != address(0), "reg: referrer required");
        require(users[_referrer].registered, "reg: referrer not registered");
        require(_referrer != _user, "reg: cannot refer self");

        UserInfo storage info = users[_user];
        info.registered = true;
        info.referrer   = _referrer;

        totalUsers += 1;
        lastJoinedUser = _user;

        // 직추천 리스트에 추가 (오래된 순으로 push)
        _directReferrals[_referrer].push(_user);

        emit Registered(_user, _referrer);

        // 상위 6단계까지 downlineCount 증가
        address current = _referrer;
        uint8 depth = 1;
        while (current != address(0) && depth <= MAX_LEVEL) {
            users[current].downlineCount += 1;
            current = users[current].referrer;
            unchecked { ++depth; }
        }
    }

    // ---------------- 핵심 로직: 예치 + 출금 ----------------

    /**
     * 7 USDT 예치 + 상위 6단계 분배 + 본인 수익 출금(2% 수수료)까지 한 번에 처리
     *
     * - 첫 참여 시:
     *    - referrer 필수
     *    - referrer는 이미 등록된 유저여야 함
     *    - 자신을 referrer로 설정 불가
     * - 재참여 시:
     *    - referrer 인자는 무시 (이미 등록된 경우)
     */
    function depositAndClaim(address _referrer) external nonReentrant {
        UserInfo storage user = users[msg.sender];

        // 1) 신규 유저라면 등록 처리
        if (!user.registered) {
            _registerUser(msg.sender, _referrer);
        }

        // 2) 7 USDT 전송 (컨트랙트로)
        require(
            usdtToken.transferFrom(msg.sender, address(this), DEPOSIT_AMOUNT),
            "USDT transferFrom failed"
        );

        user.totalDeposited  += DEPOSIT_AMOUNT;
        totalDepositedUSDT   += DEPOSIT_AMOUNT;

        emit Deposited(msg.sender, DEPOSIT_AMOUNT);

        // 3) 상위 6단계에 각 1 USDT씩 분배 (pendingReward에 누적)
        uint256 distributed = 0;
        address current = users[msg.sender].referrer;

        for (uint8 level = 1; level <= MAX_LEVEL; level++) {
            if (current == address(0)) {
                break;
            }

            UserInfo storage up = users[current];
            if (!up.registered) {
                break;
            }

            up.pendingReward += LEVEL_REWARD;
            up.totalEarned   += LEVEL_REWARD;
            distributed      += LEVEL_REWARD;

            emit RewardAdded(msg.sender, current, LEVEL_REWARD, level);

            current = users[current].referrer;
        }

        // 4) 남은 금액은 treasuryWallet 으로 전송
        uint256 remain = DEPOSIT_AMOUNT - distributed;
        if (remain > 0) {
            require(
                usdtToken.transfer(treasuryWallet, remain),
                "treasury transfer failed"
            );
            totalSentToTreasury += remain;
            emit TreasuryPaid(msg.sender, remain);
        }

        // 5) 본인 pendingReward 전액 출금 (2% 수수료)
        uint256 claimable = user.pendingReward;
        if (claimable > 0) {
            user.pendingReward  = 0;
            user.totalWithdrawn += claimable;

            uint256 feeAmount = (claimable * FEE_PERCENT) / FEE_DENOMINATOR;
            uint256 netAmount = claimable - feeAmount;

            if (feeAmount > 0) {
                require(
                    usdtToken.transfer(feeWallet, feeAmount),
                    "fee transfer failed"
                );
                totalFeeAmount += feeAmount;
                emit FeePaid(msg.sender, feeAmount);
            }

            require(
                usdtToken.transfer(msg.sender, netAmount),
                "payout transfer failed"
            );

            emit Withdrawn(msg.sender, claimable, netAmount, feeAmount);
        }
    }

    // ---------------- 조회용 뷰 함수 (기존) ----------------

    /// 유저의 인출 가능한 수익 (pendingReward)
    function getPendingReward(address _user) external view returns (uint256) {
        return users[_user].pendingReward;
    }

    /// 유저 기준 상위 6명(upline) 조회
    function getUpline6(address _user) external view returns (address[6] memory) {
        address[6] memory uplines;
        address current = users[_user].referrer;

        for (uint8 i = 0; i < 6 && current != address(0); i++) {
            uplines[i] = current;
            current = users[current].referrer;
        }

        return uplines;
    }

    /// 직추천(directReferrals) 전체 반환 (기존 기능 유지)
    function getDirectReferrals(address _user) external view returns (address[] memory) {
        return _directReferrals[_user];
    }

    // ---------------- 조회용 뷰 함수 (신규 추가) ----------------

    /**
    * returns 300 개 이하의 직추천(directReferrals) 주소 배열 from index
    * - index는 0부터 시작 0, 1, 2, ...
    * - 최대 300개까지만 반환 (오래된 순으로)start to end
    * - index가 범위를 벗어나면 빈 배열 반환
    */
    function getDirectReferralsLimited(address _user, uint256 _index)
        external
        view
        returns (address[] memory)
    {
        address[] storage list = _directReferrals[_user];
        uint256 len = list.length;

        uint256 start = _index * MAX_DIRECT_REFERRALS_RETURN;
        // _index가 범위를 벗어나면 빈 배열 반환
        if (start >= len) {
            return new address[](0);
        }

        uint256 end = start + MAX_DIRECT_REFERRALS_RETURN;
        if (end > len) {
            end = len;
        }

        // start부터 end까지의 주소 배열 반환
        uint256 size = end - start;
        address[] memory result = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = list[start + i];
        }
        return result;
    }

    /**
     * 직추천(directReferrals) 총 인원 수 반환
     * - 300명을 초과하는 인원도 모두 포함
     * - UI에서 "직추천 총 인원수" 표시용으로 사용
     */
    function getDirectReferralsCount(address _user) external view returns (uint256) {
        return _directReferrals[_user].length;
    }

    /**
     * 나 기준 하위 유저 수 (보상 트리 기준 최대 6단계)
     * - 새 유저 가입 시, 해당 유저의 상위 6단계까지 downlineCount 를 증가시킴
     */
    function getDownlineCount(address _user) external view returns (uint256) {
        return users[_user].downlineCount;
    }

    /**
     * 특정 target 주소가 user의 하위(downline)인지 여부와, 몇 단계인지 확인
     *
     * - 반환값:
     *   - isDownline: true/false
     *   - level: 1~6 (1단계~6단계), 하위가 아니면 0
     *
     * - 동작:
     *   target의 referrer 체인을 최대 MAX_LEVEL(6단계)까지 역추적하면서
     *   user와 일치하는 상위가 나오는지 검사
     */
    function checkIsDownline(address user, address target)
        external
        view
        returns (bool isDownline, uint8 level)
    {
        if (user == address(0) || target == address(0) || user == target) {
            return (false, 0);
        }

        address current = users[target].referrer;
        uint8 depth = 1;

        while (current != address(0) && depth <= MAX_LEVEL) {
            if (current == user) {
                return (true, depth);
            }
            current = users[current].referrer;
            unchecked { ++depth; }
        }

        return (false, 0);
    }

    // ---------------- 통계 조회 (기존) ----------------

    /// 유저의 총 수익 (인출된 것 포함, totalEarned)
    function getTotalEarning(address _user) external view returns (uint256) {
        return users[_user].totalEarned;
    }

    /// 전체 참여 유저 수
    function getTotalUsers() external view returns (uint256) {
        return totalUsers;
    }

    /// 총 입금된 USDT 양
    function getTotalDeposited() external view returns (uint256) {
        return totalDepositedUSDT;
    }

    /// treasuryWallet(스테이킹 컨트랙트)로 전송된 총 수량
    function getTotalSentToTreasury() external view returns (uint256) {
        return totalSentToTreasury;
    }

    /// 출금 수수료로 feeWallet에 전송된 총 수량
    function getTotalFeeAmount() external view returns (uint256) {
        return totalFeeAmount;
    }

    /// 마지막에 참여한 지갑 주소
    function getLastJoinedUser() external view returns (address) {
        return lastJoinedUser;
    }
}