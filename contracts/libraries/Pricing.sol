pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Black-scholes Solidity Math Library
 * @author Alexander Angel
 */

import { ABDKMath64x64 } from "./ABDKMath64x64.sol";
import { SafeMath } from "./SafeMath.sol";

library Pricing {
    using ABDKMath64x64 for *; // stores numerators as int128, denominator is 2^64.
    using SafeMath for uint256;

    uint256 internal constant YEAR = 31449600; // 1 year in seconds
    uint256 internal constant MANTISSA = 10**8;
    uint256 internal constant DENOMINATOR = 10**18; // wei
    uint256 internal constant PERCENTAGE = 10**3;

    // Black-Scholes Approximation for ATM options ONLY.

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
    ) internal pure returns (uint256 atm) {
        int128 spot = fromWeiToInt128(s);
        atm = (
            int128(2).div(int128(5)).mul(spot).mul(o.fromUInt()).div(PERCENTAGE.fromUInt()).mul(
                (t.fromUInt().div(YEAR.fromUInt())).sqrt()
            )
        )
            .toUInt();
    }

    // Black-Scholes functions.

    /**
     * @dev Calculate the d1 auxiliary variable.
     * @notice ( ln(s/k) + (o^2/2)*(T-t) ) / o * sqrt(T-t).
     * @param s Spot price of underlying token in USD/DAI/USDC. In wei.
     * @param k Strike price in USD/DAI/USDC. In wei.
     * @param o "volatility" scaled by 1000.
     * @param t Time until expiration in seconds.
     */
    function auxiliary(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) internal pure returns (int128 d1) {
        // ln( F / K )
        int128 moneyness = logSimpleMoneyness(s, k);
        // (r + volatility^2 / 2), r = 0 for simplicity. This should be fixed.
        int128 vol = (percentageInt128(o).pow(2)).div(ABDKMath64x64.fromUInt(2));
        // ( T - t ) time until expiry. seconds / seconds in a year = years
        int128 time = secondsToYears(t);
        // ln( F / K ) + (r + volatility^2 / 2) * (T - t)
        int128 numerator = moneyness.add(vol.mul(time));
        // volatility * sqrt(T - t)
        int128 denominator = percentageInt128(o).mul((secondsToYears(t)).sqrt());
        d1 = numerator.div(denominator);
    }

    /**
     * @dev Calculates the log simple moneyness.
     * @notice ln(F / K).
     * @param s Spot price of underlying token in USD/DAI/USDC. In wei.
     * @param k Strike price in USD/DAI/USDC. In wei.
     */
    function logSimpleMoneyness(uint256 s, uint256 k) internal pure returns (int128 moneyness) {
        int128 spot = fromWeiToInt128(s);
        int128 strike = fromWeiToInt128(k);
        moneyness = (spot.div(strike)).ln();
    }

    /**
     * @dev Calculate the d2 auxiliary variable.
     * @notice d1 - volatility*sqrt(T-t).
     * @param s Spot price of underlying token in USD/DAI/USDC. In wei.
     * @param k Strike price in USD/DAI/USDC. In wei.
     * @param o "volatility" scaled by 1000.
     * @param t Time until expiration in seconds.
     */
    function auxiliary2(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) internal pure returns (int128 d2) {
        // d1 = ( ln(s/k) + (o^2/2)*(T-t) ) / o * sqrt(T-t).
        int128 d1 = auxiliary(s, k, o, t);
        // d2 = d1 - volatility*sqrt(T-t).
        d2 = d1.sub(percentageInt128(o).mul((secondsToYears(t)).sqrt()));
    }

    /**
        @title Approximations to Standard Normal Distribution Function
        @author Ramu Yerukala and Naveen Kumar Boiroju
        International Journal of Scientific & Engineering Research, Volume 6, Issue 4, April-2015 515 ISSN 2229-5518
        @notice We use an approximation for the standard normal distribution function (CDF21) as follows: 
                       exp( -z ^ 2 / 2)
        1 - ( ----------------------------------- )
              44     8         5     
             ---- + --- * z + --- * sqrt( z^2 +3 )
              79     5         6
     */

    /**
     * @dev Calculates the numerator for the CDF.
     * @notice e ^ (-z ^ 2 / 2)
     */
    function ndnumerator(int128 z) internal pure returns (int128 numerator) {
        numerator = ((z.neg()).pow(2).div((2).fromUInt())).exp();
    }

    /**
     * @dev Calculates the first element for the denominator of CDF21.
     * @notice 
            44
           ----
            79
     */
    function cdfA() internal pure returns (int128) {
        return (44).fromUInt().div((79).fromUInt());
    }

    /**
     * @dev Calculates the second element for the denominator of CDF21.
     * @notice 
            8
           --- * z
            5
     */
    function cdfB(int128 z) internal pure returns (int128) {
        return z.mul((8).fromUInt()).div((5).fromUInt());
    }

    /**
     * @dev Calculates the first element for the third element of the denominator of CDF21.
     * @notice ( z ^ 2 ).
     */
    function cdfC0(int128 z) internal pure returns (int128) {
        return z.pow(2);
    }

    /**
     * @dev Calculates the items for the third element for the denominator of CDF21.
     * @notice ( z^2 + 3 ).
     */
    function cdfC01(int128 z) internal pure returns (int128) {
        return cdfC0(z).add((3).fromUInt());
    }

    /**
     * @dev Calculates the full element for the third element for the denominator of CDF21.
     * @notice sqrt( z^2 + 3 ).
     */
    function cdfC1(int128 z) internal pure returns (int128) {
        return (cdfC01(z)).sqrt();
    }

    /**
     * @dev Calculates the second element's first item for the denominator of the CDF21.
     * @notice ( 5 / 6).
     */
    function cdfC2() internal pure returns (int128) {
        return int128(5).div(int128(6));
    }

    /**
     * @dev Calculates the second element for the denominator of the CDF21.
     * @notice ( z * ( 5 / 6) ).
     */
    function cdfC(int128 z) internal pure returns (int128) {
        return cdfC1(z).mul(cdfC2());
    }

    /**
     * @dev Calculates the full denominator of the CDF21.
     */
    function cdfDenominator(int128 z) internal pure returns (int128 denominator) {
        int128 a = cdfA();
        int128 b = cdfB(z);
        int128 c = cdfC(z);
        denominator = a.add(b).add(c);
    }

    /**
     * @dev Calculates the normal distribution using an approximation.
     */
    function normdist(int128 z) internal pure returns (int128 n) {
        int128 numerator = ndnumerator(z);
        int128 denominator = cdfDenominator(z);
        n = (1).fromUInt().sub(numerator.div(denominator));
    }

    /**
     * @dev Calculates a call option value using black-scholes.
     * @notice C(s, t) = s * N(d1) - Ke^-r(T - t) * N(d2). Where N() is the standard normal CDF.
     * @param s Spot price of underlying token in USD/DAI/USDC. In wei.
     * @param k Strike price in USD/DAI/USDC. In wei.
     * @param o "volatility" scaled by 1000.
     * @param t Time until expiration in seconds.
     * @return c The value of the call option for the contract's parameters.
     */
    function call(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) internal pure returns (int128 c) {
        int128 spot = fromWeiToInt128(s);
        int128 strike = fromWeiToInt128(k);
        int128 d1 = auxiliary(s, k, o, t);
        int128 d2 = auxiliary2(s, k, o, t);
        int128 nd1 = normdist(d1);
        int128 nd2 = normdist(d2);
        int128 bs = spot.mul(nd1) > strike.mul(nd2)
            ? spot.mul(nd1).sub(strike.mul(nd2))
            : int128(0);
        c = bs;
    }

    /**
     * @dev Calculates a put option value using black-scholes.
     * @notice P(s, t) = Ke^-r(T - t) * N(-d2) - s * N(-d1). Where N() is the standard normal CDF.
     * @param s Spot price of underlying token in USD/DAI/USDC. In wei.
     * @param k Strike price in USD/DAI/USDC. In wei.
     * @param o "volatility" scaled by 1000.
     * @param t Time until expiration in seconds.
     * @return p The value of the put option for the contract's parameters.
     */
    function put(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) internal pure returns (int128 p) {
        int128 spot = fromWeiToInt128(s);
        int128 strike = fromWeiToInt128(k);
        int128 d1 = auxiliary(s, k, o, t);
        int128 d2 = auxiliary2(s, k, o, t);
        int128 nd1 = normdist((d1).neg());
        int128 nd2 = normdist((d2).neg());
        int128 bs = strike.mul(nd2) > spot.mul(nd1)
            ? strike.mul(nd2).sub(spot.mul(nd1))
            : int128(0);
        p = bs;
    }

    // Elasticity and greek functions.

    /**
     * @dev Calculates the numerator for the option elasticity function.
     * @notice  spot * delta. delta = ( 1 - N(d1) ). d1 is negative for puts.
     */
    function eNumerator(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t,
        int128 d1
    ) internal pure returns (int128 numerator) {
        int128 x = fromWeiToInt128(s);
        int128 delta = (1).fromUInt().sub(normdist(d1));
        numerator = x.mul(delta);
    }

    /**
     * @dev Calculates the denominator for the option elasticity function.
     * @notice P(s, t) + s
     */
    function eDenominator(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) internal pure returns (int128 denominator) {
        int128 x = fromWeiToInt128(s);
        int128 pxt = put(s, k, o, t);
        denominator = x.add(pxt);
    }

    /**
     * @dev Calculates the elasticity of an option.
     */
    function elasticity(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t,
        int128 d1
    ) internal pure returns (int128 e) {
        int128 numerator = eNumerator(s, k, o, t, d1);
        int128 denominator = eDenominator(s, k, o, t);
        e = numerator.div(denominator);
    }

    /**
     * @dev Calculates the elasticity of an option and converts to a denormalized weight in wei.
     */
    function getWeights(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) internal pure returns (uint256 riskyW, uint256 riskFW) {
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

    /**
     * @dev Gets call option price. Library entry point for easy testing.
     */
    function getCall(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) internal pure returns (uint256) {
        return _fromInt(call(s, k, o, t)).mul(uint256(10**18).div(MANTISSA));
    }

    /**
     * @dev Gets call option price. Library entry point for easy testing.
     */
    function getCallPrice(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (uint256) {
        return _fromInt(call(s, k, o, t)).mul(uint256(10**18).div(MANTISSA));
    }

    /**
     * @dev Gets put option price. Library entry point for easy testing.
     */
    function getPutPrice(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (uint256) {
        return _fromInt(put(s, k, o, t)).mul(uint256(10**18).div(MANTISSA));
    }

    /**
     * @dev Gets put option price. Library entry point for easy testing.
     */
    function getElasticity(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (uint256) {
        int128 d1 = auxiliary(s, k, o, t);
        // get elasticity using -d1 = weight of risky asset e.g. 0.5
        int128 elasticity = elasticity(s, k, o, t, d1.neg());
        // convert to uint
        uint256 weight = _fromInt(elasticity);
        return weight.mul(uint256(10**18)).div(MANTISSA);
    }

    /**
     * 
     @dev Library entry point for easy testing.
     */
    function weights(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public pure returns (uint256 riskyW, uint256 riskFW) {
        (riskyW, riskFW) = getWeights(s, k, o, t);
    }

    // Conversion functions.

    /**
     * @dev Converts a wei value uint256 into an int128 numerator value.
     * @param x A uint256 amount.
     */
    function fromWeiToInt128(uint256 x) internal pure returns (int128) {
        return x.divu(DENOMINATOR);
    }

    /**
     * @dev Converts a denormalized percentage (1000 = 100%, 10 = 1%) into an int128.
     */
    function percentageInt128(uint256 denorm) internal pure returns (int128) {
        int128 numerator = denorm.fromUInt();
        int128 denominator = PERCENTAGE.fromUInt();
        return numerator.div(denominator);
    }

    /**
     * @dev Converts second units into an int128 with units of years.
     */
    function secondsToYears(uint256 quantitySeconds) internal pure returns (int128) {
        int128 time = quantitySeconds.fromUInt();
        int128 units = YEAR.fromUInt();
        return time.div(units);
    }

    /**
     * @dev Converts a numerator x with denominator 2^64 into an uint256.
     * @notice Will return 0 if a fraction < 10^8.
     */
    function _fromInt(int128 x) internal pure returns (uint256 y) {
        x = x.mul((MANTISSA).fromUInt());
        y = x > 0 ? (x).toUInt() : uint256(0);
    }
}
