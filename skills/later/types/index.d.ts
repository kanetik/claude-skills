export type LaterListing = string

declare module 'claude-code' {
  interface PluginState {
    later: { listing: LaterListing }
  }
}
