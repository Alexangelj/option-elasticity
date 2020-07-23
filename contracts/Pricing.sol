pragma solidity >=0.5.12 <=0.6.2;

import { ABDKMath64x64 } from "./libraries/ABDKMath64x64.sol";
import { SafeMath } from "./libraries/SafeMath.sol";

contract Pricing {
    using ABDKMath64x64 for *;
    using SafeMath for uint256;

    uint256 public constant YEAR = 31449600;
    uint256 public constant MANTISSA = 10**8;
    uint256 public constant DENOMINATOR = 10**18;
    uint256 public constant PERCENTAGE = 10**3;

    constructor() public {}

    /**
     * @dev Calculate the ATM option price. 0.4 * S * sigma * sqrt(T-t).
     * @param s Spot price of underlying token in USD/DAI/USDC.
     * @param o "volatility" scaled by 1000.
     * @param t Time until expiration in seconds.
     */
    function calculateATM(
        uint256 s,
        uint256 o,
        uint256 t
    ) public pure returns (uint256 atm) {
        int128 spot = fromWeiToInt128(s);
        atm = ABDKMath64x64.toUInt(
            int128(2)
                .div(int128(5))
                .mul(spot)
                .mul(ABDKMath64x64.fromUInt(o))
                .div(ABDKMath64x64.fromUInt(PERCENTAGE))
                .mul(sqrt(ABDKMath64x64.fromUInt(t).div(ABDKMath64x64.fromUInt(YEAR))))
        );
    }

    function fromWeiToInt128(uint256 x) public pure returns (int128) {
        return x.divu(DENOMINATOR);
    }

    function percentageInt128(uint256 p) public pure returns (int128) {
        int128 num = ABDKMath64x64.fromUInt(p);
        int128 denom = ABDKMath64x64.fromUInt(PERCENTAGE);
        return num.div(denom);
    }

    function secondsToYears(uint256 s) public pure returns (int128) {
        int128 time = ABDKMath64x64.fromUInt(s);
        int128 units = ABDKMath64x64.fromUInt(YEAR);
        return time.div(units);
    }

    /**
     * @dev Calculate the d1 auxiliary variable.
     * @notice ( log(s/k) + (o^2/2)*(T-t) ) / o * sqrt(T-t).
     * @param s Spot price of underlying token in USD/DAI/USDC.
     * @param k Strike price in USD/DAI/USDC.
     * @param o "volatility" scaled by 1000.
     * @param t Time until expiration in seconds.
     */
    function auxiliary(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (int128 d1) {
        int128 moneyness = getMoneyness(s, k);
        // (r + sigma^2 / 2)
        int128 vol = (percentageInt128(o).pow(2)).div(ABDKMath64x64.fromUInt(2));
        // seconds / seconds in a year = years
        int128 time = secondsToYears(t);
        // log( s / k) + (r + sigma^2 / 2) * (T - t)
        int128 num = moneyness.add(vol.mul(time));
        // sigma * sqrt(T - t)
        int128 dom = percentageInt128(o).mul(sqrt(secondsToYears(t)));
        d1 = num.div(dom);
    }

    function getMoneyness(uint256 s, uint256 k) public pure returns (int128 moneyness) {
        int128 spot = fromWeiToInt128(s);
        int128 strike = fromWeiToInt128(k);
        // log( s / k)
        moneyness = ABDKMath64x64.log_2(spot.div(strike));
    }

    function sqrt(int128 x) public pure returns (int128) {
        return ABDKMath64x64.sqrt(x);
    }

    /**
     * @dev Calculate the d2 auxiliary variable.
     * @notice d1 - o*sqrt(T-t).
     * @param s Spot price of underlying token in USD/DAI/USDC.
     * @param k Strike price in USD/DAI/USDC.
     * @param o "volatility" scaled by 1000.
     * @param t Time until expiration in seconds.
     */
    function auxiliary2(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (int128 d2) {
        int128 d1 = auxiliary(s, k, o, t);
        d2 = d1.sub(percentageInt128(o).mul(sqrt(secondsToYears(t))));
    }

    function ndnumerator(int128 z) public pure returns (int128 numerator) {
        numerator = ABDKMath64x64.exp((z.neg()).pow(2).div(ABDKMath64x64.fromUInt(2)));
    }

    function cdfA() public pure returns (int128) {
        return ABDKMath64x64.fromUInt(44).div(ABDKMath64x64.fromUInt(79));
    }

    function cdfB(int128 z) public pure returns (int128) {
        return z.mul(ABDKMath64x64.fromUInt(8)).div(ABDKMath64x64.fromUInt(5));
    }

    function cdfC0(int128 z) public pure returns (int128) {
        return z.pow(2);
    }

    function cdfC01(int128 z) public pure returns (int128) {
        return cdfC0(z).add(ABDKMath64x64.fromUInt(3));
    }

    function cdfC1(int128 z) public pure returns (int128) {
        return sqrt(cdfC01(z));
    }

    function cdfC2() public pure returns (int128) {
        return int128(5).div(int128(6));
    }

    function cdfC(int128 z) public pure returns (int128) {
        return cdfC1(z).mul(cdfC2());
    }

    function cdfDenominator(int128 z) public pure returns (int128 denominator) {
        int128 a = cdfA();
        int128 b = cdfB(z);
        int128 c = cdfC(z);
        denominator = a.add(b).add(c);
    }

    function nddenominator(int128 z) public pure returns (int128 denominator) {
        //z = z.div(ABDKMath64x64.fromUInt(MANTISSA));
        int128 a = int128(44).div(int128(79));
        int128 b = int128(8).div(int128(5)).mul(z);
        int128 c = (z.pow(2)).add(int128(3));
        int128 d = sqrt(c);
        int128 e = d.mul(int128(5)).div(int128(6));
        //denominator = a.add(b).add(e);
        denominator = int128(17).div(int128(10));
    }

    /* function normdist(int128 z) public pure returns (int128 n) {
        int128 numerator = ABDKMath64x64.exp(
                            int128(-1).mul(
                            (z).pow(2)
                            .div(int128(2))
                            ));
        int128 denominator = (int128(44).div(int128(79)))
                        .add(int128(8).div(int128(5)).mul(z))
                        .add(int128(5).div(int128(6)).mul(
                            sqrt(
                                (z).pow(2).add(int128(3))
                                )
                            )
                        );
        n = ABDKMath64x64.fromUInt(MANTISSA).sub(numerator.mul(ABDKMath64x64.fromUInt(MANTISSA)).div(denominator));
    } */

    /* function normdist(int128 z) public pure returns (int128 n) {
        int128 numerator = ndnumerator(z);
        int128 denominator = nddenominator(z);
        n = numerator.div(denominator);
    } */

    function normdist(int128 z) public pure returns (int128 n) {
        int128 numerator = ndnumerator(z);
        int128 denominator = cdfDenominator(z);
        n = ABDKMath64x64.fromUInt(1).sub(numerator.div(denominator));
    }

    function square(uint256 x) public pure returns (uint256 sq) {
        sq = ABDKMath64x64.toUInt(ABDKMath64x64.fromUInt(x).pow(2));
    }

    function bs(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (int128 p) {
        int128 spot = fromWeiToInt128(s);
        int128 strike = fromWeiToInt128(k);
        int128 d1 = auxiliary(s, k, o, t);
        int128 d2 = auxiliary2(s, k, o, t);
        int128 nd1 = normdist(d1);
        int128 nd2 = normdist(d2);
        int128 bs = spot.mul(nd1) > strike.mul(nd2)
            ? spot.mul(nd1).sub(strike.mul(nd2))
            : int128(0);
        //p = ABDKMath64x64.toUInt(bs.mul(ABDKMath64x64.fromUInt(MANTISSA)));
        p = bs;
    }

    function put(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (int128 p) {
        int128 spot = fromWeiToInt128(s);
        int128 strike = fromWeiToInt128(k);
        int128 d1 = auxiliary(s, k, o, t);
        int128 d2 = auxiliary2(s, k, o, t);
        int128 nd1 = normdist(neg(d1));
        int128 nd2 = normdist(neg(d2));
        int128 bs = strike.mul(nd2) > spot.mul(nd1)
            ? strike.mul(nd2).sub(spot.mul(nd1))
            : int128(0);
        p = bs;
    }

    function neg(int128 x) public pure returns (int128 n) {
        n = ABDKMath64x64.neg(x);
    }

    function _fromInt(int128 x) public pure returns (uint256 y) {
        x = x.mul(ABDKMath64x64.fromUInt(MANTISSA));
        y = x > 0 ? ABDKMath64x64.toUInt(x) : uint256(0);
    }

    function to128(int128 x) public pure returns (int256 y) {
        y = ABDKMath64x64.to128x128(x);
    }

    function eNumerator(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t,
        int128 d1
    ) public pure returns (int128 numerator) {
        int128 x = fromWeiToInt128(s);
        int128 delta = ABDKMath64x64.fromUInt(1).sub(normdist(d1));
        numerator = x.mul(delta);
    }

    function eDenominator(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (int128 denominator) {
        int128 x = fromWeiToInt128(s);
        int128 pxt = put(s, k, o, t);
        denominator = x.add(pxt);
    }

    function elasticity(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t,
        int128 d1
    ) public pure returns (int128 e) {
        int128 numerator = eNumerator(s, k, o, t, d1);
        int128 denominator = eDenominator(s, k, o, t);
        e = numerator.div(denominator);
    }

    function getWeights(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (uint256 riskyW, uint256 riskFW) {
        // get d1
        int128 d1 = auxiliary(s, k, o, t);
        // get elasticity using -d1 = weight of risky asset e.g. 0.5
        int128 elasticity = elasticity(s, k, o, t, d1.neg());
        // get weight of risk-free asset, 1 - riskyW = 1 - 0.5 = 0.5
        int128 remainder = ABDKMath64x64.fromUInt(1).sub(elasticity);
        // convert to uint
        riskyW = _fromInt(elasticity);
        riskFW = _fromInt(remainder);
        // convert to 10 ^ 18 units
        riskyW = riskyW.mul(uint256(10**18).div(MANTISSA));
        riskFW = riskFW.mul(uint256(10**18).div(MANTISSA));
    }
}
