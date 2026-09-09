// iTantra embedded bridge.
//
// Relays iTantra frames between a BLE GATT link (phone side) and a TCP socket
// (installation side). The bridge never inspects or modifies message payloads:
// it validates only the 6-byte frame header, because a device that parsed
// message contents would need updating every time the protocol grew a field,
// and because the payload may be end-to-end encrypted between the two phones.
//
// Frame header, matching Framing.kt:
//   byte 0..1  magic 'I','T'
//   byte 2     protocol version
//   byte 3..5  payload length, big endian, 24 bits

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <WiFi.h>

namespace {

constexpr char kServiceUuid[] = "6f1d9b30-4c8a-4a4e-9a0f-1b7c5d2e8a11";
constexpr char kRxCharUuid[] = "6f1d9b31-4c8a-4a4e-9a0f-1b7c5d2e8a11";  // phone -> bridge
constexpr char kTxCharUuid[] = "6f1d9b32-4c8a-4a4e-9a0f-1b7c5d2e8a11";  // bridge -> phone

constexpr uint16_t kTcpPort = 47311;
constexpr size_t kHeaderSize = 6;
constexpr size_t kMaxPayload = 2048;   // Matches BleBridgeTransport.MAX_FRAME_BYTES.
constexpr size_t kMaxFrame = kHeaderSize + kMaxPayload;

// Static buffers: heap fragmentation on a long-running relay is a real failure
// mode, and the maximum frame size is known at compile time.
uint8_t g_ble_buffer[kMaxFrame];
size_t g_ble_used = 0;

uint8_t g_tcp_buffer[kMaxFrame];
size_t g_tcp_used = 0;

WiFiServer g_tcp_server(kTcpPort);
WiFiClient g_tcp_client;

BLECharacteristic* g_tx_characteristic = nullptr;
bool g_ble_connected = false;
// Conservative default until the ATT MTU is negotiated upward.
size_t g_ble_chunk = 20;

size_t declared_payload_length(const uint8_t* buffer) {
  return (static_cast<size_t>(buffer[3]) << 16) |
         (static_cast<size_t>(buffer[4]) << 8) |
         static_cast<size_t>(buffer[5]);
}

bool header_is_plausible(const uint8_t* buffer, size_t used) {
  if (used < 3) return true;  // Not enough to judge yet.
  if (buffer[0] != 'I' || buffer[1] != 'T') return false;
  if (buffer[2] != ITANTRA_PROTOCOL_VERSION) return false;
  if (used < kHeaderSize) return true;
  return declared_payload_length(buffer) <= kMaxPayload;
}

// Drops one byte and retries, so a corrupted stream resynchronises on the next
// genuine 'I','T' rather than staying stuck forever.
void resynchronise(uint8_t* buffer, size_t& used) {
  if (used == 0) return;
  memmove(buffer, buffer + 1, used - 1);
  used -= 1;
}

void send_to_phone(const uint8_t* frame, size_t length) {
  if (!g_ble_connected || g_tx_characteristic == nullptr) return;
  size_t offset = 0;
  while (offset < length) {
    const size_t chunk = min(g_ble_chunk, length - offset);
    g_tx_characteristic->setValue(const_cast<uint8_t*>(frame + offset), chunk);
    g_tx_characteristic->notify();
    offset += chunk;
    // BLE notifications are rate limited by the connection interval; without
    // this yield the stack drops packets under sustained load.
    delay(4);
  }
}

void send_to_socket(const uint8_t* frame, size_t length) {
  if (!g_tcp_client || !g_tcp_client.connected()) return;
  g_tcp_client.write(frame, length);
  g_tcp_client.flush();
}

// Extracts every complete frame from a buffer and hands it to `forward`.
void drain(uint8_t* buffer, size_t& used, void (*forward)(const uint8_t*, size_t)) {
  for (;;) {
    if (!header_is_plausible(buffer, used)) {
      resynchronise(buffer, used);
      continue;
    }
    if (used < kHeaderSize) return;
    const size_t payload = declared_payload_length(buffer);
    const size_t total = kHeaderSize + payload;
    if (used < total) return;
    forward(buffer, total);
    memmove(buffer, buffer + total, used - total);
    used -= total;
  }
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    g_ble_connected = true;
    Serial.println("[ble] phone connected");
  }

  void onDisconnect(BLEServer* server) override {
    g_ble_connected = false;
    g_ble_used = 0;
    Serial.println("[ble] phone disconnected, advertising again");
    server->getAdvertising()->start();
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    if (g_ble_used + value.size() > kMaxFrame) {
      // A peer that overruns the buffer is either broken or hostile; discard
      // and resynchronise rather than growing memory.
      Serial.println("[ble] overrun, resetting reassembly");
      g_ble_used = 0;
      return;
    }
    memcpy(g_ble_buffer + g_ble_used, value.data(), value.size());
    g_ble_used += value.size();
    drain(g_ble_buffer, g_ble_used, send_to_socket);
  }
};

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("[bridge] iTantra BLE/TCP relay starting");

  // Soft access point, not a station: the bridge must work with no router and
  // no internet, which is the whole point of the deployment scenario.
  WiFi.mode(WIFI_AP);
  WiFi.softAP("iTantra-Bridge", "itantra-local");
  Serial.print("[wifi] access point at ");
  Serial.println(WiFi.softAPIP());
  g_tcp_server.begin();
  g_tcp_server.setNoDelay(true);

  BLEDevice::init("iTantra Bridge");
  BLEDevice::setMTU(185);  // Request a larger ATT MTU; the phone may lower it.
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(kServiceUuid);

  BLECharacteristic* rx = service->createCharacteristic(
      kRxCharUuid, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCallbacks());

  g_tx_characteristic = service->createCharacteristic(
      kTxCharUuid, BLECharacteristic::PROPERTY_NOTIFY);
  g_tx_characteristic->addDescriptor(new BLE2902());

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  advertising->start();
  Serial.println("[ble] advertising");
}

void loop() {
  if (!g_tcp_client || !g_tcp_client.connected()) {
    WiFiClient incoming = g_tcp_server.available();
    if (incoming) {
      g_tcp_client = incoming;
      g_tcp_used = 0;
      Serial.println("[tcp] peer connected");
    }
  }

  while (g_tcp_client && g_tcp_client.available() > 0) {
    if (g_tcp_used >= kMaxFrame) {
      Serial.println("[tcp] overrun, resetting reassembly");
      g_tcp_used = 0;
    }
    const int read = g_tcp_client.read(g_tcp_buffer + g_tcp_used, kMaxFrame - g_tcp_used);
    if (read <= 0) break;
    g_tcp_used += static_cast<size_t>(read);
    drain(g_tcp_buffer, g_tcp_used, send_to_phone);
  }

  delay(2);  // Keeps the idle current low; the relay is not latency critical.
}
