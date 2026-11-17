// The panel ↔ worker contract: src/panel.tsx and worker/main.mjs both follow it.
export {}

export type SpriteRow = {
  name: string
  org: string
  url: string | null
  /** running, warm or cold from the Sprites API; gone when its org lists fine without it;
   *  unknown when the Sprites API could not be asked. */
  status: string
  /** The workspace it was made for. */
  workspace: string | null
  createdAt: number | null
}

declare module 'orca' {
  // oxlint-disable-next-line typescript/consistent-type-definitions -- declaration merging needs an interface
  interface PluginRequests {
    /** Every Sprite this computer created, with its state. */
    'sprites.list': { input: Record<string, never>; output: { sprites: SpriteRow[]; error: string | null; checkpointing: string[] } }
    /** Starts a checkpoint; `sprites.checkpointed` reports the result. False when one is running. */
    'sprites.checkpoint': { input: { name: string }; output: { started: boolean; run: number | null } }
    /** Drops a Sprite that no longer exists from the list. */
    'sprites.forget': { input: { name: string }; output: { forgotten: boolean } }
  }
  // oxlint-disable-next-line typescript/consistent-type-definitions -- declaration merging needs an interface
  interface PluginPanelEvents {
    /** A checkpoint finished. */
    'sprites.checkpointed': { name: string; run: number; ok: boolean; message: string }
  }
}
