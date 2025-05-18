// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition

import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const SPAcontractModule = buildModule("SPAcontractModule", (m) => {
  const SPAcontractModule = m.contract("SPAContract");
  return { SPAcontractModule };
});

export default SPAcontractModule;