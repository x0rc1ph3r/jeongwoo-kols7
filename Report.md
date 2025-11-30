KOLS Smart Contracts Audit Report

# KOLSParticipationBadge.sol

## No findings

# KOLSBadgeMarketPlace.sol

## Finding: Unnecessary function parameters for the function `_processFee`

## Summary

The internal function \_processFee includes two unused parameters. These parameters are passed every time the function is called, causing additional calldata expansion and stack operations, which increases gas consumption.
This also reduces code clarity and can lead to future maintenance errors if developers mistakenly assume these parameters are used.

## Affected Function (Original)

```js
   function _processFee(
    address payer,
    uint256 price,
    bool,
    uint256
) internal returns (uint256 sellerAmount) {

    uint256 feeAmount = (price * feeBps) / 10000;
    sellerAmount = price - feeAmount;

    if (feeAmount > 0) {
        require(usdt.transferFrom(payer, feeRecipient, feeAmount), "fee tx fail");
    }
}
```

## Root Cause

- The function signature includes two parameters that are neither referenced nor used.
- These parameters are also supplied by upstream calls, causing:
  - Additional calldata decoding
  - Stack writes
  - Unnecessary gas usage

## Impact

Severity: **Low**

### Issues introduced:

- Every call to `_processFee` incurs additional gas because unused parameters still require:
  - ABI decoding
  - Stack allocation
  - Increased call-site calldata size

## Recommended Fix

```diff
   function _processFee(
    address payer,
    uint256 price,
-   bool,
-   uint256
) internal returns (uint256 sellerAmount) {

    uint256 feeAmount = (price * feeBps) / 10000;
    sellerAmount = price - feeAmount;

    if (feeAmount > 0) {
        require(usdt.transferFrom(payer, feeRecipient, feeAmount), "fee tx fail");
    }
}
```

and in KOLSBadgeMarketplace::buyBadge at line 192,

```diff
-   uint256 sellerAmount = _processFee(buyer, price, false, tokenId);
+   uint256 sellerAmount = _processFee(buyer, price);
```

and also in KOLSBadgeMarketplace::buyBundle at line 253,

```diff
-   uint256 sellerAmount = _processFee(buyer, price, true, id);
+   uint256 sellerAmount = _processFee(buyer, price, true, id);
```

This reduces gas usage and improves code clarity.

# UnilevelUSDT.sol

## Finding: Hard-Capped Direct Referral Return Causes Data Truncation

## Summary

The original implementation of `getDirectReferralsLimited` enforces a hard cap of 300 addresses and always returns only the **first 300 direct referrals**, regardless of how many actually exist. This design leads to silent data truncation and makes it impossible to access referrals beyond the first 300, creating functional, scalability, and UX limitations.

## Affected Function (Original)

```js
 /**
     * 직추천(directReferrals) 상위 일부만 반환
     * - 오래된 순서(먼저 가입한 순서) 기준으로 최대 300개까지만 반환
     * - 조직도에서 상위 300명까지만 한 번에 조회
     * - 300명을 초과하는 유저는 count로만 관리하거나 개별 조회(checkIsDownline 등)에 사용
     */
    function getDirectReferralsLimited(address _user)
        external
        view
        returns (address[] memory)
    {
        address[] storage list = _directReferrals[_user];
        uint256 len = list.length;

        if (len <= MAX_DIRECT_REFERRALS_RETURN) {
            // 전체 길이가 300 이하이면 그대로 반환
            return list;
        }

        // 오래된 순(0 ~ 299)까지만 잘라서 반환
        address[] memory result = new address[](MAX_DIRECT_REFERRALS_RETURN);
        for (uint256 i = 0; i < MAX_DIRECT_REFERRALS_RETURN; i++) {
            result[i] = list[i];
        }
        return result;
    }
```

## Root Cause

The function:

- Always returns referrals from index `0` to `299`
- Provides **no mechanism** to:
  - Retrieve referrals beyond index 299
  - Paginate results
  - Query newer referrals

This permanently hides data for users with more than 300 referrals.

## Impact

Severity: **Medium**

### Issues introduced:

- Inaccessible referral records beyond index 299
- Broken analytics / reward tracking if used for calculations
- Frontend forced to rely on incomplete data

Although funds are not directly at risk, business logic relying on full referral visibility becomes unreliable.

## Recommended Fix

Replace the function with this:

```js
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
```

This enables full visibility without sacrificing gas safety.


# UnilevelUSDT.sol

## Finding: Hard-Capped Direct Referral Return Causes Data Truncation


## Summary
