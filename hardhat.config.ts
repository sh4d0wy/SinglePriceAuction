import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";
import * as dotenv from "dotenv";

dotenv.config(); // Load environment variables

const PRIVATE_KEY = process.env.PRIVATE_KEY_BASE_SEPOLIA || "";
const PRIVATE_KEY_ANVIL = process.env.PRIVATE_KEY_ANVIL || "";

const BASE_SEPOLIA_RPC_URL = process.env.BASE_SEPOLIA_RPC_URL || "";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",  // Specify the Solidity version
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      evmVersion: "cancun" // Specify the EVM version
    }
  },
  networks: {
    hardhat: {}, // Local Hardhat network
    // Inco's local node, based on anvil, called https://github.com/Inco-fhevm/lightning-rod
    // Make sure to run `docker compose up` to start the local node and covalidator
    anvil: {
      url: "http://localhost:8545",
      accounts: PRIVATE_KEY_ANVIL ? [PRIVATE_KEY_ANVIL] : [],
      chainId:31337
    },
    baseSepolia: {
      url: BASE_SEPOLIA_RPC_URL,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    }
  },
  etherscan: {
    apiKey: {
      baseSepolia: process.env.ETHERSCAN_API_KEY || "SNIIY5Z3X1U83U257H9S2M1C1CZJ641X6B",
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84531,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.etherscan.io",
        },
      },
    ],
  },
};

export default config;
