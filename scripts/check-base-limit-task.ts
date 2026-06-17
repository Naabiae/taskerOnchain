import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const DEPLOYMENT_FILE = path.join(__dirname, "..", "deployments", "deployment-base-sepolia-1777342795028.json");
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const WETH = "0x4200000000000000000000000000000000000006";
const TASK_ID = process.env.TASK_ID || "4";

const ERC20_ABI = [
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function balanceOf(address account) view returns (uint256)",
];

const GLOBAL_REGISTRY_ABI = [
    "function getTaskAddresses(uint256 taskId) view returns (address taskCore,address taskVault)",
];

const TASK_CORE_ABI = [
    "function getMetadata() view returns (tuple(uint256 id,address creator,uint96 createdAt,uint256 expiresAt,uint256 maxExecutions,uint256 executionCount,uint256 lastExecutionTime,uint256 recurringInterval,uint256 rewardPerExecution,uint8 status,bytes32 actionsHash,bytes32 seedCommitment))",
    "function isExecutable() view returns (bool)",
];

const EXECUTOR_HUB_ABI = [
    "event ExecutionCompleted(uint256 indexed taskId,address indexed executor,bool success)",
];

async function main() {
    const deployment = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf8"));
    const [signer] = await ethers.getSigners();
    const registry = new ethers.Contract(deployment.contracts.GlobalRegistry, GLOBAL_REGISTRY_ABI, signer);
    const executorHub = new ethers.Contract(deployment.contracts.ExecutorHub, EXECUTOR_HUB_ABI, signer);
    const usdc = new ethers.Contract(USDC, ERC20_ABI, signer);
    const weth = new ethers.Contract(WETH, ERC20_ABI, signer);

    const [taskCoreAddress, taskVaultAddress] = await registry.getTaskAddresses(TASK_ID);
    const taskCore = new ethers.Contract(taskCoreAddress, TASK_CORE_ABI, signer);
    const [usdcDecimals, usdcSymbol, wethSymbol, metadata, isExecutable, vaultUsdc, vaultWeth] = await Promise.all([
        usdc.decimals(),
        usdc.symbol(),
        weth.symbol(),
        taskCore.getMetadata(),
        taskCore.isExecutable(),
        usdc.balanceOf(taskVaultAddress),
        weth.balanceOf(taskVaultAddress),
    ]);

    console.log("Task:", TASK_ID);
    console.log("TaskCore:", taskCoreAddress);
    console.log("TaskVault:", taskVaultAddress);
    console.log("Status:", metadata.status.toString(), "(0=ACTIVE, 3=COMPLETED)");
    console.log("Execution count:", metadata.executionCount.toString());
    console.log("Executable:", isExecutable);
    console.log(`Vault ${usdcSymbol}:`, ethers.formatUnits(vaultUsdc, usdcDecimals));
    console.log(`Vault ${wethSymbol}:`, ethers.formatUnits(vaultWeth, 18));

    const execReceipt = await ethers.provider.getTransactionReceipt("0x28f8544733b73b4b3fc43b4b38c369e31781e55ec24d77703fa420fda9820f79");
    for (const log of execReceipt?.logs || []) {
        try {
            const parsed = executorHub.interface.parseLog(log);
            if (parsed?.name === "ExecutionCompleted") {
                console.log("ExecutionCompleted success:", parsed.args.success);
            }
        } catch {}
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
