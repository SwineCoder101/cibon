import { expect } from "chai";
import { ethers, fhevm } from "hardhat";

describe("ERC7984Example", function () {
  let token: any;
  let owner: any;
  let recipient: any;
  //   let other: any;

  //   const INITIAL_AMOUNT = 1000;
  const TRANSFER_AMOUNT = 100;

  beforeEach(async function () {
    [owner, recipient] = await ethers.getSigners();

    // Deploy ERC7984Example contract
    token = await ethers.deployContract("ERC7984Example", [
      owner.address,
      "Confidential Token",
      "CTKN",
      "https://example.com/token",
    ]);
  });

  describe("Confidential Transfer Process", function () {
    it("should transfer tokens from owner to recipient", async function () {
      // Create encrypted input for transfer amount
      const encryptedInput = await fhevm
        .createEncryptedInput(await token.getAddress(), owner.address)
        .add64(TRANSFER_AMOUNT)
        .encrypt();

      // Perform the confidential transfer
      await expect(
        token
          .connect(owner)
          [
            "confidentialTransfer(address,bytes32,bytes)"
          ](recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
      ).to.not.be.reverted;

      // Check that both addresses have balance handles (without decryption for now)
      const recipientBalanceHandle = await token.confidentialBalanceOf(recipient.address);
      const ownerBalanceHandle = await token.confidentialBalanceOf(owner.address);
      // eslint-disable-next-line @typescript-eslint/no-unused-expressions
      expect(recipientBalanceHandle).to.not.be.undefined;
      // eslint-disable-next-line @typescript-eslint/no-unused-expressions
      expect(ownerBalanceHandle).to.not.be.undefined;
    });
  });
});
