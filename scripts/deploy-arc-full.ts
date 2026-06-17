/**
 * Full Arc Testnet Deployment Script
 * Deploys all UARC contracts + mocks, configures them, and saves all addresses + tx hashes
 *
 * Usage:
 *   npx hardhat run scripts/deploy-arc-full.ts --network arcTestnet
 *
 * Deploys:
 *   - MockERC20 USDC (6 decimals)
 *   - MockERC20 EURO (6 decimals)
 *   - MockTokenMessenger (CCTP simulator)
 *   - MockStorkOracle (USDC/USD price feed)
 *   - TaskCore + TaskVault implementations
 *   - ActionRegistry, ExecutorHub, GlobalRegistry, RewardManager
 *   - TaskLogicV2 + TaskFactory
 *   - TimeBasedTransferAdapter
 *   - CCTPTransferAdapter
 *   - StorkPriceTransferAdapter
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface DeploymentRecord {
    network: string;
    chainId: string;
    deployer: string;
    deployedAt: string;
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
        contractAddress: contractAddress,
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
    console.log("\n🚀 UARC Full Deployment on Arc Testnet\n");
    console.log("=".repeat(60));

    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    const network = await ethers.provider.getNetwork();
    const balance = await ethers.provider.getBalance(deployerAddress);

    console.log("Deployer:", deployerAddress);
    console.log("Network:", network.name, "| ChainID:", network.chainId.toString());
    console.log("Balance:", ethers.formatEther(balance), "ETH\n");
    console.log("=".repeat(60), "\n");

    const contracts: Record<string, string> = {};

    // ============================================================
    // STEP 1: Mock Tokens
    // ============================================================
    console.log("📦 STEP 1: Deploying Mock Tokens...\n");

    const MockERC20 = await ethers.getContractFactory("MockERC20");

    const mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6);
    await mockUSDC.waitForDeployment();
    contracts.MockUSDC = await mockUSDC.getAddress();
    await recordTx("Deploy MockUSDC", mockUSDC.deploymentTransaction()!, contracts.MockUSDC);

    const mockEURO = await MockERC20.deploy("Mock EURO", "EURO", 6);
    await mockEURO.waitForDeployment();
    contracts.MockEURO = await mockEURO.getAddress();
    await recordTx("Deploy MockEURO", mockEURO.deploymentTransaction()!, contracts.MockEURO);

    // Mint initial supply to deployer
    const mintAmount = ethers.parseUnits("1000000", 6); // 1M tokens
    const mintUsdcTx = await mockUSDC.mint(deployerAddress, mintAmount);
    await recordTx("Mint 1M MockUSDC to deployer", mintUsdcTx);

    const mintEuroTx = await mockEURO.mint(deployerAddress, mintAmount);
    await recordTx("Mint 1M MockEURO to deployer", mintEuroTx);

    console.log();

    // ============================================================
    // STEP 2: Mock CCTP Messenger
    // ============================================================
    console.log("📦 STEP 2: Deploying Mock TokenMessenger (CCTP)...\n");

    const MockTokenMessenger = await ethers.getContractFactory("MockTokenMessenger");
    const mockMessenger = await MockTokenMessenger.deploy();
    await mockMessenger.waitForDeployment();
    contracts.MockTokenMessenger = await mockMessenger.getAddress();
    await recordTx("Deploy MockTokenMessenger", mockMessenger.deploymentTransaction()!, contracts.MockTokenMessenger);

    console.log();

    // ============================================================
    // STEP 3: Mock Stork Oracle (Chainlink-compatible)
    // ============================================================
    console.log("📦 STEP 3: Deploying Mock Stork Oracles...\n");

    const MockStorkOracle = await ethers.getContractFactory("MockStorkOracle");

    // USDC/USD — start at $1.00 (8 decimals)
    const mockUsdcOracle = await MockStorkOracle.deploy("USDC / USD", 8, 100000000n);
    await mockUsdcOracle.waitForDeployment();
    contracts.MockStorkOracleUSDC = await mockUsdcOracle.getAddress();
    await recordTx("Deploy MockStorkOracle USDC/USD", mockUsdcOracle.deploymentTransaction()!, contracts.MockStorkOracleUSDC);

    // EURO/USD — start at $1.08
    const mockEuroOracle = await MockStorkOracle.deploy("EURO / USD", 8, 108000000n);
    await mockEuroOracle.waitForDeployment();
    contracts.MockStorkOracleEURO = await mockEuroOracle.getAddress();
    await recordTx("Deploy MockStorkOracle EURO/USD", mockEuroOracle.deploymentTransaction()!, contracts.MockStorkOracleEURO);

    console.log();

    // ============================================================
    // STEP 4: Core Implementation Contracts
    // ============================================================
    console.log("📦 STEP 4: Deploying Core Implementations...\n");

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
    // STEP 5: System Contracts
    // ============================================================
    console.log("📦 STEP 5: Deploying System Contracts...\n");

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
    // STEP 6: Adapters
    // ============================================================
    console.log("📦 STEP 6: Deploying Adapters...\n");

    const TimeAdapter = await ethers.getContractFactory("TimeBasedTransferAdapter");
    const timeAdapter = await TimeAdapter.deploy();
    await timeAdapter.waitForDeployment();
    contracts.TimeBasedTransferAdapter = await timeAdapter.getAddress();
    await recordTx("Deploy TimeBasedTransferAdapter", timeAdapter.deploymentTransaction()!, contracts.TimeBasedTransferAdapter);

    const CCTPAdapter = await ethers.getContractFactory("CCTPTransferAdapter");
    const cctpAdapter = await CCTPAdapter.deploy();
    await cctpAdapter.waitForDeployment();
    contracts.CCTPTransferAdapter = await cctpAdapter.getAddress();
    await recordTx("Deploy CCTPTransferAdapter", cctpAdapter.deploymentTransaction()!, contracts.CCTPTransferAdapter);

    const StorkAdapter = await ethers.getContractFactory("StorkPriceTransferAdapter");
    const storkAdapter = await StorkAdapter.deploy();
    await storkAdapter.waitForDeployment();
    contracts.StorkPriceTransferAdapter = await storkAdapter.getAddress();
    await recordTx("Deploy StorkPriceTransferAdapter", storkAdapter.deploymentTransaction()!, contracts.StorkPriceTransferAdapter);

    console.log();

    // ============================================================
    // STEP 7: Configure System Contracts
    // ============================================================
    console.log("⚙️  STEP 7: Configuring System...\n");

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

    const setMultiplierTx = await rewardManager.setGasReimbursementMultiplier(0); // no gas reimbursement on testnet
    await recordTx("RewardManager.setGasReimbursementMultiplier", setMultiplierTx);

    const authorizeFactoryTx = await globalRegistry.authorizeFactory(contracts.TaskFactory);
    await recordTx("GlobalRegistry.authorizeFactory", authorizeFactoryTx);

    const setGlobalRegistryTx = await taskFactory.setGlobalRegistry(contracts.GlobalRegistry);
    await recordTx("TaskFactory.setGlobalRegistry", setGlobalRegistryTx);

    console.log();

    // ============================================================
    // STEP 8: Register Adapters
    // ============================================================
    console.log("📦 STEP 8: Registering Adapters...\n");

    const executeSelector = ethers.id("execute(address,bytes)").slice(0, 10);

    const regTimeTx = await actionRegistry.registerAdapter(
        executeSelector,
        contracts.TimeBasedTransferAdapter,
        150000,
        true
    );
    await recordTx("Register TimeBasedTransferAdapter", regTimeTx);

    const regCctpTx = await actionRegistry.registerAdapter(
        executeSelector,
        contracts.CCTPTransferAdapter,
        300000,
        true
    );
    await recordTx("Register CCTPTransferAdapter", regCctpTx);

    const regStorkTx = await actionRegistry.registerAdapter(
        executeSelector,
        contracts.StorkPriceTransferAdapter,
        150000,
        true
    );
    await recordTx("Register StorkPriceTransferAdapter", regStorkTx);

    // Approve mock protocols (needed by TaskLogicV2)
    const approveTimeTx = await actionRegistry.approveProtocol(contracts.TimeBasedTransferAdapter);
    await recordTx("Approve TimeBasedTransferAdapter protocol", approveTimeTx);

    const approveCctpTx = await actionRegistry.approveProtocol(contracts.CCTPTransferAdapter);
    await recordTx("Approve CCTPTransferAdapter protocol", approveCctpTx);

    const approveStorkTx = await actionRegistry.approveProtocol(contracts.StorkPriceTransferAdapter);
    await recordTx("Approve StorkPriceTransferAdapter protocol", approveStorkTx);

    console.log();

    // ============================================================
    // SUMMARY
    // ============================================================
    console.log("=".repeat(60));
    console.log("🎉 DEPLOYMENT COMPLETE");
    console.log("=".repeat(60));
    console.log("\n📋 Contract Addresses:\n");
    for (const [name, addr] of Object.entries(contracts)) {
        console.log(`   ${name}: ${addr}`);
    }
    console.log(`\n📊 Total Transactions: ${txLog.length}`);

    // ============================================================
    // SAVE DEPLOYMENT
    // ============================================================
    const deployment: DeploymentRecord = {
        network: network.name,
        chainId: network.chainId.toString(),
        deployer: deployerAddress,
        deployedAt: new Date().toISOString(),
        transactions: txLog,
        contracts,
    };

    const deploymentsDir = path.join(__dirname, "..", "deployments");
    if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

    const filename = `deployment-arc-full-${Date.now()}.json`;
    const filepath = path.join(deploymentsDir, filename);
    fs.writeFileSync(filepath, JSON.stringify(deployment, null, 2));
    console.log(`\n💾 Saved to: deployments/${filename}`);

    // Update agent manifest with new addresses
    const manifestPath = path.join(__dirname, "..", "agent", "manifest.json");
    const manifest = {
        protocol: "UARC - Universal Automation on Arc",
        network: "Arc Testnet",
        chainId: 5042002,
        deployer: deployerAddress,
        deployedAt: new Date().toISOString(),
        nativeToken: "ETH",
        contracts: {
            TaskFactory: contracts.TaskFactory,
            TaskLogicV2: contracts.TaskLogicV2,
            ExecutorHub: contracts.ExecutorHub,
            GlobalRegistry: contracts.GlobalRegistry,
            RewardManager: contracts.RewardManager,
            ActionRegistry: contracts.ActionRegistry,
        },
        tokens: {
            MockUSDC: contracts.MockUSDC,
            MockEURO: contracts.MockEURO,
        },
        oracles: {
            MockStorkUSDC: contracts.MockStorkOracleUSDC,
            MockStorkEURO: contracts.MockStorkOracleEURO,
        },
        cctp: {
            MockTokenMessenger: contracts.MockTokenMessenger,
        },
        adapters: {
            TimeBasedTransferAdapter: contracts.TimeBasedTransferAdapter,
            CCTPTransferAdapter: contracts.CCTPTransferAdapter,
            StorkPriceTransferAdapter: contracts.StorkPriceTransferAdapter,
        },
        actions: [
            {
                id: "time_based_transfer",
                adapter: contracts.TimeBasedTransferAdapter,
                description: "Transfer USDC/EURO after a specific timestamp",
                params: ["token:address", "recipient:address", "amount:uint256", "executeAfter:uint256"],
            },
            {
                id: "cctp_bridge",
                adapter: contracts.CCTPTransferAdapter,
                description: "Cross-chain bridge via Circle CCTP after a timestamp",
                params: ["cctpMessenger:address", "token:address", "amount:uint256", "destinationDomain:uint32", "mintRecipient:bytes32", "executeAfter:uint256"],
            },
            {
                id: "stork_price_transfer",
                adapter: contracts.StorkPriceTransferAdapter,
                description: "Transfer tokens when Stork Oracle price condition is met",
                params: ["storkOracle:address", "token:address", "amount:uint256", "targetPrice:int256", "isBelow:bool", "recipient:address"],
            },
        ],
    };

    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log(`💾 Updated agent/manifest.json`);

    return deployment;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("\n❌ Deployment failed:", error);
        process.exit(1);
    });
