use aztec::macros::aztec;

#[aztec]
pub contract FogOfWarChess {
    use aztec::{
        macros::{events::event, functions::{external, initializer, only_self}, storage::storage},
        protocol_types::address::AztecAddress,
        state_vars::{Map, public_mutable::PublicMutable},
    };
    use fog_of_war_chess::{
        consume_opponent_move_and_update_game_state as consume_opponent_move_and_update_game_state_inner,
        empty_game_state, GameState, move_for_contract, MoveData, UserState,
    };
    use fog_of_war_chess::piece::{PieceData, Pieces};
    use fog_of_war_chess::validate_move::validate_move_and_update_board_state;
    use poseidon::poseidon2::Poseidon2::hash as poseidon2;

    use mpclib::selective_disclosure::selective_disclosure::UserOutputState;
    use hat_nft::HatNFT;

    /// Used to track game moves and update encrypted game state client-side
    #[event]
    struct MoveEvent {
        state: UserOutputState<64, 2>,
    }

    /// Used to identify new games client-side
    #[event]
    struct NewGame {
        game_id: u32,
        password_hash: Field,
        initial_state: [Field; 2],
    }


    /// Used to identify new games client-side
    #[event]
    struct JoinedGame {
        game_id: u32,
        password_hash: Field,
        initial_state: [Field; 2],
    }

    #[storage]
    struct Storage<Context> {
        game_counter: PublicMutable<u32, Context>,
        game_secret_hashes: Map<u32, PublicMutable<[Field; 4], Context>, Context>,
        game_hashes: Map<u32, PublicMutable<Field, Context>, Context>,
        // ELO rating system
        elo_ratings: Map<AztecAddress, PublicMutable<u32, Context>, Context>,
        game_players: Map<u32, PublicMutable<[AztecAddress; 2], Context>, Context>,
        // Hat NFT contract address
        hat_nft_address: PublicMutable<AztecAddress, Context>,
    }

    /// Default ELO rating for new players
    global DEFAULT_ELO: u32 = 1200;
    /// K-factor for ELO calculations (determines rating volatility)
    global ELO_K_FACTOR: u32 = 32;

    #[external("utility")]
    unconstrained fn __empty_game_state() -> GameState {
        GameState::default()
    }

    #[external("utility")]
    unconstrained fn __empty_white_state() -> UserState {
        let u = UserState::default();
        u.initialize(0)
    }

    #[external("utility")]
    unconstrained fn __empty_black_state() -> UserState {
        let u = UserState::default();
        u.initialize(1)
    }

    #[external("utility")]
    unconstrained fn __commit_to_user_secrets(
        game_state: GameState,
        encrypt_secret: Field,
        mask_secret: Field,
        player_id: Field,
    ) -> GameState {
        let mut updated = game_state;

        let secret_hashes = [poseidon2([encrypt_secret, -1], 2), poseidon2([mask_secret, -1], 2)];
        player_id.assert_max_bit_size::<32>();
        let id = player_id as u32;
        updated.mpc_state.user_encrypt_secret_hashes[id] = secret_hashes[0];
        updated.mpc_state.user_mask_secret_hashes[id] = secret_hashes[1];
        updated
    }

    #[external("utility")]
    unconstrained fn __create_move(x1: Field, y1: Field, x2: Field, y2: Field) -> MoveData {
        MoveData { x1, y1, x2, y2 }
    }

    #[external("utility")]
    unconstrained fn __update_game_state_from_move(
        input_state: GameState,
        user_state: UserOutputState<64, 2>,
        player_id: Field,
    ) -> GameState {
        let mut new_state = input_state;
        new_state.move_count += 1;
        new_state.mpc_state.round_number += 1;
        new_state.mpc_state.previous_output_states[player_id as u32] = user_state;
        new_state
    }

    #[external("utility")]
    unconstrained fn __consume_opponent_move(
        input_state: GameState,
        user_state: UserState,
        player_id: Field,
    ) -> UserState {
        consume_opponent_move_and_update_game_state_inner(input_state, user_state, player_id)
    }

    #[external("utility")]
    unconstrained fn __update_user_state_from_move(
        is_first_two_moves: bool,
        _user_state: UserState,
        move_data: MoveData,
        player_id: Field,
    ) -> UserState {
        let mut user_state = _user_state;
        if (is_first_two_moves) {
            user_state = UserState::initialize(user_state, player_id);
        }
        let starting_piece = user_state.game_state[(move_data.x1 + move_data.y1 * 8) as u32];
        let starting_piece_data: PieceData =
            PieceData { id: starting_piece.id, x: move_data.x1, y: move_data.y1, exists: 1 };
        let ending_piece_data: PieceData =
            PieceData { id: starting_piece.id, x: move_data.x2, y: move_data.y2, exists: 1 };

        let existing_end_piece = user_state.game_state[(move_data.x2 + move_data.y2 * 8) as u32];
        let mut game_ended = false;
        if ((existing_end_piece.id == Pieces::KING) & (existing_end_piece.player_id != player_id)) {
            game_ended = true;
        }

        user_state.game_state = validate_move_and_update_board_state(
            user_state.game_state,
            starting_piece_data,
            ending_piece_data,
            player_id,
        );
        user_state
    }

    #[external("utility")]
    unconstrained fn __get_game_secret_hashes(game_id: u32) -> [Field; 4] {
        self.storage.game_secret_hashes.at(game_id).read()
    }

    #[external("utility")]
    unconstrained fn __get_elo_rating(player: AztecAddress) -> u32 {
        let rating = self.storage.elo_ratings.at(player).read();
        if rating == 0 {
            DEFAULT_ELO
        } else {
            rating
        }
    }

    #[external("utility")]
    unconstrained fn __get_game_players(game_id: u32) -> [AztecAddress; 2] {
        self.storage.game_players.at(game_id).read()
    }

    #[external("utility")]
    unconstrained fn __get_hat_nft_address() -> AztecAddress {
        self.storage.hat_nft_address.read()
    }

    #[initializer]
    #[external("public")]
    fn setup() {}

    /// Set the Hat NFT contract address (can only be called once when address is zero)
    #[external("public")]
    fn set_hat_nft_address(nft_address: AztecAddress) {
        let current = self.storage.hat_nft_address.read();
        assert(current == AztecAddress::zero(), "Hat NFT address already set");
        assert(nft_address != AztecAddress::zero(), "Cannot set zero address");
        self.storage.hat_nft_address.write(nft_address);
    }

    #[external("private")]
    fn create_game_private(user_secret: Field, user_mask: Field, password: Field) {
        let mut game_state: GameState = empty_game_state();
        // Creator plays as black (player 1) so joiner can move first as white
        game_state = game_state.commit_to_user_secrets(user_secret, user_mask, 1);
        let mut password_hash = poseidon2([password], 1);
        if (password == 0) {
            password_hash = 0;
        }
        let black_player = self.context.msg_sender().unwrap();
        self.enqueue_self.create_game_public(
            [
                game_state.mpc_state.user_encrypt_secret_hashes[1],
                game_state.mpc_state.user_mask_secret_hashes[1],
            ],
            password_hash,
            black_player,
        );
    }

    #[external("public")]
    #[only_self]
    fn create_game_public(user_secret_hashes: [Field; 2], password_hash: Field, black_player: AztecAddress) {
        let game_id: u32 = self.storage.game_counter.read();
        self.storage.game_hashes.at(game_id).write(0);
        self.storage.game_secret_hashes.at(game_id).write([
            password_hash,
            0,
            user_secret_hashes[0],
            user_secret_hashes[1],
        ]);
        // Store black player address (white player will be added when they join)
        self.storage.game_players.at(game_id).write([AztecAddress::zero(), black_player]);
        self.storage.game_counter.write(game_id + 1);

        self.emit(NewGame { game_id, password_hash, initial_state: user_secret_hashes });
    }

    #[external("private")]
    fn make_move_white_private(
        game_id: u32,
        game_state: GameState,
        user_state: UserState,
        move_data: MoveData,
    ) {
        let state_hash = game_state.hash();

        let move_result = move_for_contract::<0>(state_hash, game_state, user_state, move_data);
        let user_output_state = move_result.0;
        let move_hashes = move_result.1;

        let ending_hash = move_hashes.output_game_state;

        // Check if white captured black's king (game ends)
        let target_piece = user_state.game_state[(move_data.x2 + move_data.y2 * 8) as u32];
        let game_ended = (target_piece.id == Pieces::KING) & (target_piece.player_id == 1);

        self.enqueue_self.make_move_white_public(
            game_id,
            state_hash,
            ending_hash,
            user_output_state,
            game_ended,
        );
    }

    #[external("public")]
    #[only_self]
    fn make_move_white_public(
        game_id: u32,
        initial_hash: Field,
        final_hash: Field,
        state: UserOutputState<64, 2>,
        game_ended: bool,
    ) {
        let game_hash = self.storage.game_hashes.at(game_id).read();

        assert(initial_hash != final_hash);
        assert(game_hash != 0);
        assert(game_hash == initial_hash);

        self.storage.game_hashes.at(game_id).write(final_hash);
        self.emit(MoveEvent { state });

        // If white won (captured black's king), update ELO ratings
        if game_ended {
            let players: [AztecAddress; 2] = self.storage.game_players.at(game_id).read();
            let winner = players[0]; // white won
            let loser = players[1];  // black lost

            // Get current ratings (use default if not set)
            let mut winner_rating = self.storage.elo_ratings.at(winner).read();
            let mut loser_rating = self.storage.elo_ratings.at(loser).read();
            if winner_rating == 0 {
                winner_rating = DEFAULT_ELO;
            }
            if loser_rating == 0 {
                loser_rating = DEFAULT_ELO;
            }

            // Calculate rating change using simplified ELO
            let rating_diff: i32 = loser_rating as i32 - winner_rating as i32;
            let mut expected_x100: i32 = 50 + rating_diff / 8;
            if expected_x100 < 5 {
                expected_x100 = 5;
            }
            if expected_x100 > 95 {
                expected_x100 = 95;
            }
            let rating_change: u32 = (ELO_K_FACTOR * (100 - expected_x100 as u32)) / 100;

            // Update ratings
            let new_winner_rating = winner_rating + rating_change;
            let mut new_loser_rating = loser_rating;
            if loser_rating > rating_change {
                new_loser_rating = loser_rating - rating_change;
            } else {
                new_loser_rating = 100; // Minimum rating floor
            }

            self.storage.elo_ratings.at(winner).write(new_winner_rating);
            self.storage.elo_ratings.at(loser).write(new_loser_rating);

            // Mint hat NFT to winner if hat_nft_address is set
            let nft_address = self.storage.hat_nft_address.read();
            if nft_address != AztecAddress::zero() {
                let _ = HatNFT::at(nft_address).mint_hat(winner, game_id, new_winner_rating, new_loser_rating).call(self.context);
            }
        }
    }

    #[external("private")]
    fn make_move_black_private(
        game_id: u32,
        game_state: GameState,
        user_state: UserState,
        move_data: MoveData,
    ) {
        let state_hash = game_state.hash();

        let move_result = move_for_contract::<1>(state_hash, game_state, user_state, move_data);
        let user_output_state = move_result.0;
        let move_hashes = move_result.1;

        let ending_hash = move_hashes.output_game_state;

        // Check if black captured white's king (game ends)
        let target_piece = user_state.game_state[(move_data.x2 + move_data.y2 * 8) as u32];
        let game_ended = (target_piece.id == Pieces::KING) & (target_piece.player_id == 0);

        self.enqueue_self.make_move_black_public(
            game_id,
            state_hash,
            ending_hash,
            user_output_state,
            game_ended,
        );
    }

    #[external("public")]
    #[only_self]
    fn make_move_black_public(
        game_id: u32,
        initial_hash: Field,
        final_hash: Field,
        state: UserOutputState<64, 2>,
        game_ended: bool,
    ) {
        let game_hash = self.storage.game_hashes.at(game_id).read();

        assert(initial_hash != final_hash);
        assert(game_hash != 0);
        assert(game_hash == initial_hash);

        self.storage.game_hashes.at(game_id).write(final_hash);
        self.emit(MoveEvent { state });

        // If black won (captured white's king), update ELO ratings
        if game_ended {
            let players: [AztecAddress; 2] = self.storage.game_players.at(game_id).read();
            let winner = players[1]; // black won
            let loser = players[0];  // white lost

            // Get current ratings (use default if not set)
            let mut winner_rating = self.storage.elo_ratings.at(winner).read();
            let mut loser_rating = self.storage.elo_ratings.at(loser).read();
            if winner_rating == 0 {
                winner_rating = DEFAULT_ELO;
            }
            if loser_rating == 0 {
                loser_rating = DEFAULT_ELO;
            }

            // Calculate rating change using simplified ELO
            let rating_diff: i32 = loser_rating as i32 - winner_rating as i32;
            let mut expected_x100: i32 = 50 + rating_diff / 8;
            if expected_x100 < 5 {
                expected_x100 = 5;
            }
            if expected_x100 > 95 {
                expected_x100 = 95;
            }
            let rating_change: u32 = (ELO_K_FACTOR * (100 - expected_x100 as u32)) / 100;

            // Update ratings
            let new_winner_rating = winner_rating + rating_change;
            let mut new_loser_rating = loser_rating;
            if loser_rating > rating_change {
                new_loser_rating = loser_rating - rating_change;
            } else {
                new_loser_rating = 100; // Minimum rating floor
            }

            self.storage.elo_ratings.at(winner).write(new_winner_rating);
            self.storage.elo_ratings.at(loser).write(new_loser_rating);

            // Mint hat NFT to winner if hat_nft_address is set
            let nft_address = self.storage.hat_nft_address.read();
            if nft_address != AztecAddress::zero() {
                let _ = HatNFT::at(nft_address).mint_hat(winner, game_id, new_winner_rating, new_loser_rating).call(self.context);
            }
        }
    }

    #[external("private")]
    fn join_game_private(
        game_id: u32,
        user_secret: Field,
        user_mask: Field,
        black_secret_hashes: [Field; 2],
        password: Field,
    ) {
        let mut game_state: GameState = empty_game_state();
        // Joiner plays as white (player 0) so they can move first
        game_state = game_state.commit_to_user_secrets(user_secret, user_mask, 0);
        game_state.mpc_state.user_encrypt_secret_hashes[1] = black_secret_hashes[0];
        game_state.mpc_state.user_mask_secret_hashes[1] = black_secret_hashes[1];
        let mut password_hash = poseidon2([password], 1);
        if (password == 0) {
            password_hash = 0;
        }
        let game_hash = game_state.hash();
        let white_player = self.context.msg_sender().unwrap();
        self.enqueue_self.join_game_public(
            game_id,
            game_hash,
            [
                game_state.mpc_state.user_encrypt_secret_hashes[0],
                game_state.mpc_state.user_mask_secret_hashes[0],
            ],
            password_hash,
            white_player,
        );
    }

    #[external("public")]
    #[only_self]
    fn join_game_public(
        game_id: u32,
        game_hash: Field,
        user_secret_hashes: [Field; 2],
        password_hash: Field,
        white_player: AztecAddress,
    ) {
        let secret_hashes: [Field; 4] = self.storage.game_secret_hashes.at(game_id).read();
        assert(secret_hashes[2] != 0);
        assert(secret_hashes[3] != 0);
        assert(secret_hashes[1] == 0); // only games that have not started will have white's mask secret hash blank
        assert(secret_hashes[0] == password_hash);

        self.storage.game_secret_hashes.at(game_id).write([
            user_secret_hashes[0],
            user_secret_hashes[1],
            secret_hashes[2],
            secret_hashes[3],
        ]);

        // Store white player address
        let players = self.storage.game_players.at(game_id).read();
        self.storage.game_players.at(game_id).write([white_player, players[1]]);

        self.storage.game_hashes.at(game_id).write(game_hash);
        self.emit(JoinedGame { game_id, password_hash, initial_state: user_secret_hashes });

    }
}
