const { formatEther, parseEther } = require("ethers/lib/utils");

const ENVIRONMENT_CONFIG = {
    name: "Primitive V1 Option Pool",
    symbol: "PRMTV",
    spot: parseEther("100"),
    strike: parseEther("100"),
    volatility: 200,
    time: 31449600,
    initialSupply: parseEther("1"),
};
module.exports = ENVIRONMENT_CONFIG;
