const bre = require("@nomiclabs/buidler");
const { parseEther } = bre.ethers.utils;
const BFactory = require("../balancer-core/build/contracts/BFactory.json");
const BPool = require("../balancer-core/build/contracts/BPool.json");
const { formatEther } = require("ethers/lib/utils");
const ethers = bre.ethers;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("Pricing Contract", () => {
    let pricing;
    let s, k, o, t;

    let wallets, Admin, Alice, factory, pool, pfi, risky, riskFree;

    const DENOMINATOR = 2 ** 64;

    before(async () => {
        // get wallets
        wallets = await newWallets();
        Admin = wallets[0];
        Alice = Admin._address;

        // get assets
        const _risky = await ethers.getContractFactory("PToken");
        risky = await _risky.deploy("Risky Asset", "RISK", parseEther("10000"));
        const _riskFree = await ethers.getContractFactory("PToken");
        riskFree = await _riskFree.deploy("Risk Free Asset", "FREE", parseEther("10000"));

        // get pricing contract, could be a library tbh
        const _pricing = await ethers.getContractFactory("Pricing");
        pricing = await _pricing.deploy();

        // get parameters, s = spot = x, k = strike, o = sigma = volatility, t = T until expiry
        s = parseEther("101");
        k = parseEther("100");
        o = 100;
        t = 31449600; //one year

        // get balancer factory
        const _factory = await ethers.getContractFactory(BFactory.abi, BFactory.bytecode, Admin);
        factory = await _factory.deploy();

        // get primitive wrapper
        const _pfi = await ethers.getContractFactory("PFactory");
        pfi = await _pfi.deploy();
        await pfi.initialize(factory.address, risky.address, riskFree.address);
    });

    describe("Test Pricing", () => {
        it("Tests the ATM function", async () => {
            let atm = await pricing.calculateATM(s, o, t);
            console.log("ATM", atm.toString());
        });

        it("Tests the sq function", async () => {
            let sq = await pricing.square(2);
            console.log("sq", sq.toString());
        });

        it("Tests the ndnumerator function", async () => {
            let d1 = await pricing.auxiliary(s, k, o, t);
            let ndnumerator = await pricing.ndnumerator(d1);
            ndnumerator = await pricing._fromInt(ndnumerator);
            console.log("ndnumerator", ndnumerator.toString());
        });

        it("Tests the nddenominator function", async () => {
            let d1 = await pricing.auxiliary(s, k, o, t);
            let nddenominator = await pricing.nddenominator(d1);
            nddenominator = await pricing._fromInt(nddenominator);
            console.log("nddenominator", nddenominator.toString());
        });

        it("Tests the d1 function", async () => {
            let d1 = await pricing.auxiliary(s, k, o, t);
            d1 = await pricing._fromInt(d1);
            console.log("d1", d1.toString());
            let moneyness = await pricing.getMoneyness(s, k);
            moneyness = await pricing._fromInt(moneyness);
            console.log("moneyness", moneyness.toString());
        });

        it("Tests the d2 function", async () => {
            let d2 = await pricing.auxiliary2(s, k, o, t);
            d2 = await pricing._fromInt(d2);
            console.log("d2", d2.toString());
        });

        it("Tests the normdist function", async () => {
            let z = await pricing.auxiliary(s, k, o, t);
            let normdist = await pricing.normdist(z);
            normdist = await pricing._fromInt(normdist);
            let z2 = await pricing.auxiliary2(s, k, o, t);
            console.log("z2", (await pricing._fromInt(z2)).toString());
            let normdist2 = await pricing.normdist(z2);
            normdist2 = await pricing._fromInt(normdist2);
            console.log("normdist", normdist.toString());
            console.log("normdist2", normdist2.toString());
        });

        it("Tests the bs function", async () => {
            let bs = await pricing.bs(s, k, o, t);
            bs = await pricing._fromInt(bs);
            console.log("bs", bs.toString());
        });

        it("Tests the put function", async () => {
            let put = await pricing.put(s, k, o, t);
            put = await pricing._fromInt(put);
            console.log("put", put.toString());
            let d1 = await pricing.auxiliary(s, k, o, t);
            let neg = await pricing.neg(d1);
            let ndneg = await pricing.normdist(neg);
            ndneg = await pricing._fromInt(ndneg);
            console.log("neg", ndneg.toString());
            neg = await pricing._fromInt(neg);
            console.log("neg", neg.toString());
        });

        it("Tests it all!", async () => {
            // calculate
            let moneyness = await pricing.getMoneyness(s, k);
            let d1 = await pricing.neg(await pricing.auxiliary(s, k, o, t));
            let d2 = await pricing.neg(await pricing.auxiliary2(s, k, o, t));
            let ndnumerator = await pricing.ndnumerator(d1);
            let nddenominator = await pricing.nddenominator(d1);
            let normdist1 = await pricing.normdist(d1);
            let normdist2 = await pricing.normdist(d2);
            let put = await pricing.put(s, k, o, t);
            let cdfA = await pricing.cdfA();
            let cdfB = await pricing.cdfB(d1);
            let cdfC = await pricing.cdfC(d1);
            let cdfC0 = await pricing.cdfC0(d1);
            let cdfC01 = await pricing.cdfC01(d1);
            let cdfC1 = await pricing.cdfC1(d1);
            let cdfC2 = await pricing.cdfC2();

            // change to uint
            moneyness = await pricing._fromInt(moneyness);
            d1 = await pricing._fromInt(await pricing.neg(d1));
            d2 = await pricing._fromInt(await pricing.neg(d2));
            ndnumerator = await pricing._fromInt(ndnumerator);
            nddenominator = await pricing._fromInt(nddenominator);
            normdist1 = await pricing._fromInt(normdist1);
            normdist2 = await pricing._fromInt(normdist2);
            put = await pricing._fromInt(put);
            cdfA = await pricing._fromInt(cdfA);
            cdfB = await pricing._fromInt(cdfB);
            cdfC = await pricing._fromInt(cdfC);
            cdfC0 = await pricing._fromInt(cdfC0);
            cdfC01 = await pricing._fromInt(cdfC01);
            cdfC1 = await pricing._fromInt(cdfC1);
            cdfC2 = await pricing._fromInt(cdfC2);

            // log
            console.log("moneyness", moneyness.toString());
            console.log("d1", d1.toString());
            console.log("d2", d2.toString());
            console.log("ndnumerator", ndnumerator.toString());
            console.log("nddenominator", nddenominator.toString());
            console.log("normdist-1", normdist1.toString());
            console.log("normdist-2", normdist2.toString());
            console.log("put", put.toString());

            console.log("cdfA", cdfA.toString());
            console.log("cdfB", cdfB.toString());
            console.log("cdfC", cdfC.toString());

            let cdfDenominator = await pricing.cdfDenominator(d1);
            cdfDenominator = await pricing._fromInt(cdfDenominator);
            console.log("cdfDenominator", cdfDenominator.toString());
            console.log("cdfC0", cdfC0.toString());
            console.log("cdfC01", cdfC01.toString());
            console.log("cdfC1", cdfC1.toString());
            console.log("cdfC2", cdfC2.toString());
        });

        it("Tests it all! 2", async () => {
            // calculate
            let moneyness = await pricing.getMoneyness(s, k);
            let d1 = await pricing.neg(await pricing.auxiliary(s, k, o, t));
            let d2 = await pricing.neg(await pricing.auxiliary2(s, k, o, t));
            let ndnumerator = await pricing.ndnumerator(d1);
            let nddenominator = await pricing.cdfDenominator(d1);
            let normdist1 = await pricing.normdist(d1);
            let normdist2 = await pricing.normdist(d2);
            let put = await pricing.put(s, k, o, t);
            let cdfA = await pricing.cdfA();
            let cdfB = await pricing.cdfB(d1);
            let cdfC = await pricing.cdfC(d1);
            let cdfC0 = await pricing.cdfC0(d1);
            let cdfC01 = await pricing.cdfC01(d1);
            let cdfC1 = await pricing.cdfC1(d1);
            let cdfC2 = await pricing.cdfC2();
            let cdfDenominator = await pricing.cdfDenominator(d1);

            // log
            console.log("moneyness", (moneyness / DENOMINATOR).toString());
            console.log("d1", (d1 / DENOMINATOR).toString());
            console.log("d2", (d2 / DENOMINATOR).toString());
            console.log("ndnumerator", (ndnumerator / DENOMINATOR).toString());
            console.log("nddenominator", (nddenominator / DENOMINATOR).toString());
            console.log("normdist-1", (normdist1 / DENOMINATOR).toString());
            console.log("normdist-2", (normdist2 / DENOMINATOR).toString());
            console.log("put", (put / DENOMINATOR).toString());
            console.log("cdfA", (cdfA / DENOMINATOR).toString());
            console.log("cdfB", (cdfB / DENOMINATOR).toString());
            console.log("cdfC", (cdfC / DENOMINATOR).toString());
            console.log("cdfDenominator", (cdfDenominator / DENOMINATOR).toString());
            console.log("cdfC0", (cdfC0 / DENOMINATOR).toString());
            console.log("cdfC01", (cdfC01 / DENOMINATOR).toString());
            console.log("cdfC1", (cdfC1 / DENOMINATOR).toString());
            console.log("cdfC2", (cdfC2 / DENOMINATOR).toString());
        });

        it("Test elasticity function", async () => {
            // calculate
            let d1 = await pricing.neg(await pricing.auxiliary(s, k, o, t));
            let eNumerator = await pricing.eNumerator(s, k, o, t, d1);
            let eDenominator = await pricing.eDenominator(s, k, o, t);
            let elasticity = await pricing.elasticity(s, k, o, t, d1);

            // log
            console.log("d1", (d1 / DENOMINATOR).toString());
            console.log("eNumerator", (eNumerator / DENOMINATOR).toString());
            console.log("eDenominator", (eDenominator / DENOMINATOR).toString());
            console.log("elasticity", (elasticity / DENOMINATOR).toString());
        });
    });

    describe("Test Pool Making", () => {
        it("Deploy a new pool", async () => {
            await pfi.deployPool();
            let address = await pfi.bPool();
            pool = new ethers.Contract(address, BPool.abi, Admin);
        });

        it("Calculate Weight then Bind", async () => {
            await pfi.deployPool();
            await pfi.approvePool();
            await risky.approve(pfi.address, parseEther("1000000000"));
            await riskFree.approve(pfi.address, parseEther("1000000000"));
            let address = await pfi.bPool();
            pool = new ethers.Contract(address, BPool.abi, Admin);

            let weights = await pricing.getWeights(s, k, o, t);
            let amounts = await pfi.getAmounts(weights.riskyW, weights.riskFW);

            await pfi.connect(Admin).initializePool(s, k, o, t, { from: Alice });
            let numTokens = await pool.getNumTokens();
            let riskyWeight = await pool.getNormalizedWeight(risky.address);
            let riskFreeWeight = await pool.getNormalizedWeight(riskFree.address);
            console.log("K", formatEther(k));
            console.log("x", formatEther(s));
            console.log("sigma", (o / 1000).toString());
            console.log("T - t", (t / t).toString());
            console.log("Risky Weight: ", formatEther(weights.riskyW));
            console.log("Risk Free Weight: ", formatEther(weights.riskFW));
            console.log("Risky Amount: ", formatEther(amounts.riskyAmount));
            console.log("Risk Free Amount: ", formatEther(amounts.riskFreeAmount));
            console.log("Num Tokens: ", numTokens.toString());
            console.log("Normalized Risky Weight: ", formatEther(riskyWeight));
            console.log("Normalized Risk Free Weight: ", formatEther(riskFreeWeight));
            console.log("Risky Balance: ", formatEther(await risky.balanceOf(pool.address)));
            console.log(
                "Risk Free Balance: ",
                formatEther(await riskFree.balanceOf(pool.address))
            );
        });

        it("Tests updateWeights function", async () => {
            await pfi.deployPool();
            await pfi.approvePool();
            await risky.approve(pfi.address, parseEther("1000000000"));
            await riskFree.approve(pfi.address, parseEther("1000000000"));
            let address = await pfi.bPool();
            pool = new ethers.Contract(address, BPool.abi, Admin);

            let weights = await pricing.getWeights(s, k, o, t);
            let amounts = await pfi.getAmounts(weights.riskyW, weights.riskFW);
            await risky.transfer(pfi.address, amounts.riskyAmount);
            await riskFree.transfer(pfi.address, amounts.riskFreeAmount);
            await pfi.connect(Admin).updateWeights(s, k, o, t, { from: Alice });
        });
    });
});
