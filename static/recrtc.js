// Sends the microphone to the server as a sendonly Opus track. The server is an
// ICE-lite agent, so it answers with a single host candidate and ignores the
// ones we gather: there is nothing to trickle and nothing to wait for.

const button = document.getElementById("record");
const state = document.getElementById("state");
const logElement = document.getElementById("log");

let connection = null;
let stream = null;

function log(message) {
  logElement.textContent += message + "\n";
  logElement.scrollTop = logElement.scrollHeight;
}

async function start() {
  stream = await navigator.mediaDevices.getUserMedia({ audio: true });

  connection = new RTCPeerConnection({ iceServers: [] });
  for (const track of stream.getAudioTracks()) {
    connection.addTransceiver(track, { direction: "sendonly" });
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

  const sdp = await response.text();
  await connection.setRemoteDescription({ type: "answer", sdp });
  log("answered, connecting…");
}

function stop() {
  if (connection) {
    connection.close();
    connection = null;
  }
  if (stream) {
    stream.getTracks().forEach((track) => track.stop());
    stream = null;
  }
  state.textContent = "idle";
  log("stopped");
}

button.onclick = async () => {
  button.disabled = true;
  try {
    if (connection) {
      stop();
      button.textContent = "Record";
    } else {
      await start();
      button.textContent = "Stop";
    }
  } catch (error) {
    log("error: " + error);
    stop();
    button.textContent = "Record";
  }
  button.disabled = false;
};
