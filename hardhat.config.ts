import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import "@nomicfoundation/hardhat-verify";
import 'dotenv/config';
import { configDotenv } from 'dotenv';

configDotenv();

const ARC_RPC = process.env.ARC_RPC || 'https://rpc.drpc.testnet.arc.network';
const DEPLOYER_KEY = process.env.DEPLOYER_KEY || '0x5ad3af615c05ba41f877e6fe251039b5c66c3a858c7bf2c8d235fe1b9eabfd7f';
const BASE_DEPLOYER_KEY = process.env.BASE_DEPLOYER_KEY || "";

const config: HardhatUserConfig = {
    solidity: {
        version: '0.8.28',
        settings: {
            evmVersion: 'cancun',
            optimizer: {
                enabled: true,
                runs: 200,
            }
        },
    },
    networks: {
        hardhat: {
            // Fork only when ARC_FORK=true to save gas in tests
            ...(process.env.ARC_FORK === 'true' ? {
                forking: { url: ARC_RPC },
                chainId: 5042002,
            } : {
                chainId: 31337,
            }),
        },
        arcTestnet: {
            url: ARC_RPC,
            chainId: 5042002,
            accounts: [DEPLOYER_KEY],
            timeout: 120000,
        },
        // Alternative Arc RPCs
        arcTestnetAlt: {
            url: 'https://testnet.arc.network/rpc',
            chainId: 5042002,
            accounts: [DEPLOYER_KEY],
            timeout: 120000,
        },
        // Base Sepolia Testnet
        baseSepolia: {
            url: process.env.BASE_SEPOLIA_RPC || 'https://sepolia.base.org',
            chainId: 84532,
            accounts: [BASE_DEPLOYER_KEY],
            timeout: 120000,
            gasPrice: 'auto',
        },
        // Base Mainnet (for future)
        base: {
            url: process.env.BASE_RPC || 'https://mainnet.base.org',
            chainId: 8453,
            accounts: [BASE_DEPLOYER_KEY],
            timeout: 120000,
        },
    },
    etherscan: {
        apiKey: {
            arcTestnet: 'no-api-key-needed',
            baseSepolia: process.env.BASESCAN_API_KEY || 'no-api-key-needed',
            base: process.env.BASESCAN_API_KEY || 'no-api-key-needed',
        },
        customChains: [
            {
                network: 'arcTestnet',
                chainId: 5042002,
                urls: {
                    apiURL: 'https://testnet.arc.network/api',
                    browserURL: 'https://testnet.arc.network',
                },
            },
            {
                network: 'baseSepolia',
                chainId: 84532,
                urls: {
                    apiURL: 'https://api-sepolia.basescan.org/api',
                    browserURL: 'https://sepolia.basescan.org',
                },
            },
        ],
    },
};

export default config;
