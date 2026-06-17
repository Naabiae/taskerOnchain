/**
 * Create and execute one Base Sepolia Uniswap V3 DCA task:
 * official USDC -> WETH, default amount 1 USDC.
 *
 * Usage:
 *   npx hardhat run scripts/run-base-dca-usdc-eth.ts --network baseSepolia
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const DEPLOYMENT_FILE = path.join(
    __dirname,
    "..",
    "deployments",
    "deployment-base-sepolia-1777342795028.json"
);

const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const WETH = "0x4200000000000000000000000000000000000006";
const DEFAULT_AMOUNT_USDC = "1";

const ERC20_ABI = [
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function balanceOf(address account) view returns (uint256)",
    "function allowance(address owner,address spender) view returns (uint256)",
    "function approve(address spender,uint256 amount) returns (bool)",
];

const TASK_FACTORY_ABI = [
    "function minTaskReward() view returns (uint256)",
    "function createTaskWithTokens(tuple(uint256 expiresAt,uint256 maxExecutions,uint256 recurringInterval,uint256 rewardPerExecution,bytes32 seedCommitment) params, tuple(bytes4 selector,address protocol,bytes params)[] actions, tuple(address token,uint256 amount)[] deposits) payable returns (uint256 taskId,address taskCore,address taskVault)",
    "event TaskCreated(uint256 indexed taskId,address indexed creator,address indexed taskCore,address taskVault,uint256 reward,uint256 maxExecutions)",
];

const REWARD_MANAGER_ABI = [
    "function getMaxRewardCost(uint256 baseReward) view returns (uint256)",
];

const DCA_ADAPTER_ABI = [
    "function validateParams(bytes params) view returns (bool isValid,string errorMessage)",
    "function canExecute(bytes params) view returns (bool canExec,string reason)",
    "function getDCAStatus(bytes32 taskId) view returns (uint256 execCount,uint256 lastExec)",
];

const EXECUTOR_HUB_ABI = [
    "function executeTask(uint256 taskId) returns (bool success)",
    "event ExecutionCompleted(uint256 indexed taskId,address indexed executor,bool success)",
];

async function main() {
    const deployment = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf8"));
    const [signer] = await ethers.getSigners();
    const signerAddress = await signer.getAddress();
    const network = await ethers.provider.getNetwork();

    if (network.chainId !== 84532n) {
        throw new Error(`Wrong network. Expected Base Sepolia 84532, got ${network.chainId.toString()}`);
    }

    const amountHuman = process.env.DCA_USDC_AMOUNT || DEFAULT_AMOUNT_USDC;
    const fee = Number(process.env.UNISWAP_FEE || "3000");
    const adapterAddress = deployment.contracts.UniswapV3DCAAdapter;
    const taskFactoryAddress = deployment.contracts.TaskFactory;
    const rewardManagerAddress = deployment.contracts.RewardManager;
    const executorHubAddress = deployment.contracts.ExecutorHub;

    console.log("\nBase Sepolia USDC -> WETH DCA test");
    console.log("Signer:", signerAddress);
    console.log("USDC:", USDC);
    console.log("WETH:", WETH);
    console.log("Amount:", amountHuman, "USDC");
    console.log("Adapter:", adapterAddress);

    const usdc = new ethers.Contract(USDC, ERC20_ABI, signer);
    const weth = new ethers.Contract(WETH, ERC20_ABI, signer);
    const taskFactory = new ethers.Contract(taskFactoryAddress, TASK_FACTORY_ABI, signer);
    const rewardManager = new ethers.Contract(rewardManagerAddress, REWARD_MANAGER_ABI, signer);
    const adapter = new ethers.Contract(adapterAddress, DCA_ADAPTER_ABI, signer);
    const executorHub = new ethers.Contract(executorHubAddress, EXECUTOR_HUB_ABI, signer);

    const [usdcDecimals, usdcSymbol, wethDecimals, wethSymbol] = await Promise.all([
        usdc.decimals(),
        usdc.symbol(),
        weth.decimals(),
        weth.symbol(),
    ]);

    const amountPerSwap = ethers.parseUnits(amountHuman, usdcDecimals);
    const balance = await usdc.balanceOf(signerAddress);
    console.log(`${usdcSymbol} balance:`, ethers.formatUnits(balance, usdcDecimals));
    if (balance < amountPerSwap) {
        throw new Error(`Insufficient ${usdcSymbol}. Need ${amountHuman}, have ${ethers.formatUnits(balance, usdcDecimals)}`);
    }

    const dcaId = ethers.keccak256(
        ethers.solidityPacked(
            ["string", "address", "uint256", "uint256"],
            ["base-sepolia-dca-test", signerAddress, network.chainId, BigInt(Date.now())]
        )
    );

    const dcaParams = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address", "address", "uint24", "uint256", "uint256", "uint256", "uint256", "address"],
        [
            dcaId,
            USDC,
            WETH,
            fee,
            amountPerSwap,
            60,
            1,
            0,
            signerAddress,
        ]
    );

    const [isValid, validationError] = await adapter.validateParams(dcaParams);
    console.log("Params valid:", isValid, validationError || "");
    if (!isValid) throw new Error(`Invalid DCA params: ${validationError}`);

    const [canExecute, reason] = await adapter.canExecute(dcaParams);
    console.log("Adapter canExecute:", canExecute, reason);
    if (!canExecute) throw new Error(`DCA is not executable: ${reason}`);

    const allowance = await usdc.allowance(signerAddress, taskFactoryAddress);
    if (allowance < amountPerSwap) {
        console.log("Approving TaskFactory for", amountHuman, usdcSymbol);
        const approveTx = await usdc.approve(taskFactoryAddress, amountPerSwap);
        console.log("Approve tx:", approveTx.hash);
        await approveTx.wait();
    }

    const latestBlock = await ethers.provider.getBlock("latest");
    if (!latestBlock) throw new Error("Unable to read latest block");
    const chainNow = BigInt(latestBlock.timestamp);
    const rewardPerExecution = await taskFactory.minTaskReward();
    const nativeValue = await rewardManager.getMaxRewardCost(rewardPerExecution);

    const taskParams = {
        expiresAt: chainNow + 24n * 60n * 60n,
        maxExecutions: 1n,
        recurringInterval: 0n,
        rewardPerExecution,
        seedCommitment: ethers.ZeroHash,
    };
    const actions = [{
        selector: ethers.id("execute(address,bytes)").slice(0, 10),
        protocol: adapterAddress,
        params: dcaParams,
    }];
    const deposits = [{ token: USDC, amount: amountPerSwap }];

    console.log("Creating DCA task. Native reward funding:", ethers.formatEther(nativeValue), "ETH");
    const createGas = await taskFactory.createTaskWithTokens.estimateGas(taskParams, actions, deposits, { value: nativeValue });
    const createTx = await taskFactory.createTaskWithTokens(taskParams, actions, deposits, {
        value: nativeValue,
        gasLimit: (createGas * 130n) / 100n,
    });
    console.log("Create tx:", createTx.hash);
    const createReceipt = await createTx.wait();

    let taskId = 0n;
    let taskCore = ethers.ZeroAddress;
    let taskVault = ethers.ZeroAddress;
    for (const log of createReceipt?.logs || []) {
        try {
            const parsed = taskFactory.interface.parseLog(log);
            if (parsed?.name === "TaskCreated") {
                taskId = parsed.args.taskId;
                taskCore = parsed.args.taskCore;
                taskVault = parsed.args.taskVault;
                break;
            }
        } catch {}
    }

    console.log("Task ID:", taskId.toString());
    console.log("TaskCore:", taskCore);
    console.log("TaskVault:", taskVault);
    console.log("Create explorer:", `${deployment.explorer}/tx/${createTx.hash}`);

    const wethBefore = await weth.balanceOf(signerAddress);
    console.log(`${wethSymbol} before raw:`, wethBefore.toString());

    console.log("Executing DCA task...");
    const execGas = await executorHub.executeTask.estimateGas(taskId);
    const execTx = await executorHub.executeTask(taskId, {
        gasLimit: (execGas * 140n) / 100n,
    });
    console.log("Execute tx:", execTx.hash);
    const execReceipt = await execTx.wait();

    let executionSuccess = false;
    for (const log of execReceipt?.logs || []) {
        try {
            const parsed = executorHub.interface.parseLog(log);
            if (parsed?.name === "ExecutionCompleted") {
                executionSuccess = parsed.args.success;
            }
        } catch {}
    }

    const [wethAfter, usdcAfter, dcaStatus] = await Promise.all([
        weth.balanceOf(signerAddress),
        usdc.balanceOf(signerAddress),
        adapter.getDCAStatus(dcaId),
    ]);

    console.log("Execution success:", executionSuccess);
    console.log("Executed in block:", execReceipt?.blockNumber);
    console.log(`${wethSymbol} after raw:`, wethAfter.toString());
    console.log(`${wethSymbol} received raw:`, (wethAfter - wethBefore).toString());
    console.log(`${wethSymbol} received:`, ethers.formatUnits(wethAfter - wethBefore, wethDecimals));
    console.log(`${usdcSymbol} after:`, ethers.formatUnits(usdcAfter, usdcDecimals));
    console.log("DCA execution count:", dcaStatus.execCount.toString());
    console.log("Execute explorer:", `${deployment.explorer}/tx/${execTx.hash}`);
}

main().catch((error) => {
    console.error("\nDCA run failed:");
    console.error(error);
    process.exitCode = 1;
});
