// Sends the microphone, and optionally the camera, to the server as sendonly
// tracks. The server is an ICE-lite agent, so it answers with host candidates
// of its own and ignores the ones we gather: there is nothing to trickle and
// nothing to wait for.

const button = document.getElementById("record");
const state = document.getElementById("state");
const logElement = document.getElementById("log");
const withVideo = document.getElementById("video");
const preview = document.getElementById("preview");

let connection = null;
let stream = null;
let session = null;

const SESSION_HEADER = "X-Recrtc-Session";
const parameters = new URLSearchParams(location.search);

function log(message) {
  logElement.textContent += message + "\n";
  logElement.scrollTop = logElement.scrollHeight;
}

async function start() {
  const video = withVideo.checked;
  stream = await navigator.mediaDevices.getUserMedia({ audio: true, video });
  if (video) {
    preview.srcObject = stream;
    preview.hidden = false;
  }

  connection = new RTCPeerConnection({ iceServers: [] });
  // Order matters only in that the answer keeps it; the server tells the two
  // apart by payload type, not by position.
  for (const track of stream.getTracks()) {
    const transceiver = connection.addTransceiver(track, { direction: "sendonly" });
    if (track.kind === "video") prefer(transceiver);
  }

  connection.oniceconnectionstatechange = () => {
    if (!connection) return;
    log("ICE: " + connection.iceConnectionState);
  };
  connection.onconnectionstatechange = () => {
    if (!connection) return;
    state.textContent = connection.connectionState;
    log("connection: " + connection.connectionState);
  };

  const offer = await connection.createOffer();
  await connection.setLocalDescription(offer);

  const response = await fetch("/webrtc/offer", {
    method: "POST",
    headers: { "Content-Type": "application/sdp" },
    body: offer.sdp,
  });
  if (!response.ok) throw new Error(await response.text());
  session = response.headers.get(SESSION_HEADER);

  const sdp = await response.text();
  await connection.setRemoteDescription({ type: "answer", sdp });
  log("answered, connecting…");
}

// The browser offers every video codec it has and the server takes the first
// it knows, which is VP8. Narrowing the offer is the only way to reach the
// other path: http://localhost:8080/?autostart&codec=h264
function prefer(transceiver) {
  const wanted = parameters.get("codec");
  if (!wanted || !transceiver.setCodecPreferences) return;
  const { codecs } = RTCRtpSender.getCapabilities("video");
  const matching = codecs.filter(
    (codec) => codec.mimeType.toLowerCase() === "video/" + wanted.toLowerCase(),
  );
  if (matching.length === 0) throw new Error("no such video codec: " + wanted);
  // The retransmission and error-correction types are kept: dropping them
  // changes more than the codec.
  const auxiliary = codecs.filter((codec) =>
    /\/(rtx|red|ulpfec|flexfec)/i.test(codec.mimeType),
  );
  transceiver.setCodecPreferences(matching.concat(auxiliary));
  log("offering " + wanted + " only");
}

function stop() {
  // Tell the server to close the recording now, rather than leaving it to
  // notice that the checks have stopped coming.
  if (session) {
    fetch("/webrtc/stop", { method: "POST", headers: { [SESSION_HEADER]: session } });
    session = null;
  }
  if (connection) {
    connection.close();
    connection = null;
  }
  if (stream) {
    stream.getTracks().forEach((track) => track.stop());
    stream = null;
  }
  preview.srcObject = null;
  preview.hidden = true;
  state.textContent = "idle";
  log("stopped");
}

button.onclick = async () => {
  button.disabled = true;
  try {
    if (connection) {
      stop();
      button.textContent = "Record";
      withVideo.disabled = false;
    } else {
      withVideo.disabled = true;
      await start();
      button.textContent = "Stop";
    }
  } catch (error) {
    log("error: " + error);
    stop();
    button.textContent = "Record";
    withVideo.disabled = false;
  }
  button.disabled = false;
};

// Lets a headless browser exercise the whole path without a click:
// http://localhost:8080/?autostart, with ?autostart&audio for audio alone.
if (parameters.has("autostart")) {
  withVideo.checked = !parameters.has("audio");
  button.click();
}
