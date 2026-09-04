(** The Opus table of contents, which is what the granule positions count. *)

open Testlib

let run () =
  suite "opus";
  (* Table-of-contents parsing: configuration 15 is 20 ms, and the two low bits
     say how many frames follow (RFC 6716 §3.1). *)
  check "one 20 ms frame" (Oggopus.Writer.samples "\x78" = 960);
  check "two 20 ms frames" (Oggopus.Writer.samples "\x79" = 1920);
  check "a 10 ms frame" (Oggopus.Writer.samples "\x70" = 480);
  check "an arbitrary number of frames"
    (Oggopus.Writer.samples "\x7B\x03" = 3 * 960);
  check "a 2.5 ms CELT frame" (Oggopus.Writer.samples "\x80" = 120);
  check "an empty packet" (Oggopus.Writer.samples "" = 0)

let () =
  run ();
  exit_status ()
