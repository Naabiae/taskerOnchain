/**
 * Base Sepolia Deployment Script - Recurring Transfers MVP
 *
 * Deploys minimal contracts for recurring payment testing:
 *   - MockUSDC + MockUSDT (for testnet users)
 *   - Core system contracts
 *   - RecurringTransferAdapter (VAULT + PULL modes)
 *
 * Usage:
 *   npx hardhat run scripts/deploy-base-recurring.ts --network baseSepolia
 *
 * Prerequisites:
 *   - Set BASE_DEPLOYER_KEY env var with funded wallet
 *   - Or use default DEPLOYER_KEY
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface DeploymentRecord {
    network: string;
    chainId: string;
    deployer: string;
    deployedAt: string;
    explorer: string;
    transactions: TxRecord[];
    contracts: Record<string, string>;
}

interface TxRecord {
    step: string;
    txHash: string;
    contractAddress?: string;
    blockNumber?: number;
    gasUsed?: string;
}

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
    console.log(`   ✅ [TX ${txLog.length}] ${step}`);
    console.log(`      Hash: ${tx.hash}`);
    if (contractAddress) console.log(`      Address: ${contractAddress}`);
    console.log(`      Gas: ${record.gasUsed} | Block: ${record.blockNumber}`);
}

async function main() {
    console.log("\n🔵 UARC Recurring Transfers MVP - Base Sepolia\n");
    console.log("=".repeat(60));

    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    const network = await ethers.provider.getNetwork();
    const balance = await ethers.provider.getBalance(deployerAddress);

    console.log("Deployer:", deployerAddress);
    console.log("Network:", network.name, "| ChainID:", network.chainId.toString());
    console.log("Balance:", ethers.formatEther(balance), "ETH\n");

    if (balance < ethers.parseEther("0.01")) {
        console.log("⚠️  Warning: Low balance. Need ~0.05 ETH for full deployment.");
    }

    console.log("=".repeat(60), "\n");

    const contracts: Record<string, string> = {};

    // ============================================================
    // STEP 1: Mock Tokens (USDC + USDT for testing)
    // ============================================================
    console.log("📦 STEP 1: Deploying Mock Tokens...\n");

    const MockERC20 = await ethers.getContractFactory("MockERC20");

    const mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6);
    await mockUSDC.waitForDeployment();
    contracts.MockUSDC = await mockUSDC.getAddress();
    await recordTx("Deploy MockUSDC", mockUSDC.deploymentTransaction()!, contracts.MockUSDC);

    const mockUSDT = await MockERC20.deploy("Mock USDT", "USDT", 6);
    await mockUSDT.waitForDeployment();
    contracts.MockUSDT = await mockUSDT.getAddress();
    await recordTx("Deploy MockUSDT", mockUSDT.deploymentTransaction()!, contracts.MockUSDT);

    // Mint initial supply to deployer (for distributing to testnet users)
    const mintAmount = ethers.parseUnits("10000000", 6); // 10M tokens
    const mintUsdcTx = await mockUSDC.mint(deployerAddress, mintAmount);
    await recordTx("Mint 10M MockUSDC to deployer", mintUsdcTx);

    const mintUsdtTx = await mockUSDT.mint(deployerAddress, mintAmount);
    await recordTx("Mint 10M MockUSDT to deployer", mintUsdtTx);

    console.log();

    // ============================================================
    // STEP 2: Core Implementations (TaskCore + TaskVault)
    // ============================================================
    console.log("📦 STEP 2: Deploying Core Implementations...\n");

    const TaskCore = await ethers.getContractFactory("TaskCore");
    const taskCoreImpl = await TaskCore.deploy();
    await taskCoreImpl.waitForDeployment();
    contracts.TaskCoreImpl = await taskCoreImpl.getAddress();
    await recordTx("Deploy TaskCore Implementation", taskCoreImpl.deploymentTransaction()!, contracts.TaskCoreImpl);

    const TaskVault = await ethers.getContractFactory("TaskVault");
    const taskVaultImpl = await TaskVault.deploy();
    await taskVaultImpl.waitForDeployment();
    contracts.TaskVaultImpl = await taskVaultImpl.getAddress();
    await recordTx("Deploy TaskVault Implementation", taskVaultImpl.deploymentTransaction()!, contracts.TaskVaultImpl);

    console.log();

    // ============================================================
    // STEP 3: System Contracts
    // ============================================================
    console.log("📦 STEP 3: Deploying System Contracts...\n");

    const ActionRegistry = await ethers.getContractFactory("ActionRegistry");
    const actionRegistry = await ActionRegistry.deploy(deployerAddress);
    await actionRegistry.waitForDeployment();
    contracts.ActionRegistry = await actionRegistry.getAddress();
    await recordTx("Deploy ActionRegistry", actionRegistry.deploymentTransaction()!, contracts.ActionRegistry);

    const ExecutorHub = await ethers.getContractFactory("ExecutorHub");
    const executorHub = await ExecutorHub.deploy(deployerAddress);
    await executorHub.waitForDeployment();
    contracts.ExecutorHub = await executorHub.getAddress();
    await recordTx("Deploy ExecutorHub", executorHub.deploymentTransaction()!, contracts.ExecutorHub);

    const GlobalRegistry = await ethers.getContractFactory("GlobalRegistry");
    const globalRegistry = await GlobalRegistry.deploy(deployerAddress);
    await globalRegistry.waitForDeployment();
    contracts.GlobalRegistry = await globalRegistry.getAddress();
    await recordTx("Deploy GlobalRegistry", globalRegistry.deploymentTransaction()!, contracts.GlobalRegistry);

    const RewardManager = await ethers.getContractFactory("RewardManager");
    const rewardManager = await RewardManager.deploy(deployerAddress);
    await rewardManager.waitForDeployment();
    contracts.RewardManager = await rewardManager.getAddress();
    await recordTx("Deploy RewardManager", rewardManager.deploymentTransaction()!, contracts.RewardManager);

    const TaskLogicV2 = await ethers.getContractFactory("TaskLogicV2");
    const taskLogic = await TaskLogicV2.deploy(deployerAddress);
    await taskLogic.waitForDeployment();
    contracts.TaskLogicV2 = await taskLogic.getAddress();
    await recordTx("Deploy TaskLogicV2", taskLogic.deploymentTransaction()!, contracts.TaskLogicV2);

    const TaskFactory = await ethers.getContractFactory("TaskFactory");
    const taskFactory = await TaskFactory.deploy(
        contracts.TaskCoreImpl,
        contracts.TaskVaultImpl,
        contracts.TaskLogicV2,
        contracts.ExecutorHub,
        contracts.ActionRegistry,
        contracts.RewardManager,
        deployerAddress
    );
    await taskFactory.waitForDeployment();
    contracts.TaskFactory = await taskFactory.getAddress();
    await recordTx("Deploy TaskFactory", taskFactory.deploymentTransaction()!, contracts.TaskFactory);

    console.log();

    // ============================================================
    // STEP 4: RecurringTransferAdapter
    // ============================================================
    console.log("📦 STEP 4: Deploying RecurringTransferAdapter...\n");

    const RecurringAdapter = await ethers.getContractFactory("RecurringTransferAdapter");
    const recurringAdapter = await RecurringAdapter.deploy();
    await recurringAdapter.waitForDeployment();
    contracts.RecurringTransferAdapter = await recurringAdapter.getAddress();
    await recordTx("Deploy RecurringTransferAdapter", recurringAdapter.deploymentTransaction()!, contracts.RecurringTransferAdapter);

    // Also deploy TimeBasedTransferAdapter for simple one-time transfers
    const TimeAdapter = await ethers.getContractFactory("TimeBasedTransferAdapter");
    const timeAdapter = await TimeAdapter.deploy();
    await timeAdapter.waitForDeployment();
    contracts.TimeBasedTransferAdapter = await timeAdapter.getAddress();
    await recordTx("Deploy TimeBasedTransferAdapter", timeAdapter.deploymentTransaction()!, contracts.TimeBasedTransferAdapter);

    console.log();

    // ============================================================
    // STEP 5: Configure System
    // ============================================================
    console.log("⚙️  STEP 5: Configuring System...\n");

    const setActionRegistryTx = await taskLogic.setActionRegistry(contracts.ActionRegistry);
    await recordTx("TaskLogicV2.setActionRegistry", setActionRegistryTx);

    const setRewardManagerTx = await taskLogic.setRewardManager(contracts.RewardManager);
    await recordTx("TaskLogicV2.setRewardManager", setRewardManagerTx);

    const setExecutorHubTx = await taskLogic.setExecutorHub(contracts.ExecutorHub);
    await recordTx("TaskLogicV2.setExecutorHub", setExecutorHubTx);

    const setTaskRegistryTx = await taskLogic.setTaskRegistry(contracts.GlobalRegistry);
    await recordTx("TaskLogicV2.setTaskRegistry", setTaskRegistryTx);

    const setTaskLogicTx = await executorHub.setTaskLogic(contracts.TaskLogicV2);
    await recordTx("ExecutorHub.setTaskLogic", setTaskLogicTx);

    const setHubRegistryTx = await executorHub.setTaskRegistry(contracts.GlobalRegistry);
    await recordTx("ExecutorHub.setTaskRegistry", setHubRegistryTx);

    const setRmTaskLogicTx = await rewardManager.setTaskLogic(contracts.TaskLogicV2);
    await recordTx("RewardManager.setTaskLogic", setRmTaskLogicTx);

    const setRmExecutorHubTx = await rewardManager.setExecutorHub(contracts.ExecutorHub);
    await recordTx("RewardManager.setExecutorHub", setRmExecutorHubTx);

    // Low gas reimbursement for testnet
    const setMultiplierTx = await rewardManager.setGasReimbursementMultiplier(0);
    await recordTx("RewardManager.setGasReimbursementMultiplier(0)", setMultiplierTx);

    const authorizeFactoryTx = await globalRegistry.authorizeFactory(contracts.TaskFactory);
    await recordTx("GlobalRegistry.authorizeFactory", authorizeFactoryTx);

    const setGlobalRegistryTx = await taskFactory.setGlobalRegistry(contracts.GlobalRegistry);
    await recordTx("TaskFactory.setGlobalRegistry", setGlobalRegistryTx);

    console.log();

    // ============================================================
    // STEP 6: Register Adapters
    // ============================================================
    console.log("📦 STEP 6: Registering Adapters...\n");

    const executeSelector = ethers.id("execute(address,bytes)").slice(0, 10);

    // RecurringTransferAdapter - our main focus
    const regRecurringTx = await actionRegistry.registerAdapter(
        executeSelector,
        contracts.RecurringTransferAdapter,
        200000, // Gas limit estimate
        true
    );
    await recordTx("Register RecurringTransferAdapter", regRecurringTx);

    // TimeBasedTransferAdapter - for simple one-time transfers
    const regTimeTx = await actionRegistry.registerAdapter(
        executeSelector,
        contracts.TimeBasedTransferAdapter,
        150000,
        true
    );
    await recordTx("Register TimeBasedTransferAdapter", regTimeTx);

    // Approve adapters as valid protocols
    const approveRecurringTx = await actionRegistry.approveProtocol(contracts.RecurringTransferAdapter);
    await recordTx("Approve RecurringTransferAdapter protocol", approveRecurringTx);

    const approveTimeTx = await actionRegistry.approveProtocol(contracts.TimeBasedTransferAdapter);
    await recordTx("Approve TimeBasedTransferAdapter protocol", approveTimeTx);

    console.log();

    // ============================================================
    // SUMMARY
    // ============================================================
    console.log("=".repeat(60));
    console.log("🎉 DEPLOYMENT COMPLETE - Base Sepolia");
    console.log("=".repeat(60));
    console.log("\n📋 Contract Addresses:\n");
    for (const [name, addr] of Object.entries(contracts)) {
        console.log(`   ${name}: ${addr}`);
        console.log(`   └─ https://sepolia.basescan.org/address/${addr}`);
    }
    console.log(`\n📊 Total Transactions: ${txLog.length}`);

    // ============================================================
    // SAVE DEPLOYMENT
    // ============================================================
    const deployment: DeploymentRecord = {
        network: "baseSepolia",
        chainId: network.chainId.toString(),
        deployer: deployerAddress,
        deployedAt: new Date().toISOString(),
        explorer: "https://sepolia.basescan.org",
        transactions: txLog,
        contracts,
    };

    const deploymentsDir = path.join(__dirname, "..", "deployments");
    if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

    const filename = `deployment-base-sepolia-${Date.now()}.json`;
    const filepath = path.join(deploymentsDir, filename);
    fs.writeFileSync(filepath, JSON.stringify(deployment, null, 2));
    console.log(`\n💾 Saved to: deployments/${filename}`);

    // Update agent manifest for Base Sepolia
    const manifestPath = path.join(__dirname, "..", "agent", "manifest-base.json");
    const manifest = {
        protocol: "UARC - Universal Automation",
        network: "Base Sepolia Testnet",
        chainId: 84532,
        deployer: deployerAddress,
        deployedAt: new Date().toISOString(),
        explorer: "https://sepolia.basescan.org",
        nativeToken: "ETH",
        rpc: "https://sepolia.base.org",
        contracts: {
            TaskFactory: contracts.TaskFactory,
            TaskLogicV2: contracts.TaskLogicV2,
            ExecutorHub: contracts.ExecutorHub,
            GlobalRegistry: contracts.GlobalRegistry,
            RewardManager: contracts.RewardManager,
            ActionRegistry: contracts.ActionRegistry,
        },
        tokens: {
            MockUSDC: {
                address: contracts.MockUSDC,
                symbol: "USDC",
                decimals: 6,
                faucetAmount: "1000", // Amount to give testnet users
            },
            MockUSDT: {
                address: contracts.MockUSDT,
                symbol: "USDT",
                decimals: 6,
                faucetAmount: "1000",
            },
        },
        adapters: {
            RecurringTransferAdapter: {
                address: contracts.RecurringTransferAdapter,
                description: "Recurring token transfers (weekly, monthly, etc.)",
                fundingModes: ["VAULT", "PULL"],
            },
            TimeBasedTransferAdapter: {
                address: contracts.TimeBasedTransferAdapter,
                description: "One-time transfer at specified timestamp",
                fundingModes: ["VAULT"],
            },
        },
        actions: [
            {
                id: "recurring_transfer",
                adapter: contracts.RecurringTransferAdapter,
                description: "Send tokens on a recurring schedule (weekly, monthly)",
                params: [
                    "token:address",
                    "recipient:address",
                    "amountPerExecution:uint256",
                    "startTime:uint256",
                    "interval:uint256",
                    "maxExecutions:uint256",
                    "fundingMode:uint8 (0=VAULT, 1=PULL)",
                    "fundingSource:address (for PULL mode)",
                ],
                examples: [
                    "Send $50 USDC to alice.eth weekly",
                    "Pay 100 USDT monthly to 0x123...",
                    "Transfer $25 every day for 30 days",
                ],
            },
            {
                id: "time_based_transfer",
                adapter: contracts.TimeBasedTransferAdapter,
                description: "One-time transfer at a specific time",
                params: [
                    "token:address",
                    "recipient:address",
                    "amount:uint256",
                    "executeAfter:uint256",
                ],
                examples: [
                    "Send $100 USDC to bob.eth tomorrow at noon",
                    "Transfer 500 USDT on January 1st",
                ],
            },
        ],
        testFaucet: {
            description: "Request test tokens for trying the protocol",
            supportedTokens: ["USDC", "USDT"],
            maxPerRequest: "1000",
        },
    };

    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log(`💾 Updated agent/manifest-base.json`);

    // Print quick start guide
    console.log("\n" + "=".repeat(60));
    console.log("🚀 QUICK START FOR TESTNET USERS");
    console.log("=".repeat(60));
    console.log(`
1. Add Base Sepolia to wallet:
   - RPC: https://sepolia.base.org
   - Chain ID: 84532
   - Symbol: ETH

2. Get testnet ETH:
   - https://www.coinbase.com/faucets/base-ethereum-goerli-faucet
   - Or bridge from Sepolia

3. Request test tokens from deployer:
   - MockUSDC: ${contracts.MockUSDC}
   - MockUSDT: ${contracts.MockUSDT}

4. Create your first recurring payment!
`);

    return deployment;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("\n❌ Deployment failed:", error);
        process.exit(1);
    });
