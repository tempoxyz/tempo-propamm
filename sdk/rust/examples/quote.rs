//! Offline example: prints unsigned calldata and never connects or broadcasts.
use propamm_sdk::{Actions, Level, OrderRequest, Shape, alloy::primitives::Address};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let venue: Address = std::env::var("VENUE")?.parse()?;
    let chain_id = std::env::var("CHAIN_ID")?.parse()?;
    let sequence = std::env::var("SEQUENCE")?.parse()?;
    let valid_until = std::env::var("VALID_UNTIL")?.parse()?;
    let actions = Actions::new(venue, chain_id)?;
    let shape = Shape::new(&[Level::new(50_000, 20)], &[Level::new(50_000, 20)])?;
    let setup = actions.set_shape(0, 1, &shape);
    let quote = OrderRequest::new(0, "1.085".parse()?, 1, sequence, valid_until);
    let update = actions.bulk_orders(&[quote])?;
    println!("venue={} chain={}", actions.venue(), actions.chain_id());
    println!("set_shape={}", setup.data());
    println!("bulk_orders={}", update.data());
    Ok(())
}
