export type UnlistenFn = () => void;

type ElectronBridge = {
  invoke: (command: string, args?: unknown) => Promise<unknown>;
  listen: (event: string, callback: (payload: unknown) => void) => Promise<() => void>;
  save: (options?: unknown) => Promise<string | null>;
  open: (options?: unknown) => Promise<string | string[] | null>;
};

declare global {
  interface Window {
    qwenpawElectron?: ElectronBridge;
  }
}

const electron = () =>
  typeof window !== "undefined" ? window.qwenpawElectron : undefined;

export function isTauri(): boolean {
  return Boolean(electron());
}

export async function invoke<T>(command: string, args?: unknown): Promise<T> {
  const bridge = electron();
  if (!bridge) throw new Error("Electron bridge is unavailable");
  return (await bridge.invoke(command, args)) as T;
}

export async function listen<T>(
  event: string,
  handler: (event: { payload: T }) => void,
): Promise<UnlistenFn> {
  const bridge = electron();
  if (bridge) {
    return bridge.listen(event, (payload) => handler({ payload: payload as T }));
  }
  throw new Error("Electron bridge is unavailable");
}

export async function save(options?: unknown): Promise<string | null> {
  const bridge = electron();
  if (!bridge) throw new Error("Electron bridge is unavailable");
  return bridge.save(options);
}

export async function open(options?: unknown): Promise<string | string[] | null> {
  const bridge = electron();
  if (!bridge) throw new Error("Electron bridge is unavailable");
  return bridge.open(options);
}
