// Wire-protocol helpers for the viewer page. See docs/PROTOCOL.md.
//
// Pure functions only, so the page, its background worker and the Node tests in
// Tests/receiver can all use them. The worker gets them via PaneportProtocolFactory.toString().

function PaneportProtocolFactory() {
  /** Must match WireProtocol.version on the Mac; raised on incompatible changes. */
  const VERSION = 1;
  const FRAME_HEADER_SIZE = 17;

  /** "h:<json>", the first message on every connection → { protocol, app, name, width, height }, or null. */
  function parseHello(text) {
    try {
      const hello = JSON.parse(text.slice(2));
      return typeof hello.protocol === 'number' ? hello : null;
    } catch (e) {
      return null;
    }
  }

  /** Splits a binary frame message into its header fields and H.264 payload, or null. */
  function parseFrame(buffer) {
    if (buffer.byteLength <= FRAME_HEADER_SIZE) return null;
    const view = new DataView(buffer);
    return {
      isKeyframe: view.getUint8(0) === 1,
      capturedMicros: Number(view.getBigUint64(1)),
      sentMicros: Number(view.getBigUint64(9)),
      payload: new Uint8Array(buffer, FRAME_HEADER_SIZE),
    };
  }

  /** WebCodecs codec string (avc1.PPCCLL) from the SPS in an Annex B keyframe, or null. */
  function codecFromAnnexB(bytes) {
    for (let i = 0; i + 7 < bytes.length; i++) {
      const isStart = bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1;
      if (isStart && (bytes[i + 3] & 0x1f) === 7) {
        const hex = b => b.toString(16).padStart(2, '0');
        return 'avc1.' + hex(bytes[i + 4]) + hex(bytes[i + 5]) + hex(bytes[i + 6]);
      }
    }
    return null;
  }

  /** "m:x,y,visible,micros" → { x, y, visible, micros }. */
  function parsePointerMove(text) {
    const parts = text.slice(2).split(',');
    return {
      x: parseFloat(parts[0]),
      y: parseFloat(parts[1]),
      visible: parts[2] === '1',
      micros: Number(parts[3]),
    };
  }

  /**
   * One clock-sync sample from a pong "q:<local ms sent>:<Mac µs>" received at `receivedAt`.
   * offset = Mac clock (ms) - local clock (ms), assuming the reply took half the round trip.
   */
  function clockSample(text, receivedAt) {
    const parts = text.split(':');
    const sentAt = parseFloat(parts[1]);
    const macMs = parseFloat(parts[2]) / 1000;
    const rtt = receivedAt - sentAt;
    return { rtt, offset: macMs - (sentAt + rtt / 2) };
  }

  /** The offset from the sample with the shortest round trip, the least affected by queueing. */
  function bestOffset(samples) {
    if (!samples.length) return null;
    return samples.reduce((best, s) => (s.rtt < best.rtt ? s : best)).offset;
  }

  const average = values => (values.length ? values.reduce((a, b) => a + b, 0) / values.length : null);
  const maximum = values => (values.length ? Math.max.apply(null, values) : null);

  return {
    VERSION, FRAME_HEADER_SIZE, parseHello, parseFrame, codecFromAnnexB, parsePointerMove,
    clockSample, bestOffset, average, maximum,
  };
}

if (typeof module === 'object' && module.exports) module.exports = PaneportProtocolFactory;
