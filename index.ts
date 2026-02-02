import {  type MoveEvent, FogOfWarChessContract } from "./artifacts/FogOfWarChess.ts";
import { AztecAddress } from "@aztec/aztec.js/addresses";
import { createAztecNodeClient } from "@aztec/aztec.js/node";
import { getInitialTestAccountsData } from "@aztec/accounts/testing";
import { TestWallet } from "@aztec/test-wallet/server";
import { getDecodedPublicEvents } from "@aztec/aztec.js/events";


async function main() {
  // Connect to local network
  const node = createAztecNodeClient("http://localhost:8080");

  const wallet = await TestWallet.create(node);

  const [giggleWalletData, aliceWalletData, bobClinicWalletData] =
    await getInitialTestAccountsData();
  const giggleAccount = await wallet.createSchnorrAccount(
    giggleWalletData.secret,
    giggleWalletData.salt,
  );
  const aliceAccount = await wallet.createSchnorrAccount(
    aliceWalletData.secret,
    aliceWalletData.salt,
  );
  const bobClinicAccount = await wallet.createSchnorrAccount(
    bobClinicWalletData.secret,
    bobClinicWalletData.salt,
  );

  const giggleAddress = (await giggleAccount.getAccount()).getAddress();
  const aliceAddress = (await aliceAccount.getAccount()).getAddress();
  const bobClinicAddress = (await bobClinicAccount.getAccount()).getAddress();

  const bobToken = await FogOfWarChessContract.deploy(wallet)
    .send({ from: giggleAddress })
    .deployed();

  let whiteState = await bobToken.methods
    .__empty_white_state()
    .simulate({ from: giggleAddress });

  let gameState = await bobToken.methods
    .__empty_game_state()
    .simulate({ from: giggleAddress });

  let blackState = await bobToken.methods
    .__empty_black_state()
    .simulate({ from: giggleAddress });

  // NOTE: in a real game these secrets should be random and not shared.
  whiteState.encrypt_secret = 1;
  whiteState.mask_secret = 2;
  blackState.encrypt_secret = 3;
  blackState.mask_secret = 4;
  let whiteEncryptSecret = 1;
  let whiteMaskSecret = 2;
  let blackEncryptSecret = 3;
  let blackMaskSecret = 4;

  gameState = await bobToken.methods
    .__commit_to_user_secrets(
      gameState,
      whiteEncryptSecret,
      whiteMaskSecret,
      0, // 0 = white
    )
    .simulate({ from: giggleAddress });

    gameState = await bobToken.methods
    .__commit_to_user_secrets(
      gameState,
      blackEncryptSecret,
      blackMaskSecret,
      1, // 1 = black
    )
    .simulate({ from: giggleAddress });


  let move = await bobToken.methods
    .__create_move(0, 1, 0, 3)
    .simulate({ from: giggleAddress });


  await bobToken.methods
    .create_game_private(whiteState.encrypt_secret, whiteState.mask_secret, 3)
    .send({ from: giggleAddress })
    .wait();

  // Test: Verify wrong password is rejected
  let wrongPasswordFailed = false;
  try {
    await bobToken.methods
      .join_game_private(0, blackState.encrypt_secret, blackState.mask_secret, [gameState.mpc_state.user_encrypt_secret_hashes[0], gameState.mpc_state.user_mask_secret_hashes[0]], 999)
      .send({ from: aliceAddress })
      .wait();
  } catch (e) {
    wrongPasswordFailed = true;
    console.log("✓ Password protection works: wrong password (999) was rejected");
  }
  if (!wrongPasswordFailed) {
    throw new Error("✗ Password protection FAILED: wrong password was accepted!");
  }

  // Test: Verify no password (0) is rejected when password is required
  let noPasswordFailed = false;
  try {
    await bobToken.methods
      .join_game_private(0, blackState.encrypt_secret, blackState.mask_secret, [gameState.mpc_state.user_encrypt_secret_hashes[0], gameState.mpc_state.user_mask_secret_hashes[0]], 0)
      .send({ from: aliceAddress })
      .wait();
  } catch (e) {
    noPasswordFailed = true;
    console.log("✓ Password protection works: no password (0) was rejected");
  }
  if (!noPasswordFailed) {
    throw new Error("✗ Password protection FAILED: missing password was accepted!");
  }

  // Test: Verify correct password is accepted
  await bobToken.methods
    .join_game_private(0, blackState.encrypt_secret, blackState.mask_secret, [gameState.mpc_state.user_encrypt_secret_hashes[0], gameState.mpc_state.user_mask_secret_hashes[0]], 3)
    .send({ from: aliceAddress })
    .wait();
  console.log("✓ Password protection works: correct password (3) was accepted");

  let receipt = await bobToken.methods
    .make_move_white_private(0, gameState, whiteState, move)
    .send({ from: giggleAddress })
    .wait();


const collectedEvent0s = await getDecodedPublicEvents<MoveEvent>(
  node,
  FogOfWarChessContract.events.MoveEvent,
  receipt.blockNumber!,
  receipt.blockNumber! + 1,
);
let aliceUserOutputState = collectedEvent0s[0].state;


  let new_white_user_state = await bobToken.methods
    .__update_user_state_from_move(true, whiteState, move, 0)
    .simulate({ from: giggleAddress });


    let newGameState = await bobToken.methods.__update_game_state_from_move(gameState, aliceUserOutputState, 0).simulate({from: giggleAddress});

    let  bobNewUserState =
        await bobToken.methods.__consume_opponent_move(newGameState, blackState, 1)
        .simulate({ from: giggleAddress });
        

    let bobMove = await bobToken.methods
    .__create_move(4, 6, 4, 4)
    .simulate({ from: giggleAddress });


  let bobReceipt = await bobToken.methods
    .make_move_black_private(0, newGameState, bobNewUserState, bobMove)
    .send({ from: giggleAddress })
    .wait();
}

main().catch(console.error);
