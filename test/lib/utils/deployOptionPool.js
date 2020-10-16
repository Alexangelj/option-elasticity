const bre = require("@nomiclabs/buidler");
const ethers = bre.ethers;
const batchApproval = require("./batchApproval");
const CONFIG = require("../config");

const deployOptionPool = async (controller, oracle, token1, token2) => {
    // Setup an OptionPool and link it to the core pool.
    let poolFactory = await ethers.getContractFactory("OptionPool");
    let pool = await poolFactory.deploy();
    await controller.setController(pool.address);

    // Approve tokens to be transferred to the option pool and core pool.
    let core = await controller.bPool();
    let addresses = [pool.address, core];
    let tokens = [token1.contract, token2.contract];
    let signers = await ethers.getSigners();
    await batchApproval(addresses, tokens, signers);

    // Call initialize on option pool
    await pool.initialize(
        core,
        oracle.address,
        CONFIG.name,
        CONFIG.symbol,
        CONFIG.initialSupply,
        token1.address,
        token2.address,
        CONFIG.strike,
        CONFIG.time
    );

    return pool;
};

module.exports = deployOptionPool;
