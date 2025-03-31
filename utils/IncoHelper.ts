// @ts-ignore
import {
  generateSecp256k1Keypair,
  decodeSecp256k1PublicKey,
  getEciesEncryptor,   // @ts-ignore
} from "@inco-fhevm/js/lite";
import { getAddress, hexToBytes } from "viem";
import { HexString } from "@inco-fhevm/js/dist/binary";

// @ts-ignore
import { getReencryptor } from "@inco-fhevm/js/reencryption";
// @ts-ignore
import { incoLiteEnvQuerier, incoLiteReencrypt } from "@inco-fhevm/js/lite";
import { Schema, Binary } from "@inco-fhevm/js";
// @ts-ignore
import { getActiveIncoLiteDeployment, IncoLiteDeployment } from "@inco-fhevm/js/lite";

// ✅ Define the default KMS Endpoint for BaseSepolia
export const BASE_SEPOLIA_KMS_ENDPOINT = "https://grpc.basesepolia.covalidator.denver.inco.org";

// ✅ Define Config Type
interface EncryptConfig {
  chainId: number;
  eciesPublicKey: HexString;
  deployedAtAddress: HexString;
}

// ✅ Define Encrypt Function Input Type
interface EncryptParams {
  value: string | number | bigint;
  address: HexString;
  config: EncryptConfig;
  contractAddress: HexString;
}

// ✅ Define `InputCt` Type
export interface InputCt {
  prehandle: HexString;
  handle: HexString;
  context: {
    hostChainId: bigint;
    aclAddress: HexString;
    userAddress: HexString;
    contractAddress: HexString;
  };
  ciphertext: {
    scheme: number;
    type: number;
    value: HexString;
  };
}

// ✅ Update Encrypt Function to Return `InputCt`
export const encryptValue = async ({
  value,
  address,
  config,
  contractAddress,
}: EncryptParams): Promise<{ inputCt: InputCt }> => {
  const valueBigInt: bigint = BigInt(value); // Convert to BigInt

  const plaintextWithContext = {
    plaintext: {
      scheme: 1, // encryptionSchemes.ecies
      value: valueBigInt,
      type: 8, // handleTypes.uint256
    },
    context: {
      hostChainId: BigInt(config.chainId),
      aclAddress: config.deployedAtAddress,
      userAddress: address,
      contractAddress: contractAddress,
    },
  };

  const ephemeralKeypair = await generateSecp256k1Keypair();
  const eciesPubKey = decodeSecp256k1PublicKey(hexToBytes(config.eciesPublicKey));
  const encryptor = getEciesEncryptor({
    scheme: 1, // encryptionSchemes.ecies
    pubKeyA: eciesPubKey,
    privKeyB: ephemeralKeypair,
  });

  const inputCt: InputCt = await encryptor(plaintextWithContext);

  return { inputCt };
};

// ✅ Define Re-encrypt Function Input Type
interface ReEncryptParams {
  chainId: number;
  contractAddress: HexString;
  walletClient: unknown; // Replace with actual wallet client type if available
  handle: string;
  publicClient: unknown; // Replace with actual public client type
  incoLiteAddress: HexString;
  kmsConnectEndpoint?: string; // Optional, defaults to BaseSepolia
}

// ✅ Define `ReencryptResult` Type
export interface ReencryptResult {
  value: bigint;
}

// ✅ Updated Re-encrypt Function with Default KMS Endpoint
export const reencryptValue = async ({
  chainId,
  contractAddress,
  walletClient,
  handle,
  publicClient,
  incoLiteAddress,
  kmsConnectEndpoint = BASE_SEPOLIA_KMS_ENDPOINT, // Default value
}: ReEncryptParams): Promise<ReencryptResult> => {
  if (!chainId || !contractAddress || !walletClient || !publicClient || !incoLiteAddress) {
    throw new Error("Missing required parameters for re-encryption");
  }

  try {
    // ✅ Ensure the contract address is in checksum format
    const checksummedAddress = getAddress(contractAddress);

    const reencryptor = await getReencryptor({
      chainId: BigInt(chainId),
      contractAddress: checksummedAddress, // Use the fixed address
      walletClient,
      reencryptEndpoint: incoLiteReencrypt({
        kmsConnectRpcEndpointOrClient: kmsConnectEndpoint,
      }),
      fheEnvQuerier: incoLiteEnvQuerier({
        incoLiteAddress,
        publicClient,
      }),
    });

    const decrypted = await reencryptor({
      handle: {
        value: Schema.parse(Binary.Bytes32, handle),
        type: 8, // Default to uint256 type
      },
    });

    return { value: decrypted.value };
  } catch (error: any) {
    throw new Error(`Failed to re-encrypt value: ${error.message}`);
  }
};

// ✅ Define `incoLiteConfig` Function with Proper Type Return
export const incoLiteConfig = (network_name: string): IncoLiteDeployment => {
  return getActiveIncoLiteDeployment(network_name);
};
