use propamm_sdk::{
    Actions, Error,
    alloy::{
        primitives::{Address, B256, U256},
        sol_types::SolCall,
    },
    bindings::IVenue,
};

fn actions() -> Actions {
    Actions::new(Address::repeat_byte(0xaa), 42431).unwrap()
}

fn virtual_address() -> Address {
    let mut bytes = [0x12; 20];
    bytes[4..14].fill(0xfd);
    Address::from(bytes)
}

#[test]
fn virtual_layout_is_refused_for_additions_roles_and_payments_but_can_be_cleaned_up() {
    let a = actions();
    let v = virtual_address();
    assert!(matches!(a.set_denied(&[v], true), Err(Error::Invalid(_))));
    assert!(a.set_members(0, 0, &[v], true).is_err());
    assert!(a.approve_agent(v).is_err());
    assert!(a.transfer_ownership(v).is_err());
    assert!(
        a.withdraw(Address::repeat_byte(1), v, U256::from(1), B256::ZERO)
            .is_err()
    );
    let deny =
        IVenue::setDeniedCall::abi_decode(a.set_denied(&[v], false).unwrap().data()).unwrap();
    assert_eq!(deny.accounts, vec![v]);
    assert!(!deny.deny);
    let members =
        IVenue::setMembersCall::abi_decode(a.set_members(2, 3, &[v], false).unwrap().data())
            .unwrap();
    assert_eq!(members.accounts, vec![v]);
    assert!(!members.allowed);
    for account in [Address::ZERO, v] {
        let revoke = IVenue::setUpdaterCall::abi_decode(a.revoke_agent(account).data()).unwrap();
        assert_eq!(revoke.updater, account);
        assert!(!revoke.allowed);
    }
    assert!(a.cancel_ownership_transfer().posts().is_empty());
    assert!(a.cancel_sponsor_admin_transfer(1).posts().is_empty());
}

#[test]
fn exact_layout_boundary_matches_tip1022_not_prefix_or_suffix() {
    let a = actions();
    // Every one of the ten magic bytes matters; prefix and suffix do not.
    for index in 0..20 {
        let mut bytes = virtual_address().into_array();
        bytes[index] ^= 1;
        let account = Address::from(bytes);
        let expected = (4..14).contains(&index);
        assert_eq!(a.approve_agent(account).is_ok(), expected, "byte {index}");
        assert_eq!(a.transfer_ownership(account).is_ok(), expected);
        assert_eq!(a.set_denied(&[account], true).is_ok(), expected);
        assert_eq!(a.set_members(0, 0, &[account], true).is_ok(), expected);
        assert_eq!(
            a.withdraw(Address::repeat_byte(1), account, U256::from(1), B256::ZERO)
                .is_ok(),
            expected
        );
    }
}

#[test]
fn batches_validate_size_and_every_account_in_both_directions() {
    let a = actions();
    let account = Address::repeat_byte(1);
    for adding in [false, true] {
        for size in [0, 1, 100, 101] {
            let accounts = vec![account; size];
            assert_eq!(
                a.set_denied(&accounts, adding).is_ok(),
                (1..=100).contains(&size)
            );
            assert_eq!(
                a.set_members(0, 0, &accounts, adding).is_ok(),
                (1..=100).contains(&size)
            );
        }
        for invalid in [Address::ZERO, a.venue()] {
            for accounts in [vec![invalid, account], vec![account, invalid]] {
                assert!(a.set_denied(&accounts, adding).is_err());
                assert!(a.set_members(0, 0, &accounts, adding).is_err());
            }
        }
    }
    assert!(a.approve_agent(Address::ZERO).is_err());
    assert!(a.transfer_ownership(Address::ZERO).is_err());
    // TS does not exclude the venue itself for these two role proposals.
    assert!(a.approve_agent(a.venue()).is_ok());
    assert!(a.transfer_ownership(a.venue()).is_ok());
    for (token, to, amount) in [
        (Address::ZERO, account, U256::from(1)),
        (account, Address::ZERO, U256::from(1)),
        (account, a.venue(), U256::from(1)),
        (account, account, U256::ZERO),
    ] {
        assert!(a.withdraw(token, to, amount, B256::ZERO).is_err());
    }
    let call = a.set_members(7, 9, &[account, account], true).unwrap();
    let decoded = IVenue::setMembersCall::abi_decode(call.data()).unwrap();
    assert_eq!(decoded.pairIndex, 7);
    assert_eq!(decoded.sponsorId, 9);
    assert_eq!(decoded.accounts, vec![account, account]);
    assert!(decoded.allowed);
}

#[test]
fn validated_calls_preserve_arguments_and_scope() {
    let a = actions();
    let account = Address::repeat_byte(1);
    let token = Address::repeat_byte(2);
    let memo = B256::repeat_byte(3);
    let grant = a.approve_agent(account).unwrap();
    let updater = IVenue::setUpdaterCall::abi_decode(grant.data()).unwrap();
    assert_eq!(updater.updater, account);
    assert!(updater.allowed);
    let owner = a.transfer_ownership(account).unwrap();
    assert_eq!(
        IVenue::transferOwnershipCall::abi_decode(owner.data())
            .unwrap()
            .newOwner,
        account
    );
    let payment = a.withdraw(token, account, U256::from(42), memo).unwrap();
    let decoded = IVenue::withdrawCall::abi_decode(payment.data()).unwrap();
    assert_eq!(decoded.token, token);
    assert_eq!(decoded.to, account);
    assert_eq!(decoded.amount, U256::from(42));
    assert_eq!(decoded.memo, memo);
    for call in [grant, owner, payment] {
        assert_eq!(call.venue(), a.venue());
        assert_eq!(call.chain_id(), a.chain_id());
        assert!(call.posts().is_empty());
    }
    // A bad final entry must refuse the entire builder, never silently omit it.
    assert!(
        a.set_members(0, 0, &[account, virtual_address()], true)
            .is_err()
    );
    assert!(a.set_denied(&[account, virtual_address()], true).is_err());
}
