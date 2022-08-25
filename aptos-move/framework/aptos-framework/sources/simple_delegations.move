/// Module that offers convenient simple delegations where a single owner account can delegate
/// to multiple operators. This does not offer general purpose delegations where funds from multiple
/// delegators can be pooled and staked with a single operator.
module aptos_framework::simple_delegations {
    use std::bcs;
    use std::error;
    use std::signer;
    use std::vector;

    use aptos_std::simple_map::{Self, SimpleMap};

    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::stake::{Self, OwnerCapability};

    friend aptos_framework::genesis;

    const STAKE_POOL_ACCOUNT_SALT: vector<u8> = b"aptos_framework::simple_delegations";

    /// Delegations amount must be > 0.
    const EZERO_DELEGATION_AMOUNT: u64 = 1;
    /// Commission percentage has to be between 0 and 100.
    const EINVALID_COMMISSION_PERCENTAGE: u64 = 2;
    /// No delegations found to any operator.
    const ENO_DELEGATIONS_FOUND: u64 = 3;
    /// No delegation from the delegator to the specified operator found.
    const EDELEGATION_NOT_FOUND: u64 = 4;
    /// Can't merge two stake pools from 2 existing operators.
    const ECANT_MERGE_TWO_EXISTING_STAKE_POOLS: u64 = 5;
    /// Cannot claim any commissions as commission rate is zero.
    const EZERO_COMMISSION_RATE: u64 = 6;
    /// Cannot change an existing delegation.
    const ECANNOT_CHANGE_EXISTING_DELEGATION: u64 = 7;
    /// Cannot request commission from an inactive delegation. Any unpaid commission will be settled when the delegator
    /// withdraws funds.
    const EINACTIVE_DELEGATION: u64 = 8;
    /// Cannot end a delegation that has already been ended.
    const EDELEGATION_ALREADY_ENDED: u64 = 9;
    /// Cannot end a delegation while the original delegated stake is still pending_inactive.
    /// This can result in lost funds. Delegator needs to wait until the next epoch before they can end the delegation.
    const EPENDING_ACTIVE_FOUND: u64 = 10;
    /// Cannot withdraw stake from a still active delegation.
    const EDELEGATION_STILL_ACTIVE: u64 = 11;
    /// Cannot withdraw stake as it's still being unlocked in the stake pool.
    const EFUNDS_STILL_BEING_UNLOCKED: u64 = 12;

    struct CommissionDebt has store, drop {
        creditor: address,
        amount: u64,
    }

    struct Delegation has store {
        principal_amount: u64,
        pool_address: address,
        owner_cap: OwnerCapability,
        commission_percentage: u64,
        is_active: bool,
        // Potential debts to previous operators if operator is switched before the previous operator
        // has withdrawn their commission.
        debts: vector<CommissionDebt>,
    }

    struct Delegations has key {
        delegations: SimpleMap<address, Delegation>,
    }

    /// Only delegator can call this.
    /// Can only delegate to a specific operator once. Afterward, delegator cannot add more funds.
    public entry fun delegate(
        delegator: &signer,
        operator: address,
        voter: address,
        amount: u64,
        commission_percentage: u64,
    ) acquires Delegations {
        assert!(amount > 0, error::invalid_argument(EZERO_DELEGATION_AMOUNT));
        assert!(
            commission_percentage >= 0 && commission_percentage <= 100,
            error::invalid_argument(EINVALID_COMMISSION_PERCENTAGE),
        );

        // Initialize Delegations resource if this is the first the delegator has delegated to anyone.
        let delegator_address = signer::address_of(delegator);
        if (!exists<Delegations>(delegator_address)) {
            move_to(delegator, Delegations {
                delegations: simple_map::create<address, Delegation>(),
            })
        };

        // Only allow delegating to the same operator once.
        let delegations = &mut borrow_global_mut<Delegations>(delegator_address).delegations;
        assert!(
            !simple_map::contains_key(delegations, &operator),
            error::invalid_argument(ECANNOT_CHANGE_EXISTING_DELEGATION)
        );

        // Initialize the stake pool in a new resource account. This allows the same delegator to delegate to multiple
        // different operators.
        let seed = create_seed(delegator_address, operator);
        let (stake_pool_signer, _) = account::create_resource_account(delegator, seed);
        stake::initialize_stake_owner(&stake_pool_signer, amount, operator, voter);

        // Record the delegation.
        simple_map::add(delegations, operator, Delegation {
            is_active: true,
            principal_amount: amount,
            pool_address: signer::address_of(&stake_pool_signer),
            owner_cap: stake::extract_owner_cap(&stake_pool_signer),
            commission_percentage,
            debts: vector::empty<CommissionDebt>(),
        });
    }

    /// Unlocks commission amount from the stake pool. Operator needs to wait for the amount to become withdrawable
    /// at the end of the stake pool's lockup period before they can actually can withdraw_commission.
    ///
    /// Anyone can call this function as this is an explicit agreement between delegator and operator.
    public entry fun request_commission(operator: address, delegator: address) acquires Delegations {
        assert_delegation_exists(delegator, operator);

        let delegations = &mut borrow_global_mut<Delegations>(delegator).delegations;
        let delegation = simple_map::borrow_mut(delegations, &operator);
        assert!(delegation.commission_percentage > 0, error::invalid_argument(EZERO_COMMISSION_RATE));
        assert!(delegation.is_active, error::invalid_argument(EINACTIVE_DELEGATION));

        // Unlock just the commission portion from the stake pool.
        let accumulated_rewards = update_principal(delegation);
        let commission_amount = accumulated_rewards * delegation.commission_percentage / 100;
        stake::unlock_with_cap(commission_amount, &delegation.owner_cap);
    }

    /// Anyone can call this function as this is an explicit agreement between delegator and operator.
    public entry fun withdraw_commission(operator: address, delegator: address) acquires Delegations {
        assert_delegation_exists(delegator, operator);

        let delegations = &mut borrow_global_mut<Delegations>(delegator).delegations;
        let delegation = simple_map::borrow_mut(delegations, &operator);
        assert!(delegation.is_active, error::invalid_argument(EINACTIVE_DELEGATION));

        let pool_address = delegation.pool_address;
        // Invariant: All withdrawable coins are commission before the delegator ends the delegation or switch operators
        let (_, withdrawable_amount, _, _) = stake::get_stake(pool_address);
        let coins = stake::withdraw_with_cap(&delegation.owner_cap, withdrawable_amount);

        // Pay off any outstanding debts to previous operators first before paying commission to this current operator.
        pay_debts(delegation, &mut coins);
        coin::deposit(operator, coins);
    }

    /// Allows delegator to switch operator without going through the lenghty process to unstake.
    public entry fun switch_operator(
        delegator: &signer,
        old_operator: address,
        new_operator: address,
    ) acquires Delegations {
        let delegator_address = signer::address_of(delegator);
        assert_delegation_exists(delegator_address, old_operator);

        // Merging two existing delegations are too complex as we'd need to merge two separate stake pools.
        let delegations = &mut borrow_global_mut<Delegations>(delegator_address).delegations;
        assert!(
            !simple_map::contains_key(delegations, &new_operator),
            error::not_found(ECANT_MERGE_TWO_EXISTING_STAKE_POOLS),
        );

        let (_, delegation) = simple_map::remove(delegations, &old_operator);
        assert!(delegation.is_active, error::invalid_argument(EINACTIVE_DELEGATION));
        record_unpaid_commission(&mut delegation, old_operator);

        // Update stake pool and delegation with the new operator.
        stake::set_operator_with_cap(&delegation.owner_cap, new_operator);
        simple_map::add(delegations, new_operator, delegation);
    }

    /// Only delegator can call this.
    public entry fun end_delegation(delegator: &signer, operator: address) acquires Delegations {
        let delegator_address = signer::address_of(delegator);
        assert_delegation_exists(delegator_address, operator);

        let delegations = &mut borrow_global_mut<Delegations>(delegator_address).delegations;
        let delegation = simple_map::borrow_mut(delegations, &operator);
        assert!(delegation.is_active, error::invalid_argument(EDELEGATION_ALREADY_ENDED));
        delegation.is_active = false;

        // Update the operator to be the delegator, so we can safely make sure the validator node is removed
        // from the validator set.
        // This also ensures that from now on, the operator no longer has any power over the stake pool.
        stake::set_operator_with_cap(&delegation.owner_cap, delegator_address);
        stake::leave_validator_set(delegator, delegation.pool_address);
        let (active, _, pending_active, _) = stake::get_stake(delegation.pool_address);
        assert!(pending_active == 0, error::invalid_state(EPENDING_ACTIVE_FOUND));
        stake::unlock_with_cap(active, &delegation.owner_cap);
    }

    /// Only delegator can call this.
    public entry fun withdraw_delegation(delegator: &signer, operator: address) acquires Delegations {
        let delegator_address = signer::address_of(delegator);
        assert_delegation_exists(delegator_address, operator);

        let delegations = &mut borrow_global_mut<Delegations>(delegator_address).delegations;
        let (_, delegation) = simple_map::remove(delegations, &operator);
        assert!(!delegation.is_active, error::invalid_argument(EDELEGATION_STILL_ACTIVE));

        let (_, inactive, _, pending_inactive) = stake::get_stake(delegation.pool_address);
        // Ensure all pending_inactive funds have been converted to active to avoid any stuck/lost funds.
        assert!(pending_inactive == 0, error::invalid_state(EFUNDS_STILL_BEING_UNLOCKED));
        let coins = stake::withdraw_with_cap(&delegation.owner_cap, inactive);

        // Pay off any outstanding debts to previous operators first.
        pay_debts(&mut delegation, &mut coins);
        coin::deposit(delegator_address, coins);

        // Destroy the delegation.
        let Delegation {
            principal_amount: _,
            pool_address: _,
            owner_cap,
            commission_percentage: _,
            is_active: _,
            debts: _,
        } = delegation;
        stake::destroy_owner_cap(owner_cap);
    }

    fun assert_delegation_exists(delegator: address, operator: address) acquires Delegations {
        assert!(
            exists<Delegations>(delegator),
            error::not_found(ENO_DELEGATIONS_FOUND),
        );
        let delegations = &mut borrow_global_mut<Delegations>(delegator).delegations;
        assert!(
            simple_map::contains_key(delegations, &operator),
            error::not_found(EDELEGATION_NOT_FOUND),
        );
    }

    fun create_seed(delegator: address, operator: address): vector<u8> {
        let seed = bcs::to_bytes(&delegator);
        vector::append(&mut seed, bcs::to_bytes(&operator));
        vector::append(&mut seed, STAKE_POOL_ACCOUNT_SALT);
        seed
    }

    fun record_unpaid_commission(delegation: &mut Delegation, creditor: address) {
        // Record any outstanding commission debt that has not been paid to the old operator.
        // This includes any commision from outstanding rewards + requested commissions not yet paid out.
        let (_, inactive, _, pending_inactive) = stake::get_stake(delegation.pool_address);
        let unpaid_commission = pending_inactive + inactive;
        let accumulated_rewards = update_principal(delegation);
        let total_unpaid_commission = unpaid_commission + accumulated_rewards * delegation.commission_percentage / 100;
        vector::push_back(&mut delegation.debts, CommissionDebt {
            creditor,
            amount: total_unpaid_commission,
        });
    }

    fun pay_debts(delegation: &mut Delegation, coins: &mut Coin<AptosCoin>) {
        let debts = &mut delegation.debts;
        while (vector::length(debts) > 0 && coin::value(coins) > 0) {
            let debt = vector::remove(debts, 0);
            let coin_amount = coin::value(coins);
            // Pay as much debt as possible.
            let amount_to_pay = if (coin_amount >= debt.amount) {
                debt.amount
            } else {
                vector::push_back(debts, CommissionDebt {
                    creditor: debt.creditor,
                    amount: debt.amount - coin_amount,
                });
                coin_amount
            };
            let coins_to_pay = coin::extract(coins, amount_to_pay);
            coin::deposit(debt.creditor, coins_to_pay);
        }
    }

    fun update_principal(delegation: &mut Delegation): u64 {
        // Any outgoing flows of funds before the delegator withdraws all delegations can only come from operator
        // withdrawing commissions.
        // So to calculate rewards, we only care about current active + pending_active - last recorded principal.
        let (active, _, pending_active, _) = stake::get_stake(delegation.pool_address);
        let new_principal_amount = active + pending_active;
        let accumulated_rewards = new_principal_amount - delegation.principal_amount;
        delegation.principal_amount = new_principal_amount;

        accumulated_rewards
    }
}
