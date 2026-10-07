export type ParkingLotListing = string

declare module 'claude-code' {
  interface PluginState {
    'parking-lot': { listing: ParkingLotListing; expanded: string[] }
  }
}
