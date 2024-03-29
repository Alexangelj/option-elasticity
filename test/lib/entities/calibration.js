const bre = require("@nomiclabs/buidler");
const { parseEther, formatEther } = require("ethers/lib/utils");
const ethers = bre.ethers;

function log(val) {
    console.log(val.toString());
}

class Calibration {
    config;
    tokens;
    pricing;
    pool;
    oracle;
    weights;
    amounts;

    constructor(config, token0, token1) {
        this.config = config;
        this.tokens = [token0, token1];
    }

    async initialize(pricing, oracle, pool) {
        this.pricing = pricing;
        this.oracle = oracle;
        this.pool = pool;
        this.weights = await this.calcWeights();
        this.amounts = await this.calcAmounts();
        this.callPrice = await this.calcCallPrice();
        this.putPrice = await this.calcPutPrice();
        this.elasticity = await this.calcElasticity();
    }

    async calcAmounts() {
        /* let callValue = await this.calcCallPrice();
        let totalSupply = await this.pool.totalSupply();
        let totalValue = callValue.mul(totalSupply).div(parseEther("1"));
        let amount0 = totalValue.mul(this.weights.riskyW).div(await this.spot());
        let amount1 = totalValue.mul(this.weights.riskFW).div(parseEther("1")); */
        let amounts = [
            this.weights.riskyW,
            this.weights.riskFW.mul(await this.oracle.testPrice()).div(parseEther("1")),
        ];
        return amounts;
    }

    async calcWeights() {
        /* console.log(
            "Calculating Weights: ",
            formatEther(await this.spot()),
            formatEther(this.config.strike),
            this.config.volatility.toString(),
            this.config.time
        ); */
        let weights = await this.pricing.weights(
            await this.spot(),
            this.config.strike,
            this.config.volatility,
            this.config.time
        );
        //console.log(formatEther(weights[0]));
        return weights;
    }

    async calcCallPrice() {
        let call = await this.pricing.getCallPrice(
            await this.spot(),
            this.config.strike,
            this.config.volatility,
            this.config.time
        );
        return call;
    }

    async calcElasticity() {
        let elasticity = await this.pricing.getElasticity(
            await this.spot(),
            this.config.strike,
            this.config.volatility,
            this.config.time
        );
        return elasticity;
    }

    async calcPutPrice() {
        let putPrice = await this.pricing.getPutPrice(
            await this.spot(),
            this.config.strike,
            this.config.volatility,
            this.config.time
        );
        return putPrice;
    }

    get strike() {
        return this.config.strike;
    }

    get volatility() {
        return this.config.volatility;
    }

    get time() {
        return this.config.time;
    }

    get tokens() {
        return this.tokens;
    }

    get token0() {
        return this.tokens[0];
    }

    get token1() {
        return this.tokens[1];
    }

    get weights() {
        return this.weights;
    }

    get amounts() {
        return this.amounts;
    }

    async spot() {
        let spot = await this.oracle.getAssetPrice(this.tokens[0].address);
        return spot;
    }
}

Object.assign(module.exports, { Calibration });
