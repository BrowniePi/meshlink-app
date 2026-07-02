import CoreBluetooth
import Flutter

/// Native BLE peripheral (GATT server) for MeshLink plus CoreBluetooth state
/// restoration, bridged to Flutter over the `meshlink/ble_peripheral`
/// method channel.
///
/// Role split for the Phase 1 link: the central role (scan/connect/write)
/// lives in Dart via flutter_blue_plus; the peripheral role must be native
/// because flutter_blue_plus is central-only. Each phone runs both roles, so
/// either of two nearby phones can initiate the link.
///
/// State restoration: the peripheral manager is created with
/// CBPeripheralManagerOptionRestoreIdentifierKey so iOS relaunches the app
/// for BLE events after it is killed, per the bluetooth-peripheral
/// background mode. (The central side's restoration is enabled from Dart via
/// FlutterBluePlus.setOptions(restoreState: true), which sets
/// CBCentralManagerOptionRestoreIdentifierKey on the plugin's manager.)
class BleManager: NSObject, CBPeripheralManagerDelegate {
    static let shared = BleManager()

    // MeshLink GATT layout ("MESHLINK" in the UUID base):
    //   RX characteristic — remote centrals write inbound packets to us.
    //   TX characteristic — we notify outbound packets to subscribed centrals.
    static let serviceUUID = CBUUID(string: "4D455348-4C49-4E4B-0001-000000000001")
    static let rxCharUUID = CBUUID(string: "4D455348-4C49-4E4B-0002-000000000002")
    static let txCharUUID = CBUUID(string: "4D455348-4C49-4E4B-0003-000000000003")

    private var peripheralManager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var channel: FlutterMethodChannel?
    private var subscribedCentrals: [String: CBCentral] = [:]
    private var pendingNotifies: [(central: CBCentral, data: Data)] = []
    private var shouldAdvertise = false

    func attach(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "meshlink/ble_peripheral", binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "start":
                self.start()
                result(nil)
            case "stop":
                self.stop()
                result(nil)
            case "notify":
                guard
                    let args = call.arguments as? [String: Any],
                    let centralId = args["centralId"] as? String,
                    let data = args["data"] as? FlutterStandardTypedData
                else {
                    result(FlutterError(code: "bad_args", message: "notify needs centralId + data", details: nil))
                    return
                }
                self.notify(centralId: centralId, data: data.data)
                result(nil)
            case "listCentrals":
                result(Array(self.subscribedCentrals.keys))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func start() {
        shouldAdvertise = true
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: nil,
                options: [CBPeripheralManagerOptionRestoreIdentifierKey: "meshlink.peripheral"])
        } else if peripheralManager?.state == .poweredOn {
            publishServiceAndAdvertise()
        }
    }

    private func stop() {
        shouldAdvertise = false
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        subscribedCentrals.removeAll()
        pendingNotifies.removeAll()
    }

    private func publishServiceAndAdvertise() {
        guard let manager = peripheralManager, manager.state == .poweredOn else { return }

        let rx = CBMutableCharacteristic(
            type: BleManager.rxCharUUID,
            properties: [.writeWithoutResponse, .write],
            value: nil,
            permissions: [.writeable])
        let tx = CBMutableCharacteristic(
            type: BleManager.txCharUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable])
        txCharacteristic = tx

        let service = CBMutableService(type: BleManager.serviceUUID, primary: true)
        service.characteristics = [rx, tx]
        manager.removeAllServices()
        manager.add(service)
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleManager.serviceUUID]
        ])
    }

    private func notify(centralId: String, data: Data) {
        guard
            let manager = peripheralManager,
            let tx = txCharacteristic,
            let central = subscribedCentrals[centralId]
        else { return }
        let sent = manager.updateValue(data, for: tx, onSubscribedCentrals: [central])
        if !sent {
            // Transmit queue full — retry from peripheralManagerIsReady.
            pendingNotifies.append((central, data))
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn && shouldAdvertise {
            publishServiceAndAdvertise()
        }
        channel?.invokeMethod("onStateChanged", arguments: peripheral.state.rawValue)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // Relaunched by iOS after being killed: republish on next poweredOn.
        shouldAdvertise = true
        channel?.invokeMethod("onRestored", arguments: nil)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == BleManager.rxCharUUID else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                continue
            }
            if let data = request.value {
                channel?.invokeMethod("onWrite", arguments: [
                    "centralId": request.central.identifier.uuidString,
                    "data": FlutterStandardTypedData(bytes: data),
                ])
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == BleManager.txCharUUID else { return }
        let id = central.identifier.uuidString
        subscribedCentrals[id] = central
        channel?.invokeMethod("onSubscribe", arguments: id)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == BleManager.txCharUUID else { return }
        let id = central.identifier.uuidString
        subscribedCentrals.removeValue(forKey: id)
        pendingNotifies.removeAll { $0.central.identifier.uuidString == id }
        channel?.invokeMethod("onUnsubscribe", arguments: id)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let tx = txCharacteristic else { return }
        let queued = pendingNotifies
        pendingNotifies.removeAll()
        for item in queued {
            let sent = peripheral.updateValue(item.data, for: tx, onSubscribedCentrals: [item.central])
            if !sent {
                pendingNotifies.append(item)
                break
            }
        }
    }
}
