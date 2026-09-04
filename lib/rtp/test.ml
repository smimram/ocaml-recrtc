(** The RTP header parser and the jitter buffer; the payload formats are in
    the [Test_vp8], [Test_vp9] and [Test_h264] modules beside this one. *)

open Testlib

(* A packet with two CSRCs and a header extension, so that the payload offset
   depends on both. *)
let packet =
  hex
    ("92" (* version 2, extension, 2 CSRCs *) ^ "EF" (* marker, payload type 111 *)
   ^ "1234" (* sequence *) ^ "0000C000" (* timestamp *) ^ "DEADBEEF" (* SSRC *)
   ^ "00000001" ^ "00000002" (* CSRCs *)
   ^ "BEDE0001" ^ "10AABBCC" (* one word of header extension *)
   ^ "78797A" (* payload *))

let run () =
  suite "rtp";

  let p = Rtp.Packet.parse packet in
  check "payload type" (p.payload_type = 111);
  check "marker" p.marker;
  check "sequence" (p.sequence = 0x1234);
  check "timestamp" (p.timestamp = 0xC000l);
  check "ssrc" (p.ssrc = 0xDEADBEEFl);
  check "contributing sources" (p.csrc = [ 1l; 2l ]);
  check "header extension" (p.extension = Some (0xBEDE, hex "10AABBCC"));
  check_string "payload" ~expected:(hex "78797A") p.payload;
  check "header length" (p.header_length = 12 + 8 + 8);
  check "not RTCP" (not (Rtp.Packet.is_rtcp packet));
  (* A receiver report: payload type 201 with the marker bit set reads as 73. *)
  check "a receiver report is RTCP" (Rtp.Packet.is_rtcp (hex "81C90007"));

  suite "reorder";
  let buffer = Rtp.Reorder.create ~depth:3 () in
  let push sequence = Rtp.Reorder.push buffer sequence sequence in
  check "the first packet passes straight through" (push 100 = [ 100 ]);
  check "and the next" (push 101 = [ 101 ]);
  check "a gap is held back" (push 103 = []);
  check "and released when it fills" (push 102 = [ 102; 103 ]);
  check "a duplicate is dropped" (push 102 = []);
  check "a late packet is dropped" (push 99 = []);
  (* A packet that never arrives must not stall the stream: once the buffer is
     deeper than its limit, it moves on. *)
  check "waiting for 104" (push 105 = []);
  check "still waiting" (push 106 = []);
  check "still waiting, buffer filling" (push 107 = []);
  check "giving up on 104" (push 108 = [ 105; 106; 107; 108 ]);
  check "the loss is counted" (Rtp.Reorder.lost buffer = 1);
  check "and the stream carries on" (push 109 = [ 109 ]);

  suite "rtcp";
  (* RFC 4585 §6.3.1: version 2, feedback message type 1, payload type 206,
     two words of payload after the header word. *)
  check_string "a picture loss indication"
    ~expected:(hex "81CE0002 DEADBEEF 0000002A")
    (Rtp.Rtcp.pli ~sender:0xDEADBEEFl ~media:42l);
  check "which reads as RTCP" (Rtp.Packet.is_rtcp (Rtp.Rtcp.pli ~sender:1l ~media:2l));
  ()

let () =
  run ();
  Test_vp8.run ();
  Test_vp9.run ();
  Test_h264.run ();
  exit_status ()
