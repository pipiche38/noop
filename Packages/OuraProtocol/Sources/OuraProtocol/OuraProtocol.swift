import Foundation

/// GATT service and characteristic UUIDs for Oura Ring Gen 3/4/5.
/// Source: Th0rgal/open_oura — independent reverse engineering, clean-room.
public enum OuraGATT {
    /// Primary proprietary service. Scan for this UUID to find a ring (not the charger dock).
    public static let serviceUUID    = "98ED0001-A541-11E4-B6A0-0002A5D5C51B"
    /// Write characteristic — all command writes go here with CBCharacteristicWriteType.withResponse.
    public static let writeCharUUID  = "98ED0002-A541-11E4-B6A0-0002A5D5C51B"
    /// Notify characteristic — subscribe here to receive all response and event packets.
    public static let notifyCharUUID = "98ED0003-A541-11E4-B6A0-0002A5D5C51B"
    /// BLE manufacturer ID in advertisement data identifying a genuine Oura Ring.
    /// Filter advertisements by this value to exclude the charger dock.
    public static let manufacturerID: UInt16 = 0x02B2
    /// Charger dock service UUID — exclude peripherals advertising this service.
    public static let chargerDockServiceUUID = "8BC5888F-C577-4F5D-857F-377354093F13"
}
