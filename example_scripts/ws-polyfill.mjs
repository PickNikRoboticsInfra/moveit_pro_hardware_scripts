// The Foxglove adapter reads `WebSocket` from the global scope. Node 22+ ships a
// global WebSocket; on Node 18–21 there is none, so install the `ws` class as the
// global before the adapter module evaluates. Import this module FIRST (ESM
// evaluates imports in source order), ahead of `foxglove-ros-adapter`.
import NodeWebSocket from "ws";

if (typeof globalThis.WebSocket === "undefined") {
  globalThis.WebSocket = NodeWebSocket;
}
