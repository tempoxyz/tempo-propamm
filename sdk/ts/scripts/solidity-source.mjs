// Parser-backed, deliberately narrow source model for SDK constants, enums and NatSpec.
// Unsupported syntax/resolution fails rather than guessing Solidity semantics.

import { posix } from 'node:path'
import { parse } from '@solidity-parser/parser'
import { keccak256, stringToHex } from 'viem'

export function verifySource(text, hash, path) {
  if (!hash || keccak256(stringToHex(text)) !== hash)
    throw new Error(`stale compiler source ${path}: rebuild contracts`)
}

export function bitsOf(name) {
  const m = /^(uint|bytes)(\d*)$/.exec(name)
  if (!m || (m[1] === 'bytes' && !m[2]))
    throw new Error(`unsupported type ${name}`)
  const bits = m[1] === 'bytes' ? Number(m[2]) * 8 : Number(m[2] || 256)
  if (bits < 8 || bits > 256 || bits % 8)
    throw new Error(`unsupported type ${name}`)
  return bits
}
const units = {
  wei: 1n,
  gwei: 10n ** 9n,
  ether: 10n ** 18n,
  seconds: 1n,
  minutes: 60n,
  hours: 3600n,
  days: 86400n,
  weeks: 604800n,
}

export function sourceModel(sources) {
  const parsed = new Map()
  function unit(file) {
    if (!sources.has(file)) throw new Error(`missing source ${file}`)
    if (!parsed.has(file))
      parsed.set(file, parse(sources.get(file), { range: true }))
    return parsed.get(file)
  }
  function contract(file, name) {
    const matches = unit(file).children.filter(
      (n) => n.type === 'ContractDefinition' && n.name === name,
    )
    if (matches.length !== 1)
      throw new Error(`missing or ambiguous contract ${file}:${name}`)
    return { file, node: matches[0] }
  }
  function resolveContract(ctx, name) {
    const candidates = []
    if (
      unit(ctx.file).children.some(
        (n) => n.type === 'ContractDefinition' && n.name === name,
      )
    )
      candidates.push(contract(ctx.file, name))
    for (const imp of unit(ctx.file).children.filter(
      (n) => n.type === 'ImportDirective',
    )) {
      const path = imp.path.startsWith('.')
        ? posix.normalize(posix.join(posix.dirname(ctx.file), imp.path))
        : imp.path
      if (imp.symbolAliases) {
        for (const [original, alias] of imp.symbolAliases)
          if ((alias || original) === name)
            candidates.push(contract(path, original))
      } else if (
        !imp.unitAlias &&
        sources.has(path) &&
        unit(path).children.some(
          (n) => n.type === 'ContractDefinition' && n.name === name,
        )
      ) {
        candidates.push(contract(path, name))
      }
    }
    if (candidates.length !== 1)
      throw new Error(`unresolved or ambiguous contract ${name} in ${ctx.file}`)
    return candidates[0]
  }
  function declarations(ctx) {
    return ctx.node.subNodes
      .filter((n) => n.type === 'StateVariableDeclaration')
      .flatMap((n) => n.variables)
  }
  function declaration(ctx, name) {
    const found = declarations(ctx).filter(
      (n) => n.name === name && n.isDeclaredConst,
    )
    if (found.length !== 1)
      throw new Error(`unsupported identifier ${ctx.node.name}.${name}`)
    return found[0]
  }
  function doc(ctx, node, active = new Set()) {
    if (active.has(node)) throw new Error('cyclic inheritdoc')
    active = new Set(active).add(node)
    const before = sources.get(ctx.file).slice(0, node.range[0])
    const lines = before.match(
      /(?:^|\n)((?:[ \t]*\/\/\/[^\n]*\n)*[ \t]*\/\/\/[^\n]*)\s*$/,
    )
    const block = before.match(/\/\*\*((?:(?!\*\/)[\s\S])*)\*\/\s*$/)
    let text
    if (lines)
      text = lines[1]
        .trimEnd()
        .split('\n')
        .map((l) => l.replace(/^\s*\/\/\/ ?/, ''))
        .join('\n')
    else if (block && !block[1].includes('*/'))
      text = block[1]
        .split('\n')
        .map((l) => l.replace(/^\s*\* ?/, '').trim())
        .join('\n')
        .trim()
    if (text === undefined) return undefined
    return text
      .split('\n')
      .flatMap((raw) => {
        const line = raw.trim()
        const inherit = /^@inheritdoc (\w+)$/.exec(line)
        if (!inherit) return [line.replace(/^@(notice|dev) /, '')]
        const parent = resolveContract(ctx, inherit[1])
        const getters = parent.node.subNodes.filter(
          (n) => n.type === 'FunctionDefinition' && n.name === node.name,
        )
        if (getters.length !== 1)
          throw new Error(`ambiguous or missing inheritdoc getter ${node.name}`)
        const inherited = doc(parent, getters[0], active)
        if (inherited === undefined)
          throw new Error(`missing inheritdoc for ${node.name}`)
        return inherited.split('\n')
      })
      .join('\n')
  }
  function bound(v) {
    if (v < 0n || v.toString(2).length > 4096)
      throw new Error('constant expression out of range')
    return v
  }
  function value(ctx, decl, active = new Set()) {
    if (active.has(decl)) throw new Error(`cyclic constant ${decl.name}`)
    if (decl.typeName.type !== 'ElementaryTypeName')
      throw new Error('unsupported constant type')
    const v = evaluate(ctx, decl.expression, new Set(active).add(decl))
    if (v >= 1n << BigInt(bitsOf(decl.typeName.name)))
      throw new Error(`${decl.name} does not fit ${decl.typeName.name}`)
    return v
  }
  function evaluate(ctx, n, active) {
    if (!n) throw new Error('missing constant initializer')
    switch (n.type) {
      case 'NumberLiteral': {
        const raw = n.number.replaceAll('_', '')
        const exp = /^(\d+)e(\d+)$/.exec(raw)
        let v
        if (exp) {
          if (BigInt(exp[2]) > 1000n) throw new Error('exponent out of range')
          v = BigInt(exp[1]) * 10n ** BigInt(exp[2])
        } else if (/^(0x[0-9a-fA-F]+|\d+)$/.test(raw)) v = BigInt(raw)
        else throw new Error(`unsupported number ${raw}`)
        if (n.subdenomination) {
          if (units[n.subdenomination] === undefined)
            throw new Error('unsupported denomination')
          v *= units[n.subdenomination]
        }
        return bound(v)
      }
      case 'TupleExpression':
        if (n.components.length !== 1 || !n.components[0])
          throw new Error('unsupported tuple')
        return evaluate(ctx, n.components[0], active)
      case 'Identifier':
        return value(ctx, declaration(ctx, n.name), active)
      case 'BinaryOperation': {
        const l = evaluate(ctx, n.left, active),
          r = evaluate(ctx, n.right, active)
        if (['<<', '>>', '**'].includes(n.operator) && r > 4096n)
          throw new Error('shift or exponent out of range')
        switch (n.operator) {
          case '<<':
            return bound(l << r)
          case '>>':
            return bound(l >> r)
          case '|':
            return bound(l | r)
          case '&':
            return bound(l & r)
          case '*':
            return bound(l * r)
          case '+':
            return bound(l + r)
          case '**':
            return bound(l ** r)
          default:
            throw new Error(`unsupported operator ${n.operator}`)
        }
      }
      case 'MemberAccess': {
        const e = n.expression
        if (
          n.memberName === 'max' &&
          e.type === 'FunctionCall' &&
          e.expression.name === 'type' &&
          e.arguments.length === 1 &&
          e.arguments[0].type === 'ElementaryTypeName' &&
          e.arguments[0].name.startsWith('uint')
        )
          return (1n << BigInt(bitsOf(e.arguments[0].name))) - 1n
        if (e.type !== 'Identifier')
          throw new Error('unsupported member access')
        const target = resolveContract(ctx, e.name)
        return value(target, declaration(target, n.memberName), active)
      }
      case 'FunctionCall': {
        if (
          n.expression.type !== 'ElementaryTypeName' ||
          n.arguments.length !== 1
        )
          throw new Error('unsupported function call')
        const v = evaluate(ctx, n.arguments[0], active)
        if (v >= 1n << BigInt(bitsOf(n.expression.name)))
          throw new Error('conversion truncates')
        return v
      }
      default:
        throw new Error(`unsupported expression ${n.type}`)
    }
  }
  return {
    enums(file, name) {
      return Object.fromEntries(
        contract(file, name)
          .node.subNodes.filter((n) => n.type === 'EnumDefinition')
          .map((n) => [n.name, n.members.map((m) => m.name)]),
      )
    },
    constants(file, name) {
      const ctx = contract(file, name)
      return declarations(ctx)
        .filter((n) => n.isDeclaredConst)
        .map((n) => ({
          name: n.name,
          type: n.typeName.name,
          value: value(ctx, n),
          visibility: n.visibility,
          doc: doc(ctx, n),
        }))
    },
  }
}
