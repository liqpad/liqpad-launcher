# External Addresses

## Base mainnet (chain ID 8453)

| Component | Address | Evidence | Status |
| --- | --- | --- | --- |
| B20 factory precompile | `0xB20f000000000000000000000000000000000000` | Official Base B20 docs/base-std constant | Verified |
| B20 activation registry | `0x8453000000000000000000000000000000000001` | Project input; needs independent official page before code | Pending |
| B20 policy registry | `0x8453000000000000000000000000000000000002` | Project input; needs independent official page before code | Pending |
| VVV | `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` | Official Venice docs | Verified |
| Venice staking/sVVV proxy | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` | Official Venice docs | Verified |
| StakingV2 implementation | `0xe37A7920dbc11253ac6d031C29f592f71B348DCA` | Live ERC-1967 implementation slot + verified BaseScan source | Verified 2026-09-06 |
| DIEM | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` | Official Venice docs | Verified token address |
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | Official Uniswap deployments feed | Verified |
| Uniswap v4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` | Official Uniswap deployments feed | Verified |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Official Uniswap v4 deployments | Verified |

### Liqpad deployment


| Component | Address | Transaction | Code hash | BaseScan verified |
| --- | --- | --- | --- | --- |
| LiqpadFactory | `0x312107CE4E6A476edb5F243f456cBbf71356713F` | `0x1dd230a5d1ad7e51c0fc63949c26ed0fcb293a43bf876a532a7c26c57a85f525` | `0x7c4e7856039789e4caf67fa51025b9d8ac389c06758a78903524533986562515` | `YES` |
| LiqpadLaunchHook | `0x3056518d30315c2D6A55eB6FEB5c8F31Ee6D60cC` | `0x2b44fde66fc34e0a79d1feabc2acfa3e6603ea92102618e1be36f3154feaef7b` | `0x096fb5ccaf97248af44862a14b5d70e0a14de53a4acf60e8fd322d4b4c7dd064` | `YES` |
| FeeRouter | `0x9e2c6D47Cea0F6BC63E4A6D6870f713adD5B5FFF` | `0xe42e1b6f7b14f2881a23b10e169c6cc846bcc5ccb10c5007ca6ad505fd885e2a` | `0x56629db19f8f3bf2238a8c1ab9bf393abde4dbca24b280084b573734c20b242a` | `YES` |
| DiemEngine | `0xd44BbD89d490B079ba546e192eb30CB1836F2958` | `0x35f7fa515045c7bb7d41a676cad8f7f46e9f5ff7e0129c853372153a37a33a4c` | `0xf359d14a1e5da22cab075441156f6986faf1c0c95687fc198719f9e18437bbf0` | `YES` |
| VeniceAdapter | `0xBEa3A03c4A76fADdBD77458525a4E36eAE64d746` | `0xbba0970087b6741a26d74ae32919524d30045e5a2f161870b639140704713b9b` | `0x701c20b1863e4415549cdcde185707e30530b834fcdf2662ab4df4aa10f1a7dd` | `YES` |
| HookDeployer | `0xf8FE8D707f9E555A1DBDDcF9C1bb8d791ecD9Ac5` | `0x9c677fd03e010bd537b0638cb8c2f49847a7ea79a525bd2f280bbe6774bb0f11` | `0x4970781c4d61f543f479aefee52b5b3f57dc296cf5f595370bea5b94f7a93cbe` | `YES` |
| LockedPositionVault | `0xa7069F829e9a5790a3c030006faEF5d0006729cc` | `0x0fabe91abe665cccc7fb289c3eda1cec61b5d0835d937f5fbfafc56a01dc8abf` | `0x7d016893427f19e5ee76b7eac03d8ee47516b4a19431153e9ded6b2de1a06ece` | `YES` |

`INITIAL_OWNER`: `0x39F2d898A5C6CdD29ad26180c7b272FBE9E30d83`  
Hook CREATE2 salt: `0x0000000000000000000000000000000000000000000000000000000000008366`

Official Uniswap source: https://developers.uniswap.org/docs/protocols/v4/deployments

Official Base B20 source: https://docs.base.org/build-on-base/issue-rwa/create-an-asset-token
