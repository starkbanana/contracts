use starknet::ContractAddress;

#[starknet::interface]
trait IStaking<T> {
    fn stake(ref self: T, value: u256);
    fn unstake(ref self: T);
    fn claim(ref self: T);
    fn get_owner(self: @T) -> ContractAddress;
    fn get_tokens_staked(self: @T) -> u256;
    fn get_cumulated_tokens_staked(self: @T) -> u256;
    fn get_reward_tick_in_secs(self: @T) -> u256;
    fn get_banana_contract_address(self: @T) -> ContractAddress;
    fn get_meme_coin_contract_address(self: @T) -> ContractAddress;
    fn get_rewards_to_claim(self: @T, contract_address: ContractAddress) -> u256;
    fn get_staked_balance(self: @T, contract_address: ContractAddress) -> u256;
    fn get_staking_ts(self: @T, contract_address: ContractAddress) -> u64;
    fn get_staking_secs(self: @T, contract_address: ContractAddress) -> u256;
    fn set_timing_reward(ref self: T, reward_tick_in_secs: u256);
    fn set_fees(ref self: T, fees: u256);
    fn set_is_paused(ref self: T, is_paused: bool);
    fn upgrade(ref self: T, class_hash: starknet::ClassHash);
    fn force_withdraw(ref self: T, account: ContractAddress);
    fn withdraw_rewards(ref self: T);
    fn estimate_staking_rewards(self: @T, account_address: ContractAddress) -> u256;
    fn get_balance_multiplier(self: @T, account_address: ContractAddress) -> u256;
}

#[starknet::interface]
trait IERC20<TState> {
    fn name(self: @TState) -> felt252;
    fn symbol(self: @TState) -> felt252;
    fn decimals(self: @TState) -> u8;
    fn total_supply(self: @TState) -> u256;
    fn balance_of(self: @TState, account: ContractAddress) -> u256;
    fn totalSupply(self: @TState) -> u256;
    fn balanceOf(self: @TState, account: ContractAddress) -> u256;
    fn allowance(self: @TState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn transferFrom(
        ref self: TState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(ref self: TState, spender: ContractAddress, amount: u256) -> bool;
    fn withdraw_other(
        ref self: TState, amount: u256, receiver: ContractAddress, token: ContractAddress
    );
    fn set_pool(ref self: TState, pool_address: ContractAddress);
    fn set_hodl_limit(ref self: TState, hodl_limit: bool);
}

#[starknet::interface]
trait IBananaToken<TState> {
    // IERC20
    fn total_supply(self: @TState,) -> u256;
    fn balance_of(self: @TState, account: ContractAddress) -> u256;
    fn allowance(self: @TState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(self: @TState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        self: @TState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(self: @TState, spender: ContractAddress, amount: u256) -> bool;

    // IERC20Metadata
    fn name(self: @TState) -> felt252;
    fn symbol(self: @TState) -> felt252;
    fn decimals(self: @TState) -> u8;

    // ISafeAllowance
    fn increase_allowance(self: @TState, spender: ContractAddress, added_value: u256) -> bool;
    fn decrease_allowance(self: @TState, spender: ContractAddress, subtracted_value: u256) -> bool;

    // IERC20Camel
    fn totalSupply(self: @TState,) -> u256;
    fn balanceOf(self: @TState, account: ContractAddress) -> u256;
    fn transferFrom(
        self: @TState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

    // ISafeAllowanceCamel
    fn increaseAllowance(self: @TState, spender: ContractAddress, addedValue: u256) -> bool;
    fn decreaseAllowance(self: @TState, spender: ContractAddress, subtractedValue: u256) -> bool;
}


#[starknet::contract]
mod MemeCoinStaking {
    use core::starknet::event::EventEmitter;
    use super::{
        IERC20, IStaking, IERC20Dispatcher, IERC20DispatcherTrait, IBananaTokenDispatcherTrait,
        IBananaTokenDispatcher
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Upgraded: Upgraded,
        Stacked: Stacked,
        Unstacked: Unstacked,
        Claimed: Claimed,
    }

    #[storage]
    struct Storage {
        cumulated_tokens_staked: u256,
        tokens_staked: u256,
        accumulated_rewards: LegacyMap<ContractAddress, u256>,
        balances: LegacyMap<ContractAddress, (u256, u64)>,
        meme_coin_contract: ContractAddress,
        banana_contract: ContractAddress,
        reward_per_token_per_sec: u256,
        admin: ContractAddress,
        is_paused: bool,
        fees: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Upgraded {
        class_hash: starknet::ClassHash,
    }

    #[derive(Drop, starknet::Event)]
    struct Stacked {
        account: ContractAddress,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Unstacked {
        account: ContractAddress,
        amount: u256,
        rewards: u256,
        balance_multiplier: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Claimed {
        account: ContractAddress,
        amount: u256
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        meme_coin_contract: ContractAddress,
        banana_contract: ContractAddress
    ) {
        self.meme_coin_contract.write(meme_coin_contract);
        self.banana_contract.write(banana_contract);
        self.admin.write(owner);
        self.reward_per_token_per_sec.write(90895656);
        self.is_paused.write(false);
        self.fees.write(20);
    }

    #[external(v0)]
    impl ImplStaking of IStaking<ContractState> {
        fn get_balance_multiplier(self: @ContractState, account_address: ContractAddress) -> u256 {
            let staked_time_in_secs = self.get_staking_secs(account_address);
            let balance_multiplier = staked_time_in_secs * self.reward_per_token_per_sec.read();
            balance_multiplier
        }

        fn estimate_staking_rewards(
            self: @ContractState, account_address: ContractAddress
        ) -> u256 {
            let (balance, staking_ts) = self.balances.read(account_address);
            let block_ts = get_block_timestamp();
            let staked_time_in_secs: u256 = (block_ts - staking_ts).into();
            let balance_multiplier = staked_time_in_secs * self.reward_per_token_per_sec.read();
            let rewards = (balance / 1000000000000000000) * balance_multiplier;
            rewards
        }

        fn get_cumulated_tokens_staked(self: @ContractState) -> u256 {
            self.cumulated_tokens_staked.read()
        }

        fn get_tokens_staked(self: @ContractState) -> u256 {
            self.tokens_staked.read()
        }

        fn get_banana_contract_address(self: @ContractState) -> ContractAddress {
            self.banana_contract.read()
        }

        fn get_meme_coin_contract_address(self: @ContractState) -> ContractAddress {
            self.meme_coin_contract.read()
        }

        fn get_reward_tick_in_secs(self: @ContractState) -> u256 {
            self.reward_per_token_per_sec.read()
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn set_fees(ref self: ContractState, fees: u256) {
            assert(self.admin.read() == get_caller_address(), 'Only admin');
            self.fees.write(fees);
        }

        fn set_is_paused(ref self: ContractState, is_paused: bool) {
            assert(self.admin.read() == get_caller_address(), 'Only admin');
            self.is_paused.write(is_paused);
        }

        fn set_timing_reward(ref self: ContractState, reward_tick_in_secs: u256) {
            assert(self.admin.read() == get_caller_address(), 'Only admin');
            self.reward_per_token_per_sec.write(reward_tick_in_secs);
        }

        fn get_staking_ts(self: @ContractState, contract_address: ContractAddress) -> u64 {
            let (balance, staking_ts) = self.balances.read(contract_address);
            staking_ts
        }

        fn get_staking_secs(self: @ContractState, contract_address: ContractAddress) -> u256 {
            let (balance, staking_ts) = self.balances.read(contract_address);
            let block_ts = get_block_timestamp();
            let staked_time_in_secs: u256 = (block_ts - staking_ts).into();
            staked_time_in_secs
        }

        fn get_staked_balance(self: @ContractState, contract_address: ContractAddress) -> u256 {
            let (balance, staking_ts) = self.balances.read(contract_address);
            balance
        }

        fn get_rewards_to_claim(self: @ContractState, contract_address: ContractAddress) -> u256 {
            let rewards_to_claim = self.accumulated_rewards.read(contract_address);
            rewards_to_claim
        }

        fn stake(ref self: ContractState, value: u256) {
            assert(!self.is_paused.read(), 'Staking is paused');

            let caller_address = get_caller_address();
            let contract_address = get_contract_address();
            let (balance, staking_ts) = self.balances.read(caller_address);

            assert(balance == 0, 'Already staked');
            assert(value >= 1000000000000000000, 'Min stack is 1');

            let fee_amount = (value * self.fees.read()) / 10000; // 0.2%
            let amount = value - fee_amount;

            let dispatcher = IERC20Dispatcher { contract_address: self.meme_coin_contract.read() };
            dispatcher.transfer_from(caller_address, self.admin.read(), fee_amount);

            let dispatcher = IERC20Dispatcher { contract_address: self.meme_coin_contract.read() };
            dispatcher.transfer_from(caller_address, contract_address, amount);

            self.tokens_staked.write(self.tokens_staked.read() + amount);
            self.cumulated_tokens_staked.write(self.cumulated_tokens_staked.read() + amount);

            let block_ts = get_block_timestamp();
            self.balances.write(caller_address, (amount, block_ts));
            self.emit(Stacked { account: caller_address, amount });
        }

        fn unstake(ref self: ContractState) {
            let caller_address = get_caller_address();
            let (caller_balance, staking_ts) = self.balances.read(caller_address);

            let block_ts = get_block_timestamp();
            let time_diff_in_secs: u256 = (block_ts - staking_ts).into();

            assert(time_diff_in_secs >= 1, 'Too soon to unstake');
            assert(caller_balance != 0, 'No balance to unstake');

            let contract_address = get_contract_address();

            if (self.tokens_staked.read() > caller_balance) {
                self.tokens_staked.write(self.tokens_staked.read() - caller_balance);
            } else {
                self.tokens_staked.write(0);
            }

            let time_diff_in_secs: u256 = (block_ts - staking_ts).into();
            let balance_multiplier = (time_diff_in_secs.into()
                * self.reward_per_token_per_sec.read());

            let rewards = (caller_balance / 1000000000000000000) * balance_multiplier;
            let new_rewards_to_claim = self.accumulated_rewards.read(caller_address) + rewards;
            self.accumulated_rewards.write(caller_address, new_rewards_to_claim);

            self.balances.write(caller_address, (0, 0));
            let memeCoinDispatcher = IERC20Dispatcher {
                contract_address: self.meme_coin_contract.read()
            };
            memeCoinDispatcher.transfer(caller_address, caller_balance);

            self
                .emit(
                    Unstacked {
                        account: caller_address,
                        amount: caller_balance,
                        rewards: rewards,
                        balance_multiplier: balance_multiplier
                    }
                );
        }

        fn claim(ref self: ContractState) {
            let caller_address = get_caller_address();
            let contract_address = get_contract_address();

            let rewards_to_claim = self.accumulated_rewards.read(caller_address);
            assert(rewards_to_claim != 0, 'No rewards to claim');

            self.accumulated_rewards.write(caller_address, 0);
            let fees_amount = ((rewards_to_claim * self.fees.read()) / 10000);
            let rewards_to_claim_minus_fees = rewards_to_claim - fees_amount;

            let bananaTokenDispatcher = IBananaTokenDispatcher {
                contract_address: self.banana_contract.read()
            };
            bananaTokenDispatcher.transfer(caller_address, rewards_to_claim_minus_fees);
            bananaTokenDispatcher.transfer(self.admin.read(), fees_amount);
            self.emit(Claimed { account: caller_address, amount: rewards_to_claim_minus_fees });
        }

        fn upgrade(ref self: ContractState, class_hash: starknet::ClassHash) {
            assert(
                starknet::get_caller_address() == self.admin.read(), 'Unauthorized replace class'
            );

            match starknet::replace_class_syscall(class_hash) {
                Result::Ok(_) => self.emit(Upgraded { class_hash }),
                Result::Err(revert_reason) => panic(revert_reason),
            };
        }

        fn withdraw_rewards(ref self: ContractState) {
            assert(self.admin.read() == get_caller_address(), 'Only admin');
            let bananaTokenDispatcher = IBananaTokenDispatcher {
                contract_address: self.banana_contract.read()
            };
            let contract_address = get_contract_address();
            let banana_balance = bananaTokenDispatcher.balance_of(contract_address);
            bananaTokenDispatcher.transfer(self.admin.read(), banana_balance);
        }

        fn force_withdraw(ref self: ContractState, account: ContractAddress) {
            assert(
                starknet::get_caller_address() == self.admin.read(), 'Unauthorized force withdraw'
            );
            let (caller_balance, staking_ts) = self.balances.read(account);
            assert(caller_balance != 0, 'No balance to unstake');
            let memeCoinDispatcher = IERC20Dispatcher {
                contract_address: self.meme_coin_contract.read()
            };
            let caller_balance_u256: u256 = caller_balance.into();
            memeCoinDispatcher.transfer(account, caller_balance_u256);
            self.balances.write(account, (0, 0));
            self
                .emit(
                    Unstacked {
                        account: account, amount: caller_balance, rewards: 0, balance_multiplier: 0
                    }
                );
        }
    }
}

