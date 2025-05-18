import { expect } from "chai";
import { namedWallets, wallet, publicClient } from "../utils/wallet";
import {
  Address,
  getContract,
  parseEther,
  formatEther,
  getAddress,
  parseAbiItem,
} from "viem";
import SPAContractAbi from "../artifacts/contracts/SPAcontract.sol/SPAContract.json";
import ConfidentialERC20Abi from "../artifacts/contracts/ConfidentialERC20.sol/ConfidentialERC20.json";
import { HexString } from "@inco/js/dist/binary";
// @ts-ignore
import { Lightning } from '@inco/js/lite';

describe("Single Price Auction Tests", function () {
  let spaContract: any;
  let tokenContract: any;
  let spaContractAddress: Address;
  let tokenContractAddress: Address;
  let incoConfig: any;
  let reEncryptorForMainWallet: any;
  let reEncryptorForAliceWallet: any;
  let reEncryptorForBobWallet: any;

  beforeEach(async function () {
    // Setup Inco Configuration
    const chainId = publicClient.chain.id;
    console.log("Running on chain:", chainId);
    if(chainId === 31337){
      incoConfig = Lightning.localNode();
    }else{
      incoConfig = Lightning.latest('testnet', 84532); 
    }

    reEncryptorForMainWallet = await incoConfig.getReencryptor(wallet);
    reEncryptorForAliceWallet = await incoConfig.getReencryptor(namedWallets.alice);
    reEncryptorForBobWallet = await incoConfig.getReencryptor(namedWallets.bob);

    // Deploy Token Contract
    const tokenTxHash = await wallet.deployContract({
      abi: ConfidentialERC20Abi.abi,
      bytecode: ConfidentialERC20Abi.bytecode as HexString,
      args: [],
    });

    const tokenReceipt = await publicClient.waitForTransactionReceipt({
      hash: tokenTxHash,
    });
    tokenContractAddress = tokenReceipt.contractAddress as Address;
    console.log(`✅ Token Contract deployed at: ${tokenContractAddress}`);

    // Deploy SPA Contract
    const spaTxHash = await wallet.deployContract({
      abi: SPAContractAbi.abi,
      bytecode: SPAContractAbi.bytecode as HexString,
      args: [],
    });

    const spaReceipt = await publicClient.waitForTransactionReceipt({
      hash: spaTxHash,
    });
    spaContractAddress = spaReceipt.contractAddress as Address;
    console.log(`✅ SPA Contract deployed at: ${spaContractAddress}`);

    // Get contract instances
    tokenContract = getContract({
      address: tokenContractAddress,
      abi: ConfidentialERC20Abi.abi,
      client: wallet,
    });

    spaContract = getContract({
      address: spaContractAddress,
      abi: SPAContractAbi.abi,
      client: wallet,
    });

    // Fund test wallets if needed
    for (const [name, userWallet] of Object.entries(namedWallets)) {
      const balance = await publicClient.getBalance({
        address: userWallet.account.address,
      });
      const balanceEth = Number(formatEther(balance));

      if (balanceEth < 0.001) {
        const neededEth = 0.001 - balanceEth;
        console.log(`💰 Funding ${name} with ${neededEth.toFixed(6)} ETH...`);
        const tx = await wallet.sendTransaction({
          to: userWallet.account.address,
          value: parseEther(neededEth.toFixed(6)),
        });
        await publicClient.waitForTransactionReceipt({ hash: tx });
      }
    }
  });

  describe("Auction Creation and Bidding", function () {
    it("Should create an auction and accept bids", async function () {
      // Mint tokens for auction - Using smaller numbers
      console.log("\n------ 💰 Minting 1,000 tokens for auction ------");
      const auctionSupply = BigInt(1000); // Using 1000 tokens instead of 1,000,000
      const mintTx = await wallet.writeContract({
        address: tokenContractAddress,
        abi: ConfidentialERC20Abi.abi,
        functionName: "mint",
        args: [auctionSupply],
      });
      await publicClient.waitForTransactionReceipt({ hash: mintTx });

      // Create auction with correct parameter types
      console.log("\n------ 🏁 Creating auction ------");
      const createAuctionTx = await wallet.writeContract({
        address: spaContractAddress,
        abi: SPAContractAbi.abi,
        functionName: "createAuction",
        args: [
            tokenContractAddress,
            BigInt(10),        // Convert to BigInt explicitly
            BigInt(3600),        // Duration in seconds
            BigInt(2)            // Minimum bid price
        ],
      });
      await publicClient.waitForTransactionReceipt({ hash: createAuctionTx });

      // Place Bob's bid (500 tokens at 2 wei each)
      console.log("\n------ 📥 Placing Bob's bid ------");
      const bobQuantity = BigInt(500);
      const bobPrice = BigInt(2);
      
      const encryptedBobQuantity = await incoConfig.encrypt(bobQuantity, {
        accountAddress: namedWallets.bob.account.address,
        dappAddress: spaContractAddress,
      });
      
      const encryptedBobPrice = await incoConfig.encrypt(bobPrice, {
        accountAddress: namedWallets.bob.account.address,
        dappAddress: spaContractAddress,
      });

      const bobBidTx = await namedWallets.bob.writeContract({
        address: spaContractAddress,
        abi: SPAContractAbi.abi,
        functionName: "placeBid",
        args: [1, encryptedBobQuantity, encryptedBobPrice],
        value: BigInt(1000), // Send 1000 wei for bid
      });
      await publicClient.waitForTransactionReceipt({ hash: bobBidTx });

      // Place Carol's bid (600 tokens at 8 wei each)
      console.log("\n------ 📥 Placing Carol's bid ------");
      const carolQuantity = BigInt(600);
      const carolPrice = BigInt(8);
      
      const encryptedCarolQuantity = await incoConfig.encrypt(carolQuantity, {
        accountAddress: namedWallets.carol.account.address,
        dappAddress: spaContractAddress,
      });
      
      const encryptedCarolPrice = await incoConfig.encrypt(carolPrice, {
        accountAddress: namedWallets.carol.account.address,
        dappAddress: spaContractAddress,
      });

      // Watch for auction settlement
      const settledPromise = new Promise((resolve) => {
        const unwatch = publicClient.watchEvent({
          address: spaContractAddress,
          event: parseAbiItem("event AuctionSettled(uint256,uint256,uint256)"),
          onLogs: (logs) => {
            console.log("📢 Auction settled:", logs);
            resolve(logs[0]);
            unwatch();
          },
        });
      });

      // End auction and wait for settlement
      console.log("\n------ 🏁 Ending auction ------");
      const endAuctionTx = await wallet.writeContract({
        address: spaContractAddress,
        abi: SPAContractAbi.abi,
        functionName: "endAuction",
        args: [1],
      });
      await publicClient.waitForTransactionReceipt({ hash: endAuctionTx });

      // Wait for settlement
      const settlementResult: any = await settledPromise;
      console.log("Settlement price:", formatEther(settlementResult.args.settledPrice));
      console.log("Total tokens sold:", formatEther(settlementResult.args.totalTokensSold));

      // Verify settlement results with smaller numbers
      expect(settlementResult.args.settledPrice).to.equal(BigInt(2));
      expect(settlementResult.args.totalTokensSold).to.equal(BigInt(1000));
    });
  });
});