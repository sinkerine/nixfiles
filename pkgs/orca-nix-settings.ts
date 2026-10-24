import { existsSync, readFileSync } from 'node:fs'
import { isDeepStrictEqual } from 'node:util'

type Settings = Record<string, unknown>

function isObject(value: unknown): value is Settings {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Merge a separate declarative input; never modify legacy profile JSON or SQLite directly. */
export function mergeNixSettings<T extends object>(settings: T): T {
  const path = process.env.ORCA_NIX_SETTINGS_FILE
  if (!path || !existsSync(path)) return settings
  const declared: unknown = JSON.parse(readFileSync(path, 'utf8'))
  if (!isObject(declared)) throw new Error('Orca Nix settings must be a JSON object')
  const merge = (current: unknown, incoming: unknown): unknown => {
    if (!isObject(incoming)) return incoming
    const result: Settings = isObject(current) ? { ...current } : {}
    for (const [key, value] of Object.entries(incoming)) {
      if (key === '__proto__' || key === 'constructor' || key === 'prototype') {
        throw new Error(`Invalid Orca Nix settings key: ${key}`)
      }
      Object.defineProperty(result, key, {
        value: merge(result[key], value), enumerable: true, writable: true, configurable: true
      })
    }
    return result
  }
  const merged = merge(settings, declared) as T
  return isDeepStrictEqual(settings, merged) ? settings : merged
}
