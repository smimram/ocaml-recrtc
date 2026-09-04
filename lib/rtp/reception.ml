type t = {
  clock_rate : int;
  mutable source : int32 option;
  mutable base : int;  (** the first sequence number seen *)
  mutable cycles : int;  (** how often the sequence number has wrapped *)
  mutable highest : int;
  mutable received : int;
  (* What the two were at the last report, since the fraction is over the
     interval and not over the session. *)
  mutable received_prior : int;
  mutable expected_prior : int;
  mutable jitter : float;
  mutable transit : int option;
  mutable last_sr : int32;
  mutable last_sr_at : float option;
}

let create ~clock_rate =
  {
    clock_rate;
    source = None;
    base = 0;
    cycles = 0;
    highest = 0;
    received = 0;
    received_prior = 0;
    expected_prior = 0;
    jitter = 0.;
    transit = None;
    last_sr = 0l;
    last_sr_at = None;
  }

let source t = t.source

(* The difference of two 32-bit quantities, as the signed value it stands for:
   the arrival and the timestamp both wrap, and a wrap must read as a small
   step rather than as four billion ticks. *)
let signed32 difference =
  let difference = difference land 0xFFFFFFFF in
  if difference > 0x7FFFFFFF then difference - 0x100000000 else difference

(* The interarrival jitter of RFC 3550 §6.4.1: the mean deviation of the
   difference between a packet's timestamp spacing and its arrival spacing,
   smoothed by a sixteenth. Both are in the source's own clock, so the arrival
   has to be put into it first. *)
let observe_jitter t ~arrival ~timestamp =
  let arrival = int_of_float (arrival *. float_of_int t.clock_rate) in
  let transit = signed32 (arrival - Int32.to_int timestamp) in
  (match t.transit with
  | Some previous ->
      let d = abs (transit - previous) in
      t.jitter <- t.jitter +. ((float_of_int d -. t.jitter) /. 16.)
  | None -> ());
  t.transit <- Some transit

(* The sequence number's own wrapping, tracked here rather than taken from the
   SRTP layer's: a packet SRTP refused never reached us, and must not count as
   received. *)
let observe_sequence t sequence =
  match t.source with
  | None ->
      t.base <- sequence;
      t.highest <- sequence
  | Some _ ->
      let step = (sequence - t.highest) land 0xffff in
      if step > 0 && step < 0x8000 then begin
        if sequence < t.highest then t.cycles <- t.cycles + 0x10000;
        t.highest <- sequence
      end

let receive ?now t (packet : Packet.t) =
  let now = match now with Some now -> now | None -> Unix.gettimeofday () in
  observe_sequence t packet.sequence;
  if t.source = None then t.source <- Some packet.ssrc;
  t.received <- t.received + 1;
  observe_jitter t ~arrival:now ~timestamp:packet.timestamp

(* A sender report is read for one thing: the timestamp a receiver echoes back,
   and when it arrived. The sender subtracts the two from its own clock and has
   the round trip. *)
let sender_report ?now t ~ntp =
  let now = match now with Some now -> now | None -> Unix.gettimeofday () in
  t.last_sr <- ntp;
  t.last_sr_at <- Some now

let extended_highest t = t.cycles + t.highest
let expected t = extended_highest t - t.base + 1

(* Three octets, signed: more packets can arrive than were expected, since a
   duplicate counts as received (RFC 3550 §A.3). *)
let clamp_lost lost = max (-0x800000) (min 0x7fffff lost)

let report ?now t =
  match t.source with
  | None -> None
  | Some source ->
      let now = match now with Some now -> now | None -> Unix.gettimeofday () in
      let expected = expected t in
      let expected_interval = expected - t.expected_prior in
      let received_interval = t.received - t.received_prior in
      t.expected_prior <- expected;
      t.received_prior <- t.received;
      let lost_interval = expected_interval - received_interval in
      let fraction_lost =
        if expected_interval <= 0 || lost_interval <= 0 then 0
        else lost_interval * 256 / expected_interval
      in
      let delay_since_last_sr =
        match t.last_sr_at with
        | None -> 0l
        (* In units of 1/65536 of a second, which is the low half of an NTP
           timestamp. *)
        | Some at -> Int32.of_float ((now -. at) *. 65536.)
      in
      Some
        {
          Rtcp.source;
          fraction_lost;
          cumulative_lost = clamp_lost (expected - t.received);
          extended_highest = Int32.of_int (extended_highest t land 0xFFFFFFFF);
          jitter = Int32.of_float t.jitter;
          last_sr = t.last_sr;
          delay_since_last_sr;
        }
