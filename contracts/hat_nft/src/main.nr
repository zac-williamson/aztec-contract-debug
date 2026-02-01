use aztec::macros::aztec;

// ============ Hat Type Constants ============
// Based on ELO delta (loser_elo - winner_elo)
// Positive = underdog victory (impressive), Negative = expected win (less impressive)
global HAT_CROWN: u8 = 0;         // delta > +200 (major upset)
global HAT_LAUREL_WREATH: u8 = 1; // delta +100 to +200 (underdog victory)
global HAT_WIZARD_HAT: u8 = 2;    // delta -100 to +100 (fair match)
global HAT_TOP_HAT: u8 = 3;       // delta -200 to -100 (slight favorite)
global HAT_BOWLER_HAT: u8 = 4;    // delta -300 to -200 (clear favorite)
global HAT_BASEBALL_CAP: u8 = 5;  // delta -400 to -300 (strong favorite)
global HAT_DUNCE_CAP: u8 = 6;     // delta < -400 (crushing weaker opponent)

// ============ Quality Constants ============
// Based on winner's ELO rating
global QUALITY_TATTERED: u8 = 0;  // ELO < 800
global QUALITY_SHODDY: u8 = 1;    // ELO 800-1000
global QUALITY_PLAIN: u8 = 2;     // ELO 1000-1200
global QUALITY_FINE: u8 = 3;      // ELO 1200-1400
global QUALITY_ELEGANT: u8 = 4;   // ELO 1400-1600
global QUALITY_MAJESTIC: u8 = 5;  // ELO 1600-1800
global QUALITY_LEGENDARY: u8 = 6; // ELO 1800-2000
global QUALITY_MYTHIC: u8 = 7;    // ELO 2000+

/// Compute hat type from ELO delta (loser_elo - winner_elo)
/// Positive delta = underdog victory = more impressive hat
/// Negative delta = expected win = less impressive hat
pub fn compute_hat_type(winner_elo: u32, loser_elo: u32) -> u8 {
    let delta: i32 = loser_elo as i32 - winner_elo as i32;

    if delta > 200 {
        HAT_CROWN
    } else if delta > 100 {
        HAT_LAUREL_WREATH
    } else if delta >= -100 {
        HAT_WIZARD_HAT
    } else if delta >= -200 {
        HAT_TOP_HAT
    } else if delta >= -300 {
        HAT_BOWLER_HAT
    } else if delta >= -400 {
        HAT_BASEBALL_CAP
    } else {
        HAT_DUNCE_CAP
    }
}

/// Compute hat quality from winner's ELO rating
pub fn compute_hat_quality(winner_elo: u32) -> u8 {
    if winner_elo >= 2000 {
        QUALITY_MYTHIC
    } else if winner_elo >= 1800 {
        QUALITY_LEGENDARY
    } else if winner_elo >= 1600 {
        QUALITY_MAJESTIC
    } else if winner_elo >= 1400 {
        QUALITY_ELEGANT
    } else if winner_elo >= 1200 {
        QUALITY_FINE
    } else if winner_elo >= 1000 {
        QUALITY_PLAIN
    } else if winner_elo >= 800 {
        QUALITY_SHODDY
    } else {
        QUALITY_TATTERED
    }
}

#[aztec]
pub contract HatNFT {
    use aztec::{
        macros::{events::event, functions::{external, initializer}, storage::storage},
        protocol_types::address::AztecAddress,
        state_vars::{Map, public_mutable::PublicMutable},
    };
    use crate::{compute_hat_type, compute_hat_quality};

    /// Emitted when a new hat NFT is minted
    #[event]
    struct HatMinted {
        token_id: u32,
        owner: AztecAddress,
        game_id: u32,
        hat_type: u8,
        hat_quality: u8,
    }

    /// Emitted when a hat NFT is transferred
    #[event]
    struct HatTransferred {
        token_id: u32,
        from: AztecAddress,
        to: AztecAddress,
    }

    #[storage]
    struct Storage<Context> {
        /// Auto-incrementing token ID counter
        token_counter: PublicMutable<u32, Context>,
        /// Map from token_id to owner address
        public_owners: Map<u32, PublicMutable<AztecAddress, Context>, Context>,
        /// Map from token_id to existence flag
        nft_exists: Map<u32, PublicMutable<bool, Context>, Context>,
        /// Map from token_id to game_id
        hat_game_ids: Map<u32, PublicMutable<u32, Context>, Context>,
        /// Map from token_id to hat type (0-6, see HAT_* constants)
        hat_types: Map<u32, PublicMutable<u8, Context>, Context>,
        /// Map from token_id to hat quality (0-7, see QUALITY_* constants)
        hat_qualities: Map<u32, PublicMutable<u8, Context>, Context>,
        /// Authorized minter (chess contract address) - set once in constructor
        minter: PublicMutable<AztecAddress, Context>,
    }

    #[initializer]
    #[external("public")]
    fn constructor(chess_contract: AztecAddress) {
        assert(chess_contract != AztecAddress::zero(), "Minter cannot be zero address");
        self.storage.minter.write(chess_contract);
        self.storage.token_counter.write(0);
    }

    /// Mint a new hat NFT to the winner. Only callable by the authorized minter (chess contract).
    #[external("public")]
    fn mint_hat(to: AztecAddress, game_id: u32, winner_elo: u32, loser_elo: u32) {
        // Only the authorized minter can call this
        let minter = self.storage.minter.read();
        let caller = self.context.msg_sender().expect(f"msg_sender must be set");
        assert(caller == minter, "Only minter can mint");
        assert(to != AztecAddress::zero(), "Cannot mint to zero address");

        // Get next token ID
        let token_id = self.storage.token_counter.read();

        // Compute hat attributes from ELO ratings
        let hat_type = compute_hat_type(winner_elo, loser_elo);
        let hat_quality = compute_hat_quality(winner_elo);

        // Store NFT data
        self.storage.public_owners.at(token_id).write(to);
        self.storage.nft_exists.at(token_id).write(true);
        self.storage.hat_game_ids.at(token_id).write(game_id);
        self.storage.hat_types.at(token_id).write(hat_type);
        self.storage.hat_qualities.at(token_id).write(hat_quality);

        // Increment counter
        self.storage.token_counter.write(token_id + 1);

        // Emit event
        self.emit(HatMinted {
            token_id,
            owner: to,
            game_id,
            hat_type,
            hat_quality,
        });
    }

    /// Transfer a hat NFT from one address to another. Caller must be the current owner.
    #[external("public")]
    fn transfer(from: AztecAddress, to: AztecAddress, token_id: u32) {
        // Check token exists
        let exists = self.storage.nft_exists.at(token_id).read();
        assert(exists, "Token does not exist");

        // Check caller is the owner
        let owner = self.storage.public_owners.at(token_id).read();
        assert(owner == from, "From address is not the owner");
        let caller = self.context.msg_sender().expect(f"msg_sender must be set");
        assert(caller == from, "Only owner can transfer");
        assert(to != AztecAddress::zero(), "Cannot transfer to zero address");

        // Update owner
        self.storage.public_owners.at(token_id).write(to);

        // Emit event
        self.emit(HatTransferred { token_id, from, to });
    }

    /// Get the owner of a token
    #[external("utility")]
    unconstrained fn owner_of(token_id: u32) -> AztecAddress {
        let exists = self.storage.nft_exists.at(token_id).read();
        assert(exists, "Token does not exist");
        self.storage.public_owners.at(token_id).read()
    }

    /// Get metadata for a hat NFT
    /// Returns (game_id, hat_type, hat_quality)
    /// Hat types: 0=Crown, 1=Laurel Wreath, 2=Wizard Hat, 3=Top Hat, 4=Bowler Hat, 5=Baseball Cap, 6=Dunce Cap
    /// Qualities: 0=Tattered, 1=Shoddy, 2=Plain, 3=Fine, 4=Elegant, 5=Majestic, 6=Legendary, 7=Mythic
    #[external("utility")]
    unconstrained fn get_hat_metadata(token_id: u32) -> (u32, u8, u8) {
        let exists = self.storage.nft_exists.at(token_id).read();
        assert(exists, "Token does not exist");

        let game_id = self.storage.hat_game_ids.at(token_id).read();
        let hat_type = self.storage.hat_types.at(token_id).read();
        let hat_quality = self.storage.hat_qualities.at(token_id).read();

        (game_id, hat_type, hat_quality)
    }

    /// Get total number of minted tokens
    #[external("utility")]
    unconstrained fn total_supply() -> u32 {
        self.storage.token_counter.read()
    }

    /// Get the authorized minter address
    #[external("utility")]
    unconstrained fn get_minter() -> AztecAddress {
        self.storage.minter.read()
    }

    /// Check if a token exists
    #[external("utility")]
    unconstrained fn exists(token_id: u32) -> bool {
        self.storage.nft_exists.at(token_id).read()
    }
}
