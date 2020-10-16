const { formatEther, parseEther } = require("ethers/lib/utils");

const ENVIRONMENT_CONFIG = {
    name: "Primitive V1 Option Pool",
    symbol: "PRMTV",
    spot: parseEther("105"),
    strike: parseEther("100"),
    volatility: 100,
    time: 31449600,
    initialSupply: parseEther("1"),
};
module.exports = ENVIRONMENT_CONFIG;
