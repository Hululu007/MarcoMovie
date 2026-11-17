export interface DynamicMethodCallLike {
  args?: unknown;
  argument?: (key: string) => unknown;
  hasArgument?: (key: string) => boolean;
}

export function extractMethodArg(call: unknown, key: string): unknown {
  if (call === null || call === undefined || typeof call !== 'object') {
    return undefined;
  }
  const typed = call as DynamicMethodCallLike;
  if (typeof typed.argument === 'function') {
    try {
      if (typeof typed.hasArgument === 'function' && !typed.hasArgument(key)) {
        // Fall through to raw args inspection in case a custom codec omits hasArgument.
      } else {
        const direct = typed.argument(key);
        if (direct !== undefined) {
          return direct;
        }
      }
    } catch (_err) {
      // Fall back to raw args inspection when call.args is null/primitive.
    }
  }
  const rawArgs = typed.args;
  if (rawArgs === null || rawArgs === undefined) {
    return undefined;
  }
  if (rawArgs instanceof Map) {
    return rawArgs.get(key);
  }
  if (typeof rawArgs === 'object') {
    return (rawArgs as Record<string, unknown>)[key];
  }
  return undefined;
}

export function recordFromDynamicObject(raw: unknown): Record<string, Object> {
  const out: Record<string, Object> = {};
  if (raw === null || raw === undefined) {
    return out;
  }
  if (raw instanceof Map) {
    raw.forEach((v: unknown, k: unknown) => {
      if (v !== undefined && v !== null) {
        out[String(k)] = v as Object;
      }
    });
    return out;
  }
  if (typeof raw === 'object') {
    const src = raw as Record<string, unknown>;
    const keys = Object.keys(src);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = src[k];
      if (v !== undefined && v !== null) {
        out[k] = v as Object;
      }
    }
  }
  return out;
}

export function stringRecordFromDynamicObject(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === null || raw === undefined) {
    return out;
  }
  if (raw instanceof Map) {
    raw.forEach((v: unknown, k: unknown) => {
      const key = String(k ?? '').trim();
      if (key.length > 0 && v !== undefined && v !== null) {
        out[key] = String(v);
      }
    });
    return out;
  }
  if (typeof raw === 'object') {
    const src = raw as Record<string, unknown>;
    const keys = Object.keys(src);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i].trim();
      const v = src[keys[i]];
      if (key.length > 0 && v !== undefined && v !== null) {
        out[key] = String(v);
      }
    }
  }
  return out;
}

export function stringArrayFromDynamicValue(raw: unknown): Array<string> {
  const list: Array<string> = [];
  if (Array.isArray(raw)) {
    for (let i = 0; i < raw.length; i++) {
      list.push(String(raw[i] ?? ''));
    }
  }
  return list;
}
