// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition

import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const ConfidentialityTokenModule = buildModule("ConfidentialityTokenModule", (m) => {
  const twoOfThreeGame = m.contract("ConfidentialERC20");
  return { twoOfThreeGame };
});

export default ConfidentialityTokenModule;