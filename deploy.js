const { ethers } = require("ethers");
const { EthereumProvider } = require("@walletconnect/ethereum-provider");
const QRCode = require("qrcode-terminal");
const fs = require("fs");
const path = require("path");

const ARBITRUM_RPC = "https://arb1.arbitrum.io/rpc";
const contractArtifactPath = path.join(__dirname, "out/NonPerishableWorldVaultDAO.sol/NonPerishableWorldVaultDAO.json");

if (!fs.existsSync(contractArtifactPath)) {
    console.error("Error: Contract artifact not found. Please run 'forge build' first.");
    process.exit(1);
}
const contractArtifact = JSON.parse(fs.readFileSync(contractArtifactPath, "utf8"));

async function waitForReceiptWithRetry(txHash, provider, maxRetries = 20, intervalMs = 3000) {
    console.log(`Polling Arbitrum RPC for receipt (Hash: ${txHash})...`);
    for (let i = 0; i < maxRetries; i++) {
        try {
            const receipt = await provider.getTransactionReceipt(txHash);
            if (receipt) {
                return receipt;
            }
        } catch (err) {}
        await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
    throw new Error(`Transaction receipt not found after timeout.`);
}

async function main() {
    console.log("Initializing WalletConnect session for Arbitrum One (Chain ID: 42161)...");

    const wcProvider = await EthereumProvider.init({
        projectId: "3a8170812b534d0ff9d794f19a901d64",
        chains: [42161],
        rpcMap: {
            42161: ARBITRUM_RPC
        },
        metadata: {
            name: "Non-Perishable World Vault DAO Deployment",
            description: "Off-Grid PQC DAO Deployment on Arbitrum One",
            url: "https://obscura.network",
            icons: ["https://avatars.githubusercontent.com/u/37784886"]
        },
        showQrModal: false
    });

    wcProvider.on("display_uri", (uri) => {
        console.log("\n==================================================================");
        console.log("SCAN THIS QR CODE IN METAMASK MOBILE (Ensure network is Arbitrum One)");
        console.log("==================================================================\n");
        QRCode.generate(uri, { small: true }, (qr) => {
            console.log(qr);
        });
        console.log(`\nDirect WalletConnect URI Link:\n${uri}\n`);
    });

    console.log("Connecting to WalletConnect relay network...");
    await wcProvider.connect();

    const wcBrowserProvider = new ethers.BrowserProvider(wcProvider, "any");
    const staticArbProvider = new ethers.JsonRpcProvider(ARBITRUM_RPC);

    const signer = await wcBrowserProvider.getSigner();
    const deployerAddress = await signer.getAddress();

    console.log(`\nSuccessfully Connected Wallet: ${deployerAddress}`);

    // Instantiate ContractFactory with ABI and Bytecode
    const factory = new ethers.ContractFactory(
        contractArtifact.abi,
        contractArtifact.bytecode.object,
        signer
    );

    // Initial PQC public key constructor argument (e.g., 32-byte zero key or initial identifier bytes)
    const initialDaoPqcKey = "0x0000000000000000000000000000000000000000000000000000000000000001";

    console.log("Preparing deployment transaction with constructor arguments...");
    
    // Fetch gas data for proper EIP-1559 fee calculation
    const feeData = await staticArbProvider.getFeeData();

    // Use factory deployment with constructor argument and explicit gas options
    const deployTx = await factory.getDeployTransaction(initialDaoPqcKey, {
        gasLimit: 4000000,
        maxFeePerGas: feeData.maxFeePerGas,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas
    });

    console.log("Sending deployment transaction to MetaMask mobile... Please approve in your wallet.");
    
    let txHash;
    try {
        const txResponse = await signer.sendTransaction(deployTx);
        txHash = txResponse.hash;
    } catch (err) {
        if (err.info && err.info.sendTransactionHash) {
            txHash = err.info.sendTransactionHash;
        } else {
            throw err;
        }
    }

    console.log(`\nTransaction Broadcasted! Hash: ${txHash}`);
    console.log("Waiting for block confirmation directly on Arbitrum One RPC...");

    const receipt = await waitForReceiptWithRetry(txHash, staticArbProvider);
    const contractAddress = receipt.contractAddress;

    console.log(`\n==========================================`);
    console.log(`Deployment Successful on Arbitrum One!`);
    console.log(`NonPerishableWorldVaultDAO Address: ${contractAddress}`);
    console.log(`==========================================\n`);

    try {
        await wcProvider.disconnect();
    } catch (e) {}
    process.exit(0);
}

main().catch((error) => {
    console.error("\nDeployment failed:", error);
    process.exit(1);
});
