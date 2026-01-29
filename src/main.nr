use aztec::macros::aztec;

#[aztec]
pub contract FogOfWarChess {
    use aztec::{
        macros::{events::event, functions::{external, initializer, only_self}, storage::storage},
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
    }

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

    #[initializer]
    #[external("public")]
    fn setup() {}

    #[external("private")]
    fn create_game_private(user_secret: Field, user_mask: Field, password: Field) {
        let mut game_state: GameState = empty_game_state();
        game_state = game_state.commit_to_user_secrets(user_secret, user_mask, 0);
        let mut password_hash = poseidon2([password], 1);
        if (password == 0) {
            password_hash = 0;
        }
        self.enqueue_self.create_game_public(
            [
                game_state.mpc_state.user_encrypt_secret_hashes[0],
                game_state.mpc_state.user_mask_secret_hashes[0],
            ],
            password_hash,
        );
    }

    #[external("public")]
    #[only_self]
    fn create_game_public(user_secret_hashes: [Field; 2], password_hash: Field) {
        let game_id: u32 = self.storage.game_counter.read();
        self.storage.game_hashes.at(game_id).write(0);
        self.storage.game_secret_hashes.at(game_id).write([
            user_secret_hashes[0],
            user_secret_hashes[1],
            password_hash,
            0,
        ]);
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

        self.enqueue_self.make_move_white_public(
            game_id,
            state_hash,
            ending_hash,
            user_output_state,
        );
    }

    #[external("public")]
    #[only_self]
    fn make_move_white_public(
        game_id: u32,
        initial_hash: Field,
        final_hash: Field,
        state: UserOutputState<64, 2>,
    ) {
        let game_hash = self.storage.game_hashes.at(game_id).read();

        assert(initial_hash != final_hash);
        assert(game_hash != 0);
        assert(game_hash == initial_hash);

        self.storage.game_hashes.at(game_id).write(final_hash);
        self.emit(MoveEvent { state });
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

        self.enqueue_self.make_move_black_public(
            game_id,
            state_hash,
            ending_hash,
            user_output_state,
        );
    }

    #[external("public")]
    #[only_self]
    fn make_move_black_public(
        game_id: u32,
        initial_hash: Field,
        final_hash: Field,
        state: UserOutputState<64, 2>,
    ) {
        let game_hash = self.storage.game_hashes.at(game_id).read();

        assert(initial_hash != final_hash);
        assert(game_hash != 0);
        assert(game_hash == initial_hash);

        self.storage.game_hashes.at(game_id).write(final_hash);
        self.emit(MoveEvent { state });
    }

    #[external("private")]
    fn join_game_private(
        game_id: u32,
        user_secret: Field,
        user_mask: Field,
        white_secret_hashes: [Field; 2],
        password: Field,
    ) {
        let mut game_state: GameState = empty_game_state();
        game_state = game_state.commit_to_user_secrets(user_secret, user_mask, 1);
        game_state.mpc_state.user_encrypt_secret_hashes[0] = white_secret_hashes[0];
        game_state.mpc_state.user_mask_secret_hashes[0] = white_secret_hashes[1];
        let mut password_hash = poseidon2([password], 1);
        if (password == 0) {
            password_hash = 0;
        }
        let game_hash = game_state.hash();
        self.enqueue_self.join_game_public(
            game_id,
            game_hash,
            [
                game_state.mpc_state.user_encrypt_secret_hashes[0],
                game_state.mpc_state.user_mask_secret_hashes[0],
            ],
            password_hash,
        );
    }

    #[external("public")]
    #[only_self]
    fn join_game_public(
        game_id: u32,
        game_hash: Field,
        user_secret_hashes: [Field; 2],
        password_hash: Field,
    ) {
        let secret_hashes: [Field; 4] = self.storage.game_secret_hashes.at(game_id).read();
        assert(secret_hashes[0] != 0);
        assert(secret_hashes[1] != 0);
        assert(secret_hashes[3] == 0); // only games that have not started will have the second player mask secret hash blank
        assert(secret_hashes[2] == password_hash);

        self.storage.game_secret_hashes.at(game_id).write([
            secret_hashes[0],
            secret_hashes[1],
            user_secret_hashes[0],
            user_secret_hashes[1],
        ]);

        self.storage.game_hashes.at(game_id).write(game_hash);
        self.emit(JoinedGame { game_id, password_hash, initial_state: user_secret_hashes });

    }
}
