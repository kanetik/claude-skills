export type ParkingLotListing = string
export type ParkingLotChecked = { entry: string; handled: string; at: number; isReopening?: boolean }[]

declare module 'claude-code' {
  interface PluginState {
    'parking-lot': { listing: ParkingLotListing; expanded: string[]; checked: ParkingLotChecked; shell: string }
  }
}
