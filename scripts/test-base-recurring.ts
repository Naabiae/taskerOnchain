import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

type Deployment = {
    explorer: string;
    contracts: Record<string, string>;
};

const DEPLOYMENT_FILE = path.join(
    __dirname,
    "..",
    "deployments",
    "deployment-base-sepolia-1777342795028.json"
);

const ERC20_ABI = [
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function balanceOf(address account) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function mint(address to, uint256 amount)",
];

const TASK_FACTORY_ABI = [
    "function minTaskReward() view returns (uint256)",
    "function getTaskAddresses(uint256 taskId) view returns (address taskCore, address taskVault)",
    "function createTaskWithTokens(tuple(uint256 expiresAt,uint256 maxExecutions,uint256 recurringInterval,uint256 rewardPerExecution,bytes32 seedCommitment) params, tuple(bytes4 selector,address protocol,bytes params)[] actions, tuple(address token,uint256 amount)[] deposits) payable returns (uint256 taskId,address taskCore,address taskVault)",
    "event TaskCreated(uint256 indexed taskId,address indexed creator,address indexed taskCore,address taskVault,uint256 reward,uint256 maxExecutions)",
];

const RECURRING_ADAPTER_ABI = [
    "function validateParams(bytes params) view returns (bool isValid, string errorMessage)",
    "function canExecute(bytes params) view returns (bool canExec, string reason)",
    "function calculateTotalFunding(bytes params) pure returns (uint256 totalAmount, uint256 perExecution, uint256 executions)",
];

const REWARD_MANAGER_ABI = [
    "function getMaxRewardCost(uint256 baseReward) view returns (uint256)",
];

async function main() {
    const deployment = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf8")) as Deployment;
    const [signer] = await ethers.getSigners();
    const signerAddress = await signer.getAddress();
    const network = await ethers.provider.getNetwork();

    const taskFactoryAddress = deployment.contracts.TaskFactory;
    const usdcAddress = deployment.contracts.MockUSDC;
    const adapterAddress = deployment.contracts.RecurringTransferAdapter;
    const recipient = process.env.RECIPIENT || signerAddress;

    console.log("\nBase Sepolia recurring payment test");
    console.log("Network:", network.chainId.toString());
    console.log("Signer:", signerAddress);
    console.log("Recipient:", recipient);
    console.log("TaskFactory:", taskFactoryAddress);
    console.log("MockUSDC:", usdcAddress);
    console.log("RecurringTransferAdapter:", adapterAddress);

    const nativeBalance = await ethers.provider.getBalance(signerAddress);
    console.log("Native balance:", ethers.formatEther(nativeBalance), "ETH");

    const usdc = new ethers.Contract(usdcAddress, ERC20_ABI, signer);
    const taskFactory = new ethers.Contract(taskFactoryAddress, TASK_FACTORY_ABI, signer);
    const adapter = new ethers.Contract(adapterAddress, RECURRING_ADAPTER_ABI, signer);
    const rewardManager = new ethers.Contract(deployment.contracts.RewardManager, REWARD_MANAGER_ABI, signer);

    const symbol = await usdc.symbol();
    const decimals = await usdc.decimals();
    const amountPerExecution = ethers.parseUnits("50", decimals);
    const maxExecutions = 4n;
    const totalDeposit = amountPerExecution * maxExecutions;
    const latestBlock = await ethers.provider.getBlock("latest");
    if (!latestBlock) throw new Error("Unable to read latest block");
    const chainNow = BigInt(latestBlock.timestamp);
    const startTime = chainNow + 120n;
    const interval = 604800n;
    const fundingMode = 0; // VAULT

    const recurringParams = {
        token: usdcAddress,
        recipient,
        amountPerExecution,
        startTime,
        interval,
        maxExecutions,
        fundingMode,
        fundingSource: ethers.ZeroAddress,
    };

    const encodedParams = ethers.AbiCoder.defaultAbiCoder().encode(
        [
            "tuple(address token,address recipient,uint256 amountPerExecution,uint256 startTime,uint256 interval,uint256 maxExecutions,uint8 fundingMode,address fundingSource)",
        ],
        [recurringParams]
    );

    const [isValid, validationError] = await adapter.validateParams(encodedParams);
    console.log("Adapter params valid:", isValid, validationError || "");
    if (!isValid) throw new Error(`Adapter params invalid: ${validationError}`);

    const [canExec, reason] = await adapter.canExecute(encodedParams);
    console.log("Adapter canExecute now:", canExec, reason);

    const funding = await adapter.calculateTotalFunding(encodedParams);
    console.log(
        "Adapter total funding:",
        ethers.formatUnits(funding.totalAmount, decimals),
        symbol
    );

    let tokenBalance = await usdc.balanceOf(signerAddress);
    console.log("USDC balance:", ethers.formatUnits(tokenBalance, decimals), symbol);
    if (tokenBalance < totalDeposit) {
        const mintAmount = totalDeposit - tokenBalance;
        console.log("Minting missing USDC:", ethers.formatUnits(mintAmount, decimals), symbol);
        const mintTx = await usdc.mint(signerAddress, mintAmount);
        console.log("Mint tx:", mintTx.hash);
        await mintTx.wait();
        tokenBalance = await usdc.balanceOf(signerAddress);
        console.log("USDC balance after mint:", ethers.formatUnits(tokenBalance, decimals), symbol);
    }

    const allowance = await usdc.allowance(signerAddress, taskFactoryAddress);
    console.log("Factory allowance:", ethers.formatUnits(allowance, decimals), symbol);
    if (allowance < totalDeposit) {
        console.log("Approving TaskFactory for:", ethers.formatUnits(totalDeposit, decimals), symbol);
        const approveTx = await usdc.approve(taskFactoryAddress, totalDeposit);
        console.log("Approve tx:", approveTx.hash);
        await approveTx.wait();
    }

    const minTaskReward = await taskFactory.minTaskReward();
    const rewardPerExecution = minTaskReward;
    const maxRewardCostPerExecution = await rewardManager.getMaxRewardCost(rewardPerExecution);
    const value = maxRewardCostPerExecution * maxExecutions;
    const taskParams = {
        expiresAt: chainNow + 90n * 24n * 60n * 60n,
        maxExecutions,
        recurringInterval: interval,
        rewardPerExecution,
        seedCommitment: ethers.ZeroHash,
    };
    const actions = [
        {
            selector: ethers.id("execute(address,bytes)").slice(0, 10),
            protocol: adapterAddress,
            params: encodedParams,
        },
    ];
    const deposits = [{ token: usdcAddress, amount: totalDeposit }];

    console.log("Reward per execution:", ethers.formatEther(rewardPerExecution), "ETH");
    console.log("Max reward cost per execution:", ethers.formatEther(maxRewardCostPerExecution), "ETH");
    console.log("Native value:", ethers.formatEther(value), "ETH");
    console.log("Estimating gas...");
    const gasEstimate = await taskFactory.createTaskWithTokens.estimateGas(
        taskParams,
        actions,
        deposits,
        { value }
    );
    console.log("Gas estimate:", gasEstimate.toString());

    console.log("Submitting createTaskWithTokens...");
    const tx = await taskFactory.createTaskWithTokens(taskParams, actions, deposits, {
        value,
        gasLimit: (gasEstimate * 120n) / 100n,
    });
    console.log("Create tx:", tx.hash);
    const receipt = await tx.wait();
    console.log("Mined in block:", receipt?.blockNumber);

    let taskId = "";
    let taskCore = "";
    let taskVault = "";
    for (const log of receipt?.logs || []) {
        try {
            const parsed = taskFactory.interface.parseLog(log);
            if (parsed?.name === "TaskCreated") {
                taskId = parsed.args.taskId.toString();
                taskCore = parsed.args.taskCore;
                taskVault = parsed.args.taskVault;
                break;
            }
        } catch {}
    }

    console.log("Task ID:", taskId || "(not parsed)");
    console.log("TaskCore:", taskCore || "(not parsed)");
    console.log("TaskVault:", taskVault || "(not parsed)");
    console.log("Explorer:", `${deployment.explorer}/tx/${tx.hash}`);
}

main().catch((error) => {
    console.error("\nRecurring payment test failed:");
    console.error(error);
    process.exitCode = 1;
});
