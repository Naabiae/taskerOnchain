/**
 * Deploy Uniswap V3 DCA + Limit Order adapters to an existing Base Sepolia UARC deployment.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-base-uniswap-adapters.ts --network baseSepolia
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface TxRecord {
    step: string;
    txHash: string;
    contractAddress?: string;
    blockNumber?: number;
    gasUsed?: string;
}

interface DeploymentRecord {
    network: string;
    chainId: string;
    deployer: string;
    deployedAt: string;
    explorer: string;
    transactions: TxRecord[];
    contracts: Record<string, string>;
}

const DEPLOYMENT_FILE = "deployment-base-sepolia-1777342795028.json";
const BASE_SEPOLIA_SWAP_ROUTER = "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4";
const BASE_SEPOLIA_FACTORY = "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24";
const EXPLORER = "https://sepolia.basescan.org";

const txLog: TxRecord[] = [];

async function recordTx(step: string, tx: any, contractAddress?: string): Promise<void> {
    const receipt = await tx.wait();
    const record: TxRecord = {
        step,
        txHash: tx.hash,
        contractAddress,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed?.toString(),
    };
    txLog.push(record);

    console.log(`   [TX ${txLog.length}] ${step}`);
    console.log(`      Hash: ${tx.hash}`);
    if (contractAddress) console.log(`      Address: ${contractAddress}`);
    console.log(`      Gas: ${record.gasUsed} | Block: ${record.blockNumber}`);
}

async function deployOrAttach(
    contractName: string,
    existingAddress: string | undefined,
    args: unknown[],
    forceDeploy = false
): Promise<{ address: string; contract: any }> {
    const ContractFactory = await ethers.getContractFactory(contractName);

    if (!forceDeploy && existingAddress && existingAddress !== "") {
        const code = await ethers.provider.getCode(existingAddress);
        if (code === "0x") {
            throw new Error(`${contractName} address has no contract code: ${existingAddress}`);
        }
        console.log(`   Reusing ${contractName}: ${existingAddress}`);
        return {
            address: existingAddress,
            contract: ContractFactory.attach(existingAddress),
        };
    }

    const contract = await ContractFactory.deploy(...args);
    await contract.waitForDeployment();
    const address = await contract.getAddress();
    await recordTx(`Deploy ${contractName}`, contract.deploymentTransaction()!, address);

    return { address, contract };
}

async function isAdapterRegistered(actionRegistry: any, adapterAddress: string): Promise<boolean> {
    try {
        const info = await actionRegistry.getAdapterByAddress(adapterAddress);
        return info.adapter.toLowerCase() === adapterAddress.toLowerCase() && info.isActive;
    } catch {
        return false;
    }
}

async function registerAdapterIfNeeded(
    actionRegistry: any,
    selector: string,
    adapterName: string,
    adapterAddress: string,
    gasLimit: number
): Promise<void> {
    if (await isAdapterRegistered(actionRegistry, adapterAddress)) {
        console.log(`   ${adapterName} already registered`);
        return;
    }

    const tx = await actionRegistry.registerAdapter(selector, adapterAddress, gasLimit, true);
    await recordTx(`Register ${adapterName}`, tx);
}

async function approveProtocolIfNeeded(
    actionRegistry: any,
    protocolName: string,
    protocolAddress: string
): Promise<void> {
    if (await actionRegistry.isProtocolApproved(protocolAddress)) {
        console.log(`   ${protocolName} already approved`);
        return;
    }

    const tx = await actionRegistry.approveProtocol(protocolAddress);
    await recordTx(`Approve ${protocolName} protocol`, tx);
}

function loadDeployment(): { deployment: DeploymentRecord; filepath: string } {
    const filepath = path.join(__dirname, "..", "deployments", DEPLOYMENT_FILE);
    if (!fs.existsSync(filepath)) {
        throw new Error(`Deployment file not found: deployments/${DEPLOYMENT_FILE}`);
    }

    return {
        deployment: JSON.parse(fs.readFileSync(filepath, "utf8")) as DeploymentRecord,
        filepath,
    };
}

function updateManifest(contracts: Record<string, string>): void {
    const manifestPath = path.join(__dirname, "..", "agent", "manifest-base.json");
    if (!fs.existsSync(manifestPath)) {
        console.log("   manifest-base.json not found, skipping manifest update");
        return;
    }

    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

    manifest.adapters ??= {};
    manifest.adapters.UniswapV3DCAAdapter ??= {};
    manifest.adapters.UniswapV3LimitOrderAdapter ??= {};

    manifest.adapters.UniswapV3DCAAdapter.address = contracts.UniswapV3DCAAdapter;
    manifest.adapters.UniswapV3DCAAdapter.protocols = {
        swapRouter: BASE_SEPOLIA_SWAP_ROUTER,
    };

    manifest.adapters.UniswapV3LimitOrderAdapter.address = contracts.UniswapV3LimitOrderAdapter;
    manifest.adapters.UniswapV3LimitOrderAdapter.protocols = {
        swapRouter: BASE_SEPOLIA_SWAP_ROUTER,
        factory: BASE_SEPOLIA_FACTORY,
    };

    for (const action of manifest.actions ?? []) {
        if (action.id === "uniswap_dca") {
            action.adapter = contracts.UniswapV3DCAAdapter;
        }
        if (action.id === "uniswap_limit_order") {
            action.adapter = contracts.UniswapV3LimitOrderAdapter;
        }
    }

    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log("   Updated agent/manifest-base.json");
}

async function main() {
    console.log("\nDeploying Uniswap V3 DCA + Limit Order adapters to Base Sepolia\n");

    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    const network = await ethers.provider.getNetwork();
    const balance = await ethers.provider.getBalance(deployerAddress);
    const { deployment, filepath } = loadDeployment();

    if (network.chainId !== 84532n) {
        throw new Error(`Wrong network. Expected Base Sepolia 84532, got ${network.chainId.toString()}`);
    }
    if (!deployment.contracts.ActionRegistry) {
        throw new Error("ActionRegistry address missing from deployment file");
    }

    console.log("Deployer:", deployerAddress);
    console.log("Network:", network.name, "| ChainID:", network.chainId.toString());
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("ActionRegistry:", deployment.contracts.ActionRegistry);
    console.log("SwapRouter:", BASE_SEPOLIA_SWAP_ROUTER);
    console.log("Factory:", BASE_SEPOLIA_FACTORY, "\n");

    const dcaAdapterAddress =
        (await deployOrAttach(
            "UniswapV3DCAAdapter",
            process.env.DCA_ADAPTER_ADDRESS || deployment.contracts.UniswapV3DCAAdapter,
            [BASE_SEPOLIA_SWAP_ROUTER],
            process.env.FORCE_DEPLOY_DCA === "true"
        )).address;

    const limitOrderAdapterAddress =
        (await deployOrAttach(
            "UniswapV3LimitOrderAdapter",
            process.env.LIMIT_ORDER_ADAPTER_ADDRESS || deployment.contracts.UniswapV3LimitOrderAdapter,
            [BASE_SEPOLIA_SWAP_ROUTER, BASE_SEPOLIA_FACTORY],
            process.env.FORCE_DEPLOY_LIMIT_ORDER === "true"
        )).address;

    const actionRegistry = await ethers.getContractAt("ActionRegistry", deployment.contracts.ActionRegistry, deployer);
    const executeSelector = ethers.id("execute(address,bytes)").slice(0, 10);

    await registerAdapterIfNeeded(actionRegistry, executeSelector, "UniswapV3DCAAdapter", dcaAdapterAddress, 450000);
    await registerAdapterIfNeeded(
        actionRegistry,
        executeSelector,
        "UniswapV3LimitOrderAdapter",
        limitOrderAdapterAddress,
        650000
    );

    await approveProtocolIfNeeded(actionRegistry, "UniswapV3DCAAdapter", dcaAdapterAddress);
    await approveProtocolIfNeeded(actionRegistry, "UniswapV3LimitOrderAdapter", limitOrderAdapterAddress);

    deployment.transactions.push(...txLog);
    deployment.contracts.UniswapV3DCAAdapter = dcaAdapterAddress;
    deployment.contracts.UniswapV3LimitOrderAdapter = limitOrderAdapterAddress;
    fs.writeFileSync(filepath, JSON.stringify(deployment, null, 2));
    updateManifest(deployment.contracts);

    console.log("\nDone. New adapters:");
    console.log(`   UniswapV3DCAAdapter: ${dcaAdapterAddress}`);
    console.log(`   ${EXPLORER}/address/${dcaAdapterAddress}`);
    console.log(`   UniswapV3LimitOrderAdapter: ${limitOrderAdapterAddress}`);
    console.log(`   ${EXPLORER}/address/${limitOrderAdapterAddress}`);
    console.log(`\nUpdated: deployments/${DEPLOYMENT_FILE}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("\nDeployment failed:", error);
        process.exit(1);
    });
