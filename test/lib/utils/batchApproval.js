const { parseEther } = require("ethers/lib/utils");
const MAX_UINT = parseEther("10000000000000000000000000000000000000");

const batchApproval = async (arrayOfAddresses, arrayOfTokens, arrayOfSigners) => {
    // for each contract
    for (let c = 0; c < arrayOfAddresses.length; c++) {
        let address = arrayOfAddresses[c];
        // for each token
        for (let t = 0; t < arrayOfTokens.length; t++) {
            let token = arrayOfTokens[t];
            // for each owner
            for (let u = 0; u < arrayOfSigners.length; u++) {
                let signer = arrayOfSigners[u];

                await token.connect(signer).approve(address, MAX_UINT);
            }
        }
    }
};

module.exports = batchApproval;
