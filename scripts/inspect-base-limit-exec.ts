import { ethers } from "hardhat";

const EXEC_TX = process.env.EXEC_TX || "0x28f8544733b73b4b3fc43b4b38c369e31781e55ec24d77703fa420fda9820f79";
const POOL = "0x46880b404CD35c165EDdefF7421019F8dD25F4Ad";
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const WETH = "0x4200000000000000000000000000000000000006";

const ERC20_ABI = [
    "event Transfer(address indexed from,address indexed to,uint256 value)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function balanceOf(address account) view returns (uint256)",
];

const POOL_ABI = [
    "function token0() view returns (address)",
    "function token1() view returns (address)",
    "function liquidity() view returns (uint128)",
    "function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16 observationIndex,uint16 observationCardinality,uint16 observationCardinalityNext,uint8 feeProtocol,bool unlocked)",
    "event Swap(address indexed sender,address indexed recipient,int256 amount0,int256 amount1,uint160 sqrtPriceX96,uint128 liquidity,int24 tick)",
];

async function main() {
    const usdc = new ethers.Contract(USDC, ERC20_ABI, ethers.provider);
    const weth = new ethers.Contract(WETH, ERC20_ABI, ethers.provider);
    const pool = new ethers.Contract(POOL, POOL_ABI, ethers.provider);

    const [token0, token1, liquidity, slot0, receipt] = await Promise.all([
        pool.token0(),
        pool.token1(),
        pool.liquidity(),
        pool.slot0(),
        ethers.provider.getTransactionReceipt(EXEC_TX),
    ]);

    console.log("Pool token0:", token0);
    console.log("Pool token1:", token1);
    console.log("Pool liquidity:", liquidity.toString());
    console.log("Pool tick:", slot0.tick.toString());

    const usdcIface = usdc.interface;
    const wethIface = weth.interface;
    const poolIface = pool.interface;

    for (const log of receipt?.logs || []) {
        try {
            const parsed = poolIface.parseLog(log);
            if (parsed?.name === "Swap") {
                console.log("Swap event:");
                console.log("  recipient:", parsed.args.recipient);
                console.log("  amount0:", parsed.args.amount0.toString());
                console.log("  amount1:", parsed.args.amount1.toString());
                console.log("  tick:", parsed.args.tick.toString());
            }
        } catch {}

        if (log.address.toLowerCase() === USDC.toLowerCase()) {
            try {
                const parsed = usdcIface.parseLog(log);
                if (parsed?.name === "Transfer") {
                    console.log("USDC Transfer:", parsed.args.from, "->", parsed.args.to, ethers.formatUnits(parsed.args.value, 6));
                }
            } catch {}
        }

        if (log.address.toLowerCase() === WETH.toLowerCase()) {
            try {
                const parsed = wethIface.parseLog(log);
                if (parsed?.name === "Transfer") {
                    console.log("WETH Transfer:", parsed.args.from, "->", parsed.args.to, ethers.formatUnits(parsed.args.value, 18));
                }
            } catch {}
        }
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
