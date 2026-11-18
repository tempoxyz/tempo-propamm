//! Read a verified venue; no keys, simulation, or broadcasting.
use propamm_sdk::{
    Info,
    alloy::{
        providers::{Provider, ProviderBuilder},
        rpc::types::BlockId,
    },
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let provider = ProviderBuilder::new().connect_http(std::env::var("RPC_URL")?.parse()?);
    let info = Info::connect(
        provider,
        std::env::var("VENUE")?.parse()?,
        std::env::var("CHAIN_ID")?.parse()?,
        std::env::var("FACTORY")?.parse()?,
    )
    .await?;
    let block = BlockId::number(info.provider().get_block_number().await?);
    println!("{:?}", info.venue_state(block).await?);
    let markets = info.meta(block).await?;
    let pairs: Vec<_> = markets.iter().map(|i| i.pair_index).collect();
    for quote in info.orders(&pairs, block).await? {
        println!("{quote:?}");
    }
    Ok(())
}
