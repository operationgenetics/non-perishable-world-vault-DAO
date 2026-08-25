const { ethers } = require("ethers");

async function main() {
    const provider = new ethers.JsonRpcProvider("https://arb1.arbitrum.io/rpc");
    const txHash = "0xf25e379ffabfa101d931348f687bd71da570d7d5fea0814bf8a16520e337793d";
    
    console.log("Fetching transaction receipt from Arbitrum One...");
    const receipt = await provider.getTransactionReceipt(txHash);
    
    if (receipt && receipt.contractAddress) {
        console.log(`\n==========================================`);
        console.log(`Deployment Confirmed on Arbitrum One!`);
        console.log(`NonPerishableWorldVaultDAO Address: ${receipt.contractAddress}`);
        console.log(`==========================================\n`);
    } else {
        console.log("Transaction is still pending or not found. Try again in a few seconds.");
    }
}

main().catch(console.error);
