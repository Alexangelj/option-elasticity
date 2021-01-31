const bre = require("@nomiclabs/buidler");
const ethers = bre.ethers;

class Option {
    chainId;
    address;

    constructor(symbol, name, initialSupply) {
        this.symbol = symbol;
        this.name = name;
        this.initialSupply = initialSupply;
    }

    intialize = async () => {
        this.defaultProvider = await ethers.getDefaultProvider();
        this.signer = (await ethers.getSigners())[0];
        let factory = await ethers.getContractFactory("TestToken");
        this.token = await factory.deploy(name, symbol, initialSupply);
        this.address = this.token.address;
    };

    get token() {
        return this.token;
    }
}

Object.assign(module.exports, { Option });
