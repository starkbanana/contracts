use starknet::{ClassHash, ContractAddress};

#[starknet::interface]
trait IERC20<T> {
    fn balance_of(ref self: T, account: ContractAddress) -> u256;
    fn transfer_from(
        ref self: T, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
}

#[starknet::interface]
trait IBananaToken<TState> {
    // IERC20
    fn total_supply(self: @TState, ) -> u256;
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
    fn totalSupply(self: @TState, ) -> u256;
    fn balanceOf(self: @TState, account: ContractAddress) -> u256;
    fn transferFrom(
        self: @TState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

    // ISafeAllowanceCamel
    fn increaseAllowance(self: @TState, spender: ContractAddress, addedValue: u256) -> bool;
    fn decreaseAllowance(self: @TState, spender: ContractAddress, subtractedValue: u256) -> bool;
}

#[starknet::interface]
trait IStake<T> {
    fn get_banana_contract_address(self: @T) -> ContractAddress;
    fn get_remaining_banana_tokens(self: @T) -> u256;
    fn get_meme_coin_contract_address(self: @T) -> ContractAddress;
    fn get_staking(self: @T, account_address: ContractAddress) -> (u256, u64);
    fn get_staking_details(self: @T, contract_address: ContractAddress) -> (u256, u256);
    fn get_staking_infos(self: @T) -> (u256, u256);
    fn get_estimate_staking_rewards(self: @T, account_address: ContractAddress) -> u256;
    fn set_eth_contract_address(ref self: T, eth_contract_address: ContractAddress);
    fn set_meme_coin_contract_address(ref self: T, meme_coin_contract_address: ContractAddress);
    fn set_fees(ref self: T, fees: u256);
    fn set_reward_rate(ref self: T, reward_rate: u256);
    fn stake(ref self: T, amount: u256);
    fn unstake(ref self: T);
    fn upgrade(ref self: T, class_hash: starknet::ClassHash);
    fn set_pause(ref self: T, value: bool);
    fn withdraw_rewards(ref self: T);
    fn slash_monkey(ref self: T, account: ContractAddress);
}

#[starknet::contract]
mod Stake {
    use super::{
        IStake, IERC20Dispatcher, IERC20DispatcherTrait, IBananaTokenDispatcher,
        IBananaTokenDispatcherTrait
    };
    use starknet::{ClassHash, ContractAddress};

    #[storage]
    struct Storage {
        meme_coin_contract_address: ContractAddress,
        eth_contract_address: ContractAddress,
        admin_account_address: ContractAddress,
        fees: u256,
        staking_balances: LegacyMap<ContractAddress, u256>,
        total_staked_tokens: u256,
        staking_ts: LegacyMap<ContractAddress, u64>,
        reward_rate: u256,
        banana_contract_address: ContractAddress,
        is_paused: bool
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Upgraded: Upgraded,
        Stacked: Stacked,
        Unstacked: Unstacked
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

    #[constructor]
    fn constructor(
        ref self: ContractState,
        meme_coin_contract_address: ContractAddress,
        eth_contract_address: ContractAddress,
        admin_account_address: ContractAddress,
        banana_contract_address: ContractAddress,
        reward_rate: u256
    ) {
        self.meme_coin_contract_address.write(meme_coin_contract_address);
        self.eth_contract_address.write(eth_contract_address);
        self.admin_account_address.write(admin_account_address);
        self.fees.write(20);
        self.reward_rate.write(reward_rate);
        self.banana_contract_address.write(banana_contract_address);
        self.is_paused.write(false);
    }

    #[external(v0)]
    impl IStakeImpl of IStake<ContractState> {
        fn get_banana_contract_address(self: @ContractState) -> ContractAddress {
            self.banana_contract_address.read()
        }

        fn get_remaining_banana_tokens(self: @ContractState) -> u256 {
            let bananaTokenDispatcher = IBananaTokenDispatcher {
                contract_address: self.banana_contract_address.read()
            };
            let contract_address = starknet::get_contract_address();
            let banana_balance = bananaTokenDispatcher.balance_of(contract_address);
            banana_balance
        }

        fn get_meme_coin_contract_address(self: @ContractState) -> ContractAddress {
            self.meme_coin_contract_address.read()
        }

        fn get_staking(self: @ContractState, account_address: ContractAddress) -> (u256, u64) {
            let balance = self.staking_balances.read(account_address);
            let ts = self.staking_ts.read(account_address);
            (balance, ts)
        }

        fn get_staking_details(
            self: @ContractState, contract_address: ContractAddress
        ) -> (u256, u256) {
            let (balance, staking_ts) = self.get_staking(contract_address);
            let block_ts = starknet::get_block_timestamp();
            let staked_time_in_secs: u256 = (block_ts - staking_ts).into();
            let balance_multiplier = staked_time_in_secs * self.reward_rate.read();
            (staked_time_in_secs, balance_multiplier)
        }

        fn get_staking_infos(self: @ContractState) -> (u256, u256) {
            (self.total_staked_tokens.read(), self.reward_rate.read())
        }

        fn get_estimate_staking_rewards(
            self: @ContractState, account_address: ContractAddress
        ) -> u256 {
            let (balance, staking_ts) = self.get_staking(account_address);
            let block_ts = starknet::get_block_timestamp();
            let staked_time_in_secs: u256 = (block_ts - staking_ts).into();
            let balance_multiplier = staked_time_in_secs * self.reward_rate.read();
            let rewards = (balance / 1000000000000000000) * balance_multiplier;
            rewards
        }

        fn set_reward_rate(ref self: ContractState, reward_rate: u256) {
            assert(
                self.admin_account_address.read() == starknet::get_caller_address(), 'Only admin'
            );
            self.reward_rate.write(reward_rate);
        }

        fn set_eth_contract_address(
            ref self: ContractState, eth_contract_address: ContractAddress
        ) {
            assert(
                self.admin_account_address.read() == starknet::get_caller_address(), 'Only admin'
            );
            self.eth_contract_address.write(eth_contract_address);
        }

        fn set_meme_coin_contract_address(
            ref self: ContractState, meme_coin_contract_address: ContractAddress
        ) {
            assert(
                self.admin_account_address.read() == starknet::get_caller_address(), 'Only admin'
            );
            self.meme_coin_contract_address.write(meme_coin_contract_address);
        }

        fn set_fees(ref self: ContractState, fees: u256) {
            assert(
                self.admin_account_address.read() == starknet::get_caller_address(), 'Only admin'
            );
            self.fees.write(fees);
        }

        fn set_pause(ref self: ContractState, value: bool) {
            assert(
                self.admin_account_address.read() == starknet::get_caller_address(), 'Only admin'
            );
            self.is_paused.write(value);
        }

        fn stake(ref self: ContractState, amount: u256) {
            assert(self.is_paused.read() == false, 'Contract is paused');

            let caller_addr = starknet::get_caller_address();
            let staking_balance = self.staking_balances.read(caller_addr);
            assert(staking_balance == 0, 'No staking');

            let meme_coin_dispatcher = IERC20Dispatcher {
                contract_address: self.meme_coin_contract_address.read()
            };
            let balance = meme_coin_dispatcher.balance_of(caller_addr);

            assert(balance > 0, 'Need coin to stake');
            assert(balance >= amount, 'Not enough coins to stake');

            let eth_dispatcher = IERC20Dispatcher {
                contract_address: self.meme_coin_contract_address.read()
            };

            let block_ts = starknet::get_block_timestamp();
            self.staking_balances.write(caller_addr, amount);
            self.total_staked_tokens.write(self.total_staked_tokens.read() + amount);
            self.staking_ts.write(caller_addr, block_ts);

            // calculate fees 0.2% of amount
            let fee_amount = (amount * self.fees.read()) / 10000; // 0.2%
            eth_dispatcher
                .transfer_from(caller_addr, self.admin_account_address.read(), fee_amount);

            self.emit(Stacked { account: caller_addr, amount });
        }

        fn unstake(ref self: ContractState) {
            let caller_addr = starknet::get_caller_address();
            let staking_balance = self.staking_balances.read(caller_addr);
            assert(staking_balance != 0, 'Already staked');

            let meme_coin_dispatcher = IERC20Dispatcher {
                contract_address: self.meme_coin_contract_address.read()
            };

            let fee_amount = (staking_balance * self.fees.read()) / 10000; // 0.2%
            let balance = meme_coin_dispatcher.balance_of(caller_addr);
            assert(balance >= (staking_balance - fee_amount), 'Invalid balance');

            let block_ts = starknet::get_block_timestamp();
            let staking_ts = self.staking_ts.read(caller_addr);

            let time_diff_in_secs: u256 = (block_ts - staking_ts).into();
            let balance_multiplier = (time_diff_in_secs.into() * self.reward_rate.read());

            let rewards = (staking_balance / 1000000000000000000) * balance_multiplier;
            assert(self.get_remaining_banana_tokens() >= rewards, 'Not enough banana tokens');

            self.total_staked_tokens.write(self.total_staked_tokens.read() - staking_balance);
            self.staking_balances.write(caller_addr, 0);
            self.staking_ts.write(caller_addr, 0);

            let bananaTokenDispatcher = IBananaTokenDispatcher {
                contract_address: self.banana_contract_address.read()
            };
            bananaTokenDispatcher.transfer(caller_addr, rewards);

            self
                .emit(
                    Unstacked {
                        account: caller_addr,
                        amount: staking_balance,
                        rewards: rewards,
                        balance_multiplier: balance_multiplier
                    }
                );
        }

        fn upgrade(ref self: ContractState, class_hash: starknet::ClassHash) {
            assert(
                starknet::get_caller_address() == self.admin_account_address.read(),
                'Unauthorized replace class'
            );

            match starknet::replace_class_syscall(class_hash) {
                Result::Ok(_) => self.emit(Upgraded { class_hash }),
                Result::Err(revert_reason) => panic(revert_reason),
            };
        }

        fn withdraw_rewards(ref self: ContractState) {
            assert(
                self.admin_account_address.read() == starknet::get_caller_address(), 'Only admin'
            );

            let bananaTokenDispatcher = IBananaTokenDispatcher {
                contract_address: self.banana_contract_address.read()
            };
            let banana_balance = self.get_remaining_banana_tokens();
            bananaTokenDispatcher.transfer(self.admin_account_address.read(), banana_balance);
        }

        fn slash_monkey(ref self: ContractState, account: ContractAddress) {
            assert(
                starknet::get_caller_address() == self.admin_account_address.read(), 'Only admin'
            );
            let caller_balance = self.staking_balances.read(account);
            let staking_ts = self.staking_ts.read(account);
            self.staking_balances.write(account, 0);
            self.staking_ts.write(account, 0);
        }
    }
}
