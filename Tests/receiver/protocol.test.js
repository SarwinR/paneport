// Unit tests for the viewer page's protocol helpers. Run: node --test Tests/receiver/*.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const PaneportProtocol = require(path.join(__dirname, '../../Sources/Paneport/Resources/receiver/protocol.js'))();

function frameMessage({ isKeyframe, capturedMicros, sentMicros, payload }) {
  const buffer = new ArrayBuffer(17 + payload.length);
  const view = new DataView(buffer);
  view.setUint8(0, isKeyframe ? 1 : 0);
  view.setBigUint64(1, BigInt(capturedMicros));
  view.setBigUint64(9, BigInt(sentMicros));
  new Uint8Array(buffer, 17).set(payload);
  return buffer;
}

test('parseFrame reads the header and payload', () => {
  const buffer = frameMessage({ isKeyframe: true, capturedMicros: 1_234_567, sentMicros: 1_240_000, payload: [0, 0, 0, 1, 0x65] });
  const frame = PaneportProtocol.parseFrame(buffer);
  assert.equal(frame.isKeyframe, true);
  assert.equal(frame.capturedMicros, 1_234_567);
  assert.equal(frame.sentMicros, 1_240_000);
  assert.deepEqual([...frame.payload], [0, 0, 0, 1, 0x65]);
});

test('parseFrame rejects messages without a payload', () => {
  assert.equal(PaneportProtocol.parseFrame(new ArrayBuffer(17)), null);
});

test('codecFromAnnexB builds the codec string from the SPS', () => {
  // SPS NAL (type 7) with profile 0x64 (High), constraints 0x00, level 0x2a (4.2)
  const bytes = new Uint8Array([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2a, 0xac, 0, 0, 0, 1, 0x68, 0xee]);
  assert.equal(PaneportProtocol.codecFromAnnexB(bytes), 'avc1.64002a');
});

test('codecFromAnnexB returns null without an SPS', () => {
  assert.equal(PaneportProtocol.codecFromAnnexB(new Uint8Array([0, 0, 0, 1, 0x65, 1, 2, 3, 4])), null);
});

test('parsePointerMove reads position, visibility and time', () => {
  assert.deepEqual(PaneportProtocol.parsePointerMove('m:10.5,20.0,1,123456'),
    { x: 10.5, y: 20, visible: true, micros: 123456 });
  assert.equal(PaneportProtocol.parsePointerMove('m:0.0,0.0,0,1').visible, false);
});

test('clockSample assumes the reply took half the round trip', () => {
  // Sent at local 100 ms, received at 104 ms; the Mac stamped 5000 ms (5,000,000 µs).
  const sample = PaneportProtocol.clockSample('q:100:5000000', 104);
  assert.equal(sample.rtt, 4);
  assert.equal(sample.offset, 5000 - 102);
});

test('bestOffset uses the fastest round trip', () => {
  assert.equal(PaneportProtocol.bestOffset([{ rtt: 5, offset: 1 }, { rtt: 0.3, offset: 2 }, { rtt: 2, offset: 3 }]), 2);
  assert.equal(PaneportProtocol.bestOffset([]), null);
});

test('average and maximum handle empty input', () => {
  assert.equal(PaneportProtocol.average([]), null);
  assert.equal(PaneportProtocol.average([2, 4]), 3);
  assert.equal(PaneportProtocol.maximum([]), null);
  assert.equal(PaneportProtocol.maximum([1, 7, 3]), 7);
});

test('parseHello reads the first message', () => {
  const hello = helloFixture();
  assert.equal(hello.protocol, 1);
  assert.equal(hello.app, '0.4.0');
  assert.equal(PaneportProtocol.parseHello('h:not json'), null);
  assert.equal(PaneportProtocol.parseHello('h:{"app":"x"}'), null);
});

function helloFixture() {
  return PaneportProtocol.parseHello('h:{"protocol":1,"app":"0.4.0","name":"Left","width":1920,"height":1080}');
}

test('VERSION matches the Mac', () => {
  const fs = require('node:fs');
  const swift = fs.readFileSync(path.join(__dirname, '../../Sources/Paneport/Streaming/WireProtocol.swift'), 'utf8');
  const macVersion = Number(swift.match(/static let version = (\d+)/)[1]);
  assert.equal(PaneportProtocol.VERSION, macVersion);
});
