import assert from 'node:assert/strict'
import { test } from 'node:test'
import { keccak256, stringToHex } from 'viem'
import { bitsOf, sourceModel, verifySource } from './solidity-source.mjs'

const model = (text) => sourceModel(new Map([['C.sol', text]]))
const constants = (text) =>
  model(`contract C { ${text} }`).constants('C.sol', 'C')
test('evaluates integer syntax, references, denominations and nontruncating casts', () => {
  const c = constants(
    'uint16 constant A=0xff; uint256 constant B=(A | 256) << 2; uint64 public constant D=10 gwei; bytes32 constant E=bytes32(uint256(1)<<208); uint64 constant M=type(uint64).max; uint256 constant X=1e26;',
  )
  assert.deepEqual(
    c.map((x) => x.value),
    [255n, 2044n, 10_000_000_000n, 1n << 208n, (1n << 64n) - 1n, 10n ** 26n],
  )
  assert.equal(c[2].visibility, 'public')
})
test('enum order is source order, not alphabetical', () => {
  assert.deepEqual(
    model('interface C { enum E {None, Z, A} }').enums('C.sol', 'C'),
    { E: ['None', 'Z', 'A'] },
  )
})
test('resolves named imports and NatSpec inheritdoc without attaching earlier comments', () => {
  const m = sourceModel(
    new Map([
      ['lib/L.sol', 'library L { uint8 constant A=3; }'],
      [
        'I.sol',
        'interface I {\n/// @notice getter description\nfunction K() external view returns(uint8);\n}',
      ],
      [
        'C.sol',
        'import {L as Alias} from "./lib/L.sol"; import {I} from "./I.sol";\n/// Wrong contract docs\ncontract C {\n/// @inheritdoc I\nuint8 public constant K=Alias.A;\nuint8 constant N=4;\n/** @dev block description */\nuint8 constant B=5;\n}',
      ],
    ]),
  )
  const c = m.constants('C.sol', 'C')
  assert.equal(c[0].value, 3n)
  assert.equal(c[0].doc, 'getter description')
  assert.equal(c[1].doc, undefined)
  assert.equal(c[2].doc, 'block description')
})
for (const [name, body] of Object.entries({
  cycle: 'uint8 constant A=B; uint8 constant B=A;',
  overflow: 'uint8 constant A=256;',
  truncation: 'uint8 constant A=uint8(256);',
  unknown: 'uint8 constant A=UNKNOWN;',
  division: 'uint8 constant A=4/2;',
  negative: 'uint8 constant A=-1;',
  signed: 'int8 constant A=1;',
  call: 'uint8 constant A=f(1);',
  shift: 'uint256 constant A=1<<999999999;',
  exponent: 'uint256 constant A=1e999999999;',
  malformed: 'uint8 constant A=;',
}))
  test(`fails closed: ${name}`, () => assert.throws(() => constants(body)))
test('ambiguous imports fail instead of resolving by basename or first match', () => {
  const m = sourceModel(
    new Map([
      [
        'C.sol',
        'import {L} from "./a.sol"; import {L} from "./b.sol"; contract C { uint8 constant A=L.X; }',
      ],
      ['a.sol', 'library L {uint8 constant X=1;}'],
      ['b.sol', 'library L {uint8 constant X=2;}'],
    ]),
  )
  assert.throws(() => m.constants('C.sol', 'C'), /ambiguous/)
})
test('missing inheritdoc and namespace references fail', () => {
  assert.throws(() =>
    constants('\n/// @inheritdoc Missing\nuint8 constant A=1;'),
  )
  assert.throws(() => constants('uint8 constant A=Unknown.A;'))
})
test('compiler source hashes reject stale or unbound source', () => {
  const text = 'contract C {}'
  verifySource(text, keccak256(stringToHex(text)), 'C.sol')
  assert.throws(
    () => verifySource(`${text} `, keccak256(stringToHex(text)), 'C.sol'),
    /stale/,
  )
  assert.throws(() => verifySource(text, undefined, 'C.sol'), /stale/)
})
test('integer widths reject malformed and signed types', () => {
  for (const t of ['uint7', 'uint264', 'bytes', 'bytes33', 'int8', 'address'])
    assert.throws(() => bitsOf(t))
  assert.equal(bitsOf('uint'), 256)
  assert.equal(bitsOf('bytes32'), 256)
})
